# SPDX-License-Identifier: MIT
"""Doorbell per-function access check tests."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


DB_TYPE_SQ = 1
DB_TYPE_CQ_ARM = 3
SRIOV_ACCESS_OK = 0
SRIOV_ACCESS_DENIED = 1
SRIOV_ACCESS_DISABLED = 2
SRIOV_ACCESS_OUT_OF_RANGE = 4


def append_field(value, width, acc):
    return (acc << width) | (value & ((1 << width) - 1))


def pack_resource_window(
    qp_base=0,
    qp_limit=1023,
    cq_base=0,
    cq_limit=1023,
    mr_base=0,
    mr_limit=1023,
    doorbell_base=0,
    doorbell_limit=0x00FF_FFFF,
    msix_vector_base=0,
    msix_vector_limit=7,
):
    value = 0
    for field_value, width in [
        (qp_base, 24),
        (qp_limit, 24),
        (cq_base, 24),
        (cq_limit, 24),
        (mr_base, 24),
        (mr_limit, 24),
        (doorbell_base, 32),
        (doorbell_limit, 32),
        (msix_vector_base, 12),
        (msix_vector_limit, 12),
    ]:
        value = append_field(field_value, width, value)
    return value


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.check_valid.value = 0
    dut.doorbell_type.value = DB_TYPE_SQ
    dut.qpn.value = 0
    dut.cqn.value = 0
    dut.queue_index.value = 0
    dut.raw_payload.value = 0
    dut.owner_function.value = 0
    dut.requester_id.value = 0
    dut.function_id.value = 0
    dut.is_pf.value = 1
    dut.vf_id.value = 0
    dut.function_enabled.value = 1
    dut.resource_window.value = pack_resource_window()
    dut.check_rsp_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def check_access(
    dut,
    doorbell_type=DB_TYPE_SQ,
    qpn=0,
    cqn=0,
    owner_function=0,
    function_id=0,
    function_enabled=1,
    is_pf=1,
    resource_window=None,
):
    dut.check_valid.value = 1
    dut.doorbell_type.value = doorbell_type
    dut.qpn.value = qpn
    dut.cqn.value = cqn
    dut.owner_function.value = owner_function
    dut.function_id.value = function_id
    dut.function_enabled.value = function_enabled
    dut.is_pf.value = is_pf
    if resource_window is not None:
        dut.resource_window.value = resource_window
    await RisingEdge(dut.clk)
    dut.check_valid.value = 0
    await RisingEdge(dut.clk)
    return int(dut.access_allowed.value), int(dut.error_code.value)


@cocotb.test()
async def pf_access_is_allowed(dut):
    await reset_dut(dut)

    allowed, status = await check_access(dut, qpn=10, owner_function=0, function_id=0, is_pf=1)

    assert allowed == 1
    assert status == SRIOV_ACCESS_OK


@cocotb.test()
async def enabled_vf_in_own_window_is_allowed(dut):
    await reset_dut(dut)

    window = pack_resource_window(qp_base=100, qp_limit=199, cq_base=300, cq_limit=399)
    allowed, status = await check_access(
        dut,
        qpn=150,
        owner_function=1,
        function_id=1,
        is_pf=0,
        resource_window=window,
    )

    assert allowed == 1
    assert status == SRIOV_ACCESS_OK


@cocotb.test()
async def disabled_vf_is_denied(dut):
    await reset_dut(dut)

    allowed, status = await check_access(
        dut,
        qpn=150,
        owner_function=1,
        function_id=1,
        function_enabled=0,
        is_pf=0,
    )

    assert allowed == 0
    assert status == SRIOV_ACCESS_DISABLED


@cocotb.test()
async def cross_vf_qp_access_is_denied(dut):
    await reset_dut(dut)

    allowed, status = await check_access(dut, qpn=150, owner_function=2, function_id=1, is_pf=0)

    assert allowed == 0
    assert status == SRIOV_ACCESS_DENIED


@cocotb.test()
async def cross_vf_cq_access_is_denied(dut):
    await reset_dut(dut)

    allowed, status = await check_access(
        dut,
        doorbell_type=DB_TYPE_CQ_ARM,
        cqn=350,
        owner_function=2,
        function_id=1,
        is_pf=0,
    )

    assert allowed == 0
    assert status == SRIOV_ACCESS_DENIED


@cocotb.test()
async def qpn_out_of_range_is_denied(dut):
    await reset_dut(dut)

    window = pack_resource_window(qp_base=100, qp_limit=199)
    allowed, status = await check_access(
        dut,
        qpn=250,
        owner_function=1,
        function_id=1,
        is_pf=0,
        resource_window=window,
    )

    assert allowed == 0
    assert status == SRIOV_ACCESS_OUT_OF_RANGE


@cocotb.test()
async def cqn_out_of_range_is_denied(dut):
    await reset_dut(dut)

    window = pack_resource_window(cq_base=300, cq_limit=399)
    allowed, status = await check_access(
        dut,
        doorbell_type=DB_TYPE_CQ_ARM,
        cqn=450,
        owner_function=1,
        function_id=1,
        is_pf=0,
        resource_window=window,
    )

    assert allowed == 0
    assert status == SRIOV_ACCESS_OUT_OF_RANGE
