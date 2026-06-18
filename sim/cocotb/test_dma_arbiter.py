# SPDX-License-Identifier: MIT
"""DMA arbiter 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


MAX_SRC = 7
SRC_W = 3
QPN_W = 24
OWNER_W = 16
OP_W = 4
DIR_W = 3
LEN_W = 32
PRI_W = 4
WEIGHT_W = 8
PAYLOAD_W = 256

POLICY_FIXED = 0
POLICY_RR = 1
POLICY_WRR = 2
POLICY_STRICT_GUARD = 3

SRC_SQ_HOST_READ = 0
SRC_RQ_HOST_WRITE = 1
SRC_RDMA_WRITE_HOST_READ = 2
SRC_RDMA_READ_RESP_WRITE = 3
SRC_CQE_WRITE = 4
SRC_WQE_FETCH = 5
SRC_SGE_FETCH = 6

MR_OP_LOCAL_DMA_READ = 0
MR_OP_LOCAL_DMA_WRITE = 1
MR_OP_LOCAL_RECV_WRITE = 2
DMA_DIR_HOST_READ = 0
DMA_DIR_HOST_WRITE = 1
DMA_DIR_CQE_WRITE = 2
DMA_DIR_WQE_FETCH = 3
DMA_DIR_SGE_FETCH = 4


def pack_lane(current, idx, width, value):
    mask = ((1 << width) - 1) << (idx * width)
    return (current & ~mask) | ((value & ((1 << width) - 1)) << (idx * width))


def source_defaults(idx):
    direction = DMA_DIR_HOST_READ
    operation = MR_OP_LOCAL_DMA_READ
    if idx in (SRC_RQ_HOST_WRITE, SRC_RDMA_READ_RESP_WRITE):
        direction = DMA_DIR_HOST_WRITE
        operation = MR_OP_LOCAL_RECV_WRITE if idx == SRC_RQ_HOST_WRITE else MR_OP_LOCAL_DMA_WRITE
    elif idx == SRC_CQE_WRITE:
        direction = DMA_DIR_CQE_WRITE
    elif idx == SRC_WQE_FETCH:
        direction = DMA_DIR_WQE_FETCH
    elif idx == SRC_SGE_FETCH:
        direction = DMA_DIR_SGE_FETCH
    return {
        "source_id": idx,
        "qpn": 0x100 + idx,
        "owner": 1,
        "desc_id": 0x20 + idx,
        "operation": operation,
        "direction": direction,
        "len": 64,
        "priority": idx,
        "weight": 1,
        "payload": 0xAB00 + idx,
    }


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.arb_policy.value = POLICY_FIXED
    dut.starvation_threshold.value = 4
    dut.req_valid.value = 0
    dut.req_source_id.value = 0
    dut.req_qpn.value = 0
    dut.req_owner_function.value = 0
    dut.req_desc_id.value = 0
    dut.req_operation.value = 0
    dut.req_direction.value = 0
    dut.req_len.value = 0
    dut.req_priority.value = 0
    dut.req_weight.value = 0
    dut.req_payload.value = 0
    dut.grant_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def set_source(dut, idx, valid=1, **overrides):
    values = source_defaults(idx)
    values.update(overrides)
    req_valid = int(dut.req_valid.value)
    if valid:
        req_valid |= 1 << idx
    else:
        req_valid &= ~(1 << idx)
    dut.req_valid.value = req_valid
    dut.req_source_id.value = pack_lane(int(dut.req_source_id.value), idx, SRC_W, values["source_id"])
    dut.req_qpn.value = pack_lane(int(dut.req_qpn.value), idx, QPN_W, values["qpn"])
    dut.req_owner_function.value = pack_lane(int(dut.req_owner_function.value), idx, OWNER_W, values["owner"])
    dut.req_desc_id.value = pack_lane(int(dut.req_desc_id.value), idx, 16, values["desc_id"])
    dut.req_operation.value = pack_lane(int(dut.req_operation.value), idx, OP_W, values["operation"])
    dut.req_direction.value = pack_lane(int(dut.req_direction.value), idx, DIR_W, values["direction"])
    dut.req_len.value = pack_lane(int(dut.req_len.value), idx, LEN_W, values["len"])
    dut.req_priority.value = pack_lane(int(dut.req_priority.value), idx, PRI_W, values["priority"])
    dut.req_weight.value = pack_lane(int(dut.req_weight.value), idx, WEIGHT_W, values["weight"])
    dut.req_payload.value = pack_lane(int(dut.req_payload.value), idx, PAYLOAD_W, values["payload"])


async def wait_grant(dut, timeout=32):
    for _ in range(timeout):
        await Timer(1, units="ns")
        if int(dut.grant_valid.value) == 1:
            grant = {
                "source_id": int(dut.grant_source_id.value),
                "qpn": int(dut.grant_qpn.value),
                "desc_id": int(dut.grant_desc_id.value),
                "direction": int(dut.grant_direction.value),
                "len": int(dut.grant_len.value),
                "payload": int(dut.grant_payload.value),
                "policy": int(dut.grant_policy_used.value),
            }
            await RisingEdge(dut.clk)
            return grant
        await RisingEdge(dut.clk)
    raise AssertionError("grant_valid was not asserted")


async def accept_one_grant(dut):
    grant = await wait_grant(dut)
    await RisingEdge(dut.clk)
    return grant


@cocotb.test()
async def test_single_source_valid_grants_immediately(dut):
    await reset_dut(dut)
    set_source(dut, SRC_SQ_HOST_READ)
    grant = await accept_one_grant(dut)
    assert grant["source_id"] == SRC_SQ_HOST_READ
    assert grant["desc_id"] == 0x20 + SRC_SQ_HOST_READ


@cocotb.test()
async def test_fixed_priority_prefers_cqe_write(dut):
    await reset_dut(dut)
    dut.arb_policy.value = POLICY_FIXED
    set_source(dut, SRC_SQ_HOST_READ)
    set_source(dut, SRC_RQ_HOST_WRITE)
    set_source(dut, SRC_CQE_WRITE)
    grant = await accept_one_grant(dut)
    assert grant["source_id"] == SRC_CQE_WRITE


@cocotb.test()
async def test_round_robin_rotates_between_sources(dut):
    await reset_dut(dut)
    dut.arb_policy.value = POLICY_RR
    set_source(dut, SRC_SQ_HOST_READ)
    set_source(dut, SRC_RQ_HOST_WRITE)
    first = await accept_one_grant(dut)
    second = await accept_one_grant(dut)
    assert first["source_id"] == SRC_SQ_HOST_READ
    assert second["source_id"] == SRC_RQ_HOST_WRITE


@cocotb.test()
async def test_round_robin_skips_invalid_source(dut):
    await reset_dut(dut)
    dut.arb_policy.value = POLICY_RR
    set_source(dut, SRC_RQ_HOST_WRITE)
    grant = await accept_one_grant(dut)
    assert grant["source_id"] == SRC_RQ_HOST_WRITE


@cocotb.test()
async def test_weight_zero_source_is_disabled_for_wrr(dut):
    await reset_dut(dut)
    dut.arb_policy.value = POLICY_WRR
    set_source(dut, SRC_SQ_HOST_READ, weight=0)
    set_source(dut, SRC_RQ_HOST_WRITE, weight=1)
    grant = await accept_one_grant(dut)
    assert grant["source_id"] == SRC_RQ_HOST_WRITE


@cocotb.test()
async def test_weighted_round_robin_basic_weight_behavior(dut):
    await reset_dut(dut)
    dut.arb_policy.value = POLICY_WRR
    set_source(dut, SRC_SQ_HOST_READ, weight=2)
    set_source(dut, SRC_RQ_HOST_WRITE, weight=1)
    grants = [await accept_one_grant(dut) for _ in range(3)]
    assert [g["source_id"] for g in grants] == [
        SRC_SQ_HOST_READ,
        SRC_SQ_HOST_READ,
        SRC_RQ_HOST_WRITE,
    ]


@cocotb.test()
async def test_grant_ready_backpressure_holds_grant(dut):
    await reset_dut(dut)
    dut.grant_ready.value = 0
    set_source(dut, SRC_CQE_WRITE)
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.grant_valid.value) == 1:
            assert int(dut.grant_source_id.value) == SRC_CQE_WRITE
            await RisingEdge(dut.clk)
            assert int(dut.grant_valid.value) == 1
            break
        await RisingEdge(dut.clk)
    else:
        raise AssertionError("grant_valid was not held")
    dut.grant_ready.value = 1
    await accept_one_grant(dut)


@cocotb.test()
async def test_unselected_source_ready_is_zero(dut):
    await reset_dut(dut)
    dut.arb_policy.value = POLICY_FIXED
    set_source(dut, SRC_SQ_HOST_READ)
    set_source(dut, SRC_CQE_WRITE)
    await Timer(1, units="ns")
    grant = await wait_grant(dut)
    assert grant["source_id"] == SRC_CQE_WRITE
    ready = int(dut.req_ready.value)
    assert (ready & (1 << SRC_SQ_HOST_READ)) == 0


@cocotb.test()
async def test_last_grant_source_updates_after_accept(dut):
    await reset_dut(dut)
    set_source(dut, SRC_RQ_HOST_WRITE)
    await accept_one_grant(dut)
    for _ in range(4):
        await RisingEdge(dut.clk)
    assert int(dut.debug_last_grant_source.value) == SRC_RQ_HOST_WRITE


@cocotb.test()
async def test_starvation_counter_increases_for_waiting_source(dut):
    await reset_dut(dut)
    dut.starvation_threshold.value = 2
    dut.arb_policy.value = POLICY_FIXED
    set_source(dut, SRC_SQ_HOST_READ)
    set_source(dut, SRC_CQE_WRITE)
    for _ in range(3):
        await accept_one_grant(dut)
    assert int(dut.starvation_detected.value) & (1 << SRC_SQ_HOST_READ)


@cocotb.test()
async def test_starvation_guard_promotes_waiting_source(dut):
    await reset_dut(dut)
    dut.starvation_threshold.value = 2
    dut.arb_policy.value = POLICY_FIXED
    set_source(dut, SRC_SQ_HOST_READ)
    set_source(dut, SRC_CQE_WRITE)
    for _ in range(3):
        await accept_one_grant(dut)

    dut.arb_policy.value = POLICY_STRICT_GUARD
    grant = await accept_one_grant(dut)
    assert grant["source_id"] == SRC_SQ_HOST_READ
