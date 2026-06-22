# SPDX-License-Identifier: MIT
"""RoCEv2 ingress validation 8.2 最小行为测试。

测试只覆盖 parser metadata 后的入站合法性裁决，不实现 payload extraction、
packet builder、真实 checksum 计算器或 transport/QP 状态机。
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


ETH_TYPE_IPV4 = 0x0800
IP_PROTO_UDP = 0x11
ROCE_UDP_PORT = 4791
ROCE_OPCODE_SEND_ONLY = 0x04

PKT_PARSE_STATUS_OK = 0

PKT_VALIDATION_OK = 0
PKT_VALIDATION_ERR_PARSE = 1
PKT_VALIDATION_ERR_ETHERTYPE = 2
PKT_VALIDATION_ERR_IP_VERSION = 3
PKT_VALIDATION_ERR_IHL = 4
PKT_VALIDATION_ERR_PROTOCOL = 5
PKT_VALIDATION_ERR_UDP_PORT = 6
PKT_VALIDATION_ERR_BTH_VERSION = 7
PKT_VALIDATION_ERR_OPCODE = 8
PKT_VALIDATION_ERR_CHECKSUM = 9
PKT_VALIDATION_ERR_LENGTH = 10


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


def pack_fields(fields, values):
    packed = 0
    for name, width in fields:
        packed = (packed << width) | (values.get(name, 0) & ((1 << width) - 1))
    return packed


def pack_meta(**overrides):
    values = {
        "desc_id": 0x42,
        "qpn": 0x123456,
        "cqn": 0x44,
        "owner_function": 1,
        "pd_id": 7,
        "opcode": ROCE_OPCODE_SEND_ONLY,
        "status": PKT_PARSE_STATUS_OK,
        "frame_len": 64,
        "ethertype": ETH_TYPE_IPV4,
        "has_vlan": 0,
        "vlan_tci": 0,
        "ip_version": 4,
        "ip_ihl": 5,
        "ip_total_length": 50,
        "ip_protocol": IP_PROTO_UDP,
        "ip_checksum": 0x1111,
        "ipv4_src": 0x0A000001,
        "ipv4_dst": 0x0A000002,
        "udp_src_port": 0xC001,
        "udp_dst_port": ROCE_UDP_PORT,
        "udp_length": 30,
        "udp_checksum": 0x2222,
        "bth_transport_version": 0,
        "pkey": 0xFFFF,
        "dest_qpn": 0x123456,
        "psn": 1,
        "payload_offset": 54,
        "payload_len": 6,
        "icrc": 0xDEADBEEF,
    }
    values.update(overrides)
    return pack_fields(PACKET_META_FIELDS, values)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.meta_valid.value = 0
    dut.meta_in.value = 0
    dut.checksum_valid.value = 1
    dut.checksum_ok.value = 1
    dut.validated_ready.value = 1
    dut.drop_ready.value = 1
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


async def wait_validated(dut):
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.validated_valid.value) == 1:
            await RisingEdge(dut.clk)
            return
        await RisingEdge(dut.clk)
    raise AssertionError("validated_valid not asserted")


async def wait_drop(dut):
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.drop_valid.value) == 1:
            err = int(dut.validation_error.value)
            await RisingEdge(dut.clk)
            return err
        await RisingEdge(dut.clk)
    raise AssertionError("drop_valid not asserted")


@cocotb.test()
async def valid_rocev2_metadata_is_accepted(dut):
    await reset_dut(dut)
    await send_meta(dut, pack_meta())
    await wait_validated(dut)
    assert int(dut.validation_error.value) == PKT_VALIDATION_OK


@cocotb.test()
async def invalid_ethertype_is_dropped(dut):
    await reset_dut(dut)
    await send_meta(dut, pack_meta(ethertype=0x86DD))
    assert await wait_drop(dut) == PKT_VALIDATION_ERR_ETHERTYPE


@cocotb.test()
async def invalid_ipv4_version_is_dropped(dut):
    await reset_dut(dut)
    await send_meta(dut, pack_meta(ip_version=6))
    assert await wait_drop(dut) == PKT_VALIDATION_ERR_IP_VERSION


@cocotb.test()
async def invalid_ihl_is_dropped(dut):
    await reset_dut(dut)
    await send_meta(dut, pack_meta(ip_ihl=6))
    assert await wait_drop(dut) == PKT_VALIDATION_ERR_IHL


@cocotb.test()
async def invalid_ip_protocol_is_dropped(dut):
    await reset_dut(dut)
    await send_meta(dut, pack_meta(ip_protocol=0x06))
    assert await wait_drop(dut) == PKT_VALIDATION_ERR_PROTOCOL


@cocotb.test()
async def invalid_udp_port_is_dropped(dut):
    await reset_dut(dut)
    await send_meta(dut, pack_meta(udp_dst_port=1234))
    assert await wait_drop(dut) == PKT_VALIDATION_ERR_UDP_PORT


@cocotb.test()
async def invalid_bth_transport_version_is_dropped(dut):
    await reset_dut(dut)
    await send_meta(dut, pack_meta(bth_transport_version=1))
    assert await wait_drop(dut) == PKT_VALIDATION_ERR_BTH_VERSION


@cocotb.test()
async def unsupported_opcode_is_dropped(dut):
    await reset_dut(dut)
    await send_meta(dut, pack_meta(opcode=0xFE))
    assert await wait_drop(dut) == PKT_VALIDATION_ERR_OPCODE


@cocotb.test()
async def checksum_failure_is_dropped(dut):
    await reset_dut(dut)
    dut.checksum_ok.value = 0
    await send_meta(dut, pack_meta())
    assert await wait_drop(dut) == PKT_VALIDATION_ERR_CHECKSUM


@cocotb.test()
async def missing_checksum_result_is_dropped(dut):
    await reset_dut(dut)
    dut.checksum_valid.value = 0
    await send_meta(dut, pack_meta())
    assert await wait_drop(dut) == PKT_VALIDATION_ERR_CHECKSUM


@cocotb.test()
async def invalid_packet_length_is_dropped(dut):
    await reset_dut(dut)
    await send_meta(dut, pack_meta(ip_total_length=40))
    assert await wait_drop(dut) == PKT_VALIDATION_ERR_LENGTH


@cocotb.test()
async def output_backpressure_holds_drop(dut):
    await reset_dut(dut)
    dut.drop_ready.value = 0
    await send_meta(dut, pack_meta(udp_dst_port=1))
    for _ in range(4):
        await RisingEdge(dut.clk)
        assert int(dut.drop_valid.value) == 1
    dut.drop_ready.value = 1
    await RisingEdge(dut.clk)
