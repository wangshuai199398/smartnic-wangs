# SPDX-License-Identifier: MIT
"""DMA host memory write path 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


MR_OP_LOCAL_DMA_WRITE = 1
MR_OP_LOCAL_RECV_WRITE = 2
MR_OP_REMOTE_RDMA_WRITE = 4

DMA_HW_ERR_NONE = 0
DMA_HW_ERR_ZERO_SEGMENT_LEN = 2
DMA_HW_ERR_ZERO_PAYLOAD_LEN = 3
DMA_HW_ERR_PAYLOAD_MISMATCH = 4
DMA_HW_ERR_BOUNDS = 5
DMA_HW_ERR_ADDR_OVERFLOW = 6
DMA_HW_ERR_CPL_ERROR = 7
DMA_HW_ERR_TAG_MISMATCH = 8


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
        "key": 0x2002,
        "is_remote": 0,
        "owner_function": 1,
        "mr_id": 0x55,
    }
    values.update(overrides)
    return pack_fields(MR_REF_TOKEN_FIELDS, values)


def make_tag(desc_id, segment_index, beat_index=0):
    return ((desc_id & 0xFFFF) << 16) | ((segment_index & 0x1FF) << 7) | (beat_index & 0x7F)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0

    dut.protected_segment_valid.value = 0
    dut.protected_segment_desc_id.value = 0
    dut.protected_segment_qpn.value = 0
    dut.protected_segment_owner_function.value = 0
    dut.protected_segment_pd_id.value = 0
    dut.protected_segment_operation.value = MR_OP_LOCAL_RECV_WRITE
    dut.protected_segment_index.value = 0
    dut.protected_segment_pa.value = 0
    dut.protected_segment_len.value = 0
    dut.protected_segment_byte_offset.value = 0
    dut.protected_segment_is_last.value = 0
    dut.protected_segment_mr_refcount_token.value = 0
    dut.protected_segment_flags.value = 0

    dut.write_payload_valid.value = 0
    dut.write_payload_desc_id.value = 0
    dut.write_payload_qpn.value = 0
    dut.write_payload_owner_function.value = 0
    dut.write_payload_operation.value = MR_OP_LOCAL_RECV_WRITE
    dut.write_payload_data.value = 0
    dut.write_payload_len.value = 0
    dut.write_payload_byte_offset.value = 0
    dut.write_payload_last.value = 0
    dut.write_payload_error.value = 0

    dut.pcie_write_req_ready.value = 1
    dut.pcie_write_cpl_valid.value = 0
    dut.pcie_write_cpl_tag.value = 0
    dut.pcie_write_cpl_status.value = 0
    dut.pcie_write_cpl_error.value = 0

    dut.write_done_ready.value = 1
    dut.mr_ref_dec_ready.value = 1
    dut.host_write_error_ready.value = 1

    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_protected_segment(
    dut,
    *,
    operation=MR_OP_LOCAL_RECV_WRITE,
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
    dut.protected_segment_flags.value = 0x2
    await Timer(1, units="ns")
    assert int(dut.protected_segment_ready.value) == 1
    await RisingEdge(dut.clk)
    dut.protected_segment_valid.value = 0


async def send_payload(
    dut,
    *,
    desc_id=0x11,
    qpn=0x22,
    owner_function=1,
    operation=MR_OP_LOCAL_RECV_WRITE,
    data=0xA5A5,
    length=32,
    byte_offset=64,
    last=1,
    error=0,
):
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.write_payload_ready.value) == 1:
            break
        await RisingEdge(dut.clk)
    else:
        raise AssertionError("write_payload_ready was not asserted")

    dut.write_payload_valid.value = 1
    dut.write_payload_desc_id.value = desc_id
    dut.write_payload_qpn.value = qpn
    dut.write_payload_owner_function.value = owner_function
    dut.write_payload_operation.value = operation
    dut.write_payload_data.value = data
    dut.write_payload_len.value = length
    dut.write_payload_byte_offset.value = byte_offset
    dut.write_payload_last.value = last
    dut.write_payload_error.value = error
    await RisingEdge(dut.clk)
    dut.write_payload_valid.value = 0


async def wait_write_req(dut, timeout=32):
    for _ in range(timeout):
        await Timer(1, units="ns")
        if int(dut.pcie_write_req_valid.value) == 1:
            req = {
                "addr": int(dut.pcie_write_req_addr.value),
                "data": int(dut.pcie_write_req_data.value),
                "len": int(dut.pcie_write_req_len.value),
                "byte_enable": int(dut.pcie_write_req_byte_enable.value),
                "tag": int(dut.pcie_write_req_tag.value),
                "desc_id": int(dut.pcie_write_req_desc_id.value),
                "qpn": int(dut.pcie_write_req_qpn.value),
                "segment_index": int(dut.pcie_write_req_segment_index.value),
            }
            await RisingEdge(dut.clk)
            return req
        await RisingEdge(dut.clk)
    raise AssertionError("pcie_write_req_valid was not asserted")


async def send_write_cpl(dut, *, tag, status=0, error=0):
    dut.pcie_write_cpl_valid.value = 1
    dut.pcie_write_cpl_tag.value = tag
    dut.pcie_write_cpl_status.value = status
    dut.pcie_write_cpl_error.value = error
    await Timer(1, units="ns")
    assert int(dut.pcie_write_cpl_ready.value) == 1
    await RisingEdge(dut.clk)
    dut.pcie_write_cpl_valid.value = 0


async def wait_done(dut, timeout=32):
    for _ in range(timeout):
        await Timer(1, units="ns")
        if int(dut.write_done_valid.value) == 1:
            done = {
                "desc_id": int(dut.write_done_desc_id.value),
                "qpn": int(dut.write_done_qpn.value),
                "status": int(dut.write_done_status.value),
                "error": int(dut.write_done_error_code.value),
                "byte_len": int(dut.write_done_byte_len.value),
                "last": int(dut.write_done_last.value),
                "segment_index": int(dut.write_done_segment_index.value),
            }
            await RisingEdge(dut.clk)
            return done
        await RisingEdge(dut.clk)
    raise AssertionError("write_done_valid was not asserted")


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
        if int(dut.host_write_error_valid.value) == 1:
            code = int(dut.host_write_error_code.value)
            await RisingEdge(dut.clk)
            return code
        await RisingEdge(dut.clk)
    raise AssertionError("host_write_error_valid was not asserted")


@cocotb.test()
async def test_recv_segment_and_payload_issue_pcie_write(dut):
    await reset_dut(dut)
    await send_protected_segment(dut, operation=MR_OP_LOCAL_RECV_WRITE)
    await send_payload(dut, operation=MR_OP_LOCAL_RECV_WRITE, data=0x1234)
    req = await wait_write_req(dut)
    assert req["addr"] == 0x8000_0100
    assert req["data"] == 0x1234
    assert req["len"] == 32
    assert req["tag"] == make_tag(0x11, 3, 0)


@cocotb.test()
async def test_rdma_read_response_segment_issues_pcie_write(dut):
    await reset_dut(dut)
    await send_protected_segment(dut, operation=MR_OP_LOCAL_DMA_WRITE, length=16)
    await send_payload(dut, operation=MR_OP_LOCAL_DMA_WRITE, length=16)
    req = await wait_write_req(dut)
    assert req["addr"] == 0x8000_0100
    assert req["len"] == 16


@cocotb.test()
async def test_byte_offset_and_segment_index_are_preserved(dut):
    await reset_dut(dut)
    await send_protected_segment(dut, byte_offset=128, segment_index=5, length=16)
    await send_payload(dut, byte_offset=128, length=16)
    req = await wait_write_req(dut)
    assert req["addr"] == 0x8000_0100
    assert req["segment_index"] == 5
    assert req["tag"] == make_tag(0x11, 5, 0)


@cocotb.test()
async def test_write_completion_generates_write_done(dut):
    await reset_dut(dut)
    await send_protected_segment(dut, length=16)
    await send_payload(dut, length=16)
    req = await wait_write_req(dut)
    await send_write_cpl(dut, tag=req["tag"])
    done = await wait_done(dut)
    assert done["desc_id"] == 0x11
    assert done["qpn"] == 0x22
    assert done["byte_len"] == 16
    assert done["last"] == 1
    assert done["error"] == DMA_HW_ERR_NONE


@cocotb.test()
async def test_zero_segment_length_rejected(dut):
    await reset_dut(dut)
    await send_protected_segment(dut, length=0)
    await wait_ref_dec(dut)
    assert await wait_error(dut) == DMA_HW_ERR_ZERO_SEGMENT_LEN


@cocotb.test()
async def test_zero_payload_length_rejected(dut):
    await reset_dut(dut)
    await send_protected_segment(dut, length=32)
    await send_payload(dut, length=0)
    await wait_ref_dec(dut)
    assert await wait_error(dut) == DMA_HW_ERR_ZERO_PAYLOAD_LEN


@cocotb.test()
async def test_payload_desc_id_mismatch_rejected(dut):
    await reset_dut(dut)
    await send_protected_segment(dut, length=32)
    await send_payload(dut, desc_id=0x99, length=16)
    await wait_ref_dec(dut)
    assert await wait_error(dut) == DMA_HW_ERR_PAYLOAD_MISMATCH


@cocotb.test()
async def test_payload_exceeding_segment_length_rejected(dut):
    await reset_dut(dut)
    await send_protected_segment(dut, length=16, byte_offset=64)
    await send_payload(dut, length=32, byte_offset=64)
    await wait_ref_dec(dut)
    assert await wait_error(dut) == DMA_HW_ERR_BOUNDS


@cocotb.test()
async def test_write_address_overflow_rejected(dut):
    await reset_dut(dut)
    await send_protected_segment(dut, pa=(1 << 64) - 8, length=16, byte_offset=64)
    await send_payload(dut, length=16, byte_offset=64)
    await wait_ref_dec(dut)
    assert await wait_error(dut) == DMA_HW_ERR_ADDR_OVERFLOW


@cocotb.test()
async def test_pcie_write_completion_error_enters_error_path(dut):
    await reset_dut(dut)
    await send_protected_segment(dut, length=16)
    await send_payload(dut, length=16)
    req = await wait_write_req(dut)
    await send_write_cpl(dut, tag=req["tag"], error=1)
    await wait_ref_dec(dut)
    assert await wait_error(dut) == DMA_HW_ERR_CPL_ERROR


@cocotb.test()
async def test_completion_tag_mismatch_rejected(dut):
    await reset_dut(dut)
    await send_protected_segment(dut, length=16)
    await send_payload(dut, length=16)
    req = await wait_write_req(dut)
    await send_write_cpl(dut, tag=req["tag"] ^ 0x1)
    await wait_ref_dec(dut)
    assert await wait_error(dut) == DMA_HW_ERR_TAG_MISMATCH


@cocotb.test()
async def test_write_req_backpressure_does_not_drop_payload(dut):
    await reset_dut(dut)
    dut.pcie_write_req_ready.value = 0
    await send_protected_segment(dut, length=16)
    await send_payload(dut, length=16, data=0xBEEF)
    for _ in range(8):
        await Timer(1, units="ns")
        if int(dut.pcie_write_req_valid.value) == 1:
            assert int(dut.pcie_write_req_data.value) == 0xBEEF
            assert int(dut.pcie_write_req_len.value) == 16
            break
        await RisingEdge(dut.clk)
    else:
        raise AssertionError("pcie_write_req_valid was not held under backpressure")
    dut.pcie_write_req_ready.value = 1
    req = await wait_write_req(dut)
    assert req["data"] == 0xBEEF


@cocotb.test()
async def test_write_completion_releases_mr_refcount(dut):
    await reset_dut(dut)
    await send_protected_segment(dut, length=16, segment_index=7)
    await send_payload(dut, length=16)
    req = await wait_write_req(dut)
    await send_write_cpl(dut, tag=req["tag"])
    await wait_done(dut)
    ref = await wait_ref_dec(dut)
    assert ref["desc_id"] == 0x11
    assert ref["segment_index"] == 7
