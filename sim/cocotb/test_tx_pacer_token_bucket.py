# SPDX-License-Identifier: MIT
"""Per-QP token bucket transmit pacer tests for task 10.4."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


ROCE_OPCODE_SEND_ONLY = 0x04
ROCE_OPCODE_RDMA_WRITE_ONLY = 0x0A
PACER_STATUS_ALLOWED = 0
PACER_STATUS_THROTTLED = 1
PACER_STATUS_DISABLED = 2
PACER_STATUS_INVALID = 3

RATE_UPDATE_FIELDS = [
    ("qpn", 24), ("owner_function", 16), ("current_rate", 32),
    ("target_rate", 32), ("min_rate", 32), ("alpha", 16), ("state", 2),
]

PACER_REQ_FIELDS = [
    ("desc_id", 16), ("qpn", 24), ("owner_function", 16),
    ("pd_id", 24), ("opcode", 8), ("packet_size", 16),
]

PACER_DECISION_FIELDS = [
    ("desc_id", 16), ("qpn", 24), ("owner_function", 16),
    ("pd_id", 24), ("opcode", 8), ("tokens_after", 64), ("status", 2),
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


def pack_rate_update(qpn=0x10, owner_function=1, current_rate=100):
    return pack_fields(RATE_UPDATE_FIELDS, {
        "qpn": qpn,
        "owner_function": owner_function,
        "current_rate": current_rate,
        "target_rate": current_rate,
        "min_rate": 1,
        "alpha": 0,
        "state": 0,
    })


def pack_pace_req(qpn=0x10, owner_function=1, packet_size=128, opcode=ROCE_OPCODE_SEND_ONLY):
    return pack_fields(PACER_REQ_FIELDS, {
        "desc_id": 0x55,
        "qpn": qpn,
        "owner_function": owner_function,
        "pd_id": 7,
        "opcode": opcode,
        "packet_size": packet_size,
    })


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.pacer_enable.value = 1
    dut.config_valid.value = 0
    dut.config_qpn.value = 0
    dut.config_owner_function.value = 0
    dut.config_bucket_size.value = 0
    dut.config_initial_tokens.value = 0
    dut.config_time_now.value = 0
    dut.rate_update_valid.value = 0
    dut.rate_update.value = 0
    dut.pace_req_valid.value = 0
    dut.pace_req.value = 0
    dut.time_now.value = 0
    dut.pace_decision_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def configure_bucket(dut, qpn=0x10, owner_function=1, bucket_size=1000, initial_tokens=0, now=0):
    dut.config_qpn.value = qpn
    dut.config_owner_function.value = owner_function
    dut.config_bucket_size.value = bucket_size
    dut.config_initial_tokens.value = initial_tokens
    dut.config_time_now.value = now
    dut.config_valid.value = 1
    while int(dut.config_ready.value) == 0:
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.config_valid.value = 0


async def update_rate(dut, qpn=0x10, owner_function=1, rate=100):
    dut.rate_update.value = pack_rate_update(qpn=qpn, owner_function=owner_function, current_rate=rate)
    dut.rate_update_valid.value = 1
    while int(dut.rate_update_ready.value) == 0:
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rate_update_valid.value = 0


async def pace_packet(dut, packet_size, now, qpn=0x10, owner_function=1, opcode=ROCE_OPCODE_SEND_ONLY):
    dut.time_now.value = now
    dut.pace_req.value = pack_pace_req(
        qpn=qpn,
        owner_function=owner_function,
        packet_size=packet_size,
        opcode=opcode,
    )
    dut.pace_req_valid.value = 1
    while int(dut.pace_req_ready.value) == 0:
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.pace_req_valid.value = 0
    for _ in range(8):
        await Timer(1, units="ns")
        if int(dut.pace_decision_valid.value) == 1:
            decision = int(dut.pace_decision.value)
            await RisingEdge(dut.clk)
            return decision
        await RisingEdge(dut.clk)
    raise AssertionError("pace_decision_valid not asserted")


@cocotb.test()
async def tokens_refill_and_allow_packet(dut):
    await reset_dut(dut)
    await configure_bucket(dut, bucket_size=1000, initial_tokens=0, now=0)
    await update_rate(dut, rate=100)

    decision = await pace_packet(dut, packet_size=150, now=2)
    assert extract_field(PACER_DECISION_FIELDS, decision, "status") == PACER_STATUS_ALLOWED
    assert extract_field(PACER_DECISION_FIELDS, decision, "tokens_after") == 50
    assert int(dut.tokens_refilled.value) == 200
    assert int(dut.tx_allowed_packets.value) == 1


@cocotb.test()
async def insufficient_tokens_throttle_transmit(dut):
    await reset_dut(dut)
    await configure_bucket(dut, bucket_size=1000, initial_tokens=10, now=0)
    await update_rate(dut, rate=0)

    decision = await pace_packet(dut, packet_size=100, now=1)
    assert extract_field(PACER_DECISION_FIELDS, decision, "status") == PACER_STATUS_THROTTLED
    assert int(dut.tx_throttled_events.value) == 1


@cocotb.test()
async def refill_clamps_to_bucket_size(dut):
    await reset_dut(dut)
    await configure_bucket(dut, bucket_size=1000, initial_tokens=900, now=0)
    await update_rate(dut, rate=100)

    decision = await pace_packet(dut, packet_size=100, now=5, opcode=ROCE_OPCODE_RDMA_WRITE_ONLY)
    assert extract_field(PACER_DECISION_FIELDS, decision, "status") == PACER_STATUS_ALLOWED
    assert extract_field(PACER_DECISION_FIELDS, decision, "tokens_after") == 900
    assert int(dut.tokens_refilled.value) == 100


@cocotb.test()
async def disabled_pacer_bypasses_and_marks_decision(dut):
    await reset_dut(dut)
    dut.pacer_enable.value = 0
    decision = await pace_packet(dut, packet_size=4096, now=1)

    assert extract_field(PACER_DECISION_FIELDS, decision, "status") == PACER_STATUS_DISABLED
    assert int(dut.tx_allowed_packets.value) == 1


@cocotb.test()
async def unknown_or_mismatched_qp_is_invalid(dut):
    await reset_dut(dut)
    await configure_bucket(dut, qpn=0x10, owner_function=1, bucket_size=1000, initial_tokens=1000, now=0)
    await update_rate(dut, qpn=0x10, owner_function=1, rate=100)

    decision = await pace_packet(dut, qpn=0x10, owner_function=2, packet_size=64, now=1)
    assert extract_field(PACER_DECISION_FIELDS, decision, "status") == PACER_STATUS_INVALID
