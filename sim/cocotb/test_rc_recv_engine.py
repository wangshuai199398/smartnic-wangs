# SPDX-License-Identifier: MIT
"""RC receive-side engine 9.2 Cocotb skeleton tests."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


ROCE_OPCODE_SEND_ONLY = 0x04
ROCE_OPCODE_RDMA_WRITE_ONLY = 0x0A
PKT_PARSE_STATUS_OK = 0
RC_RECV_STATUS_DUPLICATE = 1
RC_RECV_STATUS_GAP_NAK = 2
RC_RECV_STATUS_RNR_NAK = 3
RC_NAK_SEQUENCE = 1
RC_NAK_RNR = 2


META_FIELDS = [
    ("desc_id", 16), ("qpn", 24), ("cqn", 24), ("owner_function", 16),
    ("pd_id", 24), ("opcode", 8), ("status", 4), ("frame_len", 16),
    ("ethertype", 16), ("has_vlan", 1), ("vlan_tci", 16),
    ("ip_version", 4), ("ip_ihl", 4), ("ip_dsfield", 8),
    ("ipv6_traffic_class", 8), ("ecn", 2), ("ecn_valid", 1), ("ecn_ce", 1),
    ("ip_total_length", 16),
    ("ip_protocol", 8), ("ip_checksum", 16), ("ipv4_src", 32),
    ("ipv4_dst", 32), ("udp_src_port", 16), ("udp_dst_port", 16),
    ("udp_length", 16), ("udp_checksum", 16), ("bth_transport_version", 4),
    ("pkey", 16), ("dest_qpn", 24), ("psn", 24), ("has_reth", 1),
    ("remote_va", 64), ("rkey", 32), ("dma_length", 32), ("has_aeth", 1),
    ("aeth", 32), ("has_deth", 1), ("qkey", 32), ("src_qpn", 24),
    ("has_imm", 1), ("imm_data", 32), ("icrc", 32), ("payload_offset", 16),
    ("payload_len", 16),
]

PAYLOAD_FIELDS = [
    ("desc_id", 16), ("qpn", 24), ("cqn", 24), ("owner_function", 16),
    ("pd_id", 24), ("opcode", 8), ("status", 5), ("error_code", 16),
    ("ecn", 2),
    ("ecn_valid", 1),
    ("ecn_ce", 1),
    ("data", 512), ("payload_len", 16), ("valid_bytes", 16),
    ("byte_offset", 16), ("first", 1), ("last", 1), ("has_imm", 1),
    ("imm_data", 32), ("remote_va", 64), ("rkey", 32), ("dma_length", 32),
    ("dest_qpn", 24), ("psn", 24),
]

ACK_EVENT_FIELDS = [
    ("desc_id", 16), ("qpn", 24), ("cqn", 24), ("owner_function", 16),
    ("pd_id", 24), ("opcode", 8), ("status", 5), ("error_code", 16),
    ("packet_psn", 24), ("expected_psn", 24), ("ack_psn", 24),
    ("is_ack", 1), ("is_nak", 1), ("is_rnr", 1), ("duplicate", 1),
    ("gap", 1), ("nak_code", 4), ("aeth", 32),
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


def pack_meta(psn, opcode=ROCE_OPCODE_SEND_ONLY, payload_len=0, desc_id=0x20):
    return pack_fields(META_FIELDS, {
        "desc_id": desc_id,
        "qpn": 0x123456,
        "cqn": 0x44,
        "owner_function": 1,
        "pd_id": 7,
        "opcode": opcode,
        "status": PKT_PARSE_STATUS_OK,
        "frame_len": 64,
        "ethertype": 0x0800,
        "ip_version": 4,
        "ip_ihl": 5,
        "ip_total_length": 50,
        "ip_protocol": 17,
        "udp_dst_port": 4791,
        "udp_length": 30,
        "bth_transport_version": 0,
        "pkey": 0xFFFF,
        "dest_qpn": 0x123456,
        "psn": psn,
        "payload_offset": 42,
        "payload_len": payload_len,
    })


def pack_payload(psn, payload_len=0, opcode=ROCE_OPCODE_SEND_ONLY, desc_id=0x20):
    return pack_fields(PAYLOAD_FIELDS, {
        "desc_id": desc_id,
        "qpn": 0x123456,
        "cqn": 0x44,
        "owner_function": 1,
        "pd_id": 7,
        "opcode": opcode,
        "data": 0xA5,
        "payload_len": payload_len,
        "valid_bytes": payload_len,
        "first": 1,
        "last": 1,
        "dest_qpn": 0x123456,
        "psn": psn,
    })


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.cfg_valid.value = 0
    dut.rx_meta_valid.value = 0
    dut.rx_meta.value = 0
    dut.rx_payload_valid.value = 0
    dut.rx_payload.value = 0
    dut.rq_buffer_available.value = 1
    dut.timer_tick.value = 0
    dut.accept_ready.value = 1
    dut.ack_event_ready.value = 1
    dut.drop_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def configure(dut, expected_psn=0x100, ack_count=1, ack_timeout=0):
    dut.cfg_qpn.value = 0x123456
    dut.cfg_owner_function.value = 1
    dut.cfg_pd_id.value = 7
    dut.cfg_expected_psn.value = expected_psn
    dut.cfg_ack_coalesce_count.value = ack_count
    dut.cfg_ack_timeout.value = ack_timeout
    dut.cfg_valid.value = 1
    await RisingEdge(dut.clk)
    dut.cfg_valid.value = 0
    await RisingEdge(dut.clk)


async def send_packet(dut, psn, opcode=ROCE_OPCODE_SEND_ONLY, payload_len=0):
    dut.rx_meta.value = pack_meta(psn, opcode=opcode, payload_len=payload_len)
    dut.rx_payload.value = pack_payload(psn, opcode=opcode, payload_len=payload_len)
    dut.rx_meta_valid.value = 1
    dut.rx_payload_valid.value = 1 if payload_len else 0
    while int(dut.rx_meta_ready.value) == 0:
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rx_meta_valid.value = 0
    dut.rx_payload_valid.value = 0


async def wait_accept(dut):
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.accept_valid.value) == 1:
            await RisingEdge(dut.clk)
            return
        await RisingEdge(dut.clk)
    raise AssertionError("accept_valid not asserted")


async def wait_ack(dut):
    for _ in range(24):
        await Timer(1, units="ns")
        if int(dut.ack_event_valid.value) == 1:
            event = int(dut.ack_event.value)
            await RisingEdge(dut.clk)
            return event
        await RisingEdge(dut.clk)
    raise AssertionError("ack_event_valid not asserted")


async def wait_drop(dut):
    for _ in range(24):
        await Timer(1, units="ns")
        if int(dut.drop_valid.value) == 1:
            status = int(dut.drop_status.value)
            await RisingEdge(dut.clk)
            return status
        await RisingEdge(dut.clk)
    raise AssertionError("drop_valid not asserted")


@cocotb.test()
async def in_order_packets_advance_expected_psn_and_coalesce_ack(dut):
    await reset_dut(dut)
    await configure(dut, expected_psn=0x100, ack_count=2)
    await send_packet(dut, 0x100, opcode=ROCE_OPCODE_RDMA_WRITE_ONLY)
    await wait_accept(dut)
    assert int(dut.expected_psn.value) == 0x101
    await send_packet(dut, 0x101, opcode=ROCE_OPCODE_RDMA_WRITE_ONLY)
    await wait_accept(dut)
    ack = await wait_ack(dut)
    assert extract_field(ACK_EVENT_FIELDS, ack, "is_ack") == 1
    assert extract_field(ACK_EVENT_FIELDS, ack, "is_nak") == 0
    assert extract_field(ACK_EVENT_FIELDS, ack, "ack_psn") == 0x101


@cocotb.test()
async def duplicate_packet_is_dropped_and_acknowledged(dut):
    await reset_dut(dut)
    await configure(dut, expected_psn=0x101)
    await send_packet(dut, 0x100)
    assert await wait_drop(dut) == RC_RECV_STATUS_DUPLICATE
    ack = await wait_ack(dut)
    assert extract_field(ACK_EVENT_FIELDS, ack, "duplicate") == 1
    assert extract_field(ACK_EVENT_FIELDS, ack, "ack_psn") == 0x100


@cocotb.test()
async def gap_packet_generates_sequence_nak_and_drop(dut):
    await reset_dut(dut)
    await configure(dut, expected_psn=0x200)
    await send_packet(dut, 0x202)
    ack = await wait_ack(dut)
    assert extract_field(ACK_EVENT_FIELDS, ack, "is_nak") == 1
    assert extract_field(ACK_EVENT_FIELDS, ack, "gap") == 1
    assert extract_field(ACK_EVENT_FIELDS, ack, "nak_code") == RC_NAK_SEQUENCE
    assert await wait_drop(dut) == RC_RECV_STATUS_GAP_NAK


@cocotb.test()
async def send_without_rq_buffer_generates_rnr_nak(dut):
    await reset_dut(dut)
    await configure(dut, expected_psn=0x300)
    dut.rq_buffer_available.value = 0
    await send_packet(dut, 0x300, opcode=ROCE_OPCODE_SEND_ONLY)
    ack = await wait_ack(dut)
    assert extract_field(ACK_EVENT_FIELDS, ack, "is_nak") == 1
    assert extract_field(ACK_EVENT_FIELDS, ack, "is_rnr") == 1
    assert extract_field(ACK_EVENT_FIELDS, ack, "nak_code") == RC_NAK_RNR
    assert await wait_drop(dut) == RC_RECV_STATUS_RNR_NAK
