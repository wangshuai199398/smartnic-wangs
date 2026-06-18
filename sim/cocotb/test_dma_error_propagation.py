# SPDX-License-Identifier: MIT
"""DMA error propagation 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


MAX_SRC = 9
SRC_W = 4
QPN_W = 24
CQN_W = 24
OWNER_W = 16
PD_W = 24
OP_W = 4
DIR_W = 3
SEG_W = 9
OFFSET_W = 32
WR_ID_W = 64
LEN_W = 32

SRC_DISPATCHER = 0
SRC_WQE_FETCH = 1
SRC_SGE_FETCH = 2
SRC_SGE_TRAVERSAL = 3
SRC_MR_INTEGRATION = 4
SRC_SEGMENT_SPLIT = 5
SRC_HOST_READ = 6
SRC_HOST_WRITE = 7
SRC_ARBITER = 8

DMA_ERR_MR_LOOKUP_MISS = 0x0001
DMA_ERR_KEY_DIRECTION = 0x0002
DMA_ERR_ACCESS_DENIED = 0x0003
DMA_ERR_BOUNDS = 0x0005
DMA_ERR_SGE_LENGTH = 0x0006
DMA_ERR_WQE_FETCH = 0x0008
DMA_ERR_UNSUPPORTED_OPCODE = 0x000A
DMA_ERR_PCIE_READ = 0x000B
DMA_ERR_PCIE_WRITE = 0x000C
DMA_ERR_CQ_OVERFLOW = 0x000D
DMA_ERR_ARB_MALFORMED = 0x000E

CMPL_SUCCESS = 0x00
CMPL_LOC_LEN_ERR = 0x01
CMPL_LOC_QP_OP_ERR = 0x02
CMPL_LOC_PROT_ERR = 0x03
CMPL_REM_ACCESS_ERR = 0x07
CMPL_CQ_OVERFLOW_ERR = 0x0B
CMPL_DMA_ERR = 0x0C

MR_OP_LOCAL_DMA_READ = 0
MR_OP_LOCAL_DMA_WRITE = 1
MR_OP_REMOTE_RDMA_READ = 3
MR_OP_REMOTE_RDMA_WRITE = 4

DMA_DIR_HOST_READ = 0
DMA_DIR_HOST_WRITE = 1

RDMA_OP_SEND = 0
RDMA_OP_RDMA_WRITE = 2


def pack_lane(current, idx, width, value):
    mask = ((1 << width) - 1) << (idx * width)
    return (current & ~mask) | ((value & ((1 << width) - 1)) << (idx * width))


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.error_valid.value = 0
    dut.error_source_id.value = 0
    dut.error_desc_id.value = 0
    dut.error_qpn.value = 0
    dut.error_cqn.value = 0
    dut.error_owner_function.value = 0
    dut.error_pd_id.value = 0
    dut.error_operation.value = 0
    dut.error_direction.value = 0
    dut.error_segment_index.value = 0
    dut.error_byte_offset.value = 0
    dut.error_dma_code.value = 0
    dut.error_original_status.value = 0
    dut.error_fatal.value = 0
    dut.error_retryable.value = 0
    dut.error_wr_id.value = 0
    dut.error_opcode.value = 0
    dut.error_byte_len.value = 0
    dut.error_solicited.value = 0
    dut.completion_error_ready.value = 1
    dut.qp_error_req_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def clear_errors(dut):
    dut.error_valid.value = 0
    dut.error_fatal.value = 0
    dut.error_retryable.value = 0
    dut.error_solicited.value = 0


def set_error(
    dut,
    idx,
    *,
    source,
    code,
    fatal=0,
    retryable=0,
    operation=MR_OP_LOCAL_DMA_READ,
    direction=DMA_DIR_HOST_READ,
    desc_id=0x40,
    qpn=0x123,
    cqn=0x456,
    owner=3,
    pd_id=0x22,
    segment_index=2,
    byte_offset=0x80,
    wr_id=0xABCDEF,
    opcode=RDMA_OP_SEND,
    byte_len=64,
    solicited=0,
    original_status=CMPL_SUCCESS,
):
    dut.error_valid.value = int(dut.error_valid.value) | (1 << idx)
    dut.error_source_id.value = pack_lane(int(dut.error_source_id.value), idx, SRC_W, source)
    dut.error_desc_id.value = pack_lane(int(dut.error_desc_id.value), idx, 16, desc_id)
    dut.error_qpn.value = pack_lane(int(dut.error_qpn.value), idx, QPN_W, qpn)
    dut.error_cqn.value = pack_lane(int(dut.error_cqn.value), idx, CQN_W, cqn)
    dut.error_owner_function.value = pack_lane(int(dut.error_owner_function.value), idx, OWNER_W, owner)
    dut.error_pd_id.value = pack_lane(int(dut.error_pd_id.value), idx, PD_W, pd_id)
    dut.error_operation.value = pack_lane(int(dut.error_operation.value), idx, OP_W, operation)
    dut.error_direction.value = pack_lane(int(dut.error_direction.value), idx, DIR_W, direction)
    dut.error_segment_index.value = pack_lane(int(dut.error_segment_index.value), idx, SEG_W, segment_index)
    dut.error_byte_offset.value = pack_lane(int(dut.error_byte_offset.value), idx, OFFSET_W, byte_offset)
    dut.error_dma_code.value = pack_lane(int(dut.error_dma_code.value), idx, 16, code)
    dut.error_original_status.value = pack_lane(int(dut.error_original_status.value), idx, 8, original_status)
    dut.error_wr_id.value = pack_lane(int(dut.error_wr_id.value), idx, WR_ID_W, wr_id)
    dut.error_opcode.value = pack_lane(int(dut.error_opcode.value), idx, 8, opcode)
    dut.error_byte_len.value = pack_lane(int(dut.error_byte_len.value), idx, LEN_W, byte_len)
    if fatal:
        dut.error_fatal.value = int(dut.error_fatal.value) | (1 << idx)
    if retryable:
        dut.error_retryable.value = int(dut.error_retryable.value) | (1 << idx)
    if solicited:
        dut.error_solicited.value = int(dut.error_solicited.value) | (1 << idx)


async def wait_completion(dut, timeout=32):
    for _ in range(timeout):
        await Timer(1, units="ns")
        if int(dut.completion_error_valid.value) == 1:
            event = {
                "status": int(dut.completion_status.value),
                "source": int(dut.completion_source_id.value),
                "desc_id": int(dut.completion_desc_id.value),
                "qpn": int(dut.completion_qpn.value),
                "cqn": int(dut.completion_cqn.value),
                "vendor_error": int(dut.completion_vendor_error.value),
            }
            await RisingEdge(dut.clk)
            return event
        await RisingEdge(dut.clk)
    raise AssertionError("completion_error_valid was not asserted")


async def wait_qp_error(dut, timeout=32):
    for _ in range(timeout):
        await Timer(1, units="ns")
        if int(dut.qp_error_req_valid.value) == 1:
            event = {
                "qpn": int(dut.qp_error_qpn.value),
                "source": int(dut.qp_error_source_id.value),
                "code": int(dut.qp_error_code.value),
                "desc_id": int(dut.qp_error_desc_id.value),
            }
            await RisingEdge(dut.clk)
            return event
        await RisingEdge(dut.clk)
    raise AssertionError("qp_error_req_valid was not asserted")


async def check_status(dut, code, expected_status, source=SRC_MR_INTEGRATION, **kwargs):
    await reset_dut(dut)
    set_error(dut, 0, source=source, code=code, **kwargs)
    event = await wait_completion(dut)
    assert event["status"] == expected_status
    assert event["source"] == source


@cocotb.test()
async def test_mr_lookup_miss_maps_to_local_protection(dut):
    await check_status(dut, DMA_ERR_MR_LOOKUP_MISS, CMPL_LOC_PROT_ERR)


@cocotb.test()
async def test_access_denied_maps_to_local_protection(dut):
    await check_status(dut, DMA_ERR_ACCESS_DENIED, CMPL_LOC_PROT_ERR)


@cocotb.test()
async def test_remote_access_denied_maps_to_remote_access(dut):
    await check_status(
        dut,
        DMA_ERR_ACCESS_DENIED,
        CMPL_REM_ACCESS_ERR,
        operation=MR_OP_REMOTE_RDMA_WRITE,
    )


@cocotb.test()
async def test_bounds_error_maps_to_local_length(dut):
    await check_status(dut, DMA_ERR_BOUNDS, CMPL_LOC_LEN_ERR)


@cocotb.test()
async def test_sge_length_overrun_maps_to_local_length(dut):
    await check_status(dut, DMA_ERR_SGE_LENGTH, CMPL_LOC_LEN_ERR, source=SRC_SGE_TRAVERSAL)


@cocotb.test()
async def test_wqe_fetch_error_maps_to_work_request_error(dut):
    await check_status(dut, DMA_ERR_WQE_FETCH, CMPL_LOC_QP_OP_ERR, source=SRC_WQE_FETCH)


@cocotb.test()
async def test_unsupported_opcode_maps_to_work_request_error(dut):
    await check_status(dut, DMA_ERR_UNSUPPORTED_OPCODE, CMPL_LOC_QP_OP_ERR, source=SRC_DISPATCHER)


@cocotb.test()
async def test_pcie_read_error_maps_to_dma_access_error(dut):
    await check_status(dut, DMA_ERR_PCIE_READ, CMPL_DMA_ERR, source=SRC_HOST_READ)


@cocotb.test()
async def test_pcie_write_error_maps_to_dma_access_error(dut):
    await check_status(
        dut,
        DMA_ERR_PCIE_WRITE,
        CMPL_DMA_ERR,
        source=SRC_HOST_WRITE,
        direction=DMA_DIR_HOST_WRITE,
        operation=MR_OP_LOCAL_DMA_WRITE,
    )


@cocotb.test()
async def test_cq_overflow_maps_to_cq_overflow_error(dut):
    await check_status(dut, DMA_ERR_CQ_OVERFLOW, CMPL_CQ_OVERFLOW_ERR, source=SRC_HOST_WRITE)


@cocotb.test()
async def test_fatal_error_generates_qp_error_request(dut):
    await reset_dut(dut)
    set_error(dut, 0, source=SRC_MR_INTEGRATION, code=DMA_ERR_ACCESS_DENIED, fatal=1, qpn=0x555)
    event = await wait_completion(dut)
    assert event["status"] == CMPL_LOC_PROT_ERR
    qp_error = await wait_qp_error(dut)
    assert qp_error["qpn"] == 0x555
    assert qp_error["code"] == DMA_ERR_ACCESS_DENIED


@cocotb.test()
async def test_non_fatal_error_only_generates_completion(dut):
    await reset_dut(dut)
    set_error(dut, 0, source=SRC_HOST_READ, code=DMA_ERR_PCIE_READ, fatal=0)
    event = await wait_completion(dut)
    assert event["status"] == CMPL_DMA_ERR
    for _ in range(6):
        await RisingEdge(dut.clk)
        assert int(dut.qp_error_req_valid.value) == 0


@cocotb.test()
async def test_completion_ready_backpressure_holds_error_event(dut):
    await reset_dut(dut)
    dut.completion_error_ready.value = 0
    set_error(dut, 0, source=SRC_HOST_READ, code=DMA_ERR_PCIE_READ, desc_id=0x77)
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.completion_error_valid.value) == 1:
            assert int(dut.completion_desc_id.value) == 0x77
            await RisingEdge(dut.clk)
            assert int(dut.completion_error_valid.value) == 1
            break
        await RisingEdge(dut.clk)
    else:
        raise AssertionError("completion_error_valid was not asserted under backpressure")
    dut.completion_error_ready.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_multiple_sources_choose_fatal_first(dut):
    await reset_dut(dut)
    set_error(dut, 0, source=SRC_MR_INTEGRATION, code=DMA_ERR_ACCESS_DENIED, fatal=0, desc_id=0x10)
    set_error(dut, 8, source=SRC_ARBITER, code=DMA_ERR_ARB_MALFORMED, fatal=1, desc_id=0x88)
    event = await wait_completion(dut)
    assert event["source"] == SRC_ARBITER
    assert event["desc_id"] == 0x88
    qp_error = await wait_qp_error(dut)
    assert qp_error["source"] == SRC_ARBITER


@cocotb.test()
async def test_multiple_nonfatal_sources_choose_mr_protection_first(dut):
    await reset_dut(dut)
    set_error(dut, 0, source=SRC_HOST_READ, code=DMA_ERR_PCIE_READ, desc_id=0x11)
    set_error(dut, 1, source=SRC_MR_INTEGRATION, code=DMA_ERR_MR_LOOKUP_MISS, desc_id=0x22)
    event = await wait_completion(dut)
    assert event["source"] == SRC_MR_INTEGRATION
    assert event["desc_id"] == 0x22
