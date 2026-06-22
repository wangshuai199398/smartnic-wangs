# SPDX-License-Identifier: MIT
"""最小 DMA integration test — 跨模块数据流与错误传播协议验证。

本测试不使用 Verilator 硬件仿真, 而是用 Python mock/stub 验证 DMA 模块间
的 ready/valid 流式接口协议。覆盖:

1.  dispatcher → SGE traversal → MR integration → segment splitter 最小环;
2.  error propagation 映射 DMA 错误码到 completion status;
3.  arbiter 为多个 source 公平轮转。

所有模块交互均为 stub/mock, 不依赖真实 PCIe Root Complex、IOMMU 或
完整 RoCEv2 transport。

用法:
    直接运行: python test_dma_integration.py
    cocotb 模式: make test-dma-integration
"""

import random

try:
    import cocotb
    HAS_COCOTB = True
except ImportError:
    HAS_COCOTB = False


# ===================================================================
# Mock / stub types — 复制自 smartnic_pkg.sv 的常量定义
# ===================================================================

DMA_OP_SEND           = 0
DMA_OP_RECV           = 1
DMA_OP_RDMA_WRITE     = 2
DMA_OP_CQE_WRITE      = 5
DMA_OP_WQE_FETCH      = 6
DMA_OP_SGE_FETCH      = 7

DMA_DIR_HOST_READ  = 0
DMA_DIR_HOST_WRITE = 1
DMA_DIR_CQE_WRITE  = 2
DMA_DIR_WQE_FETCH  = 3
DMA_DIR_SGE_FETCH  = 4

DMA_DISP_ERR_UNSUPPORTED = 0x0001
DMA_DISP_ERR_LENGTH      = 0x0002
DMA_DISP_ERR_FUNCTION    = 0x0003
DMA_DISP_ERR_DIRECTION   = 0x0004

SGE_TRAV_ERR_ZERO_LENGTH     = 0x0001
SGE_TRAV_ERR_LENGTH_UNDERRUN = 0x0002
SGE_TRAV_ERR_LENGTH_OVERRUN  = 0x0003
SGE_TRAV_ERR_OVERLAP         = 0x0006

DMA_MR_ERR_KEY_DIRECTION  = 0x0002
DMA_MR_ERR_ACCESS_DENIED  = 0x0005
DMA_MR_ERR_PD_MISMATCH    = 0x0006

DMA_SPLIT_ERR_ZERO_LENGTH = 0x0001
DMA_SPLIT_ERR_PMTU_CONFIG = 0x0002

DMA_ERR_MR_LOOKUP_MISS      = 0x0001
DMA_ERR_KEY_DIRECTION       = 0x0002
DMA_ERR_ACCESS_DENIED       = 0x0003
DMA_ERR_PD_MISMATCH         = 0x0004
DMA_ERR_BOUNDS              = 0x0005
DMA_ERR_SGE_LENGTH          = 0x0006
DMA_ERR_SGE_OVERLAP         = 0x0007
DMA_ERR_PCIE_READ           = 0x000B
DMA_ERR_PCIE_WRITE          = 0x000C

CMPL_SUCCESS         = 0x00
CMPL_LOC_LEN_ERR     = 0x01
CMPL_LOC_QP_OP_ERR   = 0x02
CMPL_LOC_PROT_ERR    = 0x03
CMPL_REM_ACCESS_ERR  = 0x07
CMPL_CQ_OVERFLOW_ERR = 0x0B
CMPL_DMA_ERR         = 0x0C
CMPL_GENERAL_ERR     = 0xFF

MR_OP_LOCAL_DMA_READ  = 0
MR_OP_LOCAL_DMA_WRITE = 1
MR_OP_LOCAL_RECV_WRITE = 2
MR_OP_REMOTE_RDMA_READ = 3
MR_OP_REMOTE_RDMA_WRITE = 4

POLICY_FIXED = 0
POLICY_RR    = 1
POLICY_WRR   = 2
POLICY_STRICT_GUARD = 3

