# SPDX-License-Identifier: MIT
"""SR-IOV function manager access-check tests."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


SRIOV_ACCESS_OK = 0
SRIOV_ACCESS_DISABLED = 2
SRIOV_ACCESS_OUT_OF_RANGE = 4
SRIOV_ACCESS_BAR0_DOORBELL = 0
SRIOV_ACCESS_BAR2_CSR = 1
SRIOV_ACCESS_BAR4_MSIX = 2
SRIOV_ACCESS_QP = 3
SRIOV_ACCESS_CQ = 4
SRIOV_ACCESS_MR = 5


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.pf_enable.value = 1
    dut.pf_trusted.value = 1
    dut.vf_enable_mask.value = 0
    dut.vf_trusted_mask.value = 0
    dut.query_valid.value = 0
    dut.query_by_requester_id.value = 0
    dut.query_requester_id.value = 0
    dut.query_function_id.value = 0
    dut.query_rsp_ready.value = 1
    dut.access_valid.value = 0
    dut.access_by_requester_id.value = 0
    dut.access_requester_id.value = 0
    dut.access_function_id.value = 0
    dut.access_type.value = 0
    dut.access_write.value = 0
    dut.access_qp_id.value = 0
    dut.access_cq_id.value = 0
    dut.access_mr_id.value = 0
    dut.access_bar_offset.value = 0
    dut.access_msix_vector.value = 0
    dut.access_rsp_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def check_access(
    dut,
    function_id,
    access_type,
    qp_id=0,
    cq_id=0,
    mr_id=0,
    bar_offset=0,
    msix_vector=0,
):
    dut.access_valid.value = 1
    dut.access_by_requester_id.value = 0
    dut.access_function_id.value = function_id
    dut.access_type.value = access_type
    dut.access_write.value = 1
    dut.access_qp_id.value = qp_id
    dut.access_cq_id.value = cq_id
    dut.access_mr_id.value = mr_id
    dut.access_bar_offset.value = bar_offset
    dut.access_msix_vector.value = msix_vector
    await RisingEdge(dut.clk)
    dut.access_valid.value = 0
    await RisingEdge(dut.clk)
    allowed = int(dut.access_allowed.value)
    status = int(dut.access_status.value)
    await RisingEdge(dut.clk)
    return allowed, status


@cocotb.test()
async def pf_access_is_allowed(dut):
    await reset_dut(dut)

    allowed, status = await check_access(dut, 0, SRIOV_ACCESS_BAR2_CSR)
    assert allowed == 1
    assert status == SRIOV_ACCESS_OK


@cocotb.test()
async def enabled_vf_in_window_is_allowed(dut):
    await reset_dut(dut)

    dut.vf_enable_mask.value = 0x1
    dut.vf_trusted_mask.value = 0x1
    await RisingEdge(dut.clk)

    allowed, status = await check_access(dut, 1, SRIOV_ACCESS_QP, qp_id=0)
    assert allowed == 1
    assert status == SRIOV_ACCESS_OK

    allowed, status = await check_access(dut, 1, SRIOV_ACCESS_BAR0_DOORBELL, bar_offset=0)
    assert allowed == 1
    assert status == SRIOV_ACCESS_OK


@cocotb.test()
async def disabled_vf_is_denied(dut):
    await reset_dut(dut)

    allowed, status = await check_access(dut, 1, SRIOV_ACCESS_QP, qp_id=0)
    assert allowed == 0
    assert status == SRIOV_ACCESS_DISABLED


@cocotb.test()
async def vf_out_of_range_access_is_denied(dut):
    await reset_dut(dut)

    dut.vf_enable_mask.value = 0x1
    dut.vf_trusted_mask.value = 0x1
    await RisingEdge(dut.clk)

    for access_type, kwargs in [
        (SRIOV_ACCESS_QP, {"qp_id": 2048}),
        (SRIOV_ACCESS_CQ, {"cq_id": 2048}),
        (SRIOV_ACCESS_MR, {"mr_id": 2048}),
        (SRIOV_ACCESS_BAR0_DOORBELL, {"bar_offset": 0x0200_0000}),
        (SRIOV_ACCESS_BAR4_MSIX, {"msix_vector": 7}),
    ]:
        allowed, status = await check_access(dut, 1, access_type, **kwargs)
        assert allowed == 0
        assert status == SRIOV_ACCESS_OUT_OF_RANGE
