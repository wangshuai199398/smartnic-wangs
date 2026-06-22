# SPDX-License-Identifier: MIT
"""RoCEv2 packet builder 8.4 最小行为测试。

覆盖 Ethernet/IPv4/UDP/BTH 基础 header，以及 RETH、AETH/ACK、
DETH、ImmDt、CNP 和 payload frame 的单 beat 构造。ICRC 只验证
placeholder 透传，不验证真实 CRC。
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


ROCE_OPCODE_SEND_ONLY = 0x04
ROCE_OPCODE_SEND_ONLY_IMM = 0x05
ROCE_OPCODE_RDMA_WRITE_ONLY = 0x0A
ROCE_OPCODE_ACK = 0x11
ROCE_OPCODE_CNP = 0x81
ROCE_OPCODE_UD_SEND_ONLY = 0x64

ETH_TYPE_IPV4 = 0x0800
ROCE_UDP_PORT = 4791
PKT_BUILD_ERR_MULTI_BEAT_STUB = 3
PKT_BUILD_ERR_UNSUPPORTED = 1


BUILD_REQ_FIELDS = [
    ("desc_id", 16),
    ("qpn", 24),
    ("cqn", 24),
    ("owner_function", 16),
    ("pd_id", 24),
    ("opcode", 8),
    ("status", 5),
    ("error_code", 16),
    ("dst_mac", 48),
    ("src_mac", 48),
    ("has_vlan", 1),
    ("vlan_tci", 16),
    ("src_ipv4", 32),
    ("dst_ipv4", 32),
    ("udp_src_port", 16),
    ("udp_dst_port", 16),
    ("pkey", 16),
    ("dest_qpn", 24),
    ("src_qpn", 24),
    ("psn", 24),
    ("remote_va", 64),
    ("rkey", 32),
    ("dma_length", 32),
    ("aeth", 32),
    ("qkey", 32),
    ("has_imm", 1),
    ("imm_data", 32),
    ("payload_data", 512),
    ("payload_len", 16),
    ("icrc_placeholder", 32),
]


def pack_fields(fields, values):
    packed = 0
    for name, width in fields:
        packed = (packed << width) | (values.get(name, 0) & ((1 << width) - 1))
    return packed


def get_bits(value, high, low):
    return (value >> low) & ((1 << (high - low + 1)) - 1)


def pack_req(**overrides):
    values = {
        "desc_id": 0x55,
        "qpn": 0x123456,
        "cqn": 0x44,
        "owner_function": 1,
        "pd_id": 7,
        "opcode": ROCE_OPCODE_SEND_ONLY,
        "dst_mac": 0x112233445566,
        "src_mac": 0xAABBCCDDEEFF,
        "src_ipv4": 0x0A000001,
        "dst_ipv4": 0x0A000002,
        "udp_src_port": 0xC001,
        "udp_dst_port": ROCE_UDP_PORT,
        "pkey": 0xFFFF,
        "dest_qpn": 0x654321,
        "src_qpn": 0x123456,
        "psn": 0x010203,
        "remote_va": 0x1000200030004000,
        "rkey": 0xABCDEF01,
        "dma_length": 0x20,
        "aeth": 0xCAFEBABE,
        "qkey": 0x11112222,
        "imm_data": 0xA1B2C3D4,
        "payload_data": 0xDEADBEEF,
        "payload_len": 4,
        "icrc_placeholder": 0xFEEDFACE,
    }
    values.update(overrides)
    return pack_fields(BUILD_REQ_FIELDS, values)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.build_req_valid.value = 0
    dut.build_req.value = 0
    dut.icrc_result_valid.value = 0
    dut.icrc_result.value = 0
    dut.frame_ready.value = 1
    dut.build_error_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_req(dut, req):
    dut.build_req.value = req
    dut.build_req_valid.value = 1
    while int(dut.build_req_ready.value) == 0:
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.build_req_valid.value = 0


async def wait_frame(dut):
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.frame_valid.value) == 1:
            data = int(dut.frame_data.value)
            length = int(dut.frame_len.value)
            await RisingEdge(dut.clk)
            return data, length
        await RisingEdge(dut.clk)
    raise AssertionError("frame_valid not asserted")


async def wait_error(dut):
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.build_error_valid.value) == 1:
            err = int(dut.build_error_code.value)
            await RisingEdge(dut.clk)
            return err
        await RisingEdge(dut.clk)
    raise AssertionError("build_error_valid not asserted")


@cocotb.test()
async def builds_send_payload_frame(dut):
    await reset_dut(dut)
    await send_req(dut, pack_req(opcode=ROCE_OPCODE_SEND_ONLY, payload_len=4))
    data, length = await wait_frame(dut)
    assert length == 14 + 20 + 8 + 12 + 4 + 4
    assert get_bits(data, 111, 96) == ETH_TYPE_IPV4
    assert get_bits(data, 303, 288) == ROCE_UDP_PORT
    assert get_bits(data, 319, 312) == ROCE_OPCODE_SEND_ONLY
    assert get_bits(data, 351, 328) == 0x654321
    assert get_bits(data, 511, 480) == 0xFEEDFACE


@cocotb.test()
async def builds_rdma_write_reth_header(dut):
    await reset_dut(dut)
    await send_req(dut, pack_req(opcode=ROCE_OPCODE_RDMA_WRITE_ONLY, payload_len=0))
    data, _ = await wait_frame(dut)
    assert get_bits(data, 319, 312) == ROCE_OPCODE_RDMA_WRITE_ONLY
    assert get_bits(data, 447, 384) == 0x1000200030004000
    assert get_bits(data, 479, 448) == 0xABCDEF01
    assert get_bits(data, 511, 480) == 0x20


@cocotb.test()
async def builds_ack_aeth_header(dut):
    await reset_dut(dut)
    await send_req(dut, pack_req(opcode=ROCE_OPCODE_ACK, payload_len=0))
    data, _ = await wait_frame(dut)
    assert get_bits(data, 319, 312) == ROCE_OPCODE_ACK
    assert get_bits(data, 415, 384) == 0xCAFEBABE


@cocotb.test()
async def builds_ud_deth_header(dut):
    await reset_dut(dut)
    await send_req(dut, pack_req(opcode=ROCE_OPCODE_UD_SEND_ONLY, payload_len=0))
    data, _ = await wait_frame(dut)
    assert get_bits(data, 319, 312) == ROCE_OPCODE_UD_SEND_ONLY
    assert get_bits(data, 415, 384) == 0x11112222
    assert get_bits(data, 447, 424) == 0x123456


@cocotb.test()
async def builds_send_with_immediate_header(dut):
    await reset_dut(dut)
    await send_req(dut, pack_req(opcode=ROCE_OPCODE_SEND_ONLY_IMM, payload_len=0))
    data, _ = await wait_frame(dut)
    assert get_bits(data, 319, 312) == ROCE_OPCODE_SEND_ONLY_IMM
    assert get_bits(data, 415, 384) == 0xA1B2C3D4


@cocotb.test()
async def builds_cnp_header(dut):
    await reset_dut(dut)
    await send_req(dut, pack_req(opcode=ROCE_OPCODE_CNP, payload_len=0))
    data, _ = await wait_frame(dut)
    assert get_bits(data, 319, 312) == ROCE_OPCODE_CNP


@cocotb.test()
async def unsupported_opcode_reports_error(dut):
    await reset_dut(dut)
    await send_req(dut, pack_req(opcode=0xFE))
    assert await wait_error(dut) == PKT_BUILD_ERR_UNSUPPORTED


@cocotb.test()
async def too_large_frame_reports_multi_beat_stub(dut):
    await reset_dut(dut)
    await send_req(dut, pack_req(opcode=ROCE_OPCODE_RDMA_WRITE_ONLY, payload_len=32))
    assert await wait_error(dut) == PKT_BUILD_ERR_MULTI_BEAT_STUB


@cocotb.test()
async def frame_backpressure_holds_output(dut):
    await reset_dut(dut)
    dut.frame_ready.value = 0
    await send_req(dut, pack_req(opcode=ROCE_OPCODE_ACK, payload_len=0))
    for _ in range(4):
        await RisingEdge(dut.clk)
        assert int(dut.frame_valid.value) == 1
    dut.frame_ready.value = 1
    await RisingEdge(dut.clk)
