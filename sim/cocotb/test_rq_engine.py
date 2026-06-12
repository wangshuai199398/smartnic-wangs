# SPDX-License-Identifier: MIT
"""RQ engine 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


QP_TABLE_STATUS_OK = 0

QP_TYPE_RC = 0
QP_STATE_RESET = 0
QP_STATE_INIT = 1
QP_STATE_RTR = 2
QP_STATE_RTS = 3
QP_STATE_ERR = 6

RQ_ENG_ERR_BAD_STATE = 0x0003
RQ_ENG_ERR_RNR = 0x0004
RQ_ENG_ERR_LOCAL_LEN = 0x0006

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

RQ_DMA_WRITE_REQ_FIELDS = [
    ("owner_func", 16),
    ("qpn", 24),
    ("pd_id", 24),
    ("wr_id", 64),
    ("dst_addr", 64),
    ("lkey", 32),
    ("length", 32),
    ("flags", 8),
]

RQ_COMPLETION_REQ_FIELDS = [
    ("owner_func", 16),
    ("qpn", 24),
    ("cqn", 24),
    ("wr_id", 64),
    ("status", 8),
    ("byte_count", 32),
    ("recv_with_imm", 1),
    ("has_imm", 1),
    ("imm_data", 32),
    ("solicited", 1),
    ("error_code", 16),
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
        "sq_producer": 0,
        "sq_consumer": 0,
        "rq_producer": 1,
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


def pack_recv_wqe(**overrides):
    values = {
        "opcode": 0,
        "flags": 0,
        "sge_count": 1,
        "wr_id": 0xABC,
        "local_va": 0x4000_0000,
        "lkey": 0x111,
        "length": 128,
        "remote_va": 0,
        "rkey": 0,
        "imm_data": 0,
        "inv_rkey": 0,
        "compare_add": 0,
        "swap": 0,
    }
    values.update(overrides)
    return pack_fields(WQE_FIELDS, values)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.rq_engine_enable.value = 1
    dut.inbound_send_valid.value = 0
    dut.inbound_qpn.value = 0
    dut.inbound_function_id.value = 0
    dut.inbound_payload_len.value = 0
    dut.inbound_has_imm.value = 0
    dut.inbound_imm_data.value = 0
    dut.inbound_solicited.value = 0
    dut.inbound_packet_metadata.value = 0
    dut.qp_read_ready.value = 1
    dut.qp_read_rsp_valid.value = 0
    dut.qp_read_hit.value = 0
    dut.qp_read_status.value = QP_TABLE_STATUS_OK
    dut.qp_read_data.value = 0
    dut.recv_wqe_fetch_req_ready.value = 1
    dut.recv_wqe_fetch_rsp_valid.value = 0
    dut.recv_wqe_fetch_rsp_wqe.value = 0
    dut.recv_wqe_fetch_rsp_error.value = 0
    dut.dma_write_ready.value = 1
    dut.dma_write_rsp_valid.value = 0
    dut.dma_write_rsp_error.value = 0
    dut.rq_ci_update_ready.value = 1
    dut.completion_req_ready.value = 1
    dut.rnr_error_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def start_recv(dut, qpn=7, function_id=1, payload_len=64, has_imm=0, imm_data=0, solicited=0):
    dut.inbound_send_valid.value = 1
    dut.inbound_qpn.value = qpn
    dut.inbound_function_id.value = function_id
    dut.inbound_payload_len.value = payload_len
    dut.inbound_has_imm.value = has_imm
    dut.inbound_imm_data.value = imm_data
    dut.inbound_solicited.value = solicited
    await RisingEdge(dut.clk)
    dut.inbound_send_valid.value = 0


async def respond_qp(dut, context):
    for _ in range(10):
        await RisingEdge(dut.clk)
        if int(dut.qp_read_valid.value) == 1:
            dut.qp_read_rsp_valid.value = 1
            dut.qp_read_hit.value = 1
            dut.qp_read_status.value = QP_TABLE_STATUS_OK
            dut.qp_read_data.value = context
            await RisingEdge(dut.clk)
            dut.qp_read_rsp_valid.value = 0
            return
    raise AssertionError("QP read request was not issued")


async def respond_recv_wqe(dut, wqe, fetch_error=0):
    for _ in range(20):
        await RisingEdge(dut.clk)
        if int(dut.recv_wqe_fetch_req_valid.value) == 1:
            dut.recv_wqe_fetch_rsp_valid.value = 1
            dut.recv_wqe_fetch_rsp_wqe.value = wqe
            dut.recv_wqe_fetch_rsp_error.value = fetch_error
            await RisingEdge(dut.clk)
            dut.recv_wqe_fetch_rsp_valid.value = 0
            return
    raise AssertionError("Recv WQE fetch request was not issued")


async def respond_dma_write(dut, error=0):
    for _ in range(20):
        await RisingEdge(dut.clk)
        if int(dut.dma_write_valid.value) == 1:
            dut.dma_write_rsp_valid.value = 1
            dut.dma_write_rsp_error.value = error
            await RisingEdge(dut.clk)
            dut.dma_write_rsp_valid.value = 0
            return
    raise AssertionError("DMA write request was not issued")


async def wait_for_completion_error(dut):
    for _ in range(30):
        await RisingEdge(dut.clk)
        if int(dut.completion_req_valid.value) == 1:
            return unpack_fields(RQ_COMPLETION_REQ_FIELDS, dut.completion_req.value)["error_code"]
    raise AssertionError("completion request was not issued")


async def wait_for_rnr(dut):
    for _ in range(30):
        await RisingEdge(dut.clk)
        if int(dut.rnr_error_valid.value) == 1:
            return int(dut.rnr_error_qpn.value)
    raise AssertionError("RNR indication was not issued")


@cocotb.test()
async def rtr_non_empty_rq_issues_recv_wqe_fetch(dut):
    await reset_dut(dut)

    ctx = pack_qp_context(state=QP_STATE_RTR, rq_base=0x2000_0000, rq_consumer=2, rq_producer=3)
    await start_recv(dut)
    await respond_qp(dut, ctx)

    for _ in range(10):
        await RisingEdge(dut.clk)
        if int(dut.recv_wqe_fetch_req_valid.value) == 1:
            assert int(dut.recv_wqe_fetch_addr.value) == 0x2000_0000 + 2 * WQE_BYTES
            assert int(dut.recv_wqe_fetch_rq_ci.value) == 2
            return

    raise AssertionError("RQ engine did not issue Recv WQE fetch")


@cocotb.test()
async def rts_non_empty_rq_allows_receive(dut):
    await reset_dut(dut)

    ctx = pack_qp_context(state=QP_STATE_RTS, rq_consumer=0, rq_producer=1)
    await start_recv(dut)
    await respond_qp(dut, ctx)

    for _ in range(10):
        await RisingEdge(dut.clk)
        if int(dut.recv_wqe_fetch_req_valid.value) == 1:
            return

    raise AssertionError("RTS QP did not allow receive")


@cocotb.test()
async def empty_rq_returns_rnr(dut):
    await reset_dut(dut)

    ctx = pack_qp_context(state=QP_STATE_RTS, rq_consumer=5, rq_producer=5)
    await start_recv(dut, qpn=7)
    await respond_qp(dut, ctx)

    assert await wait_for_rnr(dut) == 7
    assert int(dut.debug_error_code.value) == RQ_ENG_ERR_RNR


@cocotb.test()
async def invalid_receive_states_are_rejected(dut):
    for state in [QP_STATE_RESET, QP_STATE_INIT, QP_STATE_ERR]:
        await reset_dut(dut)
        ctx = pack_qp_context(state=state, rq_consumer=0, rq_producer=1)
        await start_recv(dut)
        await respond_qp(dut, ctx)
        assert await wait_for_completion_error(dut) == RQ_ENG_ERR_BAD_STATE


@cocotb.test()
async def payload_larger_than_recv_buffer_returns_local_length_error(dut):
    await reset_dut(dut)

    ctx = pack_qp_context(state=QP_STATE_RTS, rq_consumer=0, rq_producer=1)
    await start_recv(dut, payload_len=256)
    await respond_qp(dut, ctx)
    await respond_recv_wqe(dut, pack_recv_wqe(length=128))

    assert await wait_for_completion_error(dut) == RQ_ENG_ERR_LOCAL_LEN


@cocotb.test()
async def successful_receive_updates_rq_consumer_index(dut):
    await reset_dut(dut)

    ctx = pack_qp_context(state=QP_STATE_RTS, rq_depth=16, rq_consumer=2, rq_producer=3)
    await start_recv(dut, payload_len=64)
    await respond_qp(dut, ctx)
    await respond_recv_wqe(dut, pack_recv_wqe(local_va=0x4000_1000, lkey=0x123, length=128))

    for _ in range(20):
        await RisingEdge(dut.clk)
        if int(dut.dma_write_valid.value) == 1:
            dma_req = unpack_fields(RQ_DMA_WRITE_REQ_FIELDS, dut.dma_write_req.value)
            assert dma_req["dst_addr"] == 0x4000_1000
            assert dma_req["lkey"] == 0x123
            assert dma_req["length"] == 64
            break
    else:
        raise AssertionError("DMA write request was not issued")

    await respond_dma_write(dut)

    for _ in range(20):
        await RisingEdge(dut.clk)
        if int(dut.rq_ci_update_valid.value) == 1:
            assert int(dut.rq_ci_update_new_ci.value) == 3
            return

    raise AssertionError("RQ consumer index was not updated")


@cocotb.test()
async def consumer_index_wraparound(dut):
    await reset_dut(dut)

    ctx = pack_qp_context(state=QP_STATE_RTS, rq_depth=4, rq_consumer=3, rq_producer=0)
    await start_recv(dut)
    await respond_qp(dut, ctx)
    await respond_recv_wqe(dut, pack_recv_wqe())
    await respond_dma_write(dut)

    for _ in range(20):
        await RisingEdge(dut.clk)
        if int(dut.rq_ci_update_valid.value) == 1:
            assert int(dut.rq_ci_update_new_ci.value) == 0
            return

    raise AssertionError("RQ consumer index did not wrap to zero")


@cocotb.test()
async def successful_receive_generates_completion_request(dut):
    await reset_dut(dut)

    ctx = pack_qp_context(state=QP_STATE_RTS, rq_consumer=0, rq_producer=1, recv_cqn=22)
    await start_recv(dut, payload_len=32, has_imm=1, imm_data=0xDEAD_BEEF, solicited=1)
    await respond_qp(dut, ctx)
    await respond_recv_wqe(dut, pack_recv_wqe(wr_id=0x55, length=64))
    await respond_dma_write(dut)

    for _ in range(30):
        await RisingEdge(dut.clk)
        if int(dut.completion_req_valid.value) == 1:
            completion = unpack_fields(RQ_COMPLETION_REQ_FIELDS, dut.completion_req.value)
            assert completion["cqn"] == 22
            assert completion["wr_id"] == 0x55
            assert completion["byte_count"] == 32
            assert completion["recv_with_imm"] == 1
            assert completion["has_imm"] == 1
            assert completion["imm_data"] == 0xDEAD_BEEF
            assert completion["solicited"] == 1
            return

    raise AssertionError("receive completion request was not generated")
