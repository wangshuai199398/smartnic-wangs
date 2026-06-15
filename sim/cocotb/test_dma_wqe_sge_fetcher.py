# SPDX-License-Identifier: MIT
"""DMA WQE/SGE fetcher 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


RDMA_OP_SEND = 0x00
RDMA_OP_RDMA_WRITE = 0x02
RDMA_OP_NOP = 0xFF

QUEUE_TYPE_SQ = 0
QUEUE_TYPE_RQ = 1

WQE_FETCH_STATUS_OK = 0
WQE_FETCH_STATUS_ERROR = 1
SGE_FETCH_STATUS_OK = 0
SGE_FETCH_STATUS_ERROR = 1

WQE_FETCH_ERR_STRIDE_ZERO = 1
WQE_FETCH_ERR_HOST_READ = 3
SGE_FETCH_ERR_COUNT_ZERO = 1
SGE_FETCH_ERR_TOO_MANY = 2
SGE_FETCH_ERR_HOST_READ = 4

WQE_BYTES = 64
SGE_BYTES = 32


SEND_WQE_FIELDS = [
    ("opcode", 8),
    ("flags", 8),
    ("sge_count", 9),
    ("inline_sge_count", 2),
    ("inline_present", 1),
    ("inline_len", 16),
    ("wr_id", 64),
    ("local_va", 64),
    ("lkey", 32),
    ("length", 32),
    ("remote_va", 64),
    ("rkey", 32),
    ("imm_data", 32),
    ("extended_sge_list_addr", 64),
    ("reserved", 84),
]

SGE_FIELDS = [
    ("addr", 64),
    ("length", 32),
    ("lkey", 32),
    ("flags", 16),
    ("reserved", 112),
]


def pack_fields(fields, values):
    packed = 0
    for name, width in fields:
        packed = (packed << width) | (values.get(name, 0) & ((1 << width) - 1))
    return packed


def extract_field(fields, packed, field_name):
    offset = 0
    for name, width in reversed(fields):
        if name == field_name:
            return (int(packed) >> offset) & ((1 << width) - 1)
        offset += width
    raise KeyError(field_name)


def pack_wqe(**overrides):
    values = {
        "opcode": RDMA_OP_SEND,
        "flags": 0,
        "sge_count": 1,
        "inline_sge_count": 1,
        "inline_present": 0,
        "inline_len": 0,
        "wr_id": 0xCAFE,
        "local_va": 0x1000_0000,
        "lkey": 0x1001,
        "length": 128,
        "remote_va": 0x2000_0000,
        "rkey": 0x2001,
        "imm_data": 0,
        "extended_sge_list_addr": 0x3000_0000,
        "reserved": 0,
    }
    values.update(overrides)
    return pack_fields(SEND_WQE_FIELDS, values)


def pack_sge(**overrides):
    values = {
        "addr": 0x4000_0000,
        "length": 256,
        "lkey": 0x1001,
        "flags": 0x1,
        "reserved": 0,
    }
    values.update(overrides)
    return pack_fields(SGE_FIELDS, values)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0

    dut.wqe_fetch_req_valid.value = 0
    dut.wqe_fetch_qpn.value = 0
    dut.wqe_fetch_owner_function.value = 0
    dut.wqe_fetch_queue_type.value = 0
    dut.wqe_fetch_base_addr.value = 0
    dut.wqe_fetch_index.value = 0
    dut.wqe_fetch_stride.value = 0
    dut.wqe_fetch_desc_id.value = 0
    dut.wqe_fetch_pd_id.value = 0
    dut.wqe_fetch_resp_ready.value = 1

    dut.sge_fetch_req_valid.value = 0
    dut.sge_fetch_desc_id.value = 0
    dut.sge_fetch_qpn.value = 0
    dut.sge_fetch_owner_function.value = 0
    dut.sge_fetch_pd_id.value = 0
    dut.sge_fetch_list_base_addr.value = 0
    dut.sge_fetch_count.value = 0
    dut.sge_fetch_start_index.value = 0
    dut.sge_fetch_resp_ready.value = 1

    dut.host_read_req_ready.value = 1
    dut.host_read_resp_valid.value = 0
    dut.host_read_resp_data.value = 0
    dut.host_read_resp_tag.value = 0
    dut.host_read_resp_error.value = 0

    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_wqe_req(dut, *, queue_type=QUEUE_TYPE_SQ, base=0x1000_0000, index=2, stride=WQE_BYTES, desc_id=0x11):
    dut.wqe_fetch_req_valid.value = 1
    dut.wqe_fetch_qpn.value = 0x22
    dut.wqe_fetch_owner_function.value = 1
    dut.wqe_fetch_queue_type.value = queue_type
    dut.wqe_fetch_base_addr.value = base
    dut.wqe_fetch_index.value = index
    dut.wqe_fetch_stride.value = stride
    dut.wqe_fetch_desc_id.value = desc_id
    dut.wqe_fetch_pd_id.value = 3
    await Timer(1, units="ns")
    assert int(dut.wqe_fetch_req_ready.value) == 1
    await RisingEdge(dut.clk)
    dut.wqe_fetch_req_valid.value = 0


async def respond_host_read(dut, *, data=0, error=0):
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.host_read_req_valid.value) == 1:
            tag = int(dut.host_read_req_tag.value)
            addr = int(dut.host_read_req_addr.value)
            length = int(dut.host_read_req_len.value)
            await RisingEdge(dut.clk)
            dut.host_read_resp_valid.value = 1
            dut.host_read_resp_tag.value = tag
            dut.host_read_resp_data.value = data
            dut.host_read_resp_error.value = error
            await RisingEdge(dut.clk)
            dut.host_read_resp_valid.value = 0
            return {"tag": tag, "addr": addr, "len": length}
        await RisingEdge(dut.clk)
    raise AssertionError("host_read_req_valid was not asserted")


async def wait_wqe_resp(dut):
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.wqe_fetch_resp_valid.value) == 1:
            result = {
                "status": int(dut.wqe_fetch_status.value),
                "error": int(dut.wqe_fetch_error_code.value),
                "desc_id": int(dut.wqe_fetch_resp_desc_id.value),
                "opcode": int(dut.wqe_opcode.value),
                "wr_id": int(dut.wqe_wr_id.value),
                "sge_count": int(dut.wqe_sge_count.value),
                "ext_addr": int(dut.wqe_extended_sge_list_addr.value),
            }
            await RisingEdge(dut.clk)
            return result
        await RisingEdge(dut.clk)
    raise AssertionError("wqe_fetch_resp_valid was not asserted")


async def send_sge_req(dut, *, count=1, start=0, base=0x3000_0000, desc_id=0x21):
    dut.sge_fetch_req_valid.value = 1
    dut.sge_fetch_desc_id.value = desc_id
    dut.sge_fetch_qpn.value = 0x22
    dut.sge_fetch_owner_function.value = 1
    dut.sge_fetch_pd_id.value = 3
    dut.sge_fetch_list_base_addr.value = base
    dut.sge_fetch_count.value = count
    dut.sge_fetch_start_index.value = start
    await Timer(1, units="ns")
    assert int(dut.sge_fetch_req_ready.value) == 1
    await RisingEdge(dut.clk)
    dut.sge_fetch_req_valid.value = 0


async def collect_sge_responses(dut, expected_entries):
    entries = []
    done = False
    for _ in range(64):
        await Timer(1, units="ns")
        if int(dut.sge_fetch_resp_valid.value) == 1:
            if int(dut.sge_entry_valid.value) == 1:
                entries.append(
                    {
                        "index": int(dut.sge_entry_index.value),
                        "addr": int(dut.sge_entry_addr.value),
                        "length": int(dut.sge_entry_length.value),
                        "lkey": int(dut.sge_entry_lkey.value),
                    }
                )
            if int(dut.sge_list_done.value) == 1:
                done = True
                await RisingEdge(dut.clk)
                break
            await RisingEdge(dut.clk)
        else:
            await RisingEdge(dut.clk)
    assert len(entries) == expected_entries
    assert done is True
    return entries


@cocotb.test()
async def sq_wqe_fetch_address_is_calculated(dut):
    await reset_dut(dut)

    await send_wqe_req(dut, queue_type=QUEUE_TYPE_SQ, base=0x1000_0000, index=3, stride=64, desc_id=0x10)
    req = await respond_host_read(dut, data=pack_wqe(opcode=RDMA_OP_SEND, wr_id=0xABC, sge_count=2))
    resp = await wait_wqe_resp(dut)

    assert req["addr"] == 0x1000_0000 + 3 * 64
    assert req["len"] == WQE_BYTES
    assert resp["status"] == WQE_FETCH_STATUS_OK
    assert resp["opcode"] == RDMA_OP_SEND
    assert resp["wr_id"] == 0xABC
    assert resp["sge_count"] == 2


@cocotb.test()
async def rq_wqe_fetch_address_is_calculated(dut):
    await reset_dut(dut)

    await send_wqe_req(dut, queue_type=QUEUE_TYPE_RQ, base=0x2000_0000, index=4, stride=64, desc_id=0x12)
    req = await respond_host_read(dut, data=pack_wqe(opcode=RDMA_OP_SEND, wr_id=0xDEF))
    resp = await wait_wqe_resp(dut)

    assert req["addr"] == 0x2000_0000 + 4 * 64
    assert resp["desc_id"] == 0x12


@cocotb.test()
async def wqe_stride_zero_and_host_read_error_are_reported(dut):
    await reset_dut(dut)

    await send_wqe_req(dut, stride=0, desc_id=0x13)
    resp = await wait_wqe_resp(dut)
    assert resp["status"] == WQE_FETCH_STATUS_ERROR
    assert resp["error"] == WQE_FETCH_ERR_STRIDE_ZERO

    await send_wqe_req(dut, desc_id=0x14)
    _ = await respond_host_read(dut, data=pack_wqe(), error=1)
    resp = await wait_wqe_resp(dut)
    assert resp["status"] == WQE_FETCH_STATUS_ERROR
    assert resp["error"] == WQE_FETCH_ERR_HOST_READ


@cocotb.test()
async def inline_sge_and_extended_sge_address_are_decoded(dut):
    await reset_dut(dut)

    await send_wqe_req(dut, desc_id=0x15)
    _ = await respond_host_read(
        dut,
        data=pack_wqe(
            opcode=RDMA_OP_RDMA_WRITE,
            wr_id=0x1234,
            sge_count=3,
            inline_sge_count=1,
            local_va=0x5555_0000,
            lkey=0x2222,
            length=512,
            extended_sge_list_addr=0x7777_0000,
        ),
    )
    resp = await wait_wqe_resp(dut)

    assert resp["status"] == WQE_FETCH_STATUS_OK
    assert resp["opcode"] == RDMA_OP_RDMA_WRITE
    assert resp["wr_id"] == 0x1234
    assert resp["sge_count"] == 3
    assert resp["ext_addr"] == 0x7777_0000


@cocotb.test()
async def extended_sge_fetch_single_and_multiple_entries(dut):
    await reset_dut(dut)

    await send_sge_req(dut, count=1, start=0, base=0x3000_0000, desc_id=0x20)
    req = await respond_host_read(dut, data=pack_sge(addr=0x4000_0000, length=64, lkey=0x1001))
    entries = await collect_sge_responses(dut, 1)
    assert req["addr"] == 0x3000_0000
    assert entries[0]["addr"] == 0x4000_0000
    assert entries[0]["length"] == 64

    await send_sge_req(dut, count=2, start=1, base=0x3000_0000, desc_id=0x21)
    req0 = await respond_host_read(dut, data=pack_sge(addr=0x5000_0000, length=128, lkey=0x1002))
    req1 = await respond_host_read(dut, data=pack_sge(addr=0x5000_1000, length=256, lkey=0x1003))
    entries = await collect_sge_responses(dut, 2)
    assert req0["addr"] == 0x3000_0000 + 1 * SGE_BYTES
    assert req1["addr"] == 0x3000_0000 + 2 * SGE_BYTES
    assert entries[0]["index"] == 1
    assert entries[1]["index"] == 2


@cocotb.test()
async def sge_count_limits_and_fetch_error_are_reported(dut):
    await reset_dut(dut)

    await send_sge_req(dut, count=0, desc_id=0x22)
    await Timer(1, units="ns")
    assert int(dut.sge_fetch_resp_valid.value) == 0
    for _ in range(8):
        await RisingEdge(dut.clk)
        if int(dut.sge_fetch_resp_valid.value):
            break
    assert int(dut.sge_fetch_status.value) == SGE_FETCH_STATUS_ERROR
    assert int(dut.sge_fetch_error_code.value) == SGE_FETCH_ERR_COUNT_ZERO

    await send_sge_req(dut, count=257, desc_id=0x23)
    for _ in range(8):
        await RisingEdge(dut.clk)
        if int(dut.sge_fetch_resp_valid.value):
            break
    assert int(dut.sge_fetch_status.value) == SGE_FETCH_STATUS_ERROR
    assert int(dut.sge_fetch_error_code.value) == SGE_FETCH_ERR_TOO_MANY
    await RisingEdge(dut.clk)

    await send_sge_req(dut, count=1, desc_id=0x24)
    _ = await respond_host_read(dut, data=pack_sge(), error=1)
    for _ in range(8):
        await RisingEdge(dut.clk)
        if int(dut.sge_fetch_resp_valid.value):
            break
    assert int(dut.sge_fetch_status.value) == SGE_FETCH_STATUS_ERROR
    assert int(dut.sge_fetch_error_code.value) == SGE_FETCH_ERR_HOST_READ


@cocotb.test()
async def sge_count_256_is_accepted_and_response_backpressure_holds(dut):
    await reset_dut(dut)

    dut.sge_fetch_resp_ready.value = 0
    await send_sge_req(dut, count=256, desc_id=0x25)
    _ = await respond_host_read(dut, data=pack_sge(addr=0x6000_0000))

    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.sge_fetch_resp_valid.value) == 1:
            break
        await RisingEdge(dut.clk)
    assert int(dut.sge_fetch_resp_valid.value) == 1
    assert int(dut.sge_entry_valid.value) == 1
    assert int(dut.sge_entry_addr.value) == 0x6000_0000

    for _ in range(3):
        await RisingEdge(dut.clk)
        assert int(dut.sge_fetch_resp_valid.value) == 1
        assert int(dut.sge_entry_addr.value) == 0x6000_0000

    dut.sge_fetch_resp_ready.value = 1
    await RisingEdge(dut.clk)