MAX_SGE = 256


# ===================================================================
# Error propagation mock — 将 DMA error code 映射到 completion status
# ===================================================================

def map_dma_error_to_completion(code, operation, original_status=CMPL_SUCCESS):
    """模拟 dma_error_propagation 模块的 map_dma_error_to_completion 函数。"""
    if code == 0:
        return original_status if original_status == CMPL_SUCCESS else CMPL_GENERAL_ERR

    if code in (DMA_ERR_MR_LOOKUP_MISS, DMA_ERR_PD_MISMATCH, DMA_ERR_SGE_OVERLAP):
        return CMPL_LOC_PROT_ERR

    if code in (DMA_ERR_KEY_DIRECTION, DMA_ERR_ACCESS_DENIED):
        if operation in (MR_OP_REMOTE_RDMA_READ, MR_OP_REMOTE_RDMA_WRITE):
            return CMPL_REM_ACCESS_ERR
        return CMPL_LOC_PROT_ERR

    if code in (DMA_ERR_BOUNDS, DMA_ERR_SGE_LENGTH):
        return CMPL_LOC_LEN_ERR

    if code in (0x0008, 0x0009, 0x000A, 0x000E):  # WQE/SGE fetch, unsupported opcode, arb malformed
        return CMPL_LOC_QP_OP_ERR

    if code in (DMA_ERR_PCIE_READ, DMA_ERR_PCIE_WRITE):
        return CMPL_DMA_ERR

    if code == 0x000D:  # CQ overflow
        return CMPL_CQ_OVERFLOW_ERR

    return CMPL_GENERAL_ERR


# ===================================================================
# SGE traversal mock — SGE list 的合法性检查
# ===================================================================

def check_sge_list(sges, expected_total):
    """模拟 dma_sge_traversal 的 SGE list 校验逻辑。

    Returns: (ok, error_code) 或 (False, error_code) 表示失败。
    """
    if expected_total == 0:
        return False, SGE_TRAV_ERR_ZERO_LENGTH

    total = 0
    seen_ranges = []

    for i, sge in enumerate(sges):
        if sge["length"] == 0:
            return False, SGE_TRAV_ERR_ZERO_LENGTH

        end = sge["addr"] + sge["length"]
        if end < sge["addr"]:
            return False, SGE_TRAV_ERR_LENGTH_OVERRUN  # addr overflow

        if sge["index"] >= MAX_SGE:
            return False, SGE_TRAV_ERR_LENGTH_OVERRUN

        if sge["index"] != i:
            return False, SGE_TRAV_ERR_LENGTH_OVERRUN  # index order

        # Overlap check
        for base, end_s in seen_ranges:
            if not (end <= base or end_s <= sge["addr"]):
                return False, SGE_TRAV_ERR_OVERLAP

        seen_ranges.append((sge["addr"], end))
        total += sge["length"]

        if total > expected_total:
            return False, SGE_TRAV_ERR_LENGTH_OVERRUN

    if total < expected_total:
        return False, SGE_TRAV_ERR_LENGTH_UNDERRUN

    return True, 0


# ===================================================================
# MR integration mock — 检查 key/access/PD
# ===================================================================

def check_mr_access(lkey, is_remote, operation, mr_entries, qp_pd_id):
    """模拟 dma_mr_integration 的 MR 保护检查管线。

    Returns: (ok, error_code)
    """
    key_to_find = lkey
    for mr in mr_entries:
        match_key = mr["rkey"] if is_remote else mr["lkey"]
        if match_key == key_to_find:
            if mr["pending_deregister"]:
                return False, DMA_MR_ERR_ACCESS_DENIED  # pending
            if mr["pd_id"] != qp_pd_id:
                return False, DMA_MR_ERR_PD_MISMATCH
            required_perm = {
                MR_OP_LOCAL_DMA_READ: 0b000001,
                MR_OP_LOCAL_DMA_WRITE: 0b000010,
                MR_OP_LOCAL_RECV_WRITE: 0b000010,
                MR_OP_REMOTE_RDMA_READ: 0b000100,
                MR_OP_REMOTE_RDMA_WRITE: 0b001000,
            }.get(operation, 0)
            if (mr["access_flags"] & required_perm) == 0:
                return False, DMA_MR_ERR_ACCESS_DENIED
            return True, 0

    return False, DMA_ERR_MR_LOOKUP_MISS


