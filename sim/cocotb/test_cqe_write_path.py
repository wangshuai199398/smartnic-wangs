# SPDX-License-Identifier: MIT
"""CQE write path 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


CMPL_SUCCESS = 0x00
CMPL_GENERAL_ERR = 0xFF

CQ_TABLE_STATUS_OK = 0
CQ_TABLE_STATUS_MISS = 1
CQ_TABLE_STATUS_PERMISSION = 2

CQE_WR_ERR_NONE = 0
CQE_WR_ERR_CQ_MISS = 1
CQE_WR_ERR_PERMISSION = 2
CQE_WR_ERR_OVERFLOW = 6

CQE_BYTES = 64
CQE_W = 512


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
    base=0x4000_0000,
    depth=128,
    producer_index=3,
    consumer_index=0,
    valid=1,
    overflow=0,
):
    return pack_fields(
        CQ_CONTEXT_FIELDS,
        {
            "valid": valid,
            "cqn": cqn,
            "cq_buffer_base_addr": base,
            "cq_depth": depth,
            "producer_index": producer_index,
            "consumer_index": consumer_index,
            "owner_function": owner_function,
            "msix_vector": 2,
            "overflow": overflow,
        },
    )


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0

    dut.cqe_write_valid.value = 0
    dut.cqe_write_cqn.value = 0
    dut.cqe_write_owner_function.value = 0
    dut.cqe_write_data.value = 0
    dut.cqe_write_solicited.value = 0
    dut.cqe_write_status.value = CMPL_SUCCESS
    dut.cqe_write_error.value = 0

    dut.cq_lookup_ready.value = 1
    dut.cq_lookup_rsp_valid.value = 0
    dut.cq_lookup_hit.value = 0
    dut.cq_lookup_miss.value = 0
    dut.cq_lookup_status.value = CQ_TABLE_STATUS_MISS
    dut.cq_lookup_context.value = 0

    dut.dma_write_ready.value = 1

    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_cqe(dut, *, cqn=7, owner=1, data=0xA5, solicited=1, status=CMPL_SUCCESS, error=0):
    dut.cqe_write_valid.value = 1
    dut.cqe_write_cqn.value = cqn
    dut.cqe_write_owner_function.value = owner
    dut.cqe_write_data.value = data
    dut.cqe_write_solicited.value = solicited
    dut.cqe_write_status.value = status
    dut.cqe_write_error.value = error
    await RisingEdge(dut.clk)
    dut.cqe_write_valid.value = 0


async def respond_lookup(
    dut,
    *,
    hit=True,
    status=CQ_TABLE_STATUS_OK,
    cqn=7,
    owner=1,
    base=0x4000_0000,
    depth=128,
    pi=3,
    consumer=0,
    overflow=0,
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
        base=base,
        depth=depth,
        producer_index=pi,
        consumer_index=consumer,
        valid=1 if hit else 0,
        overflow=overflow,
    )
    await RisingEdge(dut.clk)
    dut.cq_lookup_rsp_valid.value = 0


async def wait_for_dma_write(dut, max_cycles=16):
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        if int(dut.dma_write_valid.value) == 1:
            return {
                "addr": int(dut.dma_write_addr.value),
                "data": int(dut.dma_write_data.value),
                "len": int(dut.dma_write_len.value),
                "be": int(dut.dma_write_byte_enable.value),
                "owner": int(dut.dma_write_owner_function.value),
                "tag": int(dut.dma_write_tag.value),
                "error": int(dut.dma_write_error.value),
            }
    raise AssertionError("cqe_write_path did not issue dma_write_valid")


async def wait_for_pi_update(dut, max_cycles=8):
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        if int(dut.cq_pi_update_valid.value) == 1:
            return {
                "cqn": int(dut.cq_pi_update_cqn.value),
                "new_pi": int(dut.cq_pi_update_new_producer_index.value),
                "owner": int(dut.cq_pi_update_owner_function.value),
                "solicited": int(dut.cqe_written_solicited.value),
                "status": int(dut.cqe_written_status.value),
            }
    raise AssertionError("cqe_write_path did not issue cq_pi_update_valid")


@cocotb.test()
async def calculates_cqe_address_from_base_and_producer_index(dut):
    await reset_dut(dut)

    await send_cqe(dut, cqn=7, owner=1, data=0x1234)
    await respond_lookup(dut, cqn=7, owner=1, base=0x4000_0000, depth=128, pi=3)
    write = await wait_for_dma_write(dut)

    assert write["addr"] == 0x4000_0000 + 3 * CQE_BYTES
    assert write["data"] == 0x1234
    assert write["len"] == CQE_BYTES
    assert write["be"] == (1 << CQE_BYTES) - 1
    assert write["owner"] == 1
    assert write["tag"] == 3


@cocotb.test()
async def successful_write_generates_producer_index_update(dut):
    await reset_dut(dut)

    await send_cqe(dut, cqn=8, owner=2, solicited=1, status=CMPL_SUCCESS)
    await respond_lookup(dut, cqn=8, owner=2, base=0x5000_0000, depth=16, pi=5)
    _ = await wait_for_dma_write(dut)
    pi = await wait_for_pi_update(dut)

    assert pi["cqn"] == 8
    assert pi["new_pi"] == 6
    assert pi["owner"] == 2
    assert pi["solicited"] == 1
    assert pi["status"] == CMPL_SUCCESS


@cocotb.test()
async def lookup_miss_returns_error_without_dma_write(dut):
    await reset_dut(dut)

    await send_cqe(dut, cqn=99, owner=1)
    await respond_lookup(dut, hit=False, status=CQ_TABLE_STATUS_MISS, cqn=99, owner=1)

    for _ in range(5):
        await RisingEdge(dut.clk)
        assert int(dut.dma_write_valid.value) == 0
    assert int(dut.error_code.value) == CQE_WR_ERR_CQ_MISS


@cocotb.test()
async def owner_function_mismatch_returns_permission_error(dut):
    await reset_dut(dut)

    await send_cqe(dut, cqn=7, owner=2)
    await respond_lookup(dut, hit=True, status=CQ_TABLE_STATUS_PERMISSION, cqn=7, owner=1)

    for _ in range(5):
        await RisingEdge(dut.clk)
        assert int(dut.dma_write_valid.value) == 0
    assert int(dut.error_code.value) == CQE_WR_ERR_PERMISSION


@cocotb.test()
async def dma_backpressure_holds_cqe_write_request(dut):
    await reset_dut(dut)
    dut.dma_write_ready.value = 0

    await send_cqe(dut, cqn=7, owner=1, data=0x55AA)
    await respond_lookup(dut, cqn=7, owner=1, base=0x6000_0000, depth=32, pi=2)
    write = await wait_for_dma_write(dut)

    for _ in range(3):
        await RisingEdge(dut.clk)
        assert int(dut.dma_write_valid.value) == 1
        assert int(dut.dma_write_addr.value) == write["addr"]
        assert int(dut.dma_write_data.value) == write["data"]

    dut.dma_write_ready.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def producer_index_wraps_to_zero_at_depth_minus_one(dut):
    await reset_dut(dut)

    await send_cqe(dut, cqn=10, owner=1)
    await respond_lookup(dut, cqn=10, owner=1, base=0x7000_0000, depth=4, pi=3)
    _ = await wait_for_dma_write(dut)
    pi = await wait_for_pi_update(dut)

    assert pi["new_pi"] == 0


@cocotb.test()
async def full_cq_sets_overflow_and_blocks_dma_write(dut):
    await reset_dut(dut)

    await send_cqe(dut, cqn=11, owner=1)
    # consumer == producer + 1 means full in reserved-one-entry mode.
    await respond_lookup(dut, cqn=11, owner=1, base=0x8000_0000, depth=8, pi=2, consumer=3)

    saw_overflow_set = False
    for _ in range(5):
        await RisingEdge(dut.clk)
        assert int(dut.dma_write_valid.value) == 0
        saw_overflow_set = saw_overflow_set or int(dut.cq_overflow_set_valid.value) == 1

    assert int(dut.error_code.value) == CQE_WR_ERR_OVERFLOW
    assert saw_overflow_set
    assert int(dut.cq_overflow_set_cqn.value) == 11
