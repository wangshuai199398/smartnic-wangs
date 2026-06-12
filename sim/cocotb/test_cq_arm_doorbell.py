# SPDX-License-Identifier: MIT
"""CQ arm Doorbell payload parser tests."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


DB_TYPE_CQ_ARM = 3
DB_ERR_NONE = 0
DB_ERR_ACCESS_DENIED = 2
DB_ERR_BAD_PAYLOAD = 4
DB_ERR_INVALID_CQN = 7


def pack_cq_arm_payload(consumer_index, sequence=0, flags=0):
    return ((flags & 0xFF) << 24) | ((sequence & 0xFF) << 16) | (consumer_index & 0xFFFF)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.cq_db_valid.value = 0
    dut.doorbell_type.value = DB_TYPE_CQ_ARM
    dut.cqn.value = 0
    dut.queue_index.value = 0
    dut.raw_payload.value = 0
    dut.owner_function.value = 0
    dut.access_allowed.value = 1
    dut.access_error.value = 0
    dut.access_error_code.value = 0
    dut.cqn_valid.value = 1
    dut.cq_arm_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_cq_arm_doorbell(
    dut,
    cqn=5,
    function_id=1,
    consumer_index=4,
    sequence=0x56,
    flags=0,
    access_allowed=1,
    access_error=0,
    cqn_valid=1,
    queue_index=None,
):
    dut.cq_db_valid.value = 1
    dut.doorbell_type.value = DB_TYPE_CQ_ARM
    dut.cqn.value = cqn
    dut.queue_index.value = consumer_index if queue_index is None else queue_index
    dut.raw_payload.value = pack_cq_arm_payload(consumer_index, sequence, flags)
    dut.owner_function.value = function_id
    dut.access_allowed.value = access_allowed
    dut.access_error.value = access_error
    dut.cqn_valid.value = cqn_valid
    await RisingEdge(dut.clk)
    dut.cq_db_valid.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def legal_cq_arm_updates_consumer_index(dut):
    await reset_dut(dut)

    await send_cq_arm_doorbell(dut, cqn=17, function_id=2, consumer_index=64, sequence=0x7C)

    assert int(dut.cq_arm_valid.value) == 1
    assert int(dut.cq_arm_error.value) == 0
    assert int(dut.cq_arm_error_code.value) == DB_ERR_NONE
    assert int(dut.cq_arm_cqn.value) == 17
    assert int(dut.cq_arm_function_id.value) == 2
    assert int(dut.cq_arm_consumer_index.value) == 64
    assert int(dut.cq_arm_armed.value) == 1
    assert int(dut.cq_arm_solicited_only.value) == 0
    assert int(dut.cq_arm_sequence.value) == 0x7C


@cocotb.test()
async def solicited_only_flag_is_reported(dut):
    await reset_dut(dut)

    await send_cq_arm_doorbell(dut, consumer_index=9, flags=1)

    assert int(dut.cq_arm_valid.value) == 1
    assert int(dut.cq_arm_error.value) == 0
    assert int(dut.cq_arm_solicited_only.value) == 1
    assert int(dut.cq_arm_flags.value) == 1


@cocotb.test()
async def invalid_cqn_returns_error(dut):
    await reset_dut(dut)

    await send_cq_arm_doorbell(dut, cqn=123, consumer_index=8, cqn_valid=0)

    assert int(dut.cq_arm_valid.value) == 1
    assert int(dut.cq_arm_error.value) == 1
    assert int(dut.cq_arm_error_code.value) == DB_ERR_INVALID_CQN
    assert int(dut.cq_arm_armed.value) == 0
    assert int(dut.cq_arm_cqn.value) == 123


@cocotb.test()
async def access_denied_returns_error(dut):
    await reset_dut(dut)

    await send_cq_arm_doorbell(dut, consumer_index=16, access_allowed=0, access_error=1)

    assert int(dut.cq_arm_valid.value) == 1
    assert int(dut.cq_arm_error.value) == 1
    assert int(dut.cq_arm_error_code.value) == DB_ERR_ACCESS_DENIED
    assert int(dut.cq_arm_armed.value) == 0


@cocotb.test()
async def bad_payload_returns_error(dut):
    await reset_dut(dut)

    await send_cq_arm_doorbell(dut, consumer_index=16, queue_index=15)

    assert int(dut.cq_arm_valid.value) == 1
    assert int(dut.cq_arm_error.value) == 1
    assert int(dut.cq_arm_error_code.value) == DB_ERR_BAD_PAYLOAD
    assert int(dut.cq_arm_armed.value) == 0
