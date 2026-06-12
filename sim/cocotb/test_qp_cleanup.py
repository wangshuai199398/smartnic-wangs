# SPDX-License-Identifier: MIT
"""QP cleanup manager 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


QP_TABLE_STATUS_OK = 0
QP_TABLE_STATUS_MISS = 1
QP_TABLE_STATUS_PERMISSION = 2

QP_CLEAN_ERR_NONE = 0x0000
QP_CLEAN_ERR_PERMISSION = 0x0002
QP_CLEAN_ERR_TIMEOUT = 0x0003
QP_CLEAN_ERR_ALREADY_ERR = 0x0006
QP_CLEAN_ERR_ALREADY_DESTROYED = 0x0007

QP_CLEAN_REASON_DESTROY = 1
QP_CLEAN_REASON_ERROR = 2

QP_STATE_RESET = 0
QP_STATE_RTS = 3
QP_STATE_ERR = 6

CMPL_WR_FLUSH_ERR = 0x04


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

FLUSH_COMPLETION_FIELDS = [
    ("owner_func", 16),
    ("qpn", 24),
    ("cqn", 24),
    ("status", 8),
    ("is_sq", 1),
    ("is_rq", 1),
    ("queue_index", 16),
    ("reason", 2),
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
        "qp_type": 0,
        "state": QP_STATE_RTS,
        "pd_id": 3,
        "send_cqn": 10,
        "recv_cqn": 11,
        "sq_base": 0x1000_0000,
        "rq_base": 0x2000_0000,
        "sq_depth": 8,
        "rq_depth": 8,
        "sq_producer": 0,
        "sq_consumer": 0,
        "rq_producer": 0,
        "rq_consumer": 0,
        "remote_qpn": 0,
        "sq_psn": 0,
        "rq_psn": 0,
        "last_acked_psn": 0,
        "retry_count": 0,
        "rnr_retry_count": 0,
        "pkey": 0xFFFF,
        "qkey": 0,
        "ah_id": 0,
        "error_state": 0,
        "error_code": 0,
    }
    values.update(overrides)
    return pack_fields(QP_CONTEXT_FIELDS, values)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.destroy_qp_req_valid.value = 0
    dut.destroy_qp_qpn.value = 0
    dut.destroy_qp_function_id.value = 0
    dut.destroy_qp_admin_bypass.value = 0
    dut.destroy_qp_sequence.value = 0
    dut.error_qp_req_valid.value = 0
    dut.error_qp_qpn.value = 0
    dut.error_qp_function_id.value = 0
    dut.error_qp_admin_bypass.value = 0
    dut.error_qp_error_code.value = 0
    dut.error_qp_sequence.value = 0
    dut.context_read_ready.value = 1
    dut.context_read_rsp_valid.value = 0
    dut.context_read_hit.value = 0
    dut.context_read_status.value = QP_TABLE_STATUS_MISS
    dut.context_read_data.value = 0
    dut.context_write_ready.value = 1
    dut.context_write_rsp_valid.value = 0
    dut.context_write_status.value = QP_TABLE_STATUS_OK
    dut.qp_block_doorbell_ready.value = 1
    dut.sq_inflight_count.value = 0
    dut.rq_inflight_count.value = 0
    dut.dma_inflight_count.value = 0
    dut.transport_inflight_count.value = 0
    dut.cleanup_timeout_limit.value = 8
    dut.flush_completion_ready.value = 1
    dut.cleanup_done_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def request_destroy(dut, qpn=7, owner=1):
    dut.destroy_qp_req_valid.value = 1
    dut.destroy_qp_qpn.value = qpn
    dut.destroy_qp_function_id.value = owner
    dut.destroy_qp_sequence.value = 0xD1
    await RisingEdge(dut.clk)
    dut.destroy_qp_req_valid.value = 0


async def request_error(dut, qpn=7, owner=1, error_code=0xBEEF):
    dut.error_qp_req_valid.value = 1
    dut.error_qp_qpn.value = qpn
    dut.error_qp_function_id.value = owner
    dut.error_qp_error_code.value = error_code
    dut.error_qp_sequence.value = 0xE1
    await RisingEdge(dut.clk)
    dut.error_qp_req_valid.value = 0


async def respond_read(dut, ctx, hit=1, status=QP_TABLE_STATUS_OK):
    for _ in range(10):
        await RisingEdge(dut.clk)
        if int(dut.context_read_valid.value) == 1:
            dut.context_read_rsp_valid.value = 1
            dut.context_read_hit.value = hit
            dut.context_read_status.value = status
            dut.context_read_data.value = ctx
            await RisingEdge(dut.clk)
            dut.context_read_rsp_valid.value = 0
            return
    raise AssertionError("context read request was not issued")


async def respond_write(dut, status=QP_TABLE_STATUS_OK):
    for _ in range(40):
        await RisingEdge(dut.clk)
        if int(dut.context_write_valid.value) == 1:
            written = int(dut.context_write_data.value)
            dut.context_write_rsp_valid.value = 1
            dut.context_write_status.value = status
            await RisingEdge(dut.clk)
            dut.context_write_rsp_valid.value = 0
            return written
    raise AssertionError("context write request was not issued")


async def wait_done(dut):
    for _ in range(50):
        await RisingEdge(dut.clk)
        if int(dut.cleanup_done_valid.value) == 1:
            result = {
                "error": int(dut.cleanup_done_error_code.value),
                "context": int(dut.cleanup_done_context.value),
                "reason": int(dut.cleanup_done_reason.value),
            }
            dut.cleanup_done_ready.value = 1
            await RisingEdge(dut.clk)
            dut.cleanup_done_ready.value = 0
            return result
    raise AssertionError("cleanup did not finish")


async def collect_flushes(dut, count):
    flushes = []
    for _ in range(60):
        await RisingEdge(dut.clk)
        if int(dut.flush_completion_valid.value) == 1:
            flushes.append(unpack_fields(FLUSH_COMPLETION_FIELDS, dut.flush_completion_req.value))
            if len(flushes) == count:
                return flushes
    raise AssertionError("expected flushed completions were not generated")


@cocotb.test()
async def destroy_qp_blocks_new_doorbells(dut):
    await reset_dut(dut)

    await request_destroy(dut)
    await respond_read(dut, pack_qp_context(qpn=7, owner_func=1))

    for _ in range(10):
        await RisingEdge(dut.clk)
        if int(dut.qp_block_doorbell_valid.value) == 1:
            assert int(dut.qp_block_doorbell_qpn.value) == 7
            assert int(dut.qp_block_doorbell_function_id.value) == 1
            return

    raise AssertionError("doorbell block request was not generated")


@cocotb.test()
async def destroy_qp_waits_for_inflight_work_to_drain(dut):
    await reset_dut(dut)

    dut.sq_inflight_count.value = 1
    await request_destroy(dut)
    await respond_read(dut, pack_qp_context(qpn=7, owner_func=1, sq_consumer=0, sq_producer=1))

    for _ in range(4):
        await RisingEdge(dut.clk)
        assert int(dut.flush_completion_valid.value) == 0

    dut.sq_inflight_count.value = 0
    flushes = await collect_flushes(dut, 1)
    assert flushes[0]["is_sq"] == 1


@cocotb.test()
async def destroy_qp_flushes_pending_sq_wqes(dut):
    await reset_dut(dut)

    ctx = pack_qp_context(qpn=7, owner_func=1, send_cqn=20, sq_depth=8, sq_consumer=0, sq_producer=2)
    await request_destroy(dut)
    await respond_read(dut, ctx)

    flushes = await collect_flushes(dut, 2)
    assert [f["queue_index"] for f in flushes] == [0, 1]
    assert all(f["is_sq"] == 1 for f in flushes)
    assert all(f["cqn"] == 20 for f in flushes)
    assert all(f["status"] == CMPL_WR_FLUSH_ERR for f in flushes)


@cocotb.test()
async def destroy_qp_flushes_pending_rq_wqes(dut):
    await reset_dut(dut)

    ctx = pack_qp_context(
        qpn=7,
        owner_func=1,
        recv_cqn=30,
        sq_depth=8,
        rq_depth=8,
        sq_consumer=0,
        sq_producer=0,
        rq_consumer=6,
        rq_producer=0,
    )
    await request_destroy(dut)
    await respond_read(dut, ctx)

    flushes = await collect_flushes(dut, 2)
    assert [f["queue_index"] for f in flushes] == [6, 7]
    assert all(f["is_rq"] == 1 for f in flushes)
    assert all(f["cqn"] == 30 for f in flushes)
    assert all(f["status"] == CMPL_WR_FLUSH_ERR for f in flushes)


@cocotb.test()
async def error_qp_moves_state_to_err(dut):
    await reset_dut(dut)

    ctx = pack_qp_context(qpn=7, owner_func=1, state=QP_STATE_RTS)
    await request_error(dut, error_code=0xBEEF)
    await respond_read(dut, ctx)
    written = await respond_write(dut)
    result = await wait_done(dut)
    written_ctx = unpack_fields(QP_CONTEXT_FIELDS, written)

    assert result["error"] == QP_CLEAN_ERR_NONE
    assert result["reason"] == QP_CLEAN_REASON_ERROR
    assert written_ctx["valid"] == 1
    assert written_ctx["state"] == QP_STATE_ERR
    assert written_ctx["error_state"] == 1
    assert written_ctx["error_code"] == 0xBEEF


@cocotb.test()
async def cleanup_timeout_returns_error(dut):
    await reset_dut(dut)

    dut.cleanup_timeout_limit.value = 3
    dut.dma_inflight_count.value = 1
    await request_destroy(dut)
    await respond_read(dut, pack_qp_context(qpn=7, owner_func=1))
    result = await wait_done(dut)

    assert result["error"] == QP_CLEAN_ERR_TIMEOUT


@cocotb.test()
async def cross_function_destroy_is_rejected(dut):
    await reset_dut(dut)

    await request_destroy(dut, qpn=7, owner=2)
    await respond_read(
        dut,
        pack_qp_context(qpn=7, owner_func=1),
        hit=0,
        status=QP_TABLE_STATUS_PERMISSION,
    )
    result = await wait_done(dut)

    assert result["error"] == QP_CLEAN_ERR_PERMISSION


@cocotb.test()
async def destroy_after_qp_already_destroyed_returns_status(dut):
    await reset_dut(dut)

    await request_destroy(dut, qpn=7, owner=1)
    await respond_read(dut, 0, hit=0, status=QP_TABLE_STATUS_MISS)
    result = await wait_done(dut)

    assert result["error"] == QP_CLEAN_ERR_ALREADY_DESTROYED


@cocotb.test()
async def error_cleanup_on_already_err_qp_returns_status(dut):
    await reset_dut(dut)

    ctx = pack_qp_context(qpn=7, owner_func=1, state=QP_STATE_ERR, error_state=1)
    await request_error(dut)
    await respond_read(dut, ctx)
    result = await wait_done(dut)

    assert result["error"] == QP_CLEAN_ERR_ALREADY_ERR
