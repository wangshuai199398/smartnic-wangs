# SPDX-License-Identifier: MIT
"""Doorbell address decoder tests."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


DB_TYPE_SQ = 1
DB_TYPE_RQ = 2
DB_TYPE_CQ_ARM = 3
PCIE_BAR_RSP_OK = 0
PCIE_BAR_RSP_BAD_OFFSET = 2
PCIE_BAR_RSP_MISALIGNED = 3
DB_PAGE_SHIFT = 12
DB_SQ_OFFSET = 0x000
DB_RQ_OFFSET = 0x008
DB_CQ_ARM_OFFSET = 0x010


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.db_req_valid.value = 0
    dut.db_req_write.value = 1
    dut.db_req_offset.value = 0
    dut.db_req_wdata.value = 0
    dut.db_req_be.value = 0xF
    dut.db_req_func_id.value = 0
    dut.doorbell_ready.value = 1
    dut.db_rsp_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_decode_req(dut, offset, payload=0x1234, function_id=1):
    dut.db_req_valid.value = 1
    dut.db_req_write.value = 1
    dut.db_req_offset.value = offset
    dut.db_req_wdata.value = payload
    dut.db_req_be.value = 0xF
    dut.db_req_func_id.value = function_id
    await RisingEdge(dut.clk)
    dut.db_req_valid.value = 0


@cocotb.test()
async def sq_offset_decodes_to_qpn(dut):
    await reset_dut(dut)

    await send_decode_req(dut, (7 << DB_PAGE_SHIFT) + DB_SQ_OFFSET, payload=0x55AA)

    assert int(dut.db_rsp_valid.value) == 1
    assert int(dut.db_rsp_status.value) == PCIE_BAR_RSP_OK
    assert int(dut.doorbell_valid.value) == 1
    assert int(dut.doorbell_type.value) == DB_TYPE_SQ
    assert int(dut.qpn.value) == 7
    assert int(dut.cqn.value) == 0
    assert int(dut.queue_index.value) == 0x55AA


@cocotb.test()
async def rq_offset_decodes_to_qpn(dut):
    await reset_dut(dut)

    await send_decode_req(dut, (9 << DB_PAGE_SHIFT) + DB_RQ_OFFSET, payload=0x44)

    assert int(dut.db_rsp_status.value) == PCIE_BAR_RSP_OK
    assert int(dut.doorbell_valid.value) == 1
    assert int(dut.doorbell_type.value) == DB_TYPE_RQ
    assert int(dut.qpn.value) == 9
    assert int(dut.cqn.value) == 0
    assert int(dut.queue_index.value) == 0x44


@cocotb.test()
async def cq_arm_offset_decodes_to_cqn(dut):
    await reset_dut(dut)

    await send_decode_req(dut, (11 << DB_PAGE_SHIFT) + DB_CQ_ARM_OFFSET, payload=0x88)

    assert int(dut.db_rsp_status.value) == PCIE_BAR_RSP_OK
    assert int(dut.doorbell_valid.value) == 1
    assert int(dut.doorbell_type.value) == DB_TYPE_CQ_ARM
    assert int(dut.qpn.value) == 0
    assert int(dut.cqn.value) == 11
    assert int(dut.queue_index.value) == 0x88


@cocotb.test()
async def illegal_page_offset_returns_error(dut):
    await reset_dut(dut)

    await send_decode_req(dut, (2 << DB_PAGE_SHIFT) + 0x018)

    assert int(dut.db_rsp_valid.value) == 1
    assert int(dut.db_rsp_status.value) == PCIE_BAR_RSP_BAD_OFFSET
    assert int(dut.doorbell_valid.value) == 0


@cocotb.test()
async def misaligned_offset_returns_error(dut):
    await reset_dut(dut)

    await send_decode_req(dut, (2 << DB_PAGE_SHIFT) + 0x003)

    assert int(dut.db_rsp_valid.value) == 1
    assert int(dut.db_rsp_status.value) == PCIE_BAR_RSP_MISALIGNED
    assert int(dut.doorbell_valid.value) == 0
