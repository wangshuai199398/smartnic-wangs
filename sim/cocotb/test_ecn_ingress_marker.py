# SPDX-License-Identifier: MIT
"""Ingress ECN/CE marker tests for task 10.1."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


ROCE_OPCODE_SEND_ONLY = 0x04
PKT_PARSE_STATUS_OK = 0
PKT_PARSE_STATUS_UNSUPPORTED_LAYOUT = 3


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
        "desc_id": 0x55,
        "qpn": 0x123456,
        "cqn": 0x44,
        "owner_function": 1,
        "pd_id": 7,
        "opcode": ROCE_OPCODE_SEND_ONLY,
        "status": PKT_PARSE_STATUS_OK,
        "frame_len": 64,
        "ethertype": 0x0800,
        "ip_version": 4,
        "ip_ihl": 5,
        "ip_dsfield": 0,
        "ip_total_length": 50,
        "ip_protocol": 17,
        "udp_dst_port": 4791,
        "udp_length": 30,
    }
    values.update(overrides)
    return pack_fields(PACKET_META_FIELDS, values)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.meta_valid.value = 0
    dut.meta_in.value = 0
    dut.marked_ready.value = 1
    dut.congestion_mark_ready.value = 1
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


async def wait_marked(dut):
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.marked_valid.value) == 1:
            marked = int(dut.marked_meta.value)
            mark_valid = int(dut.congestion_mark_valid.value)
            await RisingEdge(dut.clk)
            return marked, mark_valid
        await RisingEdge(dut.clk)
    raise AssertionError("marked_valid not asserted")


@cocotb.test()
async def ce_mark_generates_congestion_hook_and_counters(dut):
    await reset_dut(dut)
    await send_meta(dut, pack_meta(ip_dsfield=0x03, ecn=0x03, ecn_valid=1, ecn_ce=1))
    marked, mark_valid = await wait_marked(dut)

    assert mark_valid == 1
    assert int(dut.congestion_mark_qpn.value) == 0x123456
    assert int(dut.congestion_mark_ecn.value) == 0x03
    assert extract_field(PACKET_META_FIELDS, marked, "ecn_ce") == 1
    assert int(dut.ecn_packet_count.value) == 1
    assert int(dut.ce_packet_count.value) == 1


@cocotb.test()
async def non_ce_packet_passes_without_congestion_hook(dut):
    await reset_dut(dut)
    await send_meta(dut, pack_meta(ip_dsfield=0x02, ecn=0x02, ecn_valid=1, ecn_ce=0))
    _, mark_valid = await wait_marked(dut)

    assert mark_valid == 0
    assert int(dut.ecn_packet_count.value) == 1
    assert int(dut.ce_packet_count.value) == 0


@cocotb.test()
async def malformed_ecn_packet_updates_malformed_counter(dut):
    await reset_dut(dut)
    await send_meta(dut, pack_meta(status=PKT_PARSE_STATUS_UNSUPPORTED_LAYOUT, ecn=0x03, ecn_valid=1, ecn_ce=1))
    await wait_marked(dut)

    assert int(dut.malformed_ecn_count.value) == 1
