# SPDX-License-Identifier: MIT
"""Completion engine 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


CMPL_EVENT_SQ = 0
CMPL_EVENT_RQ = 1
CMPL_EVENT_CLEANUP = 2
CMPL_EVENT_ERROR = 3

CMPL_SRC_SQ = 0
CMPL_SRC_RQ = 1
CMPL_SRC_CLEANUP = 2

RDMA_OP_SEND = 0x00
RDMA_OP_SEND_WITH_IMM = 0x01
RDMA_OP_RDMA_WRITE = 0x02
RDMA_OP_RDMA_READ = 0x04
RDMA_OP_LOCAL_INV = 0x08
RDMA_OP_NOP = 0xFF

CMPL_SUCCESS = 0x00
CMPL_WR_FLUSH_ERR = 0x04
CMPL_GENERAL_ERR = 0xFF

CQ_TABLE_STATUS_OK = 0
CQ_TABLE_STATUS_MISS = 1
CQ_TABLE_STATUS_PERMISSION = 2

CMPL_ENG_ERR_NONE = 0
CMPL_ENG_ERR_CQ_MISS = 1
CMPL_ENG_ERR_PERMISSION = 2

CQE_SYNDROME_NONE = 0
CQE_SYNDROME_CQ_LOOKUP = 1
CQE_SYNDROME_PERMISSION = 2
CQE_SYNDROME_FLUSH = 3

CQE_FLAG_HAS_IMM = 0x0001
CQE_FLAG_SOLICITED = 0x0002
CQE_FLAG_ERROR = 0x0004
CQE_FLAG_FLUSH = 0x0008
CQE_FLAG_RECV = 0x0010
CQE_FLAG_SEND = 0x0020


CQ_CONTEXT_FIELDS = [
    ("valid", 1),
    ("cqn", 24),
    ("cq_buffer_base_addr", 64),
    ("cq_depth", 16),
    ("producer_index", 16),
    ("consumer_index", 16),
    ("owner_function", 16),
    ("msix_vector", 12),
    ("moderation_count", 16),
    ("moderation_timer", 16),
    ("moderation_counter", 16),
    ("moderation_timer_active", 1),
    ("armed", 1),
    ("solicited_only", 1),
    ("overflow", 1),
    ("error_state", 1),
    ("error_code", 16),
]


CQE_FIELDS = [
    ("wr_id", 64),
    ("qpn", 24),
    ("opcode", 8),
    ("status", 8),
    ("byte_len", 32),
    ("imm_data", 32),
    ("has_imm", 1),
    ("solicited", 1),
    ("vendor_error", 32),
    ("owner_function", 16),
    ("cqn", 24),
    ("syndrome", 16),
    ("flags", 16),
    ("timestamp", 64),
    ("valid", 1),
    ("owner_bit", 1),
    ("reserved", 172),
]


def pack_fields(fields, values):
    packed = 0
    for name, width in fields:
        packed = (packed << width) | (values.get(name, 0) & ((1 << width) - 1))
    return packed


def unpack_fields(fields, value):
    unpacked = {}
    offset = 0
    for name, width in reversed(fields):
        unpacked[name] = (int(value) >> offset) & ((1 << width) - 1)
        offset += width
    return unpacked


def pack_cq_context(cqn=7, owner_function=1, valid=1):
    return pack_fields(
        CQ_CONTEXT_FIELDS,
        {
            "valid": valid,
            "cqn": cqn,
            "cq_buffer_base_addr": 0x3000_0000,
            "cq_depth": 128,
            "producer_index": 0,
            "consumer_index": 0,
            "owner_function": owner_function,
            "msix_vector": 2,
        },
    )


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0

    dut.event_valid.value = 0
    dut.event_type.value = 0
    dut.qpn.value = 0
    dut.cqn.value = 0
    dut.owner_function.value = 0
    dut.wr_id.value = 0
    dut.opcode.value = 0
    dut.status.value = 0
    dut.byte_len.value = 0
    dut.imm_data.value = 0
    dut.has_imm.value = 0
    dut.solicited.value = 0
    dut.vendor_error.value = 0
    dut.source_engine.value = 0

    dut.cq_lookup_ready.value = 1
    dut.cq_lookup_rsp_valid.value = 0
    dut.cq_lookup_hit.value = 0
    dut.cq_lookup_miss.value = 0
    dut.cq_lookup_status.value = CQ_TABLE_STATUS_MISS
    dut.cq_lookup_context.value = 0

    dut.cqe_write_ready.value = 1

    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def respond_to_lookup(dut, *, hit=True, status=CQ_TABLE_STATUS_OK, cqn=7, owner=1):
    for _ in range(8):
        await Timer(1, units="ns")
        if int(dut.cq_lookup_valid.value) == 1:
            break
        await RisingEdge(dut.clk)

    await RisingEdge(dut.clk)
    dut.cq_lookup_rsp_valid.value = 1
    dut.cq_lookup_hit.value = 1 if hit else 0
    dut.cq_lookup_miss.value = 0 if hit else 1
    dut.cq_lookup_status.value = status
    dut.cq_lookup_context.value = pack_cq_context(cqn=cqn, owner_function=owner, valid=1 if hit else 0)
    await RisingEdge(dut.clk)
    dut.cq_lookup_rsp_valid.value = 0


async def send_event(
    dut,
    *,
    event_type=CMPL_EVENT_SQ,
    qpn=0x22,
    cqn=7,
    owner=1,
    wr_id=0xABCD,
    opcode=RDMA_OP_SEND,
    status=CMPL_SUCCESS,
    byte_len=64,
    imm_data=0,
    has_imm=0,
    solicited=0,
    vendor_error=0,
    source=CMPL_SRC_SQ,
):
    dut.event_valid.value = 1
    dut.event_type.value = event_type
    dut.qpn.value = qpn
    dut.cqn.value = cqn
    dut.owner_function.value = owner
    dut.wr_id.value = wr_id
    dut.opcode.value = opcode
    dut.status.value = status
    dut.byte_len.value = byte_len
    dut.imm_data.value = imm_data
    dut.has_imm.value = has_imm
    dut.solicited.value = solicited
    dut.vendor_error.value = vendor_error
    dut.source_engine.value = source
    await RisingEdge(dut.clk)
    dut.event_valid.value = 0


async def wait_for_cqe(dut, max_cycles=16):
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        if int(dut.cqe_write_valid.value) == 1:
            return unpack_fields(CQE_FIELDS, dut.cqe_write_data.value)
    raise AssertionError("completion_engine did not produce cqe_write_valid")


@cocotb.test()
async def sq_success_event_formats_64_byte_cqe(dut):
    await reset_dut(dut)

    await send_event(dut, event_type=CMPL_EVENT_SQ, opcode=RDMA_OP_RDMA_WRITE, byte_len=128)
    await respond_to_lookup(dut, hit=True, cqn=7, owner=1)
    cqe = await wait_for_cqe(dut)

    assert len(dut.cqe_write_data) == 512
    assert cqe["valid"] == 1
    assert cqe["status"] == CMPL_SUCCESS
    assert cqe["opcode"] == RDMA_OP_RDMA_WRITE
    assert cqe["byte_len"] == 128
    assert cqe["flags"] & CQE_FLAG_SEND
    assert cqe["syndrome"] == CQE_SYNDROME_NONE


@cocotb.test()
async def rq_recv_event_formats_cqe(dut):
    await reset_dut(dut)

    await send_event(dut, event_type=CMPL_EVENT_RQ, opcode=RDMA_OP_SEND, byte_len=96, source=CMPL_SRC_RQ)
    await respond_to_lookup(dut, hit=True, cqn=7, owner=1)
    cqe = await wait_for_cqe(dut)

    assert cqe["status"] == CMPL_SUCCESS
    assert cqe["opcode"] == RDMA_OP_SEND
    assert cqe["flags"] & CQE_FLAG_RECV


@cocotb.test()
async def recv_with_imm_carries_immediate_data(dut):
    await reset_dut(dut)

    await send_event(
        dut,
        event_type=CMPL_EVENT_RQ,
        opcode=RDMA_OP_SEND,
        imm_data=0x11223344,
        has_imm=1,
        solicited=1,
        source=CMPL_SRC_RQ,
    )
    await respond_to_lookup(dut, hit=True, cqn=7, owner=1)
    cqe = await wait_for_cqe(dut)

    assert cqe["opcode"] == RDMA_OP_SEND_WITH_IMM
    assert cqe["imm_data"] == 0x11223344
    assert cqe["has_imm"] == 1
    assert cqe["solicited"] == 1
    assert cqe["flags"] & CQE_FLAG_HAS_IMM
    assert cqe["flags"] & CQE_FLAG_SOLICITED


@cocotb.test()
async def cleanup_flush_event_generates_wr_flush_error(dut):
    await reset_dut(dut)

    await send_event(dut, event_type=CMPL_EVENT_CLEANUP, status=CMPL_SUCCESS, source=CMPL_SRC_CLEANUP)
    await respond_to_lookup(dut, hit=True, cqn=7, owner=1)
    cqe = await wait_for_cqe(dut)

    assert cqe["status"] == CMPL_WR_FLUSH_ERR
    assert cqe["syndrome"] == CQE_SYNDROME_FLUSH
    assert cqe["flags"] & CQE_FLAG_FLUSH
    assert cqe["flags"] & CQE_FLAG_ERROR


@cocotb.test()
async def cq_lookup_miss_returns_error_cqe(dut):
    await reset_dut(dut)

    await send_event(dut, cqn=99)
    await respond_to_lookup(dut, hit=False, status=CQ_TABLE_STATUS_MISS, cqn=99, owner=1)
    cqe = await wait_for_cqe(dut)

    assert int(dut.error_code.value) == CMPL_ENG_ERR_CQ_MISS
    assert cqe["status"] == CMPL_GENERAL_ERR
    assert cqe["syndrome"] == CQE_SYNDROME_CQ_LOOKUP
    assert cqe["flags"] & CQE_FLAG_ERROR


@cocotb.test()
async def owner_function_mismatch_returns_permission_error(dut):
    await reset_dut(dut)

    await send_event(dut, owner=2)
    await respond_to_lookup(dut, hit=True, status=CQ_TABLE_STATUS_PERMISSION, cqn=7, owner=1)
    cqe = await wait_for_cqe(dut)

    assert int(dut.error_code.value) == CMPL_ENG_ERR_PERMISSION
    assert cqe["status"] == CMPL_GENERAL_ERR
    assert cqe["syndrome"] == CQE_SYNDROME_PERMISSION


@cocotb.test()
async def downstream_backpressure_holds_completion_event(dut):
    await reset_dut(dut)
    dut.cqe_write_ready.value = 0

    await send_event(dut, wr_id=0xCAFE)
    await respond_to_lookup(dut, hit=True, cqn=7, owner=1)

    held = await wait_for_cqe(dut)
    for _ in range(3):
        await RisingEdge(dut.clk)
        assert int(dut.cqe_write_valid.value) == 1
        assert unpack_fields(CQE_FIELDS, dut.cqe_write_data.value)["wr_id"] == held["wr_id"]

    dut.cqe_write_ready.value = 1
    await RisingEdge(dut.clk)
