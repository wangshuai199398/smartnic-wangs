# SPDX-License-Identifier: MIT
"""RoCEv2 ingress packet parser 8.1 最小行为测试。

这些测试只覆盖 header 字段提取，不覆盖 8.2 的协议合法性校验、
8.3 的 payload stream 提取，也不计算/校验 ICRC。
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


ROCE_OPCODE_SEND_ONLY = 0x04
ROCE_OPCODE_SEND_ONLY_IMM = 0x05
ROCE_OPCODE_RDMA_WRITE_ONLY = 0x0A
ETH_TYPE_IPV4 = 0x0800
ETH_TYPE_IPV6 = 0x86DD
ETH_TYPE_VLAN = 0x8100
ROCE_UDP_PORT = 4791

PKT_PARSE_STATUS_OK = 0
PKT_PARSE_STATUS_NEED_MORE_DATA = 1
PKT_PARSE_STATUS_UNSUPPORTED_LAYOUT = 3


PACKET_META_FIELDS = [
    ("desc_id", 16),
    ("qpn", 24),
    ("cqn", 24),
    ("owner_function", 16),
    ("pd_id", 24),
    ("opcode", 8),
    ("status", 4),
    ("frame_len", 16),
    ("ethertype", 16),
    ("has_vlan", 1),
    ("vlan_tci", 16),
    ("ip_version", 4),
    ("ip_ihl", 4),
    ("ip_dsfield", 8),
    ("ipv6_traffic_class", 8),
    ("ecn", 2),
    ("ecn_valid", 1),
    ("ecn_ce", 1),
    ("ip_total_length", 16),
    ("ip_protocol", 8),
    ("ip_checksum", 16),
    ("ipv4_src", 32),
    ("ipv4_dst", 32),
    ("udp_src_port", 16),
    ("udp_dst_port", 16),
    ("udp_length", 16),
    ("udp_checksum", 16),
    ("bth_transport_version", 4),
    ("pkey", 16),
    ("dest_qpn", 24),
    ("psn", 24),
    ("has_reth", 1),
    ("remote_va", 64),
    ("rkey", 32),
    ("dma_length", 32),
    ("has_aeth", 1),
    ("aeth", 32),
    ("has_deth", 1),
    ("qkey", 32),
    ("src_qpn", 24),
    ("has_imm", 1),
    ("imm_data", 32),
    ("icrc", 32),
    ("payload_offset", 16),
    ("payload_len", 16),
]


def set_bits(value, high, low, field):
    mask = (1 << (high - low + 1)) - 1
    value &= ~(mask << low)
    value |= (field & mask) << low
    return value


def extract_field(fields, packed, name):
    bit = sum(width for _, width in fields)
    for field_name, width in fields:
        bit -= width
        if field_name == name:
            return (packed >> bit) & ((1 << width) - 1)
    raise KeyError(name)


def build_ipv4_roce_frame(opcode=ROCE_OPCODE_SEND_ONLY, with_vlan=False, dsfield=0):
    data = 0
    data = set_bits(data, 111, 96, ETH_TYPE_VLAN if with_vlan else ETH_TYPE_IPV4)

    if with_vlan:
        data = set_bits(data, 127, 112, 0x123)
        data = set_bits(data, 143, 128, ETH_TYPE_IPV4)
        data = set_bits(data, 159, 152, dsfield)
        data = set_bits(data, 271, 240, 0x0A000001)
        data = set_bits(data, 303, 272, 0x0A000002)
        data = set_bits(data, 319, 304, 0xC001)
        data = set_bits(data, 335, 320, ROCE_UDP_PORT)
        data = set_bits(data, 351, 344, opcode)
        data = set_bits(data, 367, 352, 0xFFFF)
        data = set_bits(data, 383, 360, 0x123456)
        data = set_bits(data, 415, 392, 0x00ABCD)
        data = set_bits(data, 479, 416, 0x1000200030004000)
        data = set_bits(data, 511, 480, 0xABCDEF01)
        frame_len = 86
    else:
        data = set_bits(data, 127, 120, dsfield)
        data = set_bits(data, 239, 208, 0x0A000001)
        data = set_bits(data, 271, 240, 0x0A000002)
        data = set_bits(data, 287, 272, 0xC001)
        data = set_bits(data, 303, 288, ROCE_UDP_PORT)
        data = set_bits(data, 319, 312, opcode)
        data = set_bits(data, 335, 320, 0xFFFF)
        data = set_bits(data, 351, 328, 0x123456)
        data = set_bits(data, 383, 360, 0x00ABCD)
        data = set_bits(data, 447, 384, 0x1000200030004000)
        data = set_bits(data, 479, 448, 0xABCDEF01)
        data = set_bits(data, 511, 480, 0x00000400)
        frame_len = 82

    return data, frame_len


def build_ipv6_roce_frame(traffic_class=0):
    data = 0
    data = set_bits(data, 111, 96, ETH_TYPE_IPV6)
    data = set_bits(data, 119, 116, 6)
    data = set_bits(data, 115, 108, traffic_class)
    return data, 90


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.frame_valid.value = 0
    dut.frame_data.value = 0
    dut.frame_len.value = 0
    dut.frame_last.value = 1
    dut.desc_id.value = 0x55
    dut.qpn.value = 0x22
    dut.cqn.value = 0x33
    dut.owner_function.value = 1
    dut.pd_id.value = 3
    dut.meta_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_frame(dut, data, frame_len, frame_last=1):
    dut.frame_data.value = data
    dut.frame_len.value = frame_len
    dut.frame_last.value = frame_last
    dut.frame_valid.value = 1
    while int(dut.frame_ready.value) == 0:
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.frame_valid.value = 0


async def wait_meta(dut):
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.meta_valid.value) == 1:
            meta = int(dut.meta.value)
            await RisingEdge(dut.clk)
            return meta
        await RisingEdge(dut.clk)
    raise AssertionError("meta_valid not asserted")


@cocotb.test()
async def parses_ipv4_udp_bth_reth_fields(dut):
    await reset_dut(dut)
    data, frame_len = build_ipv4_roce_frame(ROCE_OPCODE_RDMA_WRITE_ONLY, with_vlan=False)
    await send_frame(dut, data, frame_len)
    meta = await wait_meta(dut)

    assert extract_field(PACKET_META_FIELDS, meta, "status") == PKT_PARSE_STATUS_OK
    assert extract_field(PACKET_META_FIELDS, meta, "opcode") == ROCE_OPCODE_RDMA_WRITE_ONLY
    assert extract_field(PACKET_META_FIELDS, meta, "ethertype") == ETH_TYPE_IPV4
    assert extract_field(PACKET_META_FIELDS, meta, "udp_dst_port") == ROCE_UDP_PORT
    assert extract_field(PACKET_META_FIELDS, meta, "dest_qpn") == 0x123456
    assert extract_field(PACKET_META_FIELDS, meta, "psn") == 0x00ABCD
    assert extract_field(PACKET_META_FIELDS, meta, "has_reth") == 1
    assert extract_field(PACKET_META_FIELDS, meta, "remote_va") == 0x1000200030004000
    assert extract_field(PACKET_META_FIELDS, meta, "rkey") == 0xABCDEF01


@cocotb.test()
async def parses_single_vlan_header(dut):
    await reset_dut(dut)
    data, frame_len = build_ipv4_roce_frame(ROCE_OPCODE_RDMA_WRITE_ONLY, with_vlan=True)
    await send_frame(dut, data, frame_len)
    meta = await wait_meta(dut)

    assert extract_field(PACKET_META_FIELDS, meta, "has_vlan") == 1
    assert extract_field(PACKET_META_FIELDS, meta, "vlan_tci") == 0x123
    assert extract_field(PACKET_META_FIELDS, meta, "ethertype") == ETH_TYPE_IPV4
    assert extract_field(PACKET_META_FIELDS, meta, "udp_dst_port") == ROCE_UDP_PORT
    assert extract_field(PACKET_META_FIELDS, meta, "dest_qpn") == 0x123456


@cocotb.test()
async def parses_ipv4_ecn_ce_mark(dut):
    await reset_dut(dut)
    data, frame_len = build_ipv4_roce_frame(ROCE_OPCODE_SEND_ONLY, with_vlan=False, dsfield=0x03)
    await send_frame(dut, data, frame_len)
    meta = await wait_meta(dut)

    assert extract_field(PACKET_META_FIELDS, meta, "ip_dsfield") == 0x03
    assert extract_field(PACKET_META_FIELDS, meta, "ecn") == 0x03
    assert extract_field(PACKET_META_FIELDS, meta, "ecn_valid") == 1
    assert extract_field(PACKET_META_FIELDS, meta, "ecn_ce") == 1


@cocotb.test()
async def parses_ipv6_traffic_class_ecn_before_unsupported_layout_drop(dut):
    await reset_dut(dut)
    data, frame_len = build_ipv6_roce_frame(traffic_class=0xAB)
    await send_frame(dut, data, frame_len)
    meta = await wait_meta(dut)

    assert extract_field(PACKET_META_FIELDS, meta, "ethertype") == ETH_TYPE_IPV6
    assert extract_field(PACKET_META_FIELDS, meta, "status") == PKT_PARSE_STATUS_UNSUPPORTED_LAYOUT
    assert extract_field(PACKET_META_FIELDS, meta, "ipv6_traffic_class") == 0xAB
    assert extract_field(PACKET_META_FIELDS, meta, "ecn") == 0x03
    assert extract_field(PACKET_META_FIELDS, meta, "ecn_ce") == 1


@cocotb.test()
async def marks_non_last_first_beat_as_need_more_data(dut):
    await reset_dut(dut)
    data, frame_len = build_ipv4_roce_frame(ROCE_OPCODE_SEND_ONLY_IMM, with_vlan=False)
    await send_frame(dut, data, frame_len, frame_last=0)
    meta = await wait_meta(dut)

    assert int(dut.parse_status.value) == PKT_PARSE_STATUS_NEED_MORE_DATA
    assert extract_field(PACKET_META_FIELDS, meta, "status") == PKT_PARSE_STATUS_NEED_MORE_DATA
    assert extract_field(PACKET_META_FIELDS, meta, "opcode") == ROCE_OPCODE_SEND_ONLY_IMM
