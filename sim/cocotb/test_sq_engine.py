# SPDX-License-Identifier: MIT
"""SQ engine 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


QP_TABLE_STATUS_OK = 0
QP_TABLE_STATUS_MISS = 1

QP_TYPE_RC = 0
QP_STATE_RESET = 0
QP_STATE_INIT = 1
QP_STATE_RTR = 2
QP_STATE_RTS = 3
QP_STATE_ERR = 6

RDMA_OP_SEND = 0x00
RDMA_OP_RDMA_WRITE = 0x02
RDMA_OP_RDMA_READ = 0x04
RDMA_OP_NOP = 0xFF

SQ_ENG_ERR_LOOKUP_MISS = 0x0001
SQ_ENG_ERR_BAD_STATE = 0x0003
SQ_ENG_ERR_UNSUPPORTED_OPCODE = 0x0004

WQE_BYTES = 64


QP_CONTEXT_FIELDS = [
    ("valid", 1),
    ("owner_func", 16),
    ("qpn", 24),
    ("qp_type", 3),
    ("state", 4),
    ("pd_id", 24),
    ("send_cqn", 24),
    ("recv_cqn", 24),
    ("sq_base", 64),
    ("rq_base", 64),
    ("sq_depth", 16),
    ("rq_depth", 16),
    ("sq_producer", 16),
    ("sq_consumer", 16),
    ("rq_producer", 16),
    ("rq_consumer", 16),
    ("remote_qpn", 24),
    ("sq_psn", 24),
    ("rq_psn", 24),
    ("last_acked_psn", 24),
    ("retry_count", 8),
    ("rnr_retry_count", 8),
    ("pkey", 16),
    ("qkey", 32),
    ("ah_id", 24),
    ("error_state", 1),
    ("error_code", 16),
]

WQE_FIELDS = [
    ("opcode", 8),
    ("flags", 8),
    ("sge_count", 8),
    ("wr_id", 64),
    ("local_va", 64),
    ("lkey", 32),
    ("length", 32),
    ("remote_va", 64),
    ("rkey", 32),
    ("imm_data", 32),
    ("inv_rkey", 32),
    ("compare_add", 64),
    ("swap", 64),
]

SQ_DISPATCH_REQ_FIELDS = [
    ("owner_func", 16),
    ("qpn", 24),
    ("opcode", 8),
    ("qp_type", 3),
    ("pd_id", 24),
    ("send_cqn", 24),
    ("sq_consumer", 16),
    ("wqe", 504),
]


def pack_fields(fields, values):
    packed = 0
    for name, width in fields:
        packed = (packed << width) | (values.get(name, 0) & ((1 << width) - 1))
    return packed


def unpack_fields(fields, packed):
    values = {}
    remaining = int(packed)
    for name, width in reversed(fields):
        values[name] = remaining & ((1 << width) - 1)
        remaining >>= width
    return values


def pack_qp_context(**overrides):
    values = {
        "valid": 1,
        "owner_func": 1,
        "qpn": 7,
        "qp_type": QP_TYPE_RC,
        "state": QP_STATE_RTS,
        "pd_id": 3,
        "send_cqn": 10,
        "recv_cqn": 11,
        "sq_base": 0x1000_0000,
        "rq_base": 0x2000_0000,
        "sq_depth": 16,
        "rq_depth": 16,
        "sq_producer": 1,
        "sq_consumer": 0,
        "rq_producer": 0,
        "rq_consumer": 0,
        "remote_qpn": 0x123,
        "sq_psn": 0x100,
        "rq_psn": 0x200,
        "last_acked_psn": 0,
        "retry_count": 7,
        "rnr_retry_count": 7,
        "pkey": 0xFFFF,
        "qkey": 0x1111_1111,
        "ah_id": 1,
        "error_state": 0,
        "error_code": 0,
    }
    values.update(overrides)
    return pack_fields(QP_CONTEXT_FIELDS, values)


def pack_wqe(opcode, **overrides):
    values = {
        "opcode": opcode,
        "flags": 0,
        "sge_count": 1,
        "wr_id": 0xABC,
        "local_va": 0x4000_0000,
        "lkey": 0x111,
        "length": 64,
        "remote_va": 0x5000_0000,
        "rkey": 0x222,
    }
    values.update(overrides)
    return pack_fields(WQE_FIELDS, values)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.sq_engine_enable.value = 1
    dut.sq_req_valid.value = 0
    dut.sq_req_qpn.value = 0
    dut.sq_req_function_id.value = 0
    dut.qp_read_ready.value = 1
    dut.qp_read_rsp_valid.value = 0
    dut.qp_read_hit.value = 0
    dut.qp_read_status.value = QP_TABLE_STATUS_MISS
    dut.qp_read_data.value = 0
    dut.wqe_fetch_req_ready.value = 1
    dut.wqe_fetch_rsp_valid.value = 0
    dut.wqe_fetch_rsp_wqe.value = 0
    dut.wqe_fetch_rsp_error.value = 0
    dut.dma_dispatch_ready.value = 1
    dut.transport_dispatch_ready.value = 1
    dut.local_inv_ready.value = 1
    dut.sq_ci_update_ready.value = 1
    dut.completion_req_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def start_sq(dut, qpn=7, function_id=1):
    dut.sq_req_valid.value = 1
    dut.sq_req_qpn.value = qpn
    dut.sq_req_function_id.value = function_id
    await RisingEdge(dut.clk)
    dut.sq_req_valid.value = 0


async def respond_qp(dut, context, hit=1, status=QP_TABLE_STATUS_OK):
    for _ in range(10):
        await RisingEdge(dut.clk)
        if int(dut.qp_read_valid.value) == 1:
            dut.qp_read_rsp_valid.value = 1
            dut.qp_read_hit.value = hit
            dut.qp_read_status.value = status
            dut.qp_read_data.value = context
            await RisingEdge(dut.clk)
            dut.qp_read_rsp_valid.value = 0
            return
    raise AssertionError("QP read request was not issued")


async def respond_wqe(dut, wqe, fetch_error=0):
    for _ in range(10):
        await RisingEdge(dut.clk)
        if int(dut.wqe_fetch_req_valid.value) == 1:
            dut.wqe_fetch_rsp_valid.value = 1
            dut.wqe_fetch_rsp_wqe.value = wqe
            dut.wqe_fetch_rsp_error.value = fetch_error
            await RisingEdge(dut.clk)
            dut.wqe_fetch_rsp_valid.value = 0
            return
    raise AssertionError("WQE fetch request was not issued")


async def wait_for_completion(dut):
    for _ in range(20):
        await RisingEdge(dut.clk)
        if int(dut.completion_req_valid.value) == 1:
            return int(dut.completion_error_code.value)
    raise AssertionError("completion/error request was not issued")


@cocotb.test()
async def rts_non_empty_sq_issues_wqe_fetch(dut):
    await reset_dut(dut)

    ctx = pack_qp_context(state=QP_STATE_RTS, sq_base=0x1000_0000, sq_consumer=2, sq_producer=3)
    await start_sq(dut)
    await respond_qp(dut, ctx)

    for _ in range(10):
        await RisingEdge(dut.clk)
        if int(dut.wqe_fetch_req_valid.value) == 1:
            assert int(dut.wqe_fetch_addr.value) == 0x1000_0000 + 2 * WQE_BYTES
            assert int(dut.wqe_fetch_sq_ci.value) == 2
            return

    raise AssertionError("SQ engine did not issue WQE fetch")


@cocotb.test()
async def empty_sq_does_not_fetch(dut):
    await reset_dut(dut)

    ctx = pack_qp_context(state=QP_STATE_RTS, sq_consumer=5, sq_producer=5)
    await start_sq(dut)
    await respond_qp(dut, ctx)

    for _ in range(8):
        await RisingEdge(dut.clk)
        assert int(dut.wqe_fetch_req_valid.value) == 0


@cocotb.test()
async def non_rts_states_are_rejected(dut):
    for state in [QP_STATE_RESET, QP_STATE_INIT, QP_STATE_RTR, QP_STATE_ERR]:
        await reset_dut(dut)
        ctx = pack_qp_context(state=state, sq_consumer=0, sq_producer=1)
        await start_sq(dut)
        await respond_qp(dut, ctx)
        assert await wait_for_completion(dut) == SQ_ENG_ERR_BAD_STATE


@cocotb.test()
async def nop_wqe_updates_consumer_index(dut):
    await reset_dut(dut)

    ctx = pack_qp_context(state=QP_STATE_RTS, sq_depth=16, sq_consumer=2, sq_producer=3)
    await start_sq(dut)
    await respond_qp(dut, ctx)
    await respond_wqe(dut, pack_wqe(RDMA_OP_NOP))

    for _ in range(20):
        await RisingEdge(dut.clk)
        if int(dut.sq_ci_update_valid.value) == 1:
            assert int(dut.sq_ci_update_new_ci.value) == 3
            return

    raise AssertionError("NOP WQE did not update SQ consumer index")


@cocotb.test()
async def unsupported_opcode_returns_error(dut):
    await reset_dut(dut)

    ctx = pack_qp_context(state=QP_STATE_RTS, sq_consumer=0, sq_producer=1)
    await start_sq(dut)
    await respond_qp(dut, ctx)
    await respond_wqe(dut, pack_wqe(0xEE))

    assert await wait_for_completion(dut) == SQ_ENG_ERR_UNSUPPORTED_OPCODE


@cocotb.test()
async def consumer_index_wraparound(dut):
    await reset_dut(dut)

    ctx = pack_qp_context(state=QP_STATE_RTS, sq_depth=4, sq_consumer=3, sq_producer=0)
    await start_sq(dut)
    await respond_qp(dut, ctx)
    await respond_wqe(dut, pack_wqe(RDMA_OP_NOP))

    for _ in range(20):
        await RisingEdge(dut.clk)
        if int(dut.sq_ci_update_valid.value) == 1:
            assert int(dut.sq_ci_update_new_ci.value) == 0
            return

    raise AssertionError("SQ consumer index did not wrap to zero")


@cocotb.test()
async def dispatch_request_basic_fields_are_correct(dut):
    await reset_dut(dut)

    ctx = pack_qp_context(
        state=QP_STATE_RTS,
        owner_func=3,
        qpn=21,
        pd_id=5,
        send_cqn=9,
        sq_consumer=1,
        sq_producer=2,
    )
    wqe = pack_wqe(RDMA_OP_SEND, wr_id=0x1234, length=32)

    await start_sq(dut, qpn=21, function_id=3)
    await respond_qp(dut, ctx)
    await respond_wqe(dut, wqe)

    for _ in range(20):
        await RisingEdge(dut.clk)
        if int(dut.transport_dispatch_valid.value) == 1:
            req = unpack_fields(SQ_DISPATCH_REQ_FIELDS, dut.transport_dispatch_req.value)
            assert req["owner_func"] == 3
            assert req["qpn"] == 21
            assert req["opcode"] == RDMA_OP_SEND
            assert req["qp_type"] == QP_TYPE_RC
            assert req["pd_id"] == 5
            assert req["send_cqn"] == 9
            assert req["sq_consumer"] == 1
            return

    raise AssertionError("SQ dispatch request was not generated")
