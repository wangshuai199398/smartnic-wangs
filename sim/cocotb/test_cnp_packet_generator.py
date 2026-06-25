# SPDX-License-Identifier: MIT
"""CNP packet generator tests for task 10.2."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


ROCE_OPCODE_CNP = 0x81

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


def extract_field(fields, packed, name):
    bit = sum(width for _, width in fields)
    for field_name, width in fields:
        bit -= width
        if field_name == name:
            return (packed >> bit) & ((1 << width) - 1)
    raise KeyError(name)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.cnp_enable.value = 1
    dut.cnp_rate_limit_cycles.value = 4
    dut.ce_mark_valid.value = 0
    dut.queue_congestion_valid.value = 0
    dut.port_congestion_valid.value = 0
    dut.local_mac.value = 0x001122334455
    dut.peer_mac.value = 0x66778899AABB
    dut.local_ipv4.value = 0x0A000001
    dut.peer_ipv4.value = 0x0A000002
    dut.udp_src_port.value = 0xC001
    dut.pkey.value = 0xFFFF
    dut.build_req_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def wait_build_req(dut):
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.build_req_valid.value) == 1:
            req = int(dut.build_req.value)
            await RisingEdge(dut.clk)
            return req
        await RisingEdge(dut.clk)
    raise AssertionError("build_req_valid not asserted")


@cocotb.test()
async def ce_mark_generates_cnp_build_request(dut):
    await reset_dut(dut)
    dut.ce_mark_desc_id.value = 0x55
    dut.ce_mark_qpn.value = 0x123456
    dut.ce_mark_cqn.value = 0x44
    dut.ce_mark_owner_function.value = 3
    dut.ce_mark_pd_id.value = 7
    dut.ce_mark_opcode.value = 0x04
    dut.ce_mark_valid.value = 1
    await RisingEdge(dut.clk)
    dut.ce_mark_valid.value = 0

    req = await wait_build_req(dut)
    assert extract_field(BUILD_REQ_FIELDS, req, "opcode") == ROCE_OPCODE_CNP
    assert extract_field(BUILD_REQ_FIELDS, req, "dest_qpn") == 0x123456
    assert extract_field(BUILD_REQ_FIELDS, req, "has_imm") == 1
    assert extract_field(BUILD_REQ_FIELDS, req, "imm_data") & 0x3 == 0
    assert int(dut.cnp_generated_total.value) == 1


@cocotb.test()
async def queue_congestion_trigger_generates_queue_type_cnp(dut):
    await reset_dut(dut)
    dut.queue_congestion_qpn.value = 0x222222
    dut.queue_congestion_owner_function.value = 1
    dut.queue_congestion_valid.value = 1
    await RisingEdge(dut.clk)
    dut.queue_congestion_valid.value = 0

    req = await wait_build_req(dut)
    assert extract_field(BUILD_REQ_FIELDS, req, "opcode") == ROCE_OPCODE_CNP
    assert extract_field(BUILD_REQ_FIELDS, req, "dest_qpn") == 0x222222
    assert extract_field(BUILD_REQ_FIELDS, req, "imm_data") & 0x3 == 1


@cocotb.test()
async def per_qp_rate_limit_suppresses_second_cnp(dut):
    await reset_dut(dut)
    dut.ce_mark_qpn.value = 0x10
    dut.ce_mark_valid.value = 1
    await RisingEdge(dut.clk)
    dut.ce_mark_valid.value = 0
    await wait_build_req(dut)

    dut.ce_mark_valid.value = 1
    await RisingEdge(dut.clk)
    dut.ce_mark_valid.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)

    assert int(dut.cnp_generated_total.value) == 1
    assert int(dut.cnp_rate_limited.value) == 1
