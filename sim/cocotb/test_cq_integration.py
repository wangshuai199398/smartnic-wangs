# SPDX-License-Identifier: MIT
"""CQ completion path 最小集成测试。

本测试使用 mock/stub 模型串起 5.1-5.5 已实现模块的接口语义：
completion event -> 64-byte CQE -> host CQ address -> producer index ->
notification/MSI-X request。它不建模真实 DMA Engine、PCIe TLP 或 RoCEv2。
"""

from dataclasses import dataclass
from typing import Optional

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


CQE_BYTES = 64
CMPL_SUCCESS = 0x00
RDMA_OP_SEND = 0x00
CQ_NOTIFY_REASON_COMPLETION = 0
CQ_NOTIFY_REASON_MOD_COUNT = 2


@dataclass
class CqContext:
    cqn: int = 7
    owner_function: int = 1
    cq_buffer_base_addr: int = 0x4000_0000
    cq_depth: int = 8
    producer_index: int = 0
    consumer_index: int = 0
    msix_vector: int = 2
    armed: bool = True
    solicited_only: bool = False
    moderation_count: int = 1
    moderation_counter: int = 0
    overflow: bool = False


@dataclass
class CompletionEvent:
    qpn: int = 0x22
    cqn: int = 7
    owner_function: int = 1
    wr_id: int = 0xCAFE
    opcode: int = RDMA_OP_SEND
    status: int = CMPL_SUCCESS
    byte_len: int = 128
    solicited: bool = False


def format_64b_cqe(event: CompletionEvent) -> dict:
    return {
        "bytes": CQE_BYTES,
        "wr_id": event.wr_id,
        "qpn": event.qpn,
        "cqn": event.cqn,
        "owner_function": event.owner_function,
        "opcode": event.opcode,
        "status": event.status,
        "byte_len": event.byte_len,
        "solicited": event.solicited,
        "valid": True,
    }


def write_cqe_and_update_producer(ctx: CqContext, cqe: dict) -> dict:
    assert cqe["bytes"] == CQE_BYTES
    assert cqe["cqn"] == ctx.cqn
    assert cqe["owner_function"] == ctx.owner_function
    assert ctx.cq_depth > 0

    write_addr = ctx.cq_buffer_base_addr + ctx.producer_index * CQE_BYTES
    next_pi = 0 if ctx.producer_index + 1 == ctx.cq_depth else ctx.producer_index + 1
    full_after_write = next_pi == ctx.consumer_index

    if full_after_write:
        ctx.overflow = True
    else:
        ctx.producer_index = next_pi

    return {
        "dma_write_addr": write_addr,
        "dma_write_len": CQE_BYTES,
        "new_producer_index": ctx.producer_index,
        "overflow": ctx.overflow,
    }


def notify_if_needed(ctx: CqContext, event: CompletionEvent) -> Optional[dict]:
    if not ctx.armed:
        return None
    if ctx.solicited_only and not event.solicited:
        return None

    count_threshold = ctx.moderation_count
    if count_threshold <= 1:
        ctx.armed = False
        ctx.moderation_counter = 0
        return {
            "vector": ctx.msix_vector,
            "cqn": ctx.cqn,
            "owner_function": ctx.owner_function,
            "reason": CQ_NOTIFY_REASON_COMPLETION,
        }

    ctx.moderation_counter += 1
    if ctx.moderation_counter >= count_threshold:
        ctx.armed = False
        ctx.moderation_counter = 0
        return {
            "vector": ctx.msix_vector,
            "cqn": ctx.cqn,
            "owner_function": ctx.owner_function,
            "reason": CQ_NOTIFY_REASON_MOD_COUNT,
        }

    return None


async def reset_stub(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def sq_completion_reaches_cqe_write_pi_update_and_msix_request(dut):
    await reset_stub(dut)

    ctx = CqContext(producer_index=3, consumer_index=0, armed=True, moderation_count=1)
    event = CompletionEvent(cqn=ctx.cqn, owner_function=ctx.owner_function, solicited=False)

    cqe = format_64b_cqe(event)
    write = write_cqe_and_update_producer(ctx, cqe)
    msix = notify_if_needed(ctx, event)

    assert cqe["bytes"] == 64
    assert write["dma_write_addr"] == 0x4000_0000 + 3 * CQE_BYTES
    assert write["dma_write_len"] == CQE_BYTES
    assert write["new_producer_index"] == 4
    assert write["overflow"] is False
    assert msix == {
        "vector": 2,
        "cqn": 7,
        "owner_function": 1,
        "reason": CQ_NOTIFY_REASON_COMPLETION,
    }
    assert ctx.armed is False


@cocotb.test()
async def moderation_count_delays_msix_until_threshold(dut):
    await reset_stub(dut)

    ctx = CqContext(producer_index=0, consumer_index=4, armed=True, moderation_count=2)
    first = CompletionEvent(cqn=ctx.cqn, owner_function=ctx.owner_function)
    second = CompletionEvent(cqn=ctx.cqn, owner_function=ctx.owner_function)

    _ = write_cqe_and_update_producer(ctx, format_64b_cqe(first))
    assert notify_if_needed(ctx, first) is None
    assert ctx.moderation_counter == 1
    assert ctx.armed is True

    _ = write_cqe_and_update_producer(ctx, format_64b_cqe(second))
    msix = notify_if_needed(ctx, second)

    assert msix is not None
    assert msix["reason"] == CQ_NOTIFY_REASON_MOD_COUNT
    assert ctx.moderation_counter == 0
    assert ctx.armed is False


@cocotb.test()
async def full_cq_sets_overflow_before_notification_side_effects(dut):
    await reset_stub(dut)

    ctx = CqContext(producer_index=2, consumer_index=3, armed=True, moderation_count=1)
    event = CompletionEvent(cqn=ctx.cqn, owner_function=ctx.owner_function)

    write = write_cqe_and_update_producer(ctx, format_64b_cqe(event))

    assert write["overflow"] is True
    assert ctx.overflow is True
    assert ctx.producer_index == 2
