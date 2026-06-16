# SPDX-License-Identifier: MIT
"""DMA host memory read path 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


MR_OP_LOCAL_DMA_READ = 0
MR_OP_LOCAL_DMA_WRITE = 1

DMA_HR_ERR_NONE = 0
DMA_HR_ERR_UNSUPPORTED_OP = 1
DMA_HR_ERR_ZERO_LENGTH = 2
DMA_HR_ERR_RESP_ERROR = 6
DMA_HR_ERR_TAG_MISMATCH = 7


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
        "key": 0x1001,
        "is_remote": 0,
        "owner_function": 1,
        "mr_id": 0x44,
    }
    values.update(overrides)
    return pack_fields(MR_REF_TOKEN_FIELDS, values)


def make_tag(desc_id, segment_index, chunk_index=0):
    return ((desc_id & 0xFFFF) << 16) | ((segment_index & 0x1FF) << 7) | (chunk_index & 0x7F)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0

    dut.protected_segment_valid.value = 0
    dut.protected_segment_desc_id.value = 0
    dut.protected_segment_qpn.value = 0
    dut.protected_segment_owner_function.value = 0
    dut.protected_segment_pd_id.value = 0
    dut.protected_segment_operation.value = MR_OP_LOCAL_DMA_READ
    dut.protected_segment_index.value = 0
    dut.protected_segment_pa.value = 0
    dut.protected_segment_len.value = 0
    dut.protected_segment_byte_offset.value = 0
    dut.protected_segment_is_last.value = 0
    dut.protected_segment_mr_refcount_token.value = 0
    dut.protected_segment_flags.value = 0

    dut.pcie_read_req_ready.value = 1
    dut.pcie_read_resp_valid.value = 0
    dut.pcie_read_resp_tag.value = 0
    dut.pcie_read_resp_data.value = 0
    dut.pcie_read_resp_len.value = 0
    dut.pcie_read_resp_error.value = 0
    dut.pcie_read_resp_last.value = 1

    dut.payload_ready.value = 1
    dut.mr_ref_dec_ready.value = 1
    dut.host_read_error_ready.value = 1

    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_protected_segment(
    dut,
    *,
    operation=MR_OP_LOCAL_DMA_READ,
    pa=0x8000_0100,
    length=32,
    byte_offset=64,
    segment_index=3,
    is_last=1,
):
    dut.protected_segment_valid.value = 1
    dut.protected_segment_desc_id.value = 0x11
    dut.protected_segment_qpn.value = 0x22
    dut.protected_segment_owner_function.value = 1
    dut.protected_segment_pd_id.value = 3
    dut.protected_segment_operation.value = operation
    dut.protected_segment_index.value = segment_index
    dut.protected_segment_pa.value = pa
    dut.protected_segment_len.value = length
    dut.protected_segment_byte_offset.value = byte_offset
    dut.protected_segment_is_last.value = is_last
    dut.protected_segment_mr_refcount_token.value = pack_ref_token()
    dut.protected_segment_flags.value = 0x1
    await Timer(1, units="ns")
    assert int(dut.protected_segment_ready.value) == 1
    await RisingEdge(dut.clk)
    dut.protected_segment_valid.value = 0


async def wait_read_req(dut, timeout=32):
    for _ in range(timeout):
        await Timer(1, units="ns")
        if int(dut.pcie_read_req_valid.value) == 1:
            req = {
                "addr": int(dut.pcie_read_req_addr.value),
                "len": int(dut.pcie_read_req_len.value),
                "tag": int(dut.pcie_read_req_tag.value),
                "desc_id": int(dut.pcie_read_req_desc_id.value),
                "qpn": int(dut.pcie_read_req_qpn.value),
                "segment_index": int(dut.pcie_read_req_segment_index.value),
            }
            await RisingEdge(dut.clk)
            return req
        await RisingEdge(dut.clk)
    raise AssertionError("pcie_read_req_valid was not asserted")


async def send_read_resp(dut, *, tag, data=0xA5A5, length=32, error=0, last=1):
    dut.pcie_read_resp_valid.value = 1
    dut.pcie_read_resp_tag.value = tag
    dut.pcie_read_resp_data.value = data
    dut.pcie_read_resp_len.value = length
    dut.pcie_read_resp_error.value = error
    dut.pcie_read_resp_last.value = last
    await Timer(1, units="ns")
    assert int(dut.pcie_read_resp_ready.value) == 1
    await RisingEdge(dut.clk)
    dut.pcie_read_resp_valid.value = 0


async def wait_payload(dut, timeout=32):
    for _ in range(timeout):
        await Timer(1, units="ns")
        if int(dut.payload_valid.value) == 1:
            payload = {
                "desc_id": int(dut.payload_desc_id.value),
                "qpn": int(dut.payload_qpn.value),
                "len": int(dut.payload_len.value),
                "byte_offset": int(dut.payload_byte_offset.value),
                "segment_index": int(dut.payload_segment_index.value),
                "segment_last": int(dut.payload_segment_last.value),
                "wqe_last": int(dut.payload_wqe_last.value),
                "error": int(dut.payload_error_code.value),
            }
            await RisingEdge(dut.clk)
            return payload
        await RisingEdge(dut.clk)
    raise AssertionError("payload_valid was not asserted")


async def wait_ref_dec(dut, timeout=32):
    for _ in range(timeout):
        await Timer(1, units="ns")
        if int(dut.mr_ref_dec_valid.value) == 1:
            result = {
                "desc_id": int(dut.mr_ref_dec_desc_id.value),
                "segment_index": int(dut.mr_ref_dec_segment_index.value),
                "token": int(dut.mr_ref_dec_token.value),
            }
            await RisingEdge(dut.clk)
            return result
        await RisingEdge(dut.clk)
    raise AssertionError("mr_ref_dec_valid was not asserted")


async def wait_error(dut, timeout=32):
    for _ in range(timeout):
        await Timer(1, units="ns")
        if int(dut.host_read_error_valid.value) == 1:
            code = int(dut.host_read_error_code.value)
            await RisingEdge(dut.clk)
            return code
        await RisingEdge(dut.clk)
    raise AssertionError("host_read_error_valid was not asserted")


@cocotb.test()
async def test_send_protected_segment_issues_pcie_read(dut):
    await reset_dut(dut)
    await send_protected_segment(dut, length=32)
    req = await wait_read_req(dut)
    assert req["addr"] == 0x8000_0100
    assert req["len"] == 32
    assert req["tag"] == make_tag(0x11, 3, 0)


@cocotb.test()
async def test_rdma_write_payload_read_issues_pcie_read(dut):
    await reset_dut(dut)
    await send_protected_segment(dut, operation=MR_OP_LOCAL_DMA_READ, length=16)
    req = await wait_read_req(dut)
    assert req["addr"] == 0x8000_0100
    assert req["len"] == 16


@cocotb.test()
async def test_read_response_becomes_payload_stream(dut):
    await reset_dut(dut)
    await send_protected_segment(dut, length=32)
    req = await wait_read_req(dut)
    await send_read_resp(dut, tag=req["tag"], length=req["len"], data=0x1234)
    payload = await wait_payload(dut)
    assert payload["desc_id"] == 0x11
    assert payload["qpn"] == 0x22
    assert payload["len"] == 32
    assert payload["error"] == DMA_HR_ERR_NONE
    await wait_ref_dec(dut)


@cocotb.test()
async def test_byte_offset_and_segment_index_are_preserved(dut):
    await reset_dut(dut)
    await send_protected_segment(dut, length=16, byte_offset=128, segment_index=5)
    req = await wait_read_req(dut)
    await send_read_resp(dut, tag=req["tag"], length=req["len"])
    payload = await wait_payload(dut)
    assert payload["byte_offset"] == 128
    assert payload["segment_index"] == 5


@cocotb.test()
async def test_last_segment_sets_payload_wqe_last(dut):
    await reset_dut(dut)
    await send_protected_segment(dut, length=32, is_last=1)
    req = await wait_read_req(dut)
    await send_read_resp(dut, tag=req["tag"], length=req["len"])
    payload = await wait_payload(dut)
    assert payload["segment_last"] == 1
    assert payload["wqe_last"] == 1


@cocotb.test()
async def test_zero_length_rejected_and_ref_dec_issued(dut):
    await reset_dut(dut)
    await send_protected_segment(dut, length=0)
    await wait_ref_dec(dut)
    assert await wait_error(dut) == DMA_HR_ERR_ZERO_LENGTH


@cocotb.test()
async def test_unsupported_operation_rejected(dut):
    await reset_dut(dut)
    await send_protected_segment(dut, operation=MR_OP_LOCAL_DMA_WRITE, length=32)
    await wait_ref_dec(dut)
    assert await wait_error(dut) == DMA_HR_ERR_UNSUPPORTED_OP


@cocotb.test()
async def test_pcie_read_response_error_enters_error_path(dut):
    await reset_dut(dut)
    await send_protected_segment(dut, length=32)
    req = await wait_read_req(dut)
    await send_read_resp(dut, tag=req["tag"], length=req["len"], error=1)
    await wait_ref_dec(dut)
    assert await wait_error(dut) == DMA_HR_ERR_RESP_ERROR


@cocotb.test()
async def test_response_tag_mismatch_rejected(dut):
    await reset_dut(dut)
    await send_protected_segment(dut, length=32)
    req = await wait_read_req(dut)
    await send_read_resp(dut, tag=req["tag"] ^ 0x1, length=req["len"])
    await wait_ref_dec(dut)
    assert await wait_error(dut) == DMA_HR_ERR_TAG_MISMATCH


@cocotb.test()
async def test_payload_ready_backpressure_does_not_drop_data(dut):
    await reset_dut(dut)
    dut.payload_ready.value = 0
    await send_protected_segment(dut, length=32)
    req = await wait_read_req(dut)
    await send_read_resp(dut, tag=req["tag"], length=req["len"], data=0xDEAD)
    for _ in range(8):
        await Timer(1, units="ns")
        if int(dut.payload_valid.value) == 1:
            assert int(dut.payload_len.value) == 32
            break
        await RisingEdge(dut.clk)
    else:
        raise AssertionError("payload_valid was not held under backpressure")
    dut.payload_ready.value = 1
    payload = await wait_payload(dut)
    assert payload["len"] == 32


@cocotb.test()
async def test_read_completion_releases_mr_refcount(dut):
    await reset_dut(dut)
    await send_protected_segment(dut, length=32, segment_index=7)
    req = await wait_read_req(dut)
    await send_read_resp(dut, tag=req["tag"], length=req["len"])
    await wait_payload(dut)
    ref = await wait_ref_dec(dut)
    assert ref["desc_id"] == 0x11
    assert ref["segment_index"] == 7


@cocotb.test()
async def test_segment_larger_than_max_read_is_split(dut):
    await reset_dut(dut)
    await send_protected_segment(dut, length=64, byte_offset=16, is_last=1)
    first = await wait_read_req(dut)
    assert first["len"] == 32
    await send_read_resp(dut, tag=first["tag"], length=first["len"])
    first_payload = await wait_payload(dut)
    assert first_payload["byte_offset"] == 16
    assert first_payload["segment_last"] == 0
    second = await wait_read_req(dut)
    assert second["addr"] == 0x8000_0120
    assert second["len"] == 32
    await send_read_resp(dut, tag=second["tag"], length=second["len"])
    second_payload = await wait_payload(dut)
    assert second_payload["byte_offset"] == 48
    assert second_payload["segment_last"] == 1
    assert second_payload["wqe_last"] == 1
