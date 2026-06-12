# SPDX-License-Identifier: MIT
"""CQ notification 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


CMPL_SUCCESS = 0x00
CMPL_GENERAL_ERR = 0xFF

CQ_TABLE_STATUS_OK = 0
CQ_TABLE_STATUS_MISS = 1
CQ_TABLE_STATUS_PERMISSION = 2

CQ_NOTIFY_REASON_COMPLETION = 0
CQ_NOTIFY_REASON_SOLICITED = 1
CQ_NOTIFY_REASON_MOD_COUNT = 2
CQ_NOTIFY_REASON_MOD_TIMER = 3
CQ_NOTIFY_REASON_ERROR = 4

CQ_NOTIFY_ERR_NONE = 0
CQ_NOTIFY_ERR_CQ_MISS = 1
CQ_NOTIFY_ERR_PERMISSION = 2


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


def pack_cq_context(
    *,
    cqn=7,
    owner_function=1,
    valid=1,
    vector=2,
    armed=1,
    solicited_only=0,
    moderation_count=1,
    moderation_timer=0,
    moderation_counter=0,
):
    return pack_fields(
        CQ_CONTEXT_FIELDS,
        {
            "valid": valid,
            "cqn": cqn,
            "cq_buffer_base_addr": 0x4000_0000,
            "cq_depth": 128,
            "producer_index": 0,
            "consumer_index": 0,
            "owner_function": owner_function,
            "msix_vector": vector,
            "moderation_count": moderation_count,
            "moderation_timer": moderation_timer,
            "moderation_counter": moderation_counter,
            "armed": armed,
            "solicited_only": solicited_only,
        },
    )


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0

    dut.cqe_commit_valid.value = 0
    dut.cqe_commit_cqn.value = 0
    dut.cqe_commit_owner_function.value = 0
    dut.cqe_commit_solicited.value = 0
    dut.cqe_commit_status.value = CMPL_SUCCESS
    dut.cqe_commit_error.value = 0

    dut.cq_lookup_ready.value = 1
    dut.cq_lookup_rsp_valid.value = 0
    dut.cq_lookup_hit.value = 0
    dut.cq_lookup_miss.value = 0
    dut.cq_lookup_status.value = CQ_TABLE_STATUS_MISS
    dut.cq_lookup_context.value = 0

    dut.timer_tick.value = 0
    dut.msix_ready.value = 1

    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_commit(
    dut,
    *,
    cqn=7,
    owner=1,
    solicited=0,
    status=CMPL_SUCCESS,
    error=0,
):
    dut.cqe_commit_valid.value = 1
    dut.cqe_commit_cqn.value = cqn
    dut.cqe_commit_owner_function.value = owner
    dut.cqe_commit_solicited.value = solicited
    dut.cqe_commit_status.value = status
    dut.cqe_commit_error.value = error
    await RisingEdge(dut.clk)
    dut.cqe_commit_valid.value = 0


async def respond_lookup(
    dut,
    *,
    hit=True,
    status=CQ_TABLE_STATUS_OK,
    cqn=7,
    owner=1,
    vector=2,
    armed=1,
    solicited_only=0,
    moderation_count=1,
    moderation_timer=0,
    moderation_counter=0,
):
    for _ in range(8):
        await Timer(1, units="ns")
        if int(dut.cq_lookup_valid.value) == 1:
            break
        await RisingEdge(dut.clk)

    await RisingEdge(dut.clk)
    dut.cq_lookup_rsp_valid.value = 1
    dut.cq_lookup_hit.value = 1 if hit else 0
    dut.cq_lookup_miss.value = 0 if hit else 1
    dut.cq_lookup_status.value = status
    dut.cq_lookup_context.value = pack_cq_context(
        cqn=cqn,
        owner_function=owner,
        valid=1 if hit else 0,
        vector=vector,
        armed=armed,
        solicited_only=solicited_only,
        moderation_count=moderation_count,
        moderation_timer=moderation_timer,
        moderation_counter=moderation_counter,
    )
    await RisingEdge(dut.clk)
    dut.cq_lookup_rsp_valid.value = 0


async def wait_for_msix(dut, max_cycles=16):
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        if int(dut.msix_req_valid.value) == 1:
            return {
                "vector": int(dut.msix_req_vector.value),
                "cqn": int(dut.msix_req_cqn.value),
                "owner": int(dut.msix_req_owner_function.value),
                "reason": int(dut.msix_req_reason.value),
            }
    raise AssertionError("cq_notification did not issue MSI-X request")


async def assert_no_msix(dut, cycles=6):
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        assert int(dut.msix_req_valid.value) == 0


async def pulse_timer(dut, cycles=1):
    for _ in range(cycles):
        dut.timer_tick.value = 1
        await RisingEdge(dut.clk)
        dut.timer_tick.value = 0
        await RisingEdge(dut.clk)


@cocotb.test()
async def unarmed_cq_stays_in_polling_mode_without_msix(dut):
    await reset_dut(dut)

    await send_commit(dut, cqn=7, owner=1, solicited=1)
    await respond_lookup(dut, cqn=7, owner=1, armed=0)
    await assert_no_msix(dut)


@cocotb.test()
async def armed_cq_without_solicited_only_triggers_notification(dut):
    await reset_dut(dut)

    await send_commit(dut, cqn=8, owner=2, solicited=0)
    await respond_lookup(dut, cqn=8, owner=2, vector=3, armed=1, solicited_only=0)
    msg = await wait_for_msix(dut)

    assert msg["vector"] == 3
    assert msg["cqn"] == 8
    assert msg["owner"] == 2
    assert msg["reason"] == CQ_NOTIFY_REASON_COMPLETION


@cocotb.test()
async def solicited_only_rejects_unsolicited_completion(dut):
    await reset_dut(dut)

    await send_commit(dut, cqn=7, owner=1, solicited=0)
    await respond_lookup(dut, armed=1, solicited_only=1)
    await assert_no_msix(dut)


@cocotb.test()
async def solicited_only_accepts_solicited_completion(dut):
    await reset_dut(dut)

    await send_commit(dut, cqn=7, owner=1, solicited=1)
    await respond_lookup(dut, armed=1, solicited_only=1)
    msg = await wait_for_msix(dut)

    assert msg["reason"] == CQ_NOTIFY_REASON_SOLICITED


@cocotb.test()
async def moderation_count_threshold_triggers_notification(dut):
    await reset_dut(dut)

    await send_commit(dut, cqn=7, owner=1, solicited=0)
    await respond_lookup(dut, armed=1, moderation_count=2, moderation_counter=1)
    msg = await wait_for_msix(dut)

    assert msg["reason"] == CQ_NOTIFY_REASON_MOD_COUNT
    assert int(dut.moderation_counter_update.value) == 0


@cocotb.test()
async def moderation_timer_expiry_triggers_notification(dut):
    await reset_dut(dut)

    await send_commit(dut, cqn=9, owner=3, solicited=0)
    await respond_lookup(
        dut,
        cqn=9,
        owner=3,
        vector=4,
        armed=1,
        moderation_count=4,
        moderation_timer=2,
        moderation_counter=0,
    )
    await assert_no_msix(dut, cycles=2)
    await pulse_timer(dut, cycles=2)
    msg = await wait_for_msix(dut)

    assert msg["vector"] == 4
    assert msg["cqn"] == 9
    assert msg["owner"] == 3
    assert msg["reason"] == CQ_NOTIFY_REASON_MOD_TIMER


@cocotb.test()
async def error_completion_bypasses_moderation(dut):
    await reset_dut(dut)

    await send_commit(dut, cqn=7, owner=1, status=CMPL_GENERAL_ERR, error=1)
    await respond_lookup(dut, armed=1, moderation_count=16, moderation_timer=32)
    msg = await wait_for_msix(dut)

    assert msg["reason"] == CQ_NOTIFY_REASON_ERROR


@cocotb.test()
async def notification_clears_armed_flag_update(dut):
    await reset_dut(dut)

    await send_commit(dut, cqn=7, owner=1, solicited=1)
    await respond_lookup(dut, armed=1, solicited_only=1)
    _ = await wait_for_msix(dut)

    for _ in range(8):
        await RisingEdge(dut.clk)
        if int(dut.cq_context_update_valid.value) == 1:
            assert int(dut.armed_clear_update.value) == 1
            assert int(dut.cq_context_update_cqn.value) == 7
            return
    raise AssertionError("cq_notification did not request armed clear update")


@cocotb.test()
async def msix_backpressure_holds_request_until_ready(dut):
    await reset_dut(dut)
    dut.msix_ready.value = 0

    await send_commit(dut, cqn=7, owner=1, solicited=1)
    await respond_lookup(dut, armed=1, solicited_only=1)
    msg = await wait_for_msix(dut)

    assert msg["reason"] == CQ_NOTIFY_REASON_SOLICITED
    for _ in range(3):
        await RisingEdge(dut.clk)
        assert int(dut.msix_req_valid.value) == 1

    dut.msix_ready.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    assert int(dut.msix_req_valid.value) == 0


@cocotb.test()
async def lookup_miss_reports_notification_error(dut):
    await reset_dut(dut)

    await send_commit(dut, cqn=42, owner=1, solicited=1)
    await respond_lookup(dut, hit=False, status=CQ_TABLE_STATUS_MISS)

    for _ in range(6):
        await RisingEdge(dut.clk)
        if int(dut.notification_error_code.value) == CQ_NOTIFY_ERR_CQ_MISS:
            return
    raise AssertionError("cq_notification did not report lookup miss")


@cocotb.test()
async def owner_mismatch_reports_permission_error(dut):
    await reset_dut(dut)

    await send_commit(dut, cqn=7, owner=1, solicited=1)
    await respond_lookup(dut, cqn=7, owner=2, status=CQ_TABLE_STATUS_OK)

    for _ in range(6):
        await RisingEdge(dut.clk)
        if int(dut.notification_error_code.value) == CQ_NOTIFY_ERR_PERMISSION:
            return
    raise AssertionError("cq_notification did not report permission error")
