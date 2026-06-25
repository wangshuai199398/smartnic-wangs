# SPDX-License-Identifier: MIT
"""DCQCN state machine tests for task 10.3."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


DCQCN_STATE_NORMAL = 0
DCQCN_STATE_CONGESTED = 1
DCQCN_STATE_RECOVERY = 2

CNP_EVENT_FIELDS = [
    ("desc_id", 16), ("qpn", 24), ("cqn", 24), ("owner_function", 16),
    ("pd_id", 24), ("congestion_type", 2), ("source_qpn", 24),
    ("status", 4), ("error_code", 16),
]

RATE_UPDATE_FIELDS = [
    ("qpn", 24), ("owner_function", 16), ("current_rate", 32),
    ("target_rate", 32), ("min_rate", 32), ("alpha", 16), ("state", 2),
]


def pack_fields(fields, values):
    packed = 0
    for name, width in fields:
        packed = (packed << width) | (values.get(name, 0) & ((1 << width) - 1))
    return packed


def extract_field(fields, packed, name):
    bit = sum(width for _, width in fields)
    for field_name, width in fields:
        bit -= width
        if field_name == name:
            return (packed >> bit) & ((1 << width) - 1)
    raise KeyError(name)


def pack_cnp_event(qpn=0x10, owner_function=1):
    return pack_fields(CNP_EVENT_FIELDS, {
        "desc_id": 0x55,
        "qpn": qpn,
        "owner_function": owner_function,
        "status": 0,
    })


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.config_valid.value = 0
    dut.cnp_event_valid.value = 0
    dut.cnp_event.value = 0
    dut.recovery_tick_valid.value = 0
    dut.rate_update_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def wait_update(dut):
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.rate_update_valid.value) == 1:
            update = int(dut.rate_update.value)
            await RisingEdge(dut.clk)
            return update
        await RisingEdge(dut.clk)
    raise AssertionError("rate_update_valid not asserted")


async def configure_qp(dut, qpn=0x10, current=1000, target=1000, minimum=100, ai=100, alpha=0, g=4):
    dut.config_qpn.value = qpn
    dut.config_owner_function.value = 1
    dut.config_current_rate.value = current
    dut.config_target_rate.value = target
    dut.config_min_rate.value = minimum
    dut.config_ai_rate.value = ai
    dut.config_alpha_g_shift.value = g
    dut.config_initial_alpha.value = alpha
    dut.config_valid.value = 1
    while int(dut.config_ready.value) == 0:
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.config_valid.value = 0
    return await wait_update(dut)


async def send_cnp(dut, qpn=0x10):
    dut.cnp_event.value = pack_cnp_event(qpn=qpn)
    dut.cnp_event_valid.value = 1
    while int(dut.cnp_event_ready.value) == 0:
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.cnp_event_valid.value = 0
    return await wait_update(dut)


async def recovery_tick(dut, qpn=0x10):
    dut.recovery_tick_qpn.value = qpn
    dut.recovery_tick_owner_function.value = 1
    dut.recovery_tick_valid.value = 1
    while int(dut.recovery_tick_ready.value) == 0:
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.recovery_tick_valid.value = 0
    return await wait_update(dut)


@cocotb.test()
async def cnp_halves_current_rate_and_enters_congested(dut):
    await reset_dut(dut)
    await configure_qp(dut, current=1000, target=1000, minimum=100, ai=100, g=4)
    update = await send_cnp(dut)

    assert extract_field(RATE_UPDATE_FIELDS, update, "current_rate") == 500
    assert extract_field(RATE_UPDATE_FIELDS, update, "state") == DCQCN_STATE_CONGESTED
    assert int(dut.cnp_events.value) == 1
    assert int(dut.rate_decrease.value) == 1


@cocotb.test()
async def cnp_rate_decrease_clamps_to_min_rate(dut):
    await reset_dut(dut)
    await configure_qp(dut, current=120, target=1000, minimum=100, ai=100, g=4)
    update = await send_cnp(dut)

    assert extract_field(RATE_UPDATE_FIELDS, update, "current_rate") == 100


@cocotb.test()
async def recovery_additive_increase_reaches_normal(dut):
    await reset_dut(dut)
    await configure_qp(dut, current=1000, target=1000, minimum=100, ai=250, g=4)
    await send_cnp(dut)

    update = await recovery_tick(dut)
    assert extract_field(RATE_UPDATE_FIELDS, update, "current_rate") == 750
    assert extract_field(RATE_UPDATE_FIELDS, update, "state") == DCQCN_STATE_RECOVERY

    update = await recovery_tick(dut)
    assert extract_field(RATE_UPDATE_FIELDS, update, "current_rate") == 1000
    assert extract_field(RATE_UPDATE_FIELDS, update, "state") == DCQCN_STATE_NORMAL
    assert int(dut.rate_increase.value) == 2


@cocotb.test()
async def alpha_ewma_increases_on_cnp(dut):
    await reset_dut(dut)
    await configure_qp(dut, current=1000, target=1000, minimum=100, ai=100, alpha=0, g=4)
    update = await send_cnp(dut)

    assert extract_field(RATE_UPDATE_FIELDS, update, "alpha") == 0x0FFF
