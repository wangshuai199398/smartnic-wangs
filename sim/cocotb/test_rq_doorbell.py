# SPDX-License-Identifier: MIT
"""RQ Doorbell payload parser tests."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


DB_TYPE_RQ = 2
DB_ERR_NONE = 0
DB_ERR_ACCESS_DENIED = 2
DB_ERR_INVALID_QPN = 3


def pack_rq_payload(new_pi, sequence=0, flags=0):
    return ((flags & 0xFF) << 24) | ((sequence & 0xFF) << 16) | (new_pi & 0xFFFF)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.rq_db_valid.value = 0
    dut.doorbell_type.value = DB_TYPE_RQ
    dut.qpn.value = 0
    dut.queue_index.value = 0
    dut.raw_payload.value = 0
    dut.owner_function.value = 0
    dut.access_allowed.value = 1
    dut.access_error.value = 0
    dut.access_error_code.value = 0
    dut.qpn_valid.value = 1
    dut.current_rq_producer_index.value = 0
    dut.qp_rq_update_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_rq_doorbell(
    dut,
    qpn=7,
    function_id=1,
    new_pi=4,
    current_pi=0,
    sequence=0x34,
    flags=0,
    access_allowed=1,
    access_error=0,
    qpn_valid=1,
):
    dut.rq_db_valid.value = 1
    dut.doorbell_type.value = DB_TYPE_RQ
    dut.qpn.value = qpn
    dut.queue_index.value = new_pi
    dut.raw_payload.value = pack_rq_payload(new_pi, sequence, flags)
    dut.owner_function.value = function_id
    dut.access_allowed.value = access_allowed
    dut.access_error.value = access_error
    dut.qpn_valid.value = qpn_valid
    dut.current_rq_producer_index.value = current_pi
    await RisingEdge(dut.clk)
    dut.rq_db_valid.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def legal_rq_doorbell_updates_producer_index(dut):
    await reset_dut(dut)

    await send_rq_doorbell(dut, qpn=21, function_id=3, new_pi=48, sequence=0x6B, flags=1)

    assert int(dut.qp_rq_update_valid.value) == 1
    assert int(dut.qp_rq_update_error.value) == 0
    assert int(dut.qp_rq_update_error_code.value) == DB_ERR_NONE
    assert int(dut.qp_rq_update_qpn.value) == 21
    assert int(dut.qp_rq_update_function_id.value) == 3
    assert int(dut.qp_rq_update_new_pi.value) == 48
    assert int(dut.qp_rq_update_doorbell_sequence.value) == 0x6B
    assert int(dut.qp_rq_update_flags.value) == 1


@cocotb.test()
async def producer_index_wraparound_is_reported(dut):
    await reset_dut(dut)

    await send_rq_doorbell(dut, new_pi=2, current_pi=0xFFFF)

    assert int(dut.qp_rq_update_valid.value) == 1
    assert int(dut.qp_rq_update_error.value) == 0
    assert int(dut.qp_rq_update_wraparound.value) == 1
    assert int(dut.qp_rq_update_new_pi.value) == 2


@cocotb.test()
async def invalid_qpn_returns_error(dut):
    await reset_dut(dut)

    await send_rq_doorbell(dut, qpn=123, new_pi=9, qpn_valid=0)

    assert int(dut.qp_rq_update_valid.value) == 1
    assert int(dut.qp_rq_update_error.value) == 1
    assert int(dut.qp_rq_update_error_code.value) == DB_ERR_INVALID_QPN
    assert int(dut.qp_rq_update_qpn.value) == 123


@cocotb.test()
async def access_denied_returns_error(dut):
    await reset_dut(dut)

    await send_rq_doorbell(dut, new_pi=16, access_allowed=0, access_error=1)

    assert int(dut.qp_rq_update_valid.value) == 1
    assert int(dut.qp_rq_update_error.value) == 1
    assert int(dut.qp_rq_update_error_code.value) == DB_ERR_ACCESS_DENIED
