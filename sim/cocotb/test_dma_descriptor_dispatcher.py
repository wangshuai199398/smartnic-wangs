# SPDX-License-Identifier: MIT
"""DMA descriptor dispatcher 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


DMA_OP_SEND = 0
DMA_OP_RECV = 1
DMA_OP_RDMA_WRITE = 2
DMA_OP_RDMA_READ_REQ = 3
DMA_OP_RDMA_READ_RESP = 4
DMA_OP_CQE_WRITE = 5
DMA_OP_WQE_FETCH = 6
DMA_OP_SGE_FETCH = 7
DMA_OP_NOP = 8
DMA_OP_ERROR = 15

DMA_DIR_HOST_READ = 0
DMA_DIR_HOST_WRITE = 1
DMA_DIR_CQE_WRITE = 2
DMA_DIR_WQE_FETCH = 3
DMA_DIR_SGE_FETCH = 4

DMA_DISP_ERR_UNSUPPORTED = 1
DMA_DISP_ERR_LENGTH = 2


DMA_DESC_FIELDS = [
    ("desc_valid", 1),
    ("desc_id", 16),
    ("dma_opcode", 4),
    ("qpn", 24),
    ("cqn", 24),
    ("owner_function", 16),
    ("pd_id", 24),
    ("wr_id", 64),
    ("local_key", 32),
    ("remote_key", 32),
    ("local_va", 64),
    ("remote_va", 64),
    ("physical_addr", 64),
    ("length", 32),
    ("byte_len_remaining", 32),
    ("sge_count", 8),
    ("sge_index", 8),
    ("inline_data_present", 1),
    ("inline_data_len", 16),
    ("direction", 3),
    ("solicited", 1),
    ("has_imm", 1),
    ("imm_data", 32),
    ("completion_required", 1),
    ("error_code", 16),
    ("user_context", 64),
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
        "desc_valid": 1,
        "desc_id": 0x11,
        "dma_opcode": DMA_OP_SEND,
        "qpn": 0x22,
        "cqn": 0x33,
        "owner_function": 1,
        "pd_id": 3,
        "wr_id": 0xCAFE,
        "local_key": 0x1001,
        "remote_key": 0x2001,
        "local_va": 0x1000_0000,
        "remote_va": 0x2000_0000,
        "physical_addr": 0,
        "length": 128,
        "byte_len_remaining": 128,
        "sge_count": 1,
        "sge_index": 0,
        "inline_data_present": 0,
        "inline_data_len": 0,
        "direction": DMA_DIR_HOST_READ,
        "solicited": 0,
        "has_imm": 0,
        "imm_data": 0,
        "completion_required": 1,
        "error_code": 0,
        "user_context": 0x1234,
    }
    values.update(overrides)
    return pack_fields(DMA_DESC_FIELDS, values)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0

    dut.sq_dma_req_valid.value = 0
    dut.sq_dma_req.value = 0
    dut.rq_dma_req_valid.value = 0
    dut.rq_dma_req.value = 0
    dut.cqe_dma_req_valid.value = 0
    dut.cqe_dma_req.value = 0
    dut.wqe_fetch_req_valid.value = 0
    dut.wqe_fetch_req.value = 0
    dut.sge_fetch_req_valid.value = 0
    dut.sge_fetch_req.value = 0

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


async def wait_output(dut, valid_name, desc_name):
    for _ in range(12):
        await Timer(1, units="ns")
        if int(getattr(dut, valid_name).value) == 1:
            desc = int(getattr(dut, desc_name).value)
            await RisingEdge(dut.clk)
            return desc
        await RisingEdge(dut.clk)
    raise AssertionError(f"{valid_name} was not asserted")


async def wait_error(dut):
    for _ in range(12):
        await Timer(1, units="ns")
        if int(dut.dma_error_valid.value) == 1:
            result = {
                "desc_id": int(dut.dma_error_desc_id.value),
                "error": int(dut.dma_error_code.value),
            }
            await RisingEdge(dut.clk)
            return result
        await RisingEdge(dut.clk)
    raise AssertionError("dma_error_valid was not asserted")


@cocotb.test()
async def sq_send_routes_to_host_read(dut):
    await reset_dut(dut)

    desc = pack_dma_desc(desc_id=0x10, dma_opcode=DMA_OP_SEND, direction=DMA_DIR_HOST_READ)
    await send_source(dut, "sq_dma_req", desc)
    out = await wait_output(dut, "host_read_desc_valid", "host_read_desc")

    assert extract_field(DMA_DESC_FIELDS, out, "desc_id") == 0x10
    assert extract_field(DMA_DESC_FIELDS, out, "dma_opcode") == DMA_OP_SEND


@cocotb.test()
async def sq_rdma_write_routes_to_host_read(dut):
    await reset_dut(dut)

    desc = pack_dma_desc(desc_id=0x11, dma_opcode=DMA_OP_RDMA_WRITE, direction=DMA_DIR_HOST_READ)
    await send_source(dut, "sq_dma_req", desc)
    out = await wait_output(dut, "host_read_desc_valid", "host_read_desc")

    assert extract_field(DMA_DESC_FIELDS, out, "desc_id") == 0x11
    assert extract_field(DMA_DESC_FIELDS, out, "dma_opcode") == DMA_OP_RDMA_WRITE


@cocotb.test()
async def rq_recv_routes_to_host_write(dut):
    await reset_dut(dut)

    desc = pack_dma_desc(desc_id=0x12, dma_opcode=DMA_OP_RECV, direction=DMA_DIR_HOST_WRITE)
    await send_source(dut, "rq_dma_req", desc)
    out = await wait_output(dut, "host_write_desc_valid", "host_write_desc")

    assert extract_field(DMA_DESC_FIELDS, out, "desc_id") == 0x12
    assert extract_field(DMA_DESC_FIELDS, out, "dma_opcode") == DMA_OP_RECV


@cocotb.test()
async def rdma_read_response_routes_to_host_write(dut):
    await reset_dut(dut)

    desc = pack_dma_desc(desc_id=0x13, dma_opcode=DMA_OP_RDMA_READ_RESP, direction=DMA_DIR_HOST_WRITE)
    await send_source(dut, "sq_dma_req", desc)
    out = await wait_output(dut, "host_write_desc_valid", "host_write_desc")

    assert extract_field(DMA_DESC_FIELDS, out, "desc_id") == 0x13
    assert extract_field(DMA_DESC_FIELDS, out, "dma_opcode") == DMA_OP_RDMA_READ_RESP


@cocotb.test()
async def cqe_write_routes_to_cqe_write_path(dut):
    await reset_dut(dut)

    desc = pack_dma_desc(desc_id=0x14, dma_opcode=DMA_OP_CQE_WRITE, direction=DMA_DIR_CQE_WRITE, length=64)
    await send_source(dut, "cqe_dma_req", desc)
    out = await wait_output(dut, "cqe_write_desc_valid", "cqe_write_desc")

    assert extract_field(DMA_DESC_FIELDS, out, "desc_id") == 0x14
    assert extract_field(DMA_DESC_FIELDS, out, "length") == 64


@cocotb.test()
async def wqe_and_sge_fetch_route_to_fetch_path(dut):
    await reset_dut(dut)

    wqe = pack_dma_desc(desc_id=0x15, dma_opcode=DMA_OP_WQE_FETCH, direction=DMA_DIR_WQE_FETCH, length=64)
    await send_source(dut, "wqe_fetch_req", wqe)
    out_wqe = await wait_output(dut, "fetch_desc_valid", "fetch_desc")

    sge = pack_dma_desc(desc_id=0x16, dma_opcode=DMA_OP_SGE_FETCH, direction=DMA_DIR_SGE_FETCH, length=32)
    await send_source(dut, "sge_fetch_req", sge)
    out_sge = await wait_output(dut, "fetch_desc_valid", "fetch_desc")

    assert extract_field(DMA_DESC_FIELDS, out_wqe, "desc_id") == 0x15
    assert extract_field(DMA_DESC_FIELDS, out_sge, "desc_id") == 0x16


@cocotb.test()
async def unsupported_opcode_and_zero_length_report_dma_error(dut):
    await reset_dut(dut)

    bad_opcode = pack_dma_desc(desc_id=0x17, dma_opcode=DMA_OP_ERROR, direction=DMA_DIR_HOST_READ)
    await send_source(dut, "sq_dma_req", bad_opcode)
    err = await wait_error(dut)
    assert err["desc_id"] == 0x17
    assert err["error"] == DMA_DISP_ERR_UNSUPPORTED

    zero_len = pack_dma_desc(desc_id=0x18, dma_opcode=DMA_OP_SEND, direction=DMA_DIR_HOST_READ, length=0)
    await send_source(dut, "sq_dma_req", zero_len)
    err = await wait_error(dut)
    assert err["desc_id"] == 0x18
    assert err["error"] == DMA_DISP_ERR_LENGTH


@cocotb.test()
async def output_backpressure_holds_descriptor(dut):
    await reset_dut(dut)

    dut.host_read_desc_ready.value = 0
    desc = pack_dma_desc(desc_id=0x19, dma_opcode=DMA_OP_SEND, direction=DMA_DIR_HOST_READ)
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
        assert extract_field(DMA_DESC_FIELDS, dut.host_read_desc.value, "desc_id") == 0x19

    dut.host_read_desc_ready.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def simultaneous_inputs_use_fixed_priority(dut):
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
    dut.sq_dma_req_valid.value = 0
    dut.rq_dma_req_valid.value = 0
    dut.cqe_dma_req_valid.value = 0

    out = await wait_output(dut, "cqe_write_desc_valid", "cqe_write_desc")
    assert extract_field(DMA_DESC_FIELDS, out, "desc_id") == 0x22
