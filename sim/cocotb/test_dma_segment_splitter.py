# SPDX-License-Identifier: MIT
"""DMA segment splitter 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


MR_OP_LOCAL_DMA_READ = 0

DMA_SPLIT_ERR_NONE = 0
DMA_SPLIT_ERR_ZERO_LENGTH = 1
DMA_SPLIT_ERR_PMTU_CONFIG = 2


MR_REF_TOKEN_FIELDS = [
    ("key", 32),
    ("is_remote", 1),
    ("owner_function", 16),
    ("mr_id", 24),
]


def pack_fields(fields, values):
    packed = 0
    for name, width in fields:
        packed = (packed << width) | (values.get(name, 0) & ((1 << width) - 1))
    return packed


def pack_ref_token(**overrides):
    values = {
        "key": 0x3003,
        "is_remote": 0,
        "owner_function": 1,
        "mr_id": 0x66,
    }
    values.update(overrides)
    return pack_fields(MR_REF_TOKEN_FIELDS, values)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0

    dut.pmtu_bytes.value = 1024
    dut.enable_pmtu_split.value = 1
    dut.enable_4kb_boundary_split.value = 1
    dut.max_dma_segment_bytes.value = 4096

    dut.protected_segment_valid.value = 0
    dut.protected_segment_desc_id.value = 0
    dut.protected_segment_qpn.value = 0
    dut.protected_segment_owner_function.value = 0
    dut.protected_segment_pd_id.value = 0
    dut.protected_segment_operation.value = MR_OP_LOCAL_DMA_READ
    dut.protected_segment_index.value = 0
    dut.protected_segment_va.value = 0
    dut.protected_segment_pa.value = 0
    dut.protected_segment_len.value = 0
    dut.protected_segment_byte_offset.value = 0
    dut.protected_segment_is_last.value = 0
    dut.protected_segment_mr_refcount_token.value = 0
    dut.protected_segment_flags.value = 0

    dut.split_segment_ready.value = 1

    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_segment(
    dut,
    *,
    va=0x1000_0000,
    pa=0x8000_0000,
    length=512,
    byte_offset=64,
    is_last=1,
    index=3,
):
    dut.protected_segment_valid.value = 1
    dut.protected_segment_desc_id.value = 0x11
    dut.protected_segment_qpn.value = 0x22
    dut.protected_segment_owner_function.value = 1
    dut.protected_segment_pd_id.value = 3
    dut.protected_segment_operation.value = MR_OP_LOCAL_DMA_READ
    dut.protected_segment_index.value = index
    dut.protected_segment_va.value = va
    dut.protected_segment_pa.value = pa
    dut.protected_segment_len.value = length
    dut.protected_segment_byte_offset.value = byte_offset
    dut.protected_segment_is_last.value = is_last
    dut.protected_segment_mr_refcount_token.value = pack_ref_token()
    dut.protected_segment_flags.value = 0x5
    await Timer(1, units="ns")
    assert int(dut.protected_segment_ready.value) == 1
    await RisingEdge(dut.clk)
    dut.protected_segment_valid.value = 0


async def collect_splits(dut, expected_count, timeout=128):
    splits = []
    for _ in range(timeout):
        await Timer(1, units="ns")
        if int(dut.split_segment_valid.value) == 1:
            splits.append(
                {
                    "desc_id": int(dut.split_segment_desc_id.value),
                    "qpn": int(dut.split_segment_qpn.value),
                    "owner": int(dut.split_segment_owner_function.value),
                    "index": int(dut.split_segment_index.value),
                    "sub_index": int(dut.split_segment_sub_index.value),
                    "va": int(dut.split_segment_va.value),
                    "pa": int(dut.split_segment_pa.value),
                    "len": int(dut.split_segment_len.value),
                    "byte_offset": int(dut.split_segment_byte_offset.value),
                    "segment_last": int(dut.split_segment_is_segment_last.value),
                    "wqe_last": int(dut.split_segment_is_wqe_last.value),
                    "flags": int(dut.split_segment_flags.value),
                    "error": int(dut.split_segment_error_code.value),
                }
            )
            await RisingEdge(dut.clk)
            if len(splits) == expected_count:
                return splits
        else:
            await RisingEdge(dut.clk)
    raise AssertionError(f"expected {expected_count} split segments, got {len(splits)}")


@cocotb.test()
async def test_segment_smaller_than_pmtu_and_not_crossing_page_is_not_split(dut):
    await reset_dut(dut)
    dut.pmtu_bytes.value = 1024
    await send_segment(dut, pa=0x8000_0000, length=512)
    splits = await collect_splits(dut, 1)
    assert splits[0]["len"] == 512
    assert splits[0]["sub_index"] == 0
    assert splits[0]["segment_last"] == 1
    assert splits[0]["wqe_last"] == 1
    assert splits[0]["error"] == DMA_SPLIT_ERR_NONE


@cocotb.test()
async def test_segment_larger_than_pmtu_is_split_by_pmtu(dut):
    await reset_dut(dut)
    dut.pmtu_bytes.value = 1024
    await send_segment(dut, pa=0x8000_0000, length=2500, byte_offset=32)
    splits = await collect_splits(dut, 3)
    assert [s["len"] for s in splits] == [1024, 1024, 452]
    assert [s["byte_offset"] for s in splits] == [32, 1056, 2080]
    assert [s["sub_index"] for s in splits] == [0, 1, 2]
    assert [s["segment_last"] for s in splits] == [0, 0, 1]


@cocotb.test()
async def test_pa_near_4kb_boundary_splits_by_page_remaining(dut):
    await reset_dut(dut)
    dut.pmtu_bytes.value = 4096
    await send_segment(dut, pa=0x8000_0F00, length=512)
    splits = await collect_splits(dut, 2)
    assert [s["pa"] for s in splits] == [0x8000_0F00, 0x8000_1000]
    assert [s["len"] for s in splits] == [256, 256]


@cocotb.test()
async def test_pmtu_and_4kb_boundary_take_minimum(dut):
    await reset_dut(dut)
    dut.pmtu_bytes.value = 512
    await send_segment(dut, pa=0x8000_0E00, length=1200)
    splits = await collect_splits(dut, 3)
    assert [s["len"] for s in splits] == [512, 512, 176]
    assert [s["pa"] for s in splits] == [0x8000_0E00, 0x8000_1000, 0x8000_1200]


@cocotb.test()
async def test_max_dma_segment_bytes_limit_applies(dut):
    await reset_dut(dut)
    dut.pmtu_bytes.value = 4096
    dut.max_dma_segment_bytes.value = 300
    await send_segment(dut, pa=0x8000_0000, length=700)
    splits = await collect_splits(dut, 3)
    assert [s["len"] for s in splits] == [300, 300, 100]


@cocotb.test()
async def test_4kb_aligned_pa_has_4096_page_remaining(dut):
    await reset_dut(dut)
    dut.pmtu_bytes.value = 4096
    await send_segment(dut, pa=0x8000_1000, length=4096)
    splits = await collect_splits(dut, 1)
    assert splits[0]["len"] == 4096
    assert splits[0]["pa"] == 0x8000_1000


@cocotb.test()
async def test_wqe_last_only_on_final_split_when_input_is_last(dut):
    await reset_dut(dut)
    dut.pmtu_bytes.value = 512
    await send_segment(dut, length=1200, is_last=1)
    splits = await collect_splits(dut, 3)
    assert [s["wqe_last"] for s in splits] == [0, 0, 1]


@cocotb.test()
async def test_wqe_last_not_set_when_input_is_not_last(dut):
    await reset_dut(dut)
    dut.pmtu_bytes.value = 512
    await send_segment(dut, length=1200, is_last=0)
    splits = await collect_splits(dut, 3)
    assert [s["segment_last"] for s in splits] == [0, 0, 1]
    assert [s["wqe_last"] for s in splits] == [0, 0, 0]


@cocotb.test()
async def test_zero_length_rejected(dut):
    await reset_dut(dut)
    await send_segment(dut, length=0)
    splits = await collect_splits(dut, 1)
    assert splits[0]["error"] == DMA_SPLIT_ERR_ZERO_LENGTH


@cocotb.test()
async def test_illegal_pmtu_rejected(dut):
    await reset_dut(dut)
    dut.pmtu_bytes.value = 1536
    await send_segment(dut, length=512)
    splits = await collect_splits(dut, 1)
    assert splits[0]["error"] == DMA_SPLIT_ERR_PMTU_CONFIG


@cocotb.test()
async def test_split_ready_backpressure_holds_current_split(dut):
    await reset_dut(dut)
    dut.split_segment_ready.value = 0
    dut.pmtu_bytes.value = 512
    await send_segment(dut, length=1200)
    for _ in range(12):
        await Timer(1, units="ns")
        if int(dut.split_segment_valid.value) == 1:
            assert int(dut.split_segment_len.value) == 512
            assert int(dut.split_segment_sub_index.value) == 0
            break
        await RisingEdge(dut.clk)
    else:
        raise AssertionError("split_segment_valid was not held under backpressure")

    dut.split_segment_ready.value = 1
    splits = await collect_splits(dut, 3)
    assert [s["len"] for s in splits] == [512, 512, 176]
