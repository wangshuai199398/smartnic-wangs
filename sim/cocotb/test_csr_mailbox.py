# SPDX-License-Identifier: MIT
"""CSR mailbox lifecycle tests."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


CSR_CMD_NOP = 0x0000
CSR_MB_ERR_INVALID_CMD = 0x0001
CSR_MB_ERR_TIMEOUT = 0x0002
CSR_MB_COMMAND_ID_OFFSET = 0x0100
CSR_MB_CONTROL_OFFSET = 0x0108
CSR_MB_STATUS_OFFSET = 0x010C
CSR_MB_ERROR_CODE_OFFSET = 0x0110
CSR_MB_TIMEOUT_COUNTER_OFFSET = 0x0114


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.csr_req_valid.value = 0
    dut.csr_req_write.value = 0
    dut.csr_req_offset.value = 0
    dut.csr_req_wdata.value = 0
    dut.csr_req_be.value = 0
    dut.csr_req_func_id.value = 0
    dut.csr_rsp_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def csr_write(dut, offset, data, be=0xF):
    dut.csr_req_valid.value = 1
    dut.csr_req_write.value = 1
    dut.csr_req_offset.value = offset
    dut.csr_req_wdata.value = data
    dut.csr_req_be.value = be
    await RisingEdge(dut.clk)
    dut.csr_req_valid.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)


async def csr_read(dut, offset):
    dut.csr_req_valid.value = 1
    dut.csr_req_write.value = 0
    dut.csr_req_offset.value = offset
    dut.csr_req_wdata.value = 0
    dut.csr_req_be.value = 0
    await RisingEdge(dut.clk)
    dut.csr_req_valid.value = 0
    await RisingEdge(dut.clk)
    value = int(dut.csr_rsp_rdata.value)
    status = int(dut.csr_rsp_status.value)
    await RisingEdge(dut.clk)
    return value, status


@cocotb.test()
async def nop_go_done_lifecycle(dut):
    await reset_dut(dut)

    await csr_write(dut, CSR_MB_COMMAND_ID_OFFSET, CSR_CMD_NOP, be=0x3)
    await csr_write(dut, CSR_MB_CONTROL_OFFSET, 0x1, be=0x1)

    for _ in range(5):
        await RisingEdge(dut.clk)

    control, _ = await csr_read(dut, CSR_MB_CONTROL_OFFSET)
    status, _ = await csr_read(dut, CSR_MB_STATUS_OFFSET)
    error_code, _ = await csr_read(dut, CSR_MB_ERROR_CODE_OFFSET)

    assert control & 0x2
    assert status & 0xFF == 0x02
    assert error_code & 0xFFFF == 0


@cocotb.test()
async def invalid_command_reports_error(dut):
    await reset_dut(dut)

    await csr_write(dut, CSR_MB_COMMAND_ID_OFFSET, 0xDEAD, be=0x3)
    await csr_write(dut, CSR_MB_CONTROL_OFFSET, 0x1, be=0x1)
    for _ in range(3):
        await RisingEdge(dut.clk)

    error_code, _ = await csr_read(dut, CSR_MB_ERROR_CODE_OFFSET)
    assert error_code & 0xFFFF == CSR_MB_ERR_INVALID_CMD


@cocotb.test()
async def timeout_error_path_is_reported(dut):
    await reset_dut(dut)

    await csr_write(dut, CSR_MB_COMMAND_ID_OFFSET, CSR_CMD_NOP, be=0x3)

    dut.csr_req_valid.value = 1
    dut.csr_req_write.value = 1
    dut.csr_req_offset.value = CSR_MB_CONTROL_OFFSET
    dut.csr_req_wdata.value = 0x1
    dut.csr_req_be.value = 0x1
    await RisingEdge(dut.clk)
    dut.csr_req_valid.value = 0

    await RisingEdge(dut.clk)
    dut.timeout_counter_reg.value = 1024
    await RisingEdge(dut.clk)

    timeout_counter, _ = await csr_read(dut, CSR_MB_TIMEOUT_COUNTER_OFFSET)
    error_code, _ = await csr_read(dut, CSR_MB_ERROR_CODE_OFFSET)
    assert timeout_counter >= 1024
    assert error_code & 0xFFFF == CSR_MB_ERR_TIMEOUT
