# SPDX-License-Identifier: MIT
"""RoCEv2 payload extraction 8.3 最小行为测试。

本测试只覆盖 validated metadata + 单个 frame beat 到 transport metadata
和 receive-DMA payload stream 的接口转换，不实现 packet builder 或第 9 阶段
transport 协议状态机。
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


ROCE_OPCODE_SEND_ONLY = 0x04
PKT_PARSE_STATUS_OK = 0
PKT_PAYLOAD_ERR_MULTI_BEAT_STUB = 3


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

PACKET_PAYLOAD_FIELDS = [
    ("desc_id", 16),
    ("qpn", 24),
    ("cqn", 24),
    ("owner_function", 16),
    ("pd_id", 24),
    ("opcode", 8),
    ("status", 5),
    ("error_code", 16),
    ("data", 512),
    ("payload_len", 16),
    ("valid_bytes", 16),
    ("byte_offset", 16),
    ("first", 1),
    ("last", 1),
    ("has_imm", 1),
    ("imm_data", 32),
    ("remote_va", 64),
    ("rkey", 32),
    ("dma_length", 32),
    ("dest_qpn", 24),
    ("psn", 24),
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
        "payload_offset": 54,
        "payload_len": 6,
        "dest_qpn": 0x123456,
        "psn": 0x10203,
        "has_imm": 1,
        "imm_data": 0xAABBCCDD,
    }
    values.update(overrides)
    return pack_fields(PACKET_META_FIELDS, values)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.meta_valid.value = 0
    dut.meta_in.value = 0
    dut.frame_valid.value = 0
    dut.frame_data.value = 0
    dut.frame_len.value = 0
    dut.frame_last.value = 1
    dut.transport_meta_ready.value = 1
    dut.rx_payload_ready.value = 1
    dut.extract_error_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_pair(dut, meta, frame_data=0xDEADBEEF << (54 * 8), frame_len=64, frame_last=1):
    dut.meta_in.value = meta
    dut.frame_data.value = frame_data
    dut.frame_len.value = frame_len
    dut.frame_last.value = frame_last
    dut.meta_valid.value = 1
    dut.frame_valid.value = 1
    while int(dut.meta_ready.value) == 0 or int(dut.frame_ready.value) == 0:
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.meta_valid.value = 0
    dut.frame_valid.value = 0


async def wait_payload(dut):
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.rx_payload_valid.value) == 1:
            payload = int(dut.rx_payload.value)
            await RisingEdge(dut.clk)
            return payload
        await RisingEdge(dut.clk)
    raise AssertionError("rx_payload_valid not asserted")


async def wait_error(dut):
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.extract_error_valid.value) == 1:
            err = int(dut.extract_error_code.value)
            await RisingEdge(dut.clk)
            return err
        await RisingEdge(dut.clk)
    raise AssertionError("extract_error_valid not asserted")


@cocotb.test()
async def emits_transport_metadata_and_payload_stream(dut):
    await reset_dut(dut)
    await send_pair(dut, pack_meta())
    payload = await wait_payload(dut)

    assert int(dut.transport_meta_valid.value) == 1
    assert extract_field(PACKET_PAYLOAD_FIELDS, payload, "desc_id") == 0x55
    assert extract_field(PACKET_PAYLOAD_FIELDS, payload, "qpn") == 0x123456
    assert extract_field(PACKET_PAYLOAD_FIELDS, payload, "payload_len") == 6
    assert extract_field(PACKET_PAYLOAD_FIELDS, payload, "valid_bytes") == 6
    assert extract_field(PACKET_PAYLOAD_FIELDS, payload, "first") == 1
    assert extract_field(PACKET_PAYLOAD_FIELDS, payload, "last") == 1


@cocotb.test()
async def zero_payload_emits_only_transport_metadata(dut):
    await reset_dut(dut)
    await send_pair(dut, pack_meta(payload_len=0), frame_data=0, frame_len=58)
    for _ in range(8):
        await Timer(1, units="ns")
        if int(dut.transport_meta_valid.value) == 1:
            assert int(dut.rx_payload_valid.value) == 0
            return
        await RisingEdge(dut.clk)
    raise AssertionError("transport_meta_valid not asserted")


@cocotb.test()
async def multi_beat_payload_reports_stub_error(dut):
    await reset_dut(dut)
    await send_pair(dut, pack_meta(payload_offset=54, payload_len=32, frame_len=100), frame_len=100)
    assert await wait_error(dut) == PKT_PAYLOAD_ERR_MULTI_BEAT_STUB


@cocotb.test()
async def output_backpressure_holds_payload(dut):
    await reset_dut(dut)
    dut.rx_payload_ready.value = 0
    await send_pair(dut, pack_meta())
    for _ in range(4):
        await RisingEdge(dut.clk)
        assert int(dut.rx_payload_valid.value) == 1
        assert int(dut.transport_meta_valid.value) == 1
    dut.rx_payload_ready.value = 1
    await RisingEdge(dut.clk)
