# SPDX-License-Identifier: MIT
"""RoCEv2 ICRC placeholder 8.5 测试。

本测试明确验证当前 ICRC 模块只是隔离的 placeholder：
TX 方向透传已有 ICRC 字段，RX 方向标记为 unchecked，并始终声明
compatibility_limited=1。真实 ICRC 计算不在本阶段实现。
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


ROCE_OPCODE_SEND_ONLY = 0x04
PKT_ICRC_STATUS_PLACEHOLDER = 0
PKT_ICRC_STATUS_UNCHECKED = 1


ICRC_RESULT_FIELDS = [
    ("desc_id", 16),
    ("qpn", 24),
    ("cqn", 24),
    ("owner_function", 16),
    ("pd_id", 24),
    ("opcode", 8),
    ("status", 4),
    ("error_code", 16),
    ("icrc_value", 32),
    ("compatibility_limited", 1),
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
    dut.req_valid.value = 0
    dut.req_desc_id.value = 0
    dut.req_qpn.value = 0
    dut.req_cqn.value = 0
    dut.req_owner_function.value = 0
    dut.req_pd_id.value = 0
    dut.req_opcode.value = 0
    dut.req_frame_data.value = 0
    dut.req_frame_len.value = 0
    dut.req_existing_icrc.value = 0
    dut.req_is_tx.value = 1
    dut.result_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_req(dut, *, existing_icrc=0xA5A55A5A, is_tx=1):
    dut.req_desc_id.value = 0x55
    dut.req_qpn.value = 0x123456
    dut.req_cqn.value = 0x44
    dut.req_owner_function.value = 1
    dut.req_pd_id.value = 7
    dut.req_opcode.value = ROCE_OPCODE_SEND_ONLY
    dut.req_frame_data.value = 0xDEADBEEF
    dut.req_frame_len.value = 64
    dut.req_existing_icrc.value = existing_icrc
    dut.req_is_tx.value = is_tx
    dut.req_valid.value = 1
    while int(dut.req_ready.value) == 0:
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.req_valid.value = 0


async def wait_result(dut):
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.result_valid.value) == 1:
            result = int(dut.result.value)
            await RisingEdge(dut.clk)
            return result
        await RisingEdge(dut.clk)
    raise AssertionError("result_valid not asserted")


@cocotb.test()
async def tx_placeholder_passthrough_marks_compatibility_limited(dut):
    await reset_dut(dut)
    await send_req(dut, existing_icrc=0xFEEDFACE, is_tx=1)
    result = await wait_result(dut)
    assert extract_field(ICRC_RESULT_FIELDS, result, "status") == PKT_ICRC_STATUS_PLACEHOLDER
    assert extract_field(ICRC_RESULT_FIELDS, result, "icrc_value") == 0xFEEDFACE
    assert extract_field(ICRC_RESULT_FIELDS, result, "compatibility_limited") == 1
    assert extract_field(ICRC_RESULT_FIELDS, result, "desc_id") == 0x55
    assert extract_field(ICRC_RESULT_FIELDS, result, "qpn") == 0x123456


@cocotb.test()
async def rx_placeholder_reports_unchecked(dut):
    await reset_dut(dut)
    await send_req(dut, existing_icrc=0x12345678, is_tx=0)
    result = await wait_result(dut)
    assert extract_field(ICRC_RESULT_FIELDS, result, "status") == PKT_ICRC_STATUS_UNCHECKED
    assert extract_field(ICRC_RESULT_FIELDS, result, "error_code") == 1
    assert extract_field(ICRC_RESULT_FIELDS, result, "icrc_value") == 0x12345678
    assert extract_field(ICRC_RESULT_FIELDS, result, "compatibility_limited") == 1


@cocotb.test()
async def result_backpressure_holds_placeholder(dut):
    await reset_dut(dut)
    dut.result_ready.value = 0
    await send_req(dut, existing_icrc=0xCAFEBABE, is_tx=1)
    for _ in range(4):
        await RisingEdge(dut.clk)
        assert int(dut.result_valid.value) == 1
    dut.result_ready.value = 1
    await RisingEdge(dut.clk)
