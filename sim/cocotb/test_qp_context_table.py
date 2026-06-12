# SPDX-License-Identifier: MIT
"""QP context table 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


QP_TABLE_STATUS_OK = 0
QP_TABLE_STATUS_MISS = 1
QP_TABLE_STATUS_PERMISSION = 2
QP_TABLE_STATUS_ALIAS = 3

QP_TYPE_RC = 0
QP_STATE_RTS = 3


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
        "sq_depth": 128,
        "rq_depth": 128,
        "sq_producer": 0,
        "sq_consumer": 0,
        "rq_producer": 0,
        "rq_consumer": 0,
        "remote_qpn": 0x123,
        "sq_psn": 0x100,
        "rq_psn": 0x200,
        "last_acked_psn": 0x0FF,
        "retry_count": 7,
        "rnr_retry_count": 7,
        "pkey": 0xFFFF,
        "qkey": 0x1111_1111,
        "ah_id": 0,
        "error_state": 0,
        "error_code": 0,
    }
    values.update(overrides)

    packed = 0
    for name, width in QP_CONTEXT_FIELDS:
        packed = (packed << width) | (values[name] & ((1 << width) - 1))
    return packed


def extract_field(packed, field_name):
    offset = 0
    for name, width in reversed(QP_CONTEXT_FIELDS):
        if name == field_name:
            return (packed >> offset) & ((1 << width) - 1)
        offset += width
    raise KeyError(field_name)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0

    dut.lookup_valid.value = 0
    dut.lookup_qpn.value = 0
    dut.lookup_function_id.value = 0
    dut.lookup_pf_bypass.value = 0
    dut.lookup_rsp_ready.value = 0

    dut.context_write_valid.value = 0
    dut.context_write_qpn.value = 0
    dut.context_write_function_id.value = 0
    dut.context_write_pf_bypass.value = 0
    dut.context_write_use_index.value = 0
    dut.context_write_index.value = 0
    dut.context_write_data.value = 0
    dut.context_write_rsp_ready.value = 0

    dut.context_read_valid.value = 0
    dut.context_read_qpn.value = 0
    dut.context_read_function_id.value = 0
    dut.context_read_pf_bypass.value = 0
    dut.context_read_rsp_ready.value = 0

    dut.sq_pi_update_valid.value = 0
    dut.sq_pi_update_qpn.value = 0
    dut.sq_pi_update_function_id.value = 0
    dut.sq_pi_update_new_pi.value = 0
    dut.sq_pi_update_error.value = 0
    dut.sq_pi_update_rsp_ready.value = 0

    dut.rq_pi_update_valid.value = 0
    dut.rq_pi_update_qpn.value = 0
    dut.rq_pi_update_function_id.value = 0
    dut.rq_pi_update_new_pi.value = 0
    dut.rq_pi_update_error.value = 0
    dut.rq_pi_update_rsp_ready.value = 0

    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def clear_response(dut, ready_name):
    getattr(dut, ready_name).value = 1
    await RisingEdge(dut.clk)
    getattr(dut, ready_name).value = 0


async def write_context(dut, qpn, owner=1, index=0, use_index=0):
    dut.context_write_valid.value = 1
    dut.context_write_qpn.value = qpn
    dut.context_write_function_id.value = owner
    dut.context_write_pf_bypass.value = 0
    dut.context_write_use_index.value = use_index
    dut.context_write_index.value = index
    dut.context_write_data.value = pack_qp_context(qpn=qpn, owner_func=owner)
    await RisingEdge(dut.clk)
    dut.context_write_valid.value = 0
    status = int(dut.context_write_status.value)
    await clear_response(dut, "context_write_rsp_ready")
    return status


async def lookup_context(dut, qpn, function_id=1):
    dut.lookup_valid.value = 1
    dut.lookup_qpn.value = qpn
    dut.lookup_function_id.value = function_id
    dut.lookup_pf_bypass.value = 0
    await RisingEdge(dut.clk)
    dut.lookup_valid.value = 0
    result = {
        "status": int(dut.lookup_status.value),
        "hit": int(dut.lookup_hit.value),
        "miss": int(dut.lookup_miss.value),
        "context": int(dut.lookup_context.value),
    }
    await clear_response(dut, "lookup_rsp_ready")
    return result


async def read_context(dut, qpn, function_id=1):
    dut.context_read_valid.value = 1
    dut.context_read_qpn.value = qpn
    dut.context_read_function_id.value = function_id
    dut.context_read_pf_bypass.value = 0
    await RisingEdge(dut.clk)
    dut.context_read_valid.value = 0
    result = {
        "status": int(dut.context_read_status.value),
        "hit": int(dut.context_read_hit.value),
        "data": int(dut.context_read_data.value),
    }
    await clear_response(dut, "context_read_rsp_ready")
    return result


async def update_sq_pi(dut, qpn, function_id, new_pi, upstream_error=0):
    dut.sq_pi_update_valid.value = 1
    dut.sq_pi_update_qpn.value = qpn
    dut.sq_pi_update_function_id.value = function_id
    dut.sq_pi_update_new_pi.value = new_pi
    dut.sq_pi_update_error.value = upstream_error
    await RisingEdge(dut.clk)
    dut.sq_pi_update_valid.value = 0
    status = int(dut.sq_pi_update_status.value)
    await clear_response(dut, "sq_pi_update_rsp_ready")
    return status


async def update_rq_pi(dut, qpn, function_id, new_pi, upstream_error=0):
    dut.rq_pi_update_valid.value = 1
    dut.rq_pi_update_qpn.value = qpn
    dut.rq_pi_update_function_id.value = function_id
    dut.rq_pi_update_new_pi.value = new_pi
    dut.rq_pi_update_error.value = upstream_error
    await RisingEdge(dut.clk)
    dut.rq_pi_update_valid.value = 0
    status = int(dut.rq_pi_update_status.value)
    await clear_response(dut, "rq_pi_update_rsp_ready")
    return status


@cocotb.test()
async def write_and_lookup_qp_context(dut):
    await reset_dut(dut)

    assert await write_context(dut, qpn=7, owner=1) == QP_TABLE_STATUS_OK
    result = await lookup_context(dut, qpn=7, function_id=1)

    assert result["status"] == QP_TABLE_STATUS_OK
    assert result["hit"] == 1
    assert result["miss"] == 0
    assert result["context"] == pack_qp_context(qpn=7, owner_func=1)


@cocotb.test()
async def lookup_miss_returns_miss_status(dut):
    await reset_dut(dut)

    result = await lookup_context(dut, qpn=99, function_id=1)

    assert result["status"] == QP_TABLE_STATUS_MISS
    assert result["hit"] == 0
    assert result["miss"] == 1


@cocotb.test()
async def duplicate_qpn_in_different_slot_is_rejected(dut):
    await reset_dut(dut)

    assert await write_context(dut, qpn=8, owner=1, index=0, use_index=1) == QP_TABLE_STATUS_OK
    assert await write_context(dut, qpn=8, owner=1, index=1, use_index=1) == QP_TABLE_STATUS_ALIAS


@cocotb.test()
async def sq_producer_index_update_is_recorded(dut):
    await reset_dut(dut)

    assert await write_context(dut, qpn=9, owner=1) == QP_TABLE_STATUS_OK
    assert await update_sq_pi(dut, qpn=9, function_id=1, new_pi=33) == QP_TABLE_STATUS_OK
    result = await read_context(dut, qpn=9, function_id=1)

    assert result["status"] == QP_TABLE_STATUS_OK
    assert extract_field(result["data"], "sq_producer") == 33


@cocotb.test()
async def rq_producer_index_update_is_recorded(dut):
    await reset_dut(dut)

    assert await write_context(dut, qpn=10, owner=1) == QP_TABLE_STATUS_OK
    assert await update_rq_pi(dut, qpn=10, function_id=1, new_pi=44) == QP_TABLE_STATUS_OK
    result = await read_context(dut, qpn=10, function_id=1)

    assert result["status"] == QP_TABLE_STATUS_OK
    assert extract_field(result["data"], "rq_producer") == 44


@cocotb.test()
async def cross_function_access_is_denied(dut):
    await reset_dut(dut)

    assert await write_context(dut, qpn=11, owner=2) == QP_TABLE_STATUS_OK
    result = await lookup_context(dut, qpn=11, function_id=1)

    assert result["status"] == QP_TABLE_STATUS_PERMISSION
    assert result["hit"] == 0
    assert await update_sq_pi(dut, qpn=11, function_id=1, new_pi=55) == QP_TABLE_STATUS_PERMISSION
