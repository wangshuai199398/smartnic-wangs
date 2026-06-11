# SPDX-License-Identifier: MIT
"""SQ Doorbell payload parser tests."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


DB_TYPE_SQ = 1
DB_ERR_NONE = 0
DB_ERR_ACCESS_DENIED = 2
DB_ERR_INVALID_QPN = 3


def pack_sq_payload(new_pi, sequence=0, flags=0):
    return ((flags & 0xFF) << 24) | ((sequence & 0xFF) << 16) | (new_pi & 0xFFFF)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.sq_db_valid.value = 0
    dut.doorbell_type.value = DB_TYPE_SQ
    dut.qpn.value = 0
    dut.queue_index.value = 0
    dut.raw_payload.value = 0
    dut.owner_function.value = 0
    dut.access_allowed.value = 1
    dut.access_error.value = 0
    dut.access_error_code.value = 0
    dut.qpn_valid.value = 1
    dut.current_sq_producer_index.value = 0
    dut.qp_update_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_sq_doorbell(
    dut,
    qpn=7,
    function_id=1,
    new_pi=4,
    current_pi=0,
    sequence=0x12,
    flags=0,
    access_allowed=1,
    access_error=0,
    qpn_valid=1,
):
    dut.sq_db_valid.value = 1
    dut.doorbell_type.value = DB_TYPE_SQ
    dut.qpn.value = qpn
    dut.queue_index.value = new_pi
    dut.raw_payload.value = pack_sq_payload(new_pi, sequence, flags)
    dut.owner_function.value = function_id
    dut.access_allowed.value = access_allowed
    dut.access_error.value = access_error
    dut.qpn_valid.value = qpn_valid
    dut.current_sq_producer_index.value = current_pi
    await RisingEdge(dut.clk)
    dut.sq_db_valid.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def legal_sq_doorbell_updates_producer_index(dut):
    await reset_dut(dut)

    await send_sq_doorbell(dut, qpn=11, function_id=2, new_pi=32, sequence=0x5A, flags=1)

    assert int(dut.qp_update_valid.value) == 1
    assert int(dut.qp_update_error.value) == 0
    assert int(dut.qp_update_error_code.value) == DB_ERR_NONE
    assert int(dut.qp_update_qpn.value) == 11
    assert int(dut.qp_update_function_id.value) == 2
    assert int(dut.qp_update_new_sq_pi.value) == 32
    assert int(dut.qp_update_doorbell_sequence.value) == 0x5A
    assert int(dut.qp_update_flags.value) == 1


@cocotb.test()
async def producer_index_wraparound_is_reported(dut):
    await reset_dut(dut)

    await send_sq_doorbell(dut, new_pi=3, current_pi=0xFFFE)

    assert int(dut.qp_update_valid.value) == 1
    assert int(dut.qp_update_error.value) == 0
    assert int(dut.qp_update_wraparound.value) == 1
    assert int(dut.qp_update_new_sq_pi.value) == 3


@cocotb.test()
async def invalid_qpn_returns_error(dut):
    await reset_dut(dut)

    await send_sq_doorbell(dut, qpn=123, new_pi=9, qpn_valid=0)

    assert int(dut.qp_update_valid.value) == 1
    assert int(dut.qp_update_error.value) == 1
    assert int(dut.qp_update_error_code.value) == DB_ERR_INVALID_QPN
    assert int(dut.qp_update_qpn.value) == 123


@cocotb.test()
async def access_denied_returns_error(dut):
    await reset_dut(dut)

    await send_sq_doorbell(dut, new_pi=16, access_allowed=0, access_error=1)

    assert int(dut.qp_update_valid.value) == 1
    assert int(dut.qp_update_error.value) == 1
    assert int(dut.qp_update_error_code.value) == DB_ERR_ACCESS_DENIED
