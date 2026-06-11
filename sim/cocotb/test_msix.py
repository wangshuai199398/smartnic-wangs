# SPDX-License-Identifier: MIT
"""MSI-X table, mask, pending, and PBA tests."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


MSIX_TABLE_OFFSET = 0x0000
MSIX_PBA_OFFSET = 0x0800
ENTRY_SIZE = 0x10


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.msix_req_valid.value = 0
    dut.msix_req_write.value = 0
    dut.msix_req_offset.value = 0
    dut.msix_req_wdata.value = 0
    dut.msix_req_be.value = 0
    dut.msix_req_func_id.value = 0
    dut.msix_req_is_pba.value = 0
    dut.msix_rsp_ready.value = 1
    dut.cq_interrupt_req.value = 0
    dut.admin_interrupt_req.value = 0
    dut.error_interrupt_req.value = 0
    dut.msix_msg_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def msix_write(dut, offset, data, be=0xF):
    dut.msix_req_valid.value = 1
    dut.msix_req_write.value = 1
    dut.msix_req_offset.value = offset
    dut.msix_req_wdata.value = data
    dut.msix_req_be.value = be
    dut.msix_req_is_pba.value = int(offset >= MSIX_PBA_OFFSET)
    await RisingEdge(dut.clk)
    dut.msix_req_valid.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)


async def msix_read(dut, offset):
    dut.msix_req_valid.value = 1
    dut.msix_req_write.value = 0
    dut.msix_req_offset.value = offset
    dut.msix_req_wdata.value = 0
    dut.msix_req_be.value = 0
    dut.msix_req_is_pba.value = int(offset >= MSIX_PBA_OFFSET)
    await RisingEdge(dut.clk)
    dut.msix_req_valid.value = 0
    await RisingEdge(dut.clk)
    data = int(dut.msix_rsp_rdata.value)
    status = int(dut.msix_rsp_status.value)
    await RisingEdge(dut.clk)
    return data, status


@cocotb.test()
async def masked_interrupt_sets_pending_bit(dut):
    await reset_dut(dut)

    dut.cq_interrupt_req.value = 1
    await RisingEdge(dut.clk)
    dut.cq_interrupt_req.value = 0
    await RisingEdge(dut.clk)

    assert int(dut.msix_msg_valid.value) == 0
    pba, status = await msix_read(dut, MSIX_PBA_OFFSET)
    assert status == 0
    assert pba & 0x1


@cocotb.test()
async def unmask_releases_pending_interrupt(dut):
    await reset_dut(dut)

    dut.msix_msg_ready.value = 0
    await msix_write(dut, MSIX_TABLE_OFFSET + 0 * ENTRY_SIZE + 0x0, 0xFEE0_0000)
    await msix_write(dut, MSIX_TABLE_OFFSET + 0 * ENTRY_SIZE + 0x8, 0x45)
    dut.cq_interrupt_req.value = 1
    await RisingEdge(dut.clk)
    dut.cq_interrupt_req.value = 0
    await RisingEdge(dut.clk)

    await msix_write(dut, MSIX_TABLE_OFFSET + 0 * ENTRY_SIZE + 0xC, 0x0)
    await RisingEdge(dut.clk)

    assert int(dut.msix_msg_valid.value) == 1
    assert int(dut.msix_msg_addr.value) == 0xFEE0_0000
    assert int(dut.msix_msg_data.value) == 0x45


@cocotb.test()
async def pba_write_clears_pending_bit(dut):
    await reset_dut(dut)

    dut.error_interrupt_req.value = 1
    await RisingEdge(dut.clk)
    dut.error_interrupt_req.value = 0
    await RisingEdge(dut.clk)

    pba, _ = await msix_read(dut, MSIX_PBA_OFFSET)
    assert pba & 0x4

    await msix_write(dut, MSIX_PBA_OFFSET, 0x4)
    pba, _ = await msix_read(dut, MSIX_PBA_OFFSET)
    assert (pba & 0x4) == 0