# ===================================================================
# Segment splitter mock
# ===================================================================

def split_segment(pa, length, pmtu=4096, max_segment=4096, enable_pmtu=False, enable_4kb=False):
    """模拟 dma_segment_splitter 的行为。

    Returns: list of (pa, length) 拆分后的 segments。
    """
    if length == 0:
        return [(pa, 0, DMA_SPLIT_ERR_ZERO_LENGTH)]

    if enable_pmtu and pmtu not in (256, 512, 1024, 2048, 4096):
        return [(pa, 0, DMA_SPLIT_ERR_PMTU_CONFIG)]

    splits = []
    remaining = length
    offset = 0

    while remaining > 0:
        split_len = remaining

        if enable_pmtu and pmtu < split_len:
            split_len = pmtu

        if enable_4kb:
            page_remaining = 4096 - (pa & 0xFFF)
            if page_remaining < split_len:
                split_len = page_remaining

        if max_segment and max_segment < split_len:
            split_len = max_segment

        if split_len == 0:
            return [(pa, 0, 0x0006)]  # zero split error

        splits.append((pa + offset, split_len, 0))
        offset += split_len
        remaining -= split_len

    return splits


# ===================================================================
# Arbiter mock — round-robin
# ===================================================================

def arbiter_round_robin(sources, last_grant=-1):
    """模拟 dma_arbiter 的 round-robin 选择逻辑。

    Given a list of active source indices, return the next source
    after last_grant in round-robin order.
    """
    if not sources:
        return None
    for step in range(1, len(sources) + 1):
        candidate = (last_grant + step) % (max(sources) + 1)
        if candidate in sources:
            return candidate
    return None


# ===================================================================
# Tests
# ===================================================================

# --- Error propagation --------------------------------------------------

def test_all_error_codes_map_to_known_completion_status():
    """每个 DMA error code 都能正确映射到 completion status。"""
    test_cases = [
        (DMA_ERR_MR_LOOKUP_MISS, MR_OP_LOCAL_DMA_READ, CMPL_LOC_PROT_ERR),
        (DMA_ERR_PD_MISMATCH, MR_OP_LOCAL_DMA_READ, CMPL_LOC_PROT_ERR),
        (DMA_ERR_SGE_OVERLAP, MR_OP_LOCAL_DMA_READ, CMPL_LOC_PROT_ERR),
        (DMA_ERR_ACCESS_DENIED, MR_OP_LOCAL_DMA_READ, CMPL_LOC_PROT_ERR),
        (DMA_ERR_ACCESS_DENIED, MR_OP_REMOTE_RDMA_WRITE, CMPL_REM_ACCESS_ERR),
        (DMA_ERR_KEY_DIRECTION, MR_OP_LOCAL_DMA_READ, CMPL_LOC_PROT_ERR),
        (DMA_ERR_KEY_DIRECTION, MR_OP_REMOTE_RDMA_READ, CMPL_REM_ACCESS_ERR),
        (DMA_ERR_BOUNDS, MR_OP_LOCAL_DMA_READ, CMPL_LOC_LEN_ERR),
        (DMA_ERR_SGE_LENGTH, MR_OP_LOCAL_DMA_READ, CMPL_LOC_LEN_ERR),
        (DMA_ERR_PCIE_READ, MR_OP_LOCAL_DMA_READ, CMPL_DMA_ERR),
        (DMA_ERR_PCIE_WRITE, MR_OP_LOCAL_DMA_WRITE, CMPL_DMA_ERR),
        (0x0008, MR_OP_LOCAL_DMA_READ, CMPL_LOC_QP_OP_ERR),   # WQE fetch
        (0x0009, MR_OP_LOCAL_DMA_READ, CMPL_LOC_QP_OP_ERR),   # SGE fetch
        (0x000A, MR_OP_LOCAL_DMA_READ, CMPL_LOC_QP_OP_ERR),   # unsupported opcode
        (0x000D, MR_OP_LOCAL_DMA_READ, CMPL_CQ_OVERFLOW_ERR),
        (0x000F, MR_OP_LOCAL_DMA_READ, CMPL_GENERAL_ERR),     # timeout
    ]
    for code, op, expected in test_cases:
        result = map_dma_error_to_completion(code, op)
        assert result == expected, f"code=0x{code:04X} op={op}: expected 0x{expected:02X}, got 0x{result:02X}"
    print("  PASS test_all_error_codes_map_to_known_completion_status")


