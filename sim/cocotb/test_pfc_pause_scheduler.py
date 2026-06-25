# SPDX-License-Identifier: MIT
"""PFC pause scheduler tests for task 10.5."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


ROCE_OPCODE_SEND_ONLY = 0x04
PACER_STATUS_ALLOWED = 0

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


def pack_req(qpn=0x10, packet_size=128):
    return pack_fields(PACER_REQ_FIELDS, {
        "desc_id": 0x55,
        "qpn": qpn,
        "owner_function": 1,
        "pd_id": 7,
        "opcode": ROCE_OPCODE_SEND_ONLY,
        "packet_size": packet_size,
    })


def pack_decision(qpn=0x10):
    return pack_fields(PACER_DECISION_FIELDS, {
        "desc_id": 0x55,
        "qpn": qpn,
        "owner_function": 1,
        "pd_id": 7,
        "opcode": ROCE_OPCODE_SEND_ONLY,
        "tokens_after": 1024,
        "status": PACER_STATUS_ALLOWED,
    })


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.pfc_event_valid.value = 0
    dut.pfc_priority.value = 0
    dut.pfc_pause.value = 0
    dut.pfc_resume.value = 0
    dut.pfc_pause_quanta.value = 0
    dut.tx_req_valid.value = 0
    dut.tx_req.value = 0
    dut.tx_qp_priority.value = 0
    dut.pacer_req_ready.value = 1
    dut.pacer_decision_valid.value = 0
    dut.pacer_decision.value = 0
    dut.tx_decision_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_pfc_event(dut, priority, pause, quanta=0):
    dut.pfc_priority.value = priority
    dut.pfc_pause.value = 1 if pause else 0
    dut.pfc_resume.value = 0 if pause else 1
    dut.pfc_pause_quanta.value = quanta
    dut.pfc_event_valid.value = 1
    await RisingEdge(dut.clk)
    dut.pfc_event_valid.value = 0
    dut.pfc_pause.value = 0
    dut.pfc_resume.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def pause_blocks_matching_priority_and_freezes_pacer_request(dut):
    await reset_dut(dut)
    await send_pfc_event(dut, priority=3, pause=True, quanta=8)

    dut.tx_req.value = pack_req()
    dut.tx_qp_priority.value = 3
    dut.tx_req_valid.value = 1
    await RisingEdge(dut.clk)

    assert int(dut.tx_pfc_blocked.value) == 1
    assert int(dut.tx_req_ready.value) == 0
    assert int(dut.pacer_req_valid.value) == 0
    assert int(dut.tx_stalled_due_to_pfc.value) == 1


@cocotb.test()
async def resume_releases_backpressure_and_passes_request_to_pacer(dut):
    await reset_dut(dut)
    await send_pfc_event(dut, priority=3, pause=True, quanta=8)
    await send_pfc_event(dut, priority=3, pause=False)

    dut.tx_req.value = pack_req()
    dut.tx_qp_priority.value = 3
    dut.tx_req_valid.value = 1
    await RisingEdge(dut.clk)

    assert int(dut.tx_pfc_blocked.value) == 0
    assert int(dut.tx_req_ready.value) == 1
    assert int(dut.pacer_req_valid.value) == 1
    assert int(dut.pfc_resume_events.value) >= 1


@cocotb.test()
async def other_priorities_continue_while_one_priority_is_paused(dut):
    await reset_dut(dut)
    await send_pfc_event(dut, priority=3, pause=True, quanta=8)

    dut.tx_req.value = pack_req(qpn=0x20)
    dut.tx_qp_priority.value = 4
    dut.tx_req_valid.value = 1
    await RisingEdge(dut.clk)

    assert int(dut.tx_pfc_blocked.value) == 0
    assert int(dut.pacer_req_valid.value) == 1


@cocotb.test()
async def pause_timer_expiry_resumes_priority(dut):
    await reset_dut(dut)
    await send_pfc_event(dut, priority=2, pause=True, quanta=2)
    for _ in range(3):
        await RisingEdge(dut.clk)

    dut.tx_req.value = pack_req()
    dut.tx_qp_priority.value = 2
    dut.tx_req_valid.value = 1
    await RisingEdge(dut.clk)

    assert int(dut.tx_pfc_blocked.value) == 0
    assert int(dut.pacer_req_valid.value) == 1
    assert int(dut.pfc_resume_events.value) >= 1


@cocotb.test()
async def pacer_decision_passes_through_to_tx_scheduler(dut):
    await reset_dut(dut)
    dut.pacer_decision.value = pack_decision()
    dut.pacer_decision_valid.value = 1
    await RisingEdge(dut.clk)

    assert int(dut.tx_decision_valid.value) == 1
    assert int(dut.tx_decision.value) == pack_decision()
