# SPDX-License-Identifier: MIT
"""CQ context table 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


CQ_TABLE_STATUS_OK = 0
CQ_TABLE_STATUS_MISS = 1
CQ_TABLE_STATUS_PERMISSION = 2
CQ_TABLE_STATUS_ALIAS = 3


CQ_CONTEXT_FIELDS = [
    ("valid", 1),
    ("cqn", 24),
    ("cq_buffer_base_addr", 64),
    ("cq_depth", 16),
    ("producer_index", 16),
    ("consumer_index", 16),
    ("owner_function", 16),
    ("msix_vector", 12),
    ("moderation_count", 16),
    ("moderation_timer", 16),
    ("moderation_counter", 16),
    ("moderation_timer_active", 1),
    ("armed", 1),
    ("solicited_only", 1),
    ("overflow", 1),
    ("error_state", 1),
    ("error_code", 16),
]


def pack_fields(fields, values):
    packed = 0
    for name, width in fields:
        packed = (packed << width) | (values.get(name, 0) & ((1 << width) - 1))
    return packed


def extract_field(packed, field_name):
    offset = 0
    for name, width in reversed(CQ_CONTEXT_FIELDS):
        if name == field_name:
            return (packed >> offset) & ((1 << width) - 1)
        offset += width
    raise KeyError(field_name)


def pack_cq_context(**overrides):
    values = {
        "valid": 1,
        "cqn": 7,
        "cq_buffer_base_addr": 0x3000_0000,
        "cq_depth": 128,
        "producer_index": 0,
        "consumer_index": 0,
        "owner_function": 1,
        "msix_vector": 2,
        "moderation_count": 16,
        "moderation_timer": 64,
        "moderation_counter": 0,
        "moderation_timer_active": 0,
        "armed": 0,
        "solicited_only": 0,
        "overflow": 0,
        "error_state": 0,
        "error_code": 0,
    }
    values.update(overrides)
    return pack_fields(CQ_CONTEXT_FIELDS, values)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0

    dut.lookup_valid.value = 0
    dut.lookup_cqn.value = 0
    dut.lookup_function_id.value = 0
    dut.lookup_admin_bypass.value = 0
    dut.lookup_rsp_ready.value = 0

    dut.context_write_valid.value = 0
    dut.context_write_cqn.value = 0
    dut.context_write_function_id.value = 0
    dut.context_write_admin_bypass.value = 0
    dut.context_write_use_index.value = 0
    dut.context_write_index.value = 0
    dut.context_write_data.value = 0
    dut.context_write_rsp_ready.value = 0

    dut.context_read_valid.value = 0
    dut.context_read_cqn.value = 0
    dut.context_read_function_id.value = 0
    dut.context_read_admin_bypass.value = 0
    dut.context_read_rsp_ready.value = 0

    dut.cq_arm_valid.value = 0
    dut.cq_arm_cqn.value = 0
    dut.cq_arm_function_id.value = 0
    dut.cq_arm_consumer_index.value = 0
    dut.cq_arm_armed.value = 0
    dut.cq_arm_solicited_only.value = 0
    dut.cq_arm_error.value = 0
    dut.cq_arm_rsp_ready.value = 0

    dut.completion_update_valid.value = 0
    dut.completion_update_cqn.value = 0
    dut.completion_update_owner_function.value = 0
    dut.completion_update_new_pi.value = 0
    dut.completion_update_rsp_ready.value = 0

    dut.overflow_set_valid.value = 0
    dut.overflow_set_cqn.value = 0
    dut.overflow_set_function_id.value = 0
    dut.overflow_set_rsp_ready.value = 0
    dut.overflow_clear_valid.value = 0
    dut.overflow_clear_cqn.value = 0
    dut.overflow_clear_function_id.value = 0
    dut.overflow_clear_rsp_ready.value = 0

    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def clear_response(dut, ready_name):
    getattr(dut, ready_name).value = 1
    await RisingEdge(dut.clk)
    getattr(dut, ready_name).value = 0


async def write_context(dut, cqn, owner=1, index=0, use_index=0, ctx=None):
    dut.context_write_valid.value = 1
    dut.context_write_cqn.value = cqn
    dut.context_write_function_id.value = owner
    dut.context_write_admin_bypass.value = 0
    dut.context_write_use_index.value = use_index
    dut.context_write_index.value = index
    dut.context_write_data.value = ctx if ctx is not None else pack_cq_context(cqn=cqn, owner_function=owner)
    await RisingEdge(dut.clk)
    dut.context_write_valid.value = 0
    status = int(dut.context_write_status.value)
    await clear_response(dut, "context_write_rsp_ready")
    return status


async def lookup_context(dut, cqn, function_id=1):
    dut.lookup_valid.value = 1
    dut.lookup_cqn.value = cqn
    dut.lookup_function_id.value = function_id
    dut.lookup_admin_bypass.value = 0
    await RisingEdge(dut.clk)
    dut.lookup_valid.value = 0
    result = {
        "status": int(dut.lookup_status.value),
        "hit": int(dut.lookup_hit.value),
        "miss": int(dut.lookup_miss.value),
        "context": int(dut.lookup_context.value),
    }
    await clear_response(dut, "lookup_rsp_ready")
    return result


async def read_context(dut, cqn, function_id=1):
    dut.context_read_valid.value = 1
    dut.context_read_cqn.value = cqn
    dut.context_read_function_id.value = function_id
    dut.context_read_admin_bypass.value = 0
    await RisingEdge(dut.clk)
    dut.context_read_valid.value = 0
    result = {
        "status": int(dut.context_read_status.value),
        "hit": int(dut.context_read_hit.value),
        "data": int(dut.context_read_data.value),
    }
    await clear_response(dut, "context_read_rsp_ready")
    return result


async def arm_cq(dut, cqn, function_id, consumer_index, solicited_only=0, upstream_error=0):
    dut.cq_arm_valid.value = 1
    dut.cq_arm_cqn.value = cqn
    dut.cq_arm_function_id.value = function_id
    dut.cq_arm_consumer_index.value = consumer_index
    dut.cq_arm_armed.value = 1
    dut.cq_arm_solicited_only.value = solicited_only
    dut.cq_arm_error.value = upstream_error
    await RisingEdge(dut.clk)
    dut.cq_arm_valid.value = 0
    status = int(dut.cq_arm_status.value)
    await clear_response(dut, "cq_arm_rsp_ready")
    return status


async def update_producer(dut, cqn, function_id, new_pi):
    dut.completion_update_valid.value = 1
    dut.completion_update_cqn.value = cqn
    dut.completion_update_owner_function.value = function_id
    dut.completion_update_new_pi.value = new_pi
    await RisingEdge(dut.clk)
    dut.completion_update_valid.value = 0
    status = int(dut.completion_update_status.value)
    await clear_response(dut, "completion_update_rsp_ready")
    return status


async def set_overflow(dut, cqn, function_id):
    dut.overflow_set_valid.value = 1
    dut.overflow_set_cqn.value = cqn
    dut.overflow_set_function_id.value = function_id
    await RisingEdge(dut.clk)
    dut.overflow_set_valid.value = 0
    status = int(dut.overflow_set_status.value)
    await clear_response(dut, "overflow_set_rsp_ready")
    return status


async def clear_overflow(dut, cqn, function_id):
    dut.overflow_clear_valid.value = 1
    dut.overflow_clear_cqn.value = cqn
    dut.overflow_clear_function_id.value = function_id
    await RisingEdge(dut.clk)
    dut.overflow_clear_valid.value = 0
    status = int(dut.overflow_clear_status.value)
    await clear_response(dut, "overflow_clear_rsp_ready")
    return status


@cocotb.test()
async def write_and_lookup_cq_context(dut):
    await reset_dut(dut)

    assert await write_context(dut, cqn=7, owner=1) == CQ_TABLE_STATUS_OK
    result = await lookup_context(dut, cqn=7, function_id=1)

    assert result["status"] == CQ_TABLE_STATUS_OK
    assert result["hit"] == 1
    assert result["miss"] == 0
    assert result["context"] == pack_cq_context(cqn=7, owner_function=1)


@cocotb.test()
async def lookup_miss_returns_miss_status(dut):
    await reset_dut(dut)

    result = await lookup_context(dut, cqn=99, function_id=1)

    assert result["status"] == CQ_TABLE_STATUS_MISS
    assert result["hit"] == 0
    assert result["miss"] == 1


@cocotb.test()
async def duplicate_cqn_in_different_slot_is_rejected(dut):
    await reset_dut(dut)

    assert await write_context(dut, cqn=8, owner=1, index=0, use_index=1) == CQ_TABLE_STATUS_OK
    assert await write_context(dut, cqn=8, owner=1, index=1, use_index=1) == CQ_TABLE_STATUS_ALIAS


@cocotb.test()
async def cq_arm_updates_consumer_and_arm_state(dut):
    await reset_dut(dut)

    assert await write_context(dut, cqn=9, owner=1) == CQ_TABLE_STATUS_OK
    assert await arm_cq(dut, cqn=9, function_id=1, consumer_index=44, solicited_only=1) == CQ_TABLE_STATUS_OK
    result = await read_context(dut, cqn=9, function_id=1)

    assert result["status"] == CQ_TABLE_STATUS_OK
    assert extract_field(result["data"], "consumer_index") == 44
    assert extract_field(result["data"], "armed") == 1
    assert extract_field(result["data"], "solicited_only") == 1


@cocotb.test()
async def completion_update_records_producer_index(dut):
    await reset_dut(dut)

    assert await write_context(dut, cqn=10, owner=1) == CQ_TABLE_STATUS_OK
    assert await update_producer(dut, cqn=10, function_id=1, new_pi=77) == CQ_TABLE_STATUS_OK
    result = await read_context(dut, cqn=10, function_id=1)

    assert result["status"] == CQ_TABLE_STATUS_OK
    assert extract_field(result["data"], "producer_index") == 77


@cocotb.test()
async def cross_function_access_is_denied(dut):
    await reset_dut(dut)

    assert await write_context(dut, cqn=11, owner=2) == CQ_TABLE_STATUS_OK
    result = await lookup_context(dut, cqn=11, function_id=1)

    assert result["status"] == CQ_TABLE_STATUS_PERMISSION
    assert result["hit"] == 0
    assert await arm_cq(dut, cqn=11, function_id=1, consumer_index=1) == CQ_TABLE_STATUS_PERMISSION
    assert await update_producer(dut, cqn=11, function_id=1, new_pi=2) == CQ_TABLE_STATUS_PERMISSION


@cocotb.test()
async def overflow_set_and_clear_update_context(dut):
    await reset_dut(dut)

    assert await write_context(dut, cqn=12, owner=1) == CQ_TABLE_STATUS_OK
    assert await set_overflow(dut, cqn=12, function_id=1) == CQ_TABLE_STATUS_OK
    set_result = await read_context(dut, cqn=12, function_id=1)
    assert extract_field(set_result["data"], "overflow") == 1

    assert await clear_overflow(dut, cqn=12, function_id=1) == CQ_TABLE_STATUS_OK
    clear_result = await read_context(dut, cqn=12, function_id=1)
    assert extract_field(clear_result["data"], "overflow") == 0
