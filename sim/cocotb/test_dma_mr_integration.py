# SPDX-License-Identifier: MIT
"""DMA MR integration 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


MR_OP_LOCAL_DMA_READ = 0
MR_OP_LOCAL_DMA_WRITE = 1
MR_OP_LOCAL_RECV_WRITE = 2
MR_OP_REMOTE_RDMA_READ = 3
MR_OP_REMOTE_RDMA_WRITE = 4
MR_OP_REMOTE_ATOMIC = 5

MR_TABLE_STATUS_OK = 0
MR_TABLE_STATUS_MISS = 1
MR_TABLE_STATUS_PERMISSION = 2
MR_TABLE_STATUS_BOUNDS = 6
MR_TABLE_STATUS_PENDING = 10
MR_TABLE_STATUS_REF_OVER = 8

MR_ACCESS_LOCAL_READ = 0b000001
MR_ACCESS_LOCAL_WRITE = 0b000010
MR_ACCESS_REMOTE_READ = 0b000100
MR_ACCESS_REMOTE_WRITE = 0b001000
MR_ACCESS_REMOTE_ATOMIC = 0b010000

DMA_MR_ERR_NONE = 0
DMA_MR_ERR_KEY_DIRECTION = 2
DMA_MR_ERR_LOOKUP_MISS = 3
DMA_MR_ERR_PENDING = 4
DMA_MR_ERR_ACCESS_DENIED = 5
DMA_MR_ERR_PD_MISMATCH = 6
DMA_MR_ERR_BOUNDS = 7
DMA_MR_ERR_ZERO_LENGTH = 9
DMA_MR_ERR_PERMISSION = 10
DMA_MR_ERR_MW_INVALIDATING = 11
DMA_MR_ERR_REFCOUNT_OVERFLOW = 12


MR_ENTRY_FIELDS = [
    ("valid", 1),
    ("mr_id", 24),
    ("lkey", 32),
    ("rkey", 32),
    ("virtual_base_addr", 64),
    ("physical_base_addr", 64),
    ("length", 32),
    ("page_size", 6),
    ("access_flags", 6),
    ("pd_id", 24),
    ("owner_function", 16),
    ("refcount", 16),
    ("pending_deregister", 1),
    ("memory_window", 1),
    ("invalidating", 1),
    ("bound_qpn", 24),
    ("parent_mr_key", 32),
    ("error_state", 1),
    ("error_code", 16),
]


def pack_fields(fields, values):
    packed = 0
    for name, width in fields:
        packed = (packed << width) | (values.get(name, 0) & ((1 << width) - 1))
    return packed


def pack_mr_entry(**overrides):
    values = {
        "valid": 1,
        "mr_id": 0x44,
        "lkey": 0x1001,
        "rkey": 0x2001,
        "virtual_base_addr": 0x1000_0000,
        "physical_base_addr": 0x8000_0000,
        "length": 0x1000,
        "page_size": 12,
        "access_flags": MR_ACCESS_LOCAL_READ | MR_ACCESS_LOCAL_WRITE | MR_ACCESS_REMOTE_READ | MR_ACCESS_REMOTE_WRITE,
        "pd_id": 3,
        "owner_function": 1,
        "refcount": 0,
        "pending_deregister": 0,
        "memory_window": 0,
        "invalidating": 0,
        "bound_qpn": 0x22,
        "parent_mr_key": 0,
        "error_state": 0,
        "error_code": 0,
    }
    values.update(overrides)
    return pack_fields(MR_ENTRY_FIELDS, values)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0

    dut.dma_segment_valid.value = 0
    dut.dma_segment_desc_id.value = 0
    dut.dma_segment_qpn.value = 0
    dut.dma_segment_owner_function.value = 0
    dut.dma_segment_pd_id.value = 0
    dut.dma_segment_operation.value = 0
    dut.dma_segment_index.value = 0
    dut.dma_segment_va.value = 0
    dut.dma_segment_len.value = 0
    dut.dma_segment_lkey.value = 0
    dut.dma_segment_rkey.value = 0
    dut.dma_segment_is_remote.value = 0
    dut.dma_segment_flags.value = 0
    dut.dma_segment_byte_offset.value = 0
    dut.dma_segment_is_last.value = 0

    dut.protected_segment_ready.value = 1
    dut.dma_mr_error_ready.value = 1

    dut.mr_check_ready.value = 1
    dut.mr_check_rsp_valid.value = 0
    dut.mr_check_hit.value = 0
    dut.mr_check_entry.value = 0
    dut.mr_check_pa.value = 0
    dut.mr_check_error_code.value = 0

    dut.mr_ref_update_ready.value = 1
    dut.mr_ref_update_rsp_valid.value = 0
    dut.mr_ref_update_status.value = 0
    dut.mr_refcount_out.value = 0
    dut.mr_refcount_zero.value = 1

    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_segment(
    dut,
    *,
    operation=MR_OP_LOCAL_DMA_READ,
    is_remote=0,
    lkey=0x1001,
    rkey=0x2001,
    va=0x1000_0100,
    length=128,
    pd_id=3,
    owner=1,
    index=0,
):
    dut.dma_segment_valid.value = 1
    dut.dma_segment_desc_id.value = 0x11
    dut.dma_segment_qpn.value = 0x22
    dut.dma_segment_owner_function.value = owner
    dut.dma_segment_pd_id.value = pd_id
    dut.dma_segment_operation.value = operation
    dut.dma_segment_index.value = index
    dut.dma_segment_va.value = va
    dut.dma_segment_len.value = length
    dut.dma_segment_lkey.value = lkey
    dut.dma_segment_rkey.value = rkey
    dut.dma_segment_is_remote.value = is_remote
    dut.dma_segment_flags.value = 0x1
    dut.dma_segment_byte_offset.value = 64
    dut.dma_segment_is_last.value = 1
    await Timer(1, units="ns")
    assert int(dut.dma_segment_ready.value) == 1
    await RisingEdge(dut.clk)
    dut.dma_segment_valid.value = 0


async def respond_mr_check(dut, *, entry, status=MR_TABLE_STATUS_OK, hit=1, pa=0x8000_0100):
    for _ in range(32):
        await Timer(1, units="ns")
        if int(dut.mr_check_valid.value) == 1:
            await RisingEdge(dut.clk)
            dut.mr_check_rsp_valid.value = 1
            dut.mr_check_hit.value = hit
            dut.mr_check_entry.value = entry
            dut.mr_check_pa.value = pa
            dut.mr_check_error_code.value = status
            await RisingEdge(dut.clk)
            dut.mr_check_rsp_valid.value = 0
            return
        await RisingEdge(dut.clk)
    raise AssertionError("mr_check_valid was not asserted")


async def respond_ref_inc(dut, *, status=MR_TABLE_STATUS_OK):
    for _ in range(32):
        await Timer(1, units="ns")
        if int(dut.mr_ref_inc_valid.value) == 1:
            await RisingEdge(dut.clk)
            dut.mr_ref_update_rsp_valid.value = 1
            dut.mr_ref_update_status.value = status
            dut.mr_refcount_out.value = 1
            dut.mr_refcount_zero.value = 0
            await RisingEdge(dut.clk)
            dut.mr_ref_update_rsp_valid.value = 0
            return
        await RisingEdge(dut.clk)
    raise AssertionError("mr_ref_inc_valid was not asserted")


async def wait_protected(dut, timeout=64):
    for _ in range(timeout):
        await Timer(1, units="ns")
        if int(dut.protected_segment_valid.value) == 1:
            segment = {
                "pa": int(dut.protected_segment_pa.value),
                "key": int(dut.protected_segment_key.value),
                "index": int(dut.protected_segment_index.value),
                "error": int(dut.protected_segment_error_code.value),
            }
            await RisingEdge(dut.clk)
            return segment
        await RisingEdge(dut.clk)
    raise AssertionError("protected_segment_valid was not asserted")


async def wait_error(dut, timeout=64):
    for _ in range(timeout):
        await Timer(1, units="ns")
        if int(dut.dma_mr_error_valid.value) == 1:
            code = int(dut.dma_mr_error_code.value)
            await RisingEdge(dut.clk)
            return code
        await RisingEdge(dut.clk)
    raise AssertionError("dma_mr_error_valid was not asserted")


async def run_success(dut, *, operation, is_remote, access_flags, memory_window=0):
    await send_segment(dut, operation=operation, is_remote=is_remote)
    entry = pack_mr_entry(access_flags=access_flags, memory_window=memory_window)
    await respond_mr_check(dut, entry=entry)
    await respond_ref_inc(dut)
    protected = await wait_protected(dut)
    assert protected["pa"] == 0x8000_0100
    assert protected["key"] == (0x2001 if is_remote else 0x1001)
    assert protected["error"] == DMA_MR_ERR_NONE


async def run_check_error(dut, *, operation, is_remote, entry, expected_error, status=MR_TABLE_STATUS_OK, hit=1):
    await send_segment(dut, operation=operation, is_remote=is_remote)
    await respond_mr_check(dut, entry=entry, status=status, hit=hit)
    assert await wait_error(dut) == expected_error


@cocotb.test()
async def test_local_send_segment_uses_lkey_local_read(dut):
    await reset_dut(dut)
    await run_success(dut, operation=MR_OP_LOCAL_DMA_READ, is_remote=0, access_flags=MR_ACCESS_LOCAL_READ)


@cocotb.test()
async def test_rdma_write_payload_read_uses_lkey_local_read(dut):
    await reset_dut(dut)
    await run_success(dut, operation=MR_OP_LOCAL_DMA_READ, is_remote=0, access_flags=MR_ACCESS_LOCAL_READ)


@cocotb.test()
async def test_recv_segment_uses_lkey_local_write(dut):
    await reset_dut(dut)
    await run_success(dut, operation=MR_OP_LOCAL_RECV_WRITE, is_remote=0, access_flags=MR_ACCESS_LOCAL_WRITE)


@cocotb.test()
async def test_remote_rdma_write_uses_rkey_remote_write(dut):
    await reset_dut(dut)
    await run_success(dut, operation=MR_OP_REMOTE_RDMA_WRITE, is_remote=1, access_flags=MR_ACCESS_REMOTE_WRITE)


@cocotb.test()
async def test_remote_rdma_read_uses_rkey_remote_read(dut):
    await reset_dut(dut)
    await run_success(dut, operation=MR_OP_REMOTE_RDMA_READ, is_remote=1, access_flags=MR_ACCESS_REMOTE_READ)


@cocotb.test()
async def test_local_path_using_rkey_rejected(dut):
    await reset_dut(dut)
    await send_segment(dut, operation=MR_OP_LOCAL_DMA_READ, is_remote=1)
    assert await wait_error(dut) == DMA_MR_ERR_KEY_DIRECTION


@cocotb.test()
async def test_remote_path_using_lkey_rejected(dut):
    await reset_dut(dut)
    await send_segment(dut, operation=MR_OP_REMOTE_RDMA_WRITE, is_remote=0)
    assert await wait_error(dut) == DMA_MR_ERR_KEY_DIRECTION


@cocotb.test()
async def test_access_flags_insufficient_rejected(dut):
    await reset_dut(dut)
    entry = pack_mr_entry(access_flags=MR_ACCESS_LOCAL_WRITE)
    await run_check_error(
        dut,
        operation=MR_OP_LOCAL_DMA_READ,
        is_remote=0,
        entry=entry,
        expected_error=DMA_MR_ERR_ACCESS_DENIED,
    )


@cocotb.test()
async def test_pd_mismatch_rejected(dut):
    await reset_dut(dut)
    entry = pack_mr_entry(pd_id=4, access_flags=MR_ACCESS_LOCAL_READ)
    await run_check_error(
        dut,
        operation=MR_OP_LOCAL_DMA_READ,
        is_remote=0,
        entry=entry,
        expected_error=DMA_MR_ERR_PD_MISMATCH,
    )


@cocotb.test()
async def test_va_bounds_error_rejected(dut):
    await reset_dut(dut)
    entry = pack_mr_entry(access_flags=MR_ACCESS_LOCAL_READ)
    await run_check_error(
        dut,
        operation=MR_OP_LOCAL_DMA_READ,
        is_remote=0,
        entry=entry,
        status=MR_TABLE_STATUS_BOUNDS,
        hit=0,
        expected_error=DMA_MR_ERR_BOUNDS,
    )


@cocotb.test()
async def test_pending_deregister_rejected(dut):
    await reset_dut(dut)
    entry = pack_mr_entry(access_flags=MR_ACCESS_LOCAL_READ, pending_deregister=1)
    await run_check_error(
        dut,
        operation=MR_OP_LOCAL_DMA_READ,
        is_remote=0,
        entry=entry,
        status=MR_TABLE_STATUS_PENDING,
        hit=0,
        expected_error=DMA_MR_ERR_PENDING,
    )


@cocotb.test()
async def test_memory_window_remote_access_success(dut):
    await reset_dut(dut)
    await run_success(
        dut,
        operation=MR_OP_REMOTE_RDMA_WRITE,
        is_remote=1,
        access_flags=MR_ACCESS_REMOTE_WRITE,
        memory_window=1,
    )


@cocotb.test()
async def test_memory_window_invalidating_rejected(dut):
    await reset_dut(dut)
    entry = pack_mr_entry(access_flags=MR_ACCESS_REMOTE_WRITE, memory_window=1, invalidating=1)
    await run_check_error(
        dut,
        operation=MR_OP_REMOTE_RDMA_WRITE,
        is_remote=1,
        entry=entry,
        expected_error=DMA_MR_ERR_MW_INVALIDATING,
    )


@cocotb.test()
async def test_refcount_overflow_rejected(dut):
    await reset_dut(dut)
    await send_segment(dut, operation=MR_OP_LOCAL_DMA_READ, is_remote=0)
    entry = pack_mr_entry(access_flags=MR_ACCESS_LOCAL_READ)
    await respond_mr_check(dut, entry=entry)
    await respond_ref_inc(dut, status=MR_TABLE_STATUS_REF_OVER)
    assert await wait_error(dut) == DMA_MR_ERR_REFCOUNT_OVERFLOW


@cocotb.test()
async def test_protected_segment_backpressure_holds_segment(dut):
    await reset_dut(dut)
    dut.protected_segment_ready.value = 0
    await send_segment(dut, operation=MR_OP_LOCAL_DMA_READ, is_remote=0)
    entry = pack_mr_entry(access_flags=MR_ACCESS_LOCAL_READ)
    await respond_mr_check(dut, entry=entry)
    await respond_ref_inc(dut)
    for _ in range(8):
        await Timer(1, units="ns")
        if int(dut.protected_segment_valid.value) == 1:
            assert int(dut.protected_segment_pa.value) == 0x8000_0100
            break
        await RisingEdge(dut.clk)
    else:
        raise AssertionError("protected_segment_valid was not held under backpressure")
    dut.protected_segment_ready.value = 1
    protected = await wait_protected(dut)
    assert protected["pa"] == 0x8000_0100


@cocotb.test()
async def test_lookup_miss_rejected(dut):
    await reset_dut(dut)
    entry = pack_mr_entry(valid=0)
    await run_check_error(
        dut,
        operation=MR_OP_LOCAL_DMA_READ,
        is_remote=0,
        entry=entry,
        status=MR_TABLE_STATUS_MISS,
        hit=0,
        expected_error=DMA_MR_ERR_LOOKUP_MISS,
    )


@cocotb.test()
async def test_owner_function_mismatch_rejected(dut):
    await reset_dut(dut)
    entry = pack_mr_entry(owner_function=2, access_flags=MR_ACCESS_LOCAL_READ)
    await run_check_error(
        dut,
        operation=MR_OP_LOCAL_DMA_READ,
        is_remote=0,
        entry=entry,
        status=MR_TABLE_STATUS_PERMISSION,
        hit=0,
        expected_error=DMA_MR_ERR_PERMISSION,
    )


@cocotb.test()
async def test_zero_segment_length_rejected(dut):
    await reset_dut(dut)
    await send_segment(dut, operation=MR_OP_LOCAL_DMA_READ, is_remote=0, length=0)
    assert await wait_error(dut) == DMA_MR_ERR_ZERO_LENGTH
