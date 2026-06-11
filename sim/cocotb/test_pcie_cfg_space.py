# SPDX-License-Identifier: MIT
"""PCIe configuration space minimal unit tests."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


SMARTNIC_VENDOR_ID = 0x1D0F
SMARTNIC_DEVICE_ID = 0x5A10
CFG_VENDOR_DEVICE_DW = 0x000
CFG_COMMAND_STATUS_DW = 0x001
CFG_CAP_PTR_DW = 0x00D
CAP_PCIE_DW = 0x40 >> 2
CAP_MSIX_DW = 0x60 >> 2


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.cfg_req_valid.value = 0
    dut.cfg_req_write.value = 0
    dut.cfg_req_func_id.value = 0
    dut.cfg_req_requester_id.value = 0
    dut.cfg_req_addr.value = 0
    dut.cfg_req_wdata.value = 0
    dut.cfg_req_be.value = 0
    dut.cfg_rsp_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def cfg_read(dut, addr):
    dut.cfg_req_valid.value = 1
    dut.cfg_req_write.value = 0
    dut.cfg_req_addr.value = addr
    dut.cfg_req_wdata.value = 0
    dut.cfg_req_be.value = 0
    await RisingEdge(dut.clk)
    dut.cfg_req_valid.value = 0
    await RisingEdge(dut.clk)
    data = int(dut.cfg_rsp_rdata.value)
    status = int(dut.cfg_rsp_status.value)
    await RisingEdge(dut.clk)
    return data, status


async def cfg_write(dut, addr, data, be=0xF):
    dut.cfg_req_valid.value = 1
    dut.cfg_req_write.value = 1
    dut.cfg_req_addr.value = addr
    dut.cfg_req_wdata.value = data
    dut.cfg_req_be.value = be
    await RisingEdge(dut.clk)
    dut.cfg_req_valid.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)


@cocotb.test()
async def reads_vendor_device_and_capabilities(dut):
    await reset_dut(dut)

    data, status = await cfg_read(dut, CFG_VENDOR_DEVICE_DW)
    assert status == 0
    assert data & 0xFFFF == SMARTNIC_VENDOR_ID
    assert (data >> 16) & 0xFFFF == SMARTNIC_DEVICE_ID

    data, _ = await cfg_read(dut, CFG_CAP_PTR_DW)
    assert data & 0xFF == 0x40

    pcie_cap, _ = await cfg_read(dut, CAP_PCIE_DW)
    assert pcie_cap & 0xFF == 0x10
    assert (pcie_cap >> 8) & 0xFF == 0x60

    msix_cap, _ = await cfg_read(dut, CAP_MSIX_DW)
    assert msix_cap & 0xFF == 0x11


@cocotb.test()
async def command_status_is_read_write(dut):
    await reset_dut(dut)

    await cfg_write(dut, CFG_COMMAND_STATUS_DW, 0xABCD_0006, be=0xF)
    data, status = await cfg_read(dut, CFG_COMMAND_STATUS_DW)

    assert status == 0
    assert data & 0xFFFF == 0x0006
    assert (data >> 16) & 0xFFFF == 0xABCD
    assert int(dut.cfg_mem_space_en.value) == 1
    assert int(dut.cfg_bus_master_en.value) == 1