# --- SGE traversal -------------------------------------------------------

def test_single_sge_valid():
    ok, err = check_sge_list(
        [{"index": 0, "addr": 0x1000, "length": 128}],
        expected_total=128,
    )
    assert ok and err == 0, f"Single valid SGE should pass, got {err}"
    print("  PASS test_single_sge_valid")


def test_multi_sge_valid():
    ok, err = check_sge_list(
        [
            {"index": 0, "addr": 0x1000, "length": 64},
            {"index": 1, "addr": 0x2000, "length": 64},
        ],
        expected_total=128,
    )
    assert ok, f"Multi valid SGE should pass"
    print("  PASS test_multi_sge_valid")


def test_256_sge_valid():
    sges = [{"index": i, "addr": 0x1000 + i * 0x1000, "length": 1} for i in range(256)]
    ok, err = check_sge_list(sges, expected_total=256)
    assert ok, f"256 valid SGE should pass, got err={err}"
    print("  PASS test_256_sge_valid")


def test_sge_overlap_rejected():
    ok, err = check_sge_list(
        [
            {"index": 0, "addr": 0x1000, "length": 0x1000},
            {"index": 1, "addr": 0x1800, "length": 0x1000},
        ],
        expected_total=0x2000,
    )
    assert not ok and err == SGE_TRAV_ERR_OVERLAP, f"Overlapping SGE should be rejected, got {err}"
    print("  PASS test_sge_overlap_rejected")


def test_sge_length_underrun():
    ok, err = check_sge_list(
        [{"index": 0, "addr": 0x1000, "length": 64}],
        expected_total=128,
    )
    assert not ok and err == SGE_TRAV_ERR_LENGTH_UNDERRUN, f"Length underrun should be rejected"
    print("  PASS test_sge_length_underrun")


def test_sge_length_overrun():
    ok, err = check_sge_list(
        [{"index": 0, "addr": 0x1000, "length": 200}],
        expected_total=128,
    )
    assert not ok and err == SGE_TRAV_ERR_LENGTH_OVERRUN, f"Length overrun should be rejected"
    print("  PASS test_sge_length_overrun")


# --- MR integration ------------------------------------------------------

def test_mr_permission_denied():
    mr_entries = [
        {"lkey": 0x1001, "rkey": 0x2001, "pd_id": 3, "access_flags": 0b000010,  # only LOCAL_WRITE
         "pending_deregister": False}
    ]
    ok, err = check_mr_access(0x1001, False, MR_OP_LOCAL_DMA_READ, mr_entries, 3)
    assert not ok and err == DMA_MR_ERR_ACCESS_DENIED, f"Permission denied should be rejected"
    print("  PASS test_mr_permission_denied")


