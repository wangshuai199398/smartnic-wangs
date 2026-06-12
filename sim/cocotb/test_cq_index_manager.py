# SPDX-License-Identifier: MIT
"""CQ index manager 最小行为测试。"""

import cocotb
from cocotb.triggers import Timer


CQ_INDEX_ERR_NONE = 0
CQ_INDEX_ERR_DEPTH_ZERO = 1
CQ_INDEX_ERR_PROD_RANGE = 2
CQ_INDEX_ERR_CONS_RANGE = 3
CQ_INDEX_ERR_ARM_RANGE = 4
CQ_INDEX_ERR_OVERFLOW = 5


def drive_request(
    dut,
    *,
    producer=0,
    consumer=0,
    depth=8,
    overflow=0,
    commit=0,
    arm_update=0,
    arm_consumer=0,
    clear=0,
):
    dut.cq_index_req_valid.value = 1
    dut.cq_index_req_cqn.value = 7
    dut.cq_index_req_owner_function.value = 1
    dut.current_producer_index.value = producer
    dut.current_consumer_index.value = consumer
    dut.cq_depth.value = depth
    dut.current_overflow.value = overflow
    dut.cqe_write_commit.value = commit
    dut.cq_arm_consumer_update.value = arm_update
    dut.cq_arm_consumer_index.value = arm_consumer
    dut.overflow_clear_valid.value = clear


async def settle():
    await Timer(1, units="ns")


@cocotb.test()
async def producer_index_increments_normally(dut):
    drive_request(dut, producer=2, consumer=0, depth=8, commit=1)
    await settle()

    assert int(dut.index_error_code.value) == CQ_INDEX_ERR_NONE
    assert int(dut.next_producer_index.value) == 3
    assert int(dut.cq_has_space.value) == 1


@cocotb.test()
async def producer_index_wraps_at_depth_minus_one(dut):
    drive_request(dut, producer=7, consumer=3, depth=8, commit=1)
    await settle()

    assert int(dut.index_error_code.value) == CQ_INDEX_ERR_NONE
    assert int(dut.next_producer_index.value) == 0


@cocotb.test()
async def consumer_index_updates_from_cq_arm(dut):
    drive_request(dut, producer=4, consumer=1, depth=8, arm_update=1, arm_consumer=3)
    await settle()

    assert int(dut.index_error_code.value) == CQ_INDEX_ERR_NONE
    assert int(dut.next_consumer_index.value) == 3


@cocotb.test()
async def depth_zero_returns_error(dut):
    drive_request(dut, producer=0, consumer=0, depth=0)
    await settle()

    assert int(dut.index_error_code.value) == CQ_INDEX_ERR_DEPTH_ZERO
    assert int(dut.cq_has_space.value) == 0


@cocotb.test()
async def producer_index_out_of_range_returns_error(dut):
    drive_request(dut, producer=8, consumer=0, depth=8)
    await settle()

    assert int(dut.index_error_code.value) == CQ_INDEX_ERR_PROD_RANGE


@cocotb.test()
async def consumer_index_out_of_range_returns_error(dut):
    drive_request(dut, producer=0, consumer=8, depth=8)
    await settle()

    assert int(dut.index_error_code.value) == CQ_INDEX_ERR_CONS_RANGE


@cocotb.test()
async def arm_consumer_index_out_of_range_returns_error(dut):
    drive_request(dut, producer=0, consumer=0, depth=8, arm_update=1, arm_consumer=8)
    await settle()

    assert int(dut.index_error_code.value) == CQ_INDEX_ERR_ARM_RANGE


@cocotb.test()
async def empty_when_producer_equals_consumer(dut):
    drive_request(dut, producer=3, consumer=3, depth=8)
    await settle()

    assert int(dut.cq_empty.value) == 1
    assert int(dut.cq_full.value) == 0


@cocotb.test()
async def full_when_next_producer_reaches_consumer_reserved_slot(dut):
    drive_request(dut, producer=2, consumer=3, depth=8)
    await settle()

    assert int(dut.cq_full.value) == 1
    assert int(dut.cq_empty.value) == 0
    assert int(dut.cq_has_space.value) == 0


@cocotb.test()
async def commit_while_full_sets_overflow(dut):
    drive_request(dut, producer=2, consumer=3, depth=8, commit=1)
    await settle()

    assert int(dut.index_error_code.value) == CQ_INDEX_ERR_OVERFLOW
    assert int(dut.cq_overflow.value) == 1


@cocotb.test()
async def overflow_clear_restores_space_when_not_full(dut):
    drive_request(dut, producer=1, consumer=3, depth=8, overflow=1, clear=1)
    await settle()

    assert int(dut.index_error_code.value) == CQ_INDEX_ERR_NONE
    assert int(dut.cq_overflow.value) == 0
    assert int(dut.cq_has_space.value) == 1
