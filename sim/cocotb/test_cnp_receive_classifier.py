# SPDX-License-Identifier: MIT
"""CNP receive classifier tests for task 10.2."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


ROCE_OPCODE_CNP = 0x81
ROCE_OPCODE_SEND_ONLY = 0x04
PKT_PARSE_STATUS_OK = 0
ROCEV2_UDP_PORT = 4791
CNP_CLASS_STATUS_MALFORMED = 2
CNP_CLASS_STATUS_QP_MISS = 3


PACKET_META_FIELDS = [
    ("desc_id", 16), ("qpn", 24), ("cqn", 24), ("owner_function", 16),
    ("pd_id", 24), ("opcode", 8), ("status", 4), ("frame_len", 16),
    ("ethertype", 16), ("has_vlan", 1), ("vlan_tci", 16),
    ("ip_version", 4), ("ip_ihl", 4), ("ip_dsfield", 8),
    ("ipv6_traffic_class", 8), ("ecn", 2), ("ecn_valid", 1), ("ecn_ce", 1),
    ("ip_total_length", 16), ("ip_protocol", 8), ("ip_checksum", 16),
    ("ipv4_src", 32), ("ipv4_dst", 32), ("udp_src_port", 16),
    ("udp_dst_port", 16), ("udp_length", 16), ("udp_checksum", 16),
    ("bth_transport_version", 4), ("pkey", 16), ("dest_qpn", 24),
    ("psn", 24), ("has_reth", 1), ("remote_va", 64), ("rkey", 32),
    ("dma_length", 32), ("has_aeth", 1), ("aeth", 32), ("has_deth", 1),
    ("qkey", 32), ("src_qpn", 24), ("has_imm", 1), ("imm_data", 32),
    ("icrc", 32), ("payload_offset", 16), ("payload_len", 16),
]

CNP_EVENT_FIELDS = [
    ("desc_id", 16), ("qpn", 24), ("cqn", 24), ("owner_function", 16),
    ("pd_id", 24), ("congestion_type", 2), ("source_qpn", 24),
    ("status", 4), ("error_code", 16),
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


def pack_meta(**overrides):
    values = {
        "desc_id": 0x77,
        "qpn": 0x123456,
        "cqn": 0x44,
        "owner_function": 1,
        "pd_id": 7,
        "opcode": ROCE_OPCODE_CNP,
        "status": PKT_PARSE_STATUS_OK,
        "frame_len": 64,
        "ethertype": 0x0800,
        "ip_version": 4,
        "ip_ihl": 5,
        "ip_total_length": 50,
        "ip_protocol": 17,
        "udp_dst_port": ROCEV2_UDP_PORT,
        "udp_length": 30,
        "bth_transport_version": 0,
        "dest_qpn": 0x123456,
        "src_qpn": 0xABCDEF,
        "imm_data": 0,
    }
    values.update(overrides)
    return pack_fields(PACKET_META_FIELDS, values)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.meta_valid.value = 0
    dut.meta_in.value = 0
    dut.qp_lookup_ready.value = 1
    dut.qp_lookup_hit.value = 1
    dut.qp_lookup_active.value = 1
    dut.dcqcn_event_ready.value = 1
    dut.cnp_drop_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_meta(dut, meta):
    dut.meta_in.value = meta
    dut.meta_valid.value = 1
    while int(dut.meta_ready.value) == 0:
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.meta_valid.value = 0


async def wait_event(dut):
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.dcqcn_event_valid.value) == 1:
            event = int(dut.dcqcn_event.value)
            await RisingEdge(dut.clk)
            return event
        await RisingEdge(dut.clk)
    raise AssertionError("dcqcn_event_valid not asserted")


async def wait_drop(dut):
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.cnp_drop_valid.value) == 1:
            status = int(dut.cnp_drop_status.value)
            await RisingEdge(dut.clk)
            return status
        await RisingEdge(dut.clk)
    raise AssertionError("cnp_drop_valid not asserted")


@cocotb.test()
async def valid_cnp_generates_dcqcn_event(dut):
    await reset_dut(dut)
    await send_meta(dut, pack_meta(imm_data=2))
    event = await wait_event(dut)

    assert extract_field(CNP_EVENT_FIELDS, event, "qpn") == 0x123456
    assert extract_field(CNP_EVENT_FIELDS, event, "source_qpn") == 0xABCDEF
    assert extract_field(CNP_EVENT_FIELDS, event, "congestion_type") == 2
    assert int(dut.cnp_received_total.value) == 1


@cocotb.test()
async def qp_miss_drops_cnp_and_counts_invalid(dut):
    await reset_dut(dut)
    dut.qp_lookup_hit.value = 0
    await send_meta(dut, pack_meta())
    status = await wait_drop(dut)

    assert status == CNP_CLASS_STATUS_QP_MISS
    assert int(dut.cnp_invalid_total.value) == 1


@cocotb.test()
async def malformed_cnp_is_dropped(dut):
    await reset_dut(dut)
    await send_meta(dut, pack_meta(udp_dst_port=0x9999))
    status = await wait_drop(dut)

    assert status == CNP_CLASS_STATUS_MALFORMED
    assert int(dut.cnp_invalid_total.value) == 1


@cocotb.test()
async def non_cnp_packet_is_ignored_without_invalid_count(dut):
    await reset_dut(dut)
    await send_meta(dut, pack_meta(opcode=ROCE_OPCODE_SEND_ONLY))
    await wait_drop(dut)

    assert int(dut.cnp_invalid_total.value) == 0