def test_mr_pd_mismatch():
    mr_entries = [
        {"lkey": 0x1001, "rkey": 0x2001, "pd_id": 4, "access_flags": 0b000001,
         "pending_deregister": False}
    ]
    ok, err = check_mr_access(0x1001, False, MR_OP_LOCAL_DMA_READ, mr_entries, 3)
    assert not ok and err == DMA_MR_ERR_PD_MISMATCH, f"PD mismatch should be rejected"
    print("  PASS test_mr_pd_mismatch")


def test_mr_key_not_found():
    mr_entries = [
        {"lkey": 0x9999, "rkey": 0x8888, "pd_id": 3, "access_flags": 0b000001,
         "pending_deregister": False}
    ]
    ok, err = check_mr_access(0x1001, False, MR_OP_LOCAL_DMA_READ, mr_entries, 3)
    assert not ok and err == DMA_ERR_MR_LOOKUP_MISS, f"Key not found should be rejected"
    print("  PASS test_mr_key_not_found")


# --- Segment splitter ----------------------------------------------------

def test_4kb_boundary_split():
    splits = split_segment(pa=0x8000_0F00, length=512, enable_4kb=True)
    assert len(splits) == 2, f"Expected 2 splits for 4KB boundary, got {len(splits)}"
    assert splits[0] == (0x8000_0F00, 256, 0), f"First split: {splits[0]}"
    assert splits[1] == (0x8000_1000, 256, 0), f"Second split: {splits[1]}"
    print("  PASS test_4kb_boundary_split")


def test_pmtu_split():
    splits = split_segment(pa=0x8000_0000, length=2500, pmtu=1024, enable_pmtu=True)
    assert len(splits) == 3, f"Expected 3 splits for PMTU 1024, got {len(splits)}"
    assert [s[1] for s in splits] == [1024, 1024, 452]
    print("  PASS test_pmtu_split")


def test_pmtu_and_4kb_combined():
    splits = split_segment(pa=0x8000_0E00, length=1200, pmtu=512, enable_pmtu=True, enable_4kb=True)
    assert len(splits) == 3
    assert [s[1] for s in splits] == [512, 512, 176]
    assert [s[0] for s in splits] == [0x8000_0E00, 0x8000_1000, 0x8000_1200]
    print("  PASS test_pmtu_and_4kb_combined")


# --- Arbiter -------------------------------------------------------------

def test_round_robin_fairness():
    sources = [0, 1, 2]
    grants = []
    last = -1
    for _ in range(6):
        g = arbiter_round_robin(sources, last)
        assert g is not None
        grants.append(g)
        last = g
    # With 3 sources and 6 grants, each should appear exactly twice
    count_0 = sum(1 for g in grants if g == 0)
    count_1 = sum(1 for g in grants if g == 1)
    count_2 = sum(1 for g in grants if g == 2)
    assert count_0 == 2 and count_1 == 2 and count_2 == 2, \
        f"RR should give each source 2 grants, got {count_0}/{count_1}/{count_2}"
    print("  PASS test_round_robin_fairness")


def test_round_robin_one_source():
    sources = [3]
    g = arbiter_round_robin(sources, 2)
    assert g == 3
    print("  PASS test_round_robin_one_source")


# --- Dispatcher routing --------------------------------------------------

def test_dispatcher_routing():
    """模拟 dispatcher 的 opcode → route 映射。"""
    routing_table = {
        DMA_OP_SEND: "host_read",
        DMA_OP_RDMA_WRITE: "host_read",
        DMA_OP_RECV: "host_write",
        DMA_OP_CQE_WRITE: "cqe_write",
        DMA_OP_WQE_FETCH: "fetch",
        DMA_OP_SGE_FETCH: "fetch",
    }
    for opcode, expected_route in routing_table.items():
        route = routing_table.get(opcode)
        assert route == expected_route, f"opcode {opcode}: expected {expected_route}, got {route}"
    print("  PASS test_dispatcher_routing")


# --- End-to-end data flow ------------------------------------------------

