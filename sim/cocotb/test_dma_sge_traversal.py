# SPDX-License-Identifier: MIT
"""DMA SGE traversal 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


MR_OP_LOCAL_DMA_READ = 0

SGE_TRAV_ERR_ZERO_LENGTH = 1
SGE_TRAV_ERR_LENGTH_UNDERRUN = 2
SGE_TRAV_ERR_LENGTH_OVERRUN = 3
SGE_TRAV_ERR_TOTAL_OVERFLOW = 4
SGE_TRAV_ERR_ADDR_OVERFLOW = 5
SGE_TRAV_ERR_OVERLAP = 6
SGE_TRAV_ERR_INDEX_ORDER = 7
SGE_TRAV_ERR_INDEX_RANGE = 8


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0

    dut.sge_stream_valid.value = 0
    dut.sge_stream_desc_id.value = 0
    dut.sge_stream_qpn.value = 0
    dut.sge_stream_owner_function.value = 0
    dut.sge_stream_pd_id.value = 0
    dut.sge_stream_operation.value = MR_OP_LOCAL_DMA_READ
    dut.sge_stream_index.value = 0
    dut.sge_stream_addr.value = 0
    dut.sge_stream_length.value = 0
    dut.sge_stream_lkey.value = 0
    dut.sge_stream_flags.value = 0
    dut.sge_stream_last.value = 0
    dut.expected_total_len.value = 0
    dut.inline_data_present.value = 0
    dut.inline_data_len.value = 0

    dut.dma_segment_ready.value = 1
    dut.traversal_error_ready.value = 1
    dut.traversal_done_ready.value = 1

    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_sge(
    dut,
    *,
    index=0,
    addr=0x1000_0000,
    length=128,
    expected_total=128,
    last=1,
    desc_id=0x11,
):
    dut.sge_stream_valid.value = 1
    dut.sge_stream_desc_id.value = desc_id
    dut.sge_stream_qpn.value = 0x22
    dut.sge_stream_owner_function.value = 1
    dut.sge_stream_pd_id.value = 3
    dut.sge_stream_operation.value = MR_OP_LOCAL_DMA_READ
    dut.sge_stream_index.value = index
    dut.sge_stream_addr.value = addr
    dut.sge_stream_length.value = length
    dut.sge_stream_lkey.value = 0x1001
    dut.sge_stream_flags.value = 0x1
    dut.sge_stream_last.value = last
    dut.expected_total_len.value = expected_total
    await Timer(1, units="ns")
    assert int(dut.sge_stream_ready.value) == 1
    await RisingEdge(dut.clk)
    dut.sge_stream_valid.value = 0


async def wait_segment(dut, timeout=32):
    for _ in range(timeout):
        await Timer(1, units="ns")
        if int(dut.dma_segment_valid.value) == 1:
            segment = {
                "desc_id": int(dut.dma_segment_desc_id.value),
                "qpn": int(dut.dma_segment_qpn.value),
                "index": int(dut.dma_segment_index.value),
                "va": int(dut.dma_segment_va.value),
                "len": int(dut.dma_segment_len.value),
                "lkey": int(dut.dma_segment_lkey.value),
                "byte_offset": int(dut.dma_segment_byte_offset.value),
                "is_last": int(dut.dma_segment_is_last.value),
            }
            await RisingEdge(dut.clk)
            return segment
        await RisingEdge(dut.clk)
    raise AssertionError("dma_segment_valid was not asserted")


async def wait_error(dut, timeout=32):
    for _ in range(timeout):
        await Timer(1, units="ns")
        if int(dut.traversal_error_valid.value) == 1:
            code = int(dut.traversal_error_code.value)
            await RisingEdge(dut.clk)
            return code
        await RisingEdge(dut.clk)
    raise AssertionError("traversal_error_valid was not asserted")


async def wait_done(dut, timeout=32):
    for _ in range(timeout):
        await Timer(1, units="ns")
        if int(dut.traversal_done_valid.value) == 1:
            await RisingEdge(dut.clk)
            return
        await RisingEdge(dut.clk)
    raise AssertionError("traversal_done_valid was not asserted")


async def send_and_collect(dut, **kwargs):
    await send_sge(dut, **kwargs)
    segment = await wait_segment(dut)
    if kwargs.get("last", 1):
        await wait_done(dut)
    return segment


@cocotb.test()
async def test_single_sge_total_len_match(dut):
    await reset_dut(dut)
    segment = await send_and_collect(dut, length=256, expected_total=256)
    assert segment["index"] == 0
    assert segment["len"] == 256
    assert segment["byte_offset"] == 0
    assert segment["is_last"] == 1


@cocotb.test()
async def test_multi_sge_total_len_match(dut):
    await reset_dut(dut)
    await send_sge(dut, index=0, addr=0x1000, length=64, expected_total=192, last=0)
    first = await wait_segment(dut)
    await send_sge(dut, index=1, addr=0x2000, length=128, expected_total=192, last=1)
    second = await wait_segment(dut)
    await wait_done(dut)
    assert first["byte_offset"] == 0
    assert second["byte_offset"] == 64
    assert second["is_last"] == 1


@cocotb.test()
async def test_256_sges_success(dut):
    await reset_dut(dut)
    for index in range(256):
        await send_sge(
            dut,
            index=index,
            addr=0x1000_0000 + index * 0x1000,
            length=1,
            expected_total=256,
            last=(index == 255),
        )
        segment = await wait_segment(dut)
        assert segment["index"] == index
        assert segment["byte_offset"] == index
    await wait_done(dut)


@cocotb.test()
async def test_zero_length_sge_rejected(dut):
    await reset_dut(dut)
    await send_sge(dut, length=0, expected_total=128)
    assert await wait_error(dut) == SGE_TRAV_ERR_ZERO_LENGTH


@cocotb.test()
async def test_total_length_underrun(dut):
    await reset_dut(dut)
    await send_sge(dut, length=64, expected_total=128, last=1)
    await wait_segment(dut)
    assert await wait_error(dut) == SGE_TRAV_ERR_LENGTH_UNDERRUN


@cocotb.test()
async def test_total_length_overrun(dut):
    await reset_dut(dut)
    await send_sge(dut, length=192, expected_total=128, last=1)
    assert await wait_error(dut) == SGE_TRAV_ERR_LENGTH_OVERRUN


@cocotb.test()
async def test_adjacent_ranges_do_not_overlap(dut):
    await reset_dut(dut)
    await send_sge(dut, index=0, addr=0x1000, length=0x1000, expected_total=0x2000, last=0)
    await wait_segment(dut)
    await send_sge(dut, index=1, addr=0x2000, length=0x1000, expected_total=0x2000, last=1)
    segment = await wait_segment(dut)
    await wait_done(dut)
    assert segment["va"] == 0x2000


@cocotb.test()
async def test_overlapping_ranges_rejected(dut):
    await reset_dut(dut)
    await send_sge(dut, index=0, addr=0x1000, length=0x1000, expected_total=0x2000, last=0)
    await wait_segment(dut)
    await send_sge(dut, index=1, addr=0x1800, length=0x1000, expected_total=0x2000, last=1)
    assert await wait_error(dut) == SGE_TRAV_ERR_OVERLAP


@cocotb.test()
async def test_address_plus_length_overflow_rejected(dut):
    await reset_dut(dut)
    await send_sge(dut, addr=(1 << 64) - 16, length=32, expected_total=32)
    assert await wait_error(dut) == SGE_TRAV_ERR_ADDR_OVERFLOW


@cocotb.test()
async def test_sge_index_must_be_monotonic(dut):
    await reset_dut(dut)
    await send_sge(dut, index=0, addr=0x1000, length=64, expected_total=128, last=0)
    await wait_segment(dut)
    await send_sge(dut, index=0, addr=0x2000, length=64, expected_total=128, last=1)
    assert await wait_error(dut) == SGE_TRAV_ERR_INDEX_ORDER


@cocotb.test()
async def test_sge_index_over_255_rejected(dut):
    await reset_dut(dut)
    await send_sge(dut, index=256, addr=0x1000, length=64, expected_total=64, last=1)
    assert await wait_error(dut) == SGE_TRAV_ERR_INDEX_RANGE


@cocotb.test()
async def test_segment_backpressure_holds_current_sge(dut):
    await reset_dut(dut)
    dut.dma_segment_ready.value = 0
    await send_sge(dut, addr=0x1000, length=64, expected_total=64, last=1)
    for _ in range(4):
        await Timer(1, units="ns")
        if int(dut.dma_segment_valid.value) == 1:
            assert int(dut.dma_segment_va.value) == 0x1000
            break
        await RisingEdge(dut.clk)
    else:
        raise AssertionError("dma_segment_valid was not held under backpressure")
    dut.dma_segment_ready.value = 1
    segment = await wait_segment(dut)
    await wait_done(dut)
    assert segment["va"] == 0x1000


@cocotb.test()
async def test_byte_offset_outputs_accumulated_length(dut):
    await reset_dut(dut)
    expected_offsets = [0, 8, 24]
    lengths = [8, 16, 32]
    for index, length in enumerate(lengths):
        await send_sge(
            dut,
            index=index,
            addr=0x1000 + index * 0x100,
            length=length,
            expected_total=sum(lengths),
            last=(index == len(lengths) - 1),
        )
        segment = await wait_segment(dut)
        assert segment["byte_offset"] == expected_offsets[index]
    await wait_done(dut)


@cocotb.test()
async def test_total_length_overflow_rejected(dut):
    await reset_dut(dut)
    await send_sge(dut, index=0, addr=0x1000, length=0xFFFF_FFFF, expected_total=0xFFFF_FFFF, last=0)
    await wait_segment(dut)
    await send_sge(dut, index=1, addr=0x1_0000_0000, length=1, expected_total=0xFFFF_FFFF, last=1)
    assert await wait_error(dut) == SGE_TRAV_ERR_TOTAL_OVERFLOW
