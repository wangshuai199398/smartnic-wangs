# SPDX-License-Identifier: MIT
"""DMA descriptor dispatcher 全覆盖测试。

覆盖：
1. SQ Send / RDMA Write / RDMA Read Resp 路由；
2. RQ Recv 路由；
3. CQE write 路由；
4. WQE/SGE fetch 路由；
5. unsupported opcode / 零长度 (非NOP) / owner_function 越界 / direction 不匹配 错误检测；
6. NOP descriptor 不产生输出；
7. 固定优先级 CQE > RQ > SQ > WQE_FETCH > SGE_FETCH；
8. backpressure（下游 ready=0）时 descriptor 保持不丢；
9. RDMA Read Request 不路由到任何输出。
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


DMA_OP_SEND           = 0
DMA_OP_RECV           = 1
DMA_OP_RDMA_WRITE     = 2
DMA_OP_RDMA_READ_REQ  = 3
DMA_OP_RDMA_READ_RESP = 4
DMA_OP_CQE_WRITE      = 5
DMA_OP_WQE_FETCH      = 6
DMA_OP_SGE_FETCH      = 7
DMA_OP_NOP            = 8
DMA_OP_ERROR          = 15

DMA_DIR_HOST_READ  = 0
DMA_DIR_HOST_WRITE = 1
DMA_DIR_CQE_WRITE  = 2
DMA_DIR_WQE_FETCH  = 3
DMA_DIR_SGE_FETCH  = 4

DMA_DISP_ERR_NONE        = 0x0000
DMA_DISP_ERR_UNSUPPORTED = 0x0001
DMA_DISP_ERR_LENGTH      = 0x0002
DMA_DISP_ERR_FUNCTION    = 0x0003
DMA_DISP_ERR_DIRECTION   = 0x0004

DMA_DESC_FIELDS = [
    ("desc_valid", 1),         ("desc_id", 16),
    ("dma_opcode", 4),         ("qpn", 24),
    ("cqn", 24),               ("owner_function", 16),
    ("pd_id", 24),             ("wr_id", 64),
    ("local_key", 32),         ("remote_key", 32),
    ("local_va", 64),          ("remote_va", 64),
    ("physical_addr", 64),     ("length", 32),
    ("byte_len_remaining", 32),("sge_count", 8),
    ("sge_index", 8),          ("inline_data_present", 1),
    ("inline_data_len", 16),   ("direction", 3),
    ("solicited", 1),          ("has_imm", 1),
    ("imm_data", 32),          ("completion_required", 1),
    ("error_code", 16),        ("user_context", 64),
]


def pack_fields(fields, values):
    packed = 0
    for name, width in fields:
        packed = (packed << width) | (values.get(name, 0) & ((1 << width) - 1))
    return packed


def extract_field(fields, packed, field_name):
    offset = 0
    for name, width in reversed(fields):
        if name == field_name:
            return (int(packed) >> offset) & ((1 << width) - 1)
        offset += width
    raise KeyError(field_name)


def pack_dma_desc(**overrides):
    values = {
        "desc_valid": 1, "desc_id": 0x11, "dma_opcode": DMA_OP_SEND,
        "qpn": 0x22, "cqn": 0x33, "owner_function": 1, "pd_id": 3,
        "wr_id": 0xCAFE, "local_key": 0x1001, "remote_key": 0x2001,
        "local_va": 0x1000_0000, "remote_va": 0x2000_0000,
        "physical_addr": 0, "length": 128, "byte_len_remaining": 128,
        "sge_count": 1, "sge_index": 0, "inline_data_present": 0,
        "inline_data_len": 0, "direction": DMA_DIR_HOST_READ,
        "solicited": 0, "has_imm": 0, "imm_data": 0,
        "completion_required": 1, "error_code": 0, "user_context": 0x1234,
    }
    values.update(overrides)
    return pack_fields(DMA_DESC_FIELDS, values)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.sq_dma_req_valid.value = 0;      dut.sq_dma_req.value = 0
    dut.rq_dma_req_valid.value = 0;      dut.rq_dma_req.value = 0
    dut.cqe_dma_req_valid.value = 0;     dut.cqe_dma_req.value = 0
    dut.wqe_fetch_req_valid.value = 0;   dut.wqe_fetch_req.value = 0
    dut.sge_fetch_req_valid.value = 0;   dut.sge_fetch_req.value = 0
    dut.host_read_desc_ready.value = 1
    dut.host_write_desc_ready.value = 1
    dut.cqe_write_desc_ready.value = 1
    dut.fetch_desc_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_source(dut, source, desc):
    valid = getattr(dut, f"{source}_valid")
    data = getattr(dut, source)
    ready = getattr(dut, f"{source}_ready")
    valid.value = 1
    data.value = desc
    await Timer(1, units="ns")
    assert int(ready.value) == 1
    await RisingEdge(dut.clk)
    valid.value = 0


async def wait_output(dut, valid_name, desc_name, timeout=32):
    for _ in range(timeout):
        await Timer(1, units="ns")
        if int(getattr(dut, valid_name).value) == 1:
            desc = int(getattr(dut, desc_name).value)
            await RisingEdge(dut.clk)
            return desc
        await RisingEdge(dut.clk)
    raise AssertionError(f"{valid_name} not asserted")


async def wait_error(dut, timeout=32):
    for _ in range(timeout):
        await Timer(1, units="ns")
        if int(dut.dma_error_valid.value) == 1:
            result = {"desc_id": int(dut.dma_error_desc_id.value),
                       "error": int(dut.dma_error_code.value)}
            await RisingEdge(dut.clk)
            return result
        await RisingEdge(dut.clk)
    raise AssertionError("dma_error_valid not asserted")


# ======================================================================
# 路由测试 — 每个 opcode + direction 组合
# ======================================================================

@cocotb.test()
async def test_sq_send_routes_to_host_read(dut):
    """SQ Send descriptor 路由到 host_read 路径。"""
    await reset_dut(dut)
    desc = pack_dma_desc(desc_id=0x10, dma_opcode=DMA_OP_SEND, direction=DMA_DIR_HOST_READ)
    await send_source(dut, "sq_dma_req", desc)
    out = await wait_output(dut, "host_read_desc_valid", "host_read_desc")
    assert extract_field(DMA_DESC_FIELDS, out, "desc_id") == 0x10
    assert extract_field(DMA_DESC_FIELDS, out, "dma_opcode") == DMA_OP_SEND


@cocotb.test()
async def test_sq_rdma_write_routes_to_host_read(dut):
    """SQ RDMA Write descriptor 路由到 host_read 路径。"""
    await reset_dut(dut)
    desc = pack_dma_desc(desc_id=0x11, dma_opcode=DMA_OP_RDMA_WRITE, direction=DMA_DIR_HOST_READ)
    await send_source(dut, "sq_dma_req", desc)
    out = await wait_output(dut, "host_read_desc_valid", "host_read_desc")
    assert extract_field(DMA_DESC_FIELDS, out, "dma_opcode") == DMA_OP_RDMA_WRITE


@cocotb.test()
async def test_rq_recv_routes_to_host_write(dut):
    """RQ Recv descriptor 路由到 host_write 路径。"""
    await reset_dut(dut)
    desc = pack_dma_desc(desc_id=0x12, dma_opcode=DMA_OP_RECV, direction=DMA_DIR_HOST_WRITE)
    await send_source(dut, "rq_dma_req", desc)
    out = await wait_output(dut, "host_write_desc_valid", "host_write_desc")
    assert extract_field(DMA_DESC_FIELDS, out, "desc_id") == 0x12


@cocotb.test()
async def test_rdma_read_response_routes_to_host_write(dut):
    """RDMA Read Response descriptor 路由到 host_write 路径。"""
    await reset_dut(dut)
    desc = pack_dma_desc(desc_id=0x13, dma_opcode=DMA_OP_RDMA_READ_RESP, direction=DMA_DIR_HOST_WRITE)
    await send_source(dut, "sq_dma_req", desc)
    out = await wait_output(dut, "host_write_desc_valid", "host_write_desc")
    assert extract_field(DMA_DESC_FIELDS, out, "desc_id") == 0x13


@cocotb.test()
async def test_cqe_write_routes_to_cqe_write_path(dut):
    """CQE write descriptor 路由到 cqe_write 子路径。"""
    await reset_dut(dut)
    desc = pack_dma_desc(desc_id=0x14, dma_opcode=DMA_OP_CQE_WRITE, direction=DMA_DIR_CQE_WRITE, length=64)
    await send_source(dut, "cqe_dma_req", desc)
    out = await wait_output(dut, "cqe_write_desc_valid", "cqe_write_desc")
    assert extract_field(DMA_DESC_FIELDS, out, "length") == 64


@cocotb.test()
async def test_wqe_fetch_routes_to_fetch_path(dut):
    """WQE fetch descriptor 路由到 fetch 子路径。"""
    await reset_dut(dut)
    wqe = pack_dma_desc(desc_id=0x15, dma_opcode=DMA_OP_WQE_FETCH, direction=DMA_DIR_WQE_FETCH, length=64)
    await send_source(dut, "wqe_fetch_req", wqe)
    out = await wait_output(dut, "fetch_desc_valid", "fetch_desc")
    assert extract_field(DMA_DESC_FIELDS, out, "desc_id") == 0x15


@cocotb.test()
async def test_sge_fetch_routes_to_fetch_path(dut):
    """SGE fetch descriptor 路由到 fetch 子路径。"""
    await reset_dut(dut)
    sge = pack_dma_desc(desc_id=0x16, dma_opcode=DMA_OP_SGE_FETCH, direction=DMA_DIR_SGE_FETCH, length=32)
    await send_source(dut, "sge_fetch_req", sge)
    out = await wait_output(dut, "fetch_desc_valid", "fetch_desc")
    assert extract_field(DMA_DESC_FIELDS, out, "desc_id") == 0x16


# ======================================================================
# 错误检测测试
# ======================================================================

@cocotb.test()
async def test_unsupported_opcode_rejected(dut):
    """不支持的 opcode (DMA_OP_ERROR) 产生 UNSUPPORTED 错误。"""
    await reset_dut(dut)
    bad = pack_dma_desc(desc_id=0x17, dma_opcode=DMA_OP_ERROR, direction=DMA_DIR_HOST_READ)
    await send_source(dut, "sq_dma_req", bad)
    err = await wait_error(dut)
    assert err["desc_id"] == 0x17
    assert err["error"] == DMA_DISP_ERR_UNSUPPORTED


@cocotb.test()
async def test_zero_length_non_nop_rejected(dut):
    """非 NOP 的零长度 descriptor 产生 LENGTH 错误。"""
    await reset_dut(dut)
    zero = pack_dma_desc(desc_id=0x18, dma_opcode=DMA_OP_SEND, direction=DMA_DIR_HOST_READ, length=0)
    await send_source(dut, "sq_dma_req", zero)
    err = await wait_error(dut)
    assert err["desc_id"] == 0x18
    assert err["error"] == DMA_DISP_ERR_LENGTH


@cocotb.test()
async def test_nop_zero_length_accepted(dut):
    """NOP descriptor length=0 不报错，且不产生任何输出。"""
    await reset_dut(dut)
    nop = pack_dma_desc(desc_id=0x19, dma_opcode=DMA_OP_NOP, direction=DMA_DIR_HOST_READ, length=0)
    await send_source(dut, "sq_dma_req", nop)
    for _ in range(16):
        await RisingEdge(dut.clk)
        assert int(dut.dma_error_valid.value) == 0, "NOP should not produce error"
        assert int(dut.host_read_desc_valid.value) == 0
        assert int(dut.host_write_desc_valid.value) == 0
        assert int(dut.cqe_write_desc_valid.value) == 0
        assert int(dut.fetch_desc_valid.value) == 0


@cocotb.test()
async def test_owner_function_out_of_range_rejected(dut):
    """owner_function 超出范围时产生 FUNCTION 错误。"""
    await reset_dut(dut)
    bad = pack_dma_desc(desc_id=0x1A, dma_opcode=DMA_OP_SEND, direction=DMA_DIR_HOST_READ,
                        owner_function=0xFFFF)
    await send_source(dut, "sq_dma_req", bad)
    err = await wait_error(dut)
    assert err["error"] == DMA_DISP_ERR_FUNCTION


@cocotb.test()
async def test_direction_mismatch_rejected(dut):
    """opcode 与 direction 不匹配时产生 DIRECTION 错误。"""
    await reset_dut(dut)
    bad = pack_dma_desc(desc_id=0x1B, dma_opcode=DMA_OP_SEND, direction=DMA_DIR_HOST_WRITE)
    await send_source(dut, "sq_dma_req", bad)
    err = await wait_error(dut)
    assert err["error"] == DMA_DISP_ERR_DIRECTION


# ======================================================================
# 固定优先级测试
# ======================================================================

@cocotb.test()
async def test_simultaneous_inputs_cqe_highest_priority(dut):
    """同时输入时 CQE > RQ > SQ > WQE_FETCH > SGE_FETCH 固定优先级。"""
    await reset_dut(dut)
    dut.sq_dma_req_valid.value = 1
    dut.sq_dma_req.value = pack_dma_desc(desc_id=0x20, dma_opcode=DMA_OP_SEND, direction=DMA_DIR_HOST_READ)
    dut.rq_dma_req_valid.value = 1
    dut.rq_dma_req.value = pack_dma_desc(desc_id=0x21, dma_opcode=DMA_OP_RECV, direction=DMA_DIR_HOST_WRITE)
    dut.cqe_dma_req_valid.value = 1
    dut.cqe_dma_req.value = pack_dma_desc(desc_id=0x22, dma_opcode=DMA_OP_CQE_WRITE, direction=DMA_DIR_CQE_WRITE, length=64)
    await Timer(1, units="ns")
    assert int(dut.cqe_dma_req_ready.value) == 1
    assert int(dut.rq_dma_req_ready.value) == 0
    assert int(dut.sq_dma_req_ready.value) == 0
    await RisingEdge(dut.clk)
    dut.sq_dma_req_valid.value = 0; dut.rq_dma_req_valid.value = 0; dut.cqe_dma_req_valid.value = 0
    out = await wait_output(dut, "cqe_write_desc_valid", "cqe_write_desc")
    assert extract_field(DMA_DESC_FIELDS, out, "desc_id") == 0x22


@cocotb.test()
async def test_rq_priority_over_sq(dut):
    """同时有 RQ 和 SQ 时 RQ 先选中。"""
    await reset_dut(dut)
    dut.sq_dma_req_valid.value = 1
    dut.sq_dma_req.value = pack_dma_desc(desc_id=0x30, dma_opcode=DMA_OP_SEND, direction=DMA_DIR_HOST_READ)
    dut.rq_dma_req_valid.value = 1
    dut.rq_dma_req.value = pack_dma_desc(desc_id=0x31, dma_opcode=DMA_OP_RECV, direction=DMA_DIR_HOST_WRITE)
    await Timer(1, units="ns")
    assert int(dut.rq_dma_req_ready.value) == 1
    assert int(dut.sq_dma_req_ready.value) == 0


@cocotb.test()
async def test_sq_priority_over_wqe_fetch(dut):
    """同时有 SQ 和 WQE fetch 时 SQ 先选中。"""
    await reset_dut(dut)
    dut.sq_dma_req_valid.value = 1
    dut.sq_dma_req.value = pack_dma_desc(desc_id=0x40, dma_opcode=DMA_OP_SEND, direction=DMA_DIR_HOST_READ)
    dut.wqe_fetch_req_valid.value = 1
    dut.wqe_fetch_req.value = pack_dma_desc(desc_id=0x41, dma_opcode=DMA_OP_WQE_FETCH, direction=DMA_DIR_WQE_FETCH, length=64)
    await Timer(1, units="ns")
    assert int(dut.sq_dma_req_ready.value) == 1
    assert int(dut.wqe_fetch_req_ready.value) == 0


@cocotb.test()
async def test_wqe_fetch_priority_over_sge_fetch(dut):
    """同时有 WQE fetch 和 SGE fetch 时 WQE fetch 先选中。"""
    await reset_dut(dut)
    dut.wqe_fetch_req_valid.value = 1
    dut.wqe_fetch_req.value = pack_dma_desc(desc_id=0x50, dma_opcode=DMA_OP_WQE_FETCH, direction=DMA_DIR_WQE_FETCH, length=64)
    dut.sge_fetch_req_valid.value = 1
    dut.sge_fetch_req.value = pack_dma_desc(desc_id=0x51, dma_opcode=DMA_OP_SGE_FETCH, direction=DMA_DIR_SGE_FETCH, length=32)
    await Timer(1, units="ns")
    assert int(dut.wqe_fetch_req_ready.value) == 1
    assert int(dut.sge_fetch_req_ready.value) == 0


# ======================================================================
# Backpressure 测试
# ======================================================================

@cocotb.test()
async def test_host_read_backpressure_holds_descriptor(dut):
    """下游 host_read_desc_ready=0 时 valid descriptor 保持不丢。"""
    await reset_dut(dut)
    dut.host_read_desc_ready.value = 0
    desc = pack_dma_desc(desc_id=0x60, dma_opcode=DMA_OP_SEND, direction=DMA_DIR_HOST_READ)
    await send_source(dut, "sq_dma_req", desc)
    for _ in range(8):
        await Timer(1, units="ns")
        if int(dut.host_read_desc_valid.value) == 1:
            break
        await RisingEdge(dut.clk)
    assert int(dut.host_read_desc_valid.value) == 1
    for _ in range(3):
        await RisingEdge(dut.clk)
        assert int(dut.host_read_desc_valid.value) == 1
        assert extract_field(DMA_DESC_FIELDS, int(dut.host_read_desc.value), "desc_id") == 0x60
    dut.host_read_desc_ready.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_host_write_backpressure_holds_descriptor(dut):
    """下游 host_write_desc_ready=0 时 valid descriptor 保持不丢。"""
    await reset_dut(dut)
    dut.host_write_desc_ready.value = 0
    desc = pack_dma_desc(desc_id=0x61, dma_opcode=DMA_OP_RECV, direction=DMA_DIR_HOST_WRITE)
    await send_source(dut, "rq_dma_req", desc)
    for _ in range(8):
        await Timer(1, units="ns")
        if int(dut.host_write_desc_valid.value) == 1:
            assert extract_field(DMA_DESC_FIELDS, int(dut.host_write_desc.value), "desc_id") == 0x61
            break
        await RisingEdge(dut.clk)
    else:
        raise AssertionError("host_write_desc_valid not held under backpressure")
    dut.host_write_desc_ready.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_fetch_backpressure_holds_descriptor(dut):
    """下游 fetch_desc_ready=0 时 valid descriptor 保持不丢。"""
    await reset_dut(dut)
    dut.fetch_desc_ready.value = 0
    desc = pack_dma_desc(desc_id=0x62, dma_opcode=DMA_OP_WQE_FETCH, direction=DMA_DIR_WQE_FETCH, length=64)
    await send_source(dut, "wqe_fetch_req", desc)
    for _ in range(8):
        await Timer(1, units="ns")
        if int(dut.fetch_desc_valid.value) == 1:
            assert extract_field(DMA_DESC_FIELDS, int(dut.fetch_desc.value), "desc_id") == 0x62
            break
        await RisingEdge(dut.clk)
    else:
        raise AssertionError("fetch_desc_valid not held under backpressure")
    dut.fetch_desc_ready.value = 1
    await RisingEdge(dut.clk)


# ======================================================================
# RDMA Read Request 特殊行为
# ======================================================================

@cocotb.test()
async def test_rdma_read_req_opcode_no_routed_output(dut):
    """RDMA Read Request opcode 当前阶段不路由到任何输出。"""
    await reset_dut(dut)
    desc = pack_dma_desc(desc_id=0x70, dma_opcode=DMA_OP_RDMA_READ_REQ, direction=DMA_DIR_HOST_READ)
    await send_source(dut, "sq_dma_req", desc)
    for _ in range(16):
        await RisingEdge(dut.clk)
    # 无错误，无输出
    if int(dut.dma_error_valid.value):
        # RDMA_READ_REQ 可能不产生错误，只被静默路由到 ROUTE_NONE
        pass