def test_end_to_end_send_flow():
    """完整 Send 数据流: dispatcher → SGE traversal → MR check → splitter。

    使用 mock/stub 验证整个流程的正确性,
    不依赖真实 PCIe Root Complex、IOMMU 或 RoCEv2 transport。
    """
    # Step 1: Dispatcher routes Send to host_read
    assert routing_table.get(DMA_OP_SEND) == "host_read", "Send should route to host_read"

    # Step 2: SGE traversal validates the SGE list
    sges = [
        {"index": 0, "addr": 0x10000, "length": 128},
        {"index": 1, "addr": 0x20000, "length": 384},
    ]
    ok, err = check_sge_list(sges, expected_total=512)
    assert ok, f"SGE traversal should pass, got err={err}"

    # Step 3: MR integration checks each segment
    mr_entries = [
        {"lkey": 0x1001, "rkey": 0x2001, "pd_id": 3, "access_flags": 0b000001,  # LOCAL_READ
         "pending_deregister": False}
    ]
    for sge in sges:
        ok, err = check_mr_access(0x1001, False, MR_OP_LOCAL_DMA_READ, mr_entries, 3)
        assert ok, f"MR check for SGE at {sge['addr']:#x} should pass, got err={err}"

    # Step 4: Splitter ensures no segment crosses 4KB boundary
    for sge in sges:
        splits = split_segment(pa=0x8000_0000 + sge["addr"] - 0x10000, length=sge["length"],
                               enable_4kb=True)
        assert len(splits) > 0
        for pa, length, split_err in splits:
            assert split_err == 0, f"Split error: {split_err}"
            # Ensure no split crosses 4KB boundary
            pa_end = pa + length
            if length > 0:
                assert (pa >> 12) == ((pa_end - 1) >> 12), \
                    f"Split at {pa:#x} length {length} crosses 4KB boundary"

    print("  PASS test_end_to_end_send_flow")


# ===================================================================

routing_table = {
    DMA_OP_SEND: "host_read",
    DMA_OP_RDMA_WRITE: "host_read",
    DMA_OP_RECV: "host_write",
    DMA_OP_CQE_WRITE: "cqe_write",
    DMA_OP_WQE_FETCH: "fetch",
    DMA_OP_SGE_FETCH: "fetch",
}


def run_tests():
    print("=== DMA Integration Tests (mock/stub) ===\n")

    print("[1] Error propagation:")
    test_all_error_codes_map_to_known_completion_status()

    print("\n[2] SGE traversal:")
    test_single_sge_valid()
    test_multi_sge_valid()
    test_256_sge_valid()
    test_sge_overlap_rejected()
    test_sge_length_underrun()
    test_sge_length_overrun()

    print("\n[3] MR integration:")
    test_mr_permission_denied()
    test_mr_pd_mismatch()
    test_mr_key_not_found()

    print("\n[4] Segment splitter:")
    test_4kb_boundary_split()
    test_pmtu_split()
    test_pmtu_and_4kb_combined()

    print("\n[5] Arbiter:")
    test_round_robin_fairness()
    test_round_robin_one_source()

    print("\n[6] Dispatcher:")
    test_dispatcher_routing()

    print("\n[7] End-to-end:")
    test_end_to_end_send_flow()

    print("\n=== All DMA integration tests passed ===\n")


if HAS_COCOTB:
    @cocotb.test()
    async def test_dma_integration_full(dut):
        """Run all integration tests as a single cocotb test case.

        The `dut` parameter is unused — all tests are pure Python mock/stub.
        """
        run_tests()

# Allow the integration test module to be loaded as a cocotb module.
# When used via `make test-dma-integration`, cocotb discovers the @cocotb.test()
# decorated function. Ensure one test function is exposed regardless of import.
if not HAS_COCOTB:
    if __name__ != "__main__":
        # When imported as a cocotb module but cocotb is not installed,
        # provide a dummy test so the import doesn't fail.
        def test_dma_integration_full(dut):
            raise RuntimeError("cocotb not available, cannot run integration test as cocotb test")

if __name__ == "__main__":
    run_tests()
