# SPDX-License-Identifier: MIT
"""PCIe BAR decoder minimal routing tests."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


PCIE_BAR_RSP_OK = 0
PCIE_BAR_RSP_UNSUPPORTED = 1
PCIE_BAR_RSP_BAD_OFFSET = 2


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.bar_req_valid.value = 0
    dut.bar_req_write.value = 0
    dut.bar_req_bar.value = 0
    dut.bar_req_offset.value = 0
    dut.bar_req_wdata.value = 0
    dut.bar_req_be.value = 0
    dut.bar_req_func_id.value = 0
    dut.bar_req_requester_id.value = 0
    dut.doorbell_req_ready.value = 1
    dut.csr_req_ready.value = 1
    dut.msix_req_ready.value = 1
    dut.bar_rsp_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def bar_access(dut, bar, offset, write=1):
    dut.bar_req_valid.value = 1
    dut.bar_req_write.value = write
    dut.bar_req_bar.value = bar
    dut.bar_req_offset.value = offset
    dut.bar_req_wdata.value = 0x1234_5678
    dut.bar_req_be.value = 0xF
    await RisingEdge(dut.clk)
    doorbell = int(dut.doorbell_req_valid.value)
    csr = int(dut.csr_req_valid.value)
    msix = int(dut.msix_req_valid.value)
    dut.bar_req_valid.value = 0
    await RisingEdge(dut.clk)
    status = int(dut.bar_rsp_status.value)
    await RisingEdge(dut.clk)
    return doorbell, csr, msix, status


@cocotb.test()
async def routes_bar0_bar2_bar4(dut):
    await reset_dut(dut)

    doorbell, csr, msix, status = await bar_access(dut, 0, 0x0000)
    assert (doorbell, csr, msix, status) == (1, 0, 0, PCIE_BAR_RSP_OK)

    doorbell, csr, msix, status = await bar_access(dut, 2, 0x0100)
    assert (doorbell, csr, msix, status) == (0, 1, 0, PCIE_BAR_RSP_OK)

    doorbell, csr, msix, status = await bar_access(dut, 4, 0x0000)
    assert (doorbell, csr, msix, status) == (0, 0, 1, PCIE_BAR_RSP_OK)


@cocotb.test()
async def rejects_illegal_bar_and_offset(dut):
    await reset_dut(dut)

    _, _, _, status = await bar_access(dut, 1, 0x0000)
    assert status == PCIE_BAR_RSP_UNSUPPORTED

    _, _, _, status = await bar_access(dut, 2, 0x0001_0000)
    assert status == PCIE_BAR_RSP_BAD_OFFSET
