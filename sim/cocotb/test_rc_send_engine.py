# SPDX-License-Identifier: MIT
"""RC send-side engine 9.1 Cocotb skeleton tests."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


ROCE_OPCODE_SEND_ONLY = 0x04
RC_SEND_STATUS_RETRY_EXHAUSTED = 3


BUILD_REQ_FIELDS = [
    ("desc_id", 16), ("qpn", 24), ("cqn", 24), ("owner_function", 16),
    ("pd_id", 24), ("opcode", 8), ("status", 5), ("error_code", 16),
    ("dst_mac", 48), ("src_mac", 48), ("has_vlan", 1), ("vlan_tci", 16),
    ("src_ipv4", 32), ("dst_ipv4", 32), ("udp_src_port", 16), ("udp_dst_port", 16),
    ("pkey", 16), ("dest_qpn", 24), ("src_qpn", 24), ("psn", 24),
    ("remote_va", 64), ("rkey", 32), ("dma_length", 32), ("aeth", 32),
    ("qkey", 32), ("has_imm", 1), ("imm_data", 32), ("payload_data", 512),
    ("payload_len", 16), ("icrc_placeholder", 32),
]

TX_REQ_FIELDS = [
    ("desc_id", 16), ("qpn", 24), ("cqn", 24), ("owner_function", 16),
    ("pd_id", 24), ("opcode", 8), ("status", 5), ("error_code", 16),
    ("wr_id", 64), ("payload_len", 16), ("solicited", 1),
    ("completion_required", 1), ("build_req", sum(width for _, width in BUILD_REQ_FIELDS)),
]

RC_PACKET_FIELDS = [
    ("desc_id", 16), ("qpn", 24), ("cqn", 24), ("owner_function", 16),
    ("pd_id", 24), ("opcode", 8), ("status", 5), ("error_code", 16),
    ("wr_id", 64), ("psn", 24), ("is_retry", 1), ("retry_count", 8),
    ("build_req", sum(width for _, width in BUILD_REQ_FIELDS)),
]

ACK_FIELDS = [
    ("qpn", 24), ("owner_function", 16), ("ack_psn", 24), ("retry_hint", 1),
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


def pack_build_req(**overrides):
    values = {
        "desc_id": 0x10,
        "qpn": 0x123456,
        "cqn": 0x33,
        "owner_function": 1,
        "pd_id": 7,
        "opcode": ROCE_OPCODE_SEND_ONLY,
        "dest_qpn": 0x654321,
        "payload_len": 8,
    }
    values.update(overrides)
    return pack_fields(BUILD_REQ_FIELDS, values)


def pack_tx_req(**overrides):
    values = {
        "desc_id": 0x10,
        "qpn": 0x123456,
        "cqn": 0x33,
        "owner_function": 1,
        "pd_id": 7,
        "opcode": ROCE_OPCODE_SEND_ONLY,
        "wr_id": 0xCAFE,
        "payload_len": 8,
        "solicited": 0,
        "completion_required": 1,
        "build_req": pack_build_req(),
    }
    values.update(overrides)
    return pack_fields(TX_REQ_FIELDS, values)


def pack_ack(qpn=0x123456, owner_function=1, ack_psn=0x100):
    return pack_fields(ACK_FIELDS, {
        "qpn": qpn,
        "owner_function": owner_function,
        "ack_psn": ack_psn,
        "retry_hint": 0,
    })


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.cfg_valid.value = 0
    dut.tx_req_valid.value = 0
    dut.tx_req.value = 0
    dut.packet_ready.value = 1
    dut.ack_valid.value = 0
    dut.ack_event.value = 0
    dut.timer_tick.value = 0
    dut.retry_ready.value = 1
    dut.qp_error_req_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def configure(dut, initial_psn=0x100, retry_limit=2, retry_timeout=3):
    dut.cfg_qpn.value = 0x123456
    dut.cfg_owner_function.value = 1
    dut.cfg_pd_id.value = 7
    dut.cfg_initial_psn.value = initial_psn
    dut.cfg_retry_limit.value = retry_limit
    dut.cfg_retry_timeout.value = retry_timeout
    dut.cfg_valid.value = 1
    await RisingEdge(dut.clk)
    dut.cfg_valid.value = 0


async def send_tx(dut, desc_id=0x10):
    dut.tx_req.value = pack_tx_req(desc_id=desc_id, build_req=pack_build_req(desc_id=desc_id))
    dut.tx_req_valid.value = 1
    while int(dut.tx_req_ready.value) == 0:
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.tx_req_valid.value = 0


async def wait_packet(dut):
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.packet_valid.value) == 1:
            pkt = int(dut.packet.value)
            await RisingEdge(dut.clk)
            return pkt
        await RisingEdge(dut.clk)
    raise AssertionError("packet_valid not asserted")


async def wait_retry(dut):
    for _ in range(32):
        await Timer(1, units="ns")
        if int(dut.retry_valid.value) == 1:
            pkt = int(dut.retry_packet.value)
            await RisingEdge(dut.clk)
            return pkt
        await RisingEdge(dut.clk)
    raise AssertionError("retry_valid not asserted")


async def tick_timer(dut, count):
    for _ in range(count):
        dut.timer_tick.value = 1
        await RisingEdge(dut.clk)
        dut.timer_tick.value = 0
        await RisingEdge(dut.clk)


@cocotb.test()
async def allocates_psn_and_increments_next_psn(dut):
    await reset_dut(dut)
    await configure(dut, initial_psn=0x100)
    await send_tx(dut, desc_id=0x20)
    pkt = await wait_packet(dut)
    assert extract_field(RC_PACKET_FIELDS, pkt, "psn") == 0x100
    assert extract_field(RC_PACKET_FIELDS, pkt, "desc_id") == 0x20
    assert int(dut.next_psn.value) == 0x101
    assert int(dut.outstanding_count.value) == 1


@cocotb.test()
async def ack_clears_outstanding_entry(dut):
    await reset_dut(dut)
    await configure(dut, initial_psn=0x200)
    await send_tx(dut)
    await wait_packet(dut)
    dut.ack_event.value = pack_ack(ack_psn=0x200)
    dut.ack_valid.value = 1
    await RisingEdge(dut.clk)
    dut.ack_valid.value = 0
    await RisingEdge(dut.clk)
    assert int(dut.outstanding_count.value) == 0


@cocotb.test()
async def retry_timer_emits_retry_packet(dut):
    await reset_dut(dut)
    await configure(dut, initial_psn=0x300, retry_limit=2, retry_timeout=2)
    await send_tx(dut)
    await wait_packet(dut)
    await tick_timer(dut, 3)
    retry = await wait_retry(dut)
    assert extract_field(RC_PACKET_FIELDS, retry, "psn") == 0x300
    assert extract_field(RC_PACKET_FIELDS, retry, "is_retry") == 1


@cocotb.test()
async def retry_exhaustion_requests_qp_error(dut):
    await reset_dut(dut)
    await configure(dut, initial_psn=0x400, retry_limit=0, retry_timeout=1)
    await send_tx(dut)
    await wait_packet(dut)
    await tick_timer(dut, 2)
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.qp_error_req_valid.value) == 1:
            assert int(dut.qp_error_qpn.value) == 0x123456
            assert int(dut.qp_error_code.value) == RC_SEND_STATUS_RETRY_EXHAUSTED
            return
        await RisingEdge(dut.clk)
    raise AssertionError("qp_error_req_valid not asserted")
