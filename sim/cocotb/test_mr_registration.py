# SPDX-License-Identifier: MIT
"""MR registration manager 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


MR_TABLE_STATUS_OK = 0
MR_TABLE_STATUS_MISS = 1
MR_TABLE_STATUS_PERMISSION = 2
MR_TABLE_STATUS_ALIAS = 3
MR_TABLE_STATUS_FULL = 4
MR_TABLE_STATUS_INVALID = 5
MR_TABLE_STATUS_LENGTH = 7

MR_REG_ERR_NONE = 0
MR_REG_ERR_LENGTH = 1
MR_REG_ERR_PAGE_SIZE = 2
MR_REG_ERR_VA_ALIGN = 3
MR_REG_ERR_SG_COUNT = 4
MR_REG_ERR_ALIAS = 0x000A
MR_REG_ERR_SG_FETCH = 0x000B

SG_ENTRY_BYTES = 32


SG_ENTRY_FIELDS = [
    ("physical_base_addr", 64),
    ("length", 32),
    ("page_count", 32),
    ("page_size", 6),
    ("flags", 16),
    ("reserved", 106),
]


MR_ENTRY_FIELDS = [
    ("valid", 1),
    ("mr_id", 24),
    ("lkey", 32),
    ("rkey", 32),
    ("virtual_base_addr", 64),
    ("physical_base_addr", 64),
    ("length", 32),
    ("page_size", 6),
    ("access_flags", 6),
    ("pd_id", 24),
    ("owner_function", 16),
    ("refcount", 16),
    ("pending_deregister", 1),
    ("memory_window", 1),
    ("invalidating", 1),
    ("bound_qpn", 24),
    ("parent_mr_key", 32),
    ("error_state", 1),
    ("error_code", 16),
]


def pack_fields(fields, values):
    packed = 0
    for name, width in fields:
        packed = (packed << width) | (values.get(name, 0) & ((1 << width) - 1))
    return packed


def unpack_fields(fields, value):
    unpacked = {}
    offset = 0
    for name, width in reversed(fields):
        unpacked[name] = (int(value) >> offset) & ((1 << width) - 1)
        offset += width
    return unpacked


def pack_sg_entry(**overrides):
    values = {
        "physical_base_addr": 0x8000_0000,
        "length": 0x2000,
        "page_count": 2,
        "page_size": 12,
        "flags": 0,
        "reserved": 0,
    }
    values.update(overrides)
    return pack_fields(SG_ENTRY_FIELDS, values)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0

    dut.reg_req_valid.value = 0
    dut.reg_req_owner_function.value = 0
    dut.reg_req_function_enabled.value = 1
    dut.reg_req_pd_id.value = 0
    dut.reg_req_virtual_base_addr.value = 0
    dut.reg_req_length.value = 0
    dut.reg_req_page_size.value = 12
    dut.reg_req_access_flags.value = 0
    dut.reg_req_sg_list_base_addr.value = 0
    dut.reg_req_sg_entry_count.value = 0
    dut.reg_req_lkey.value = 0
    dut.reg_req_rkey.value = 0
    dut.reg_req_cmd_sequence.value = 0
    dut.reg_resp_ready.value = 0

    dut.sg_fetch_ready.value = 1
    dut.sg_fetch_resp_valid.value = 0
    dut.sg_fetch_resp_data.value = 0
    dut.sg_fetch_resp_error.value = 0

    dut.mr_entry_write_ready.value = 1
    dut.mr_entry_write_rsp_valid.value = 0
    dut.mr_entry_write_status.value = MR_TABLE_STATUS_OK

    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_register(
    dut,
    *,
    owner=1,
    enabled=1,
    pd=3,
    va=0x1000_0000,
    length=0x1000,
    page_size=12,
    access_flags=0x03,
    sg_base=0x5000_0000,
    sg_count=1,
    lkey=0x1001,
    rkey=0x2001,
    seq=0x55,
):
    dut.reg_req_valid.value = 1
    dut.reg_req_owner_function.value = owner
    dut.reg_req_function_enabled.value = enabled
    dut.reg_req_pd_id.value = pd
    dut.reg_req_virtual_base_addr.value = va
    dut.reg_req_length.value = length
    dut.reg_req_page_size.value = page_size
    dut.reg_req_access_flags.value = access_flags
    dut.reg_req_sg_list_base_addr.value = sg_base
    dut.reg_req_sg_entry_count.value = sg_count
    dut.reg_req_lkey.value = lkey
    dut.reg_req_rkey.value = rkey
    dut.reg_req_cmd_sequence.value = seq
    await RisingEdge(dut.clk)
    dut.reg_req_valid.value = 0


async def respond_sg_fetch(dut, *, sg=None, error=0):
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.sg_fetch_valid.value) == 1:
            break
        await RisingEdge(dut.clk)

    assert int(dut.sg_fetch_valid.value) == 1
    assert int(dut.sg_fetch_len.value) == SG_ENTRY_BYTES
    await RisingEdge(dut.clk)
    dut.sg_fetch_resp_valid.value = 1
    dut.sg_fetch_resp_data.value = sg if sg is not None else pack_sg_entry()
    dut.sg_fetch_resp_error.value = error
    await RisingEdge(dut.clk)
    dut.sg_fetch_resp_valid.value = 0
    dut.sg_fetch_resp_error.value = 0


async def respond_table_write(dut, *, status=MR_TABLE_STATUS_OK):
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.mr_entry_write_valid.value) == 1:
            break
        await RisingEdge(dut.clk)

    assert int(dut.mr_entry_write_valid.value) == 1
    entry = unpack_fields(MR_ENTRY_FIELDS, dut.mr_entry_write_data.value)
    await RisingEdge(dut.clk)
    dut.mr_entry_write_rsp_valid.value = 1
    dut.mr_entry_write_status.value = status
    await RisingEdge(dut.clk)
    dut.mr_entry_write_rsp_valid.value = 0
    return entry


async def wait_response(dut, max_cycles=16):
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        if int(dut.reg_resp_valid.value) == 1:
            result = {
                "status": int(dut.reg_resp_status.value),
                "error": int(dut.reg_resp_error_code.value),
                "lkey": int(dut.reg_resp_lkey.value),
                "rkey": int(dut.reg_resp_rkey.value),
                "index": int(dut.reg_resp_mr_index.value),
                "seq": int(dut.reg_resp_cmd_sequence.value),
            }
            dut.reg_resp_ready.value = 1
            await RisingEdge(dut.clk)
            dut.reg_resp_ready.value = 0
            return result
    raise AssertionError("mr_registration_manager did not produce response")


@cocotb.test()
async def legal_register_mr_creates_table_entry(dut):
    await reset_dut(dut)

    await send_register(dut)
    await respond_sg_fetch(dut)
    entry = await respond_table_write(dut, status=MR_TABLE_STATUS_OK)
    resp = await wait_response(dut)

    assert entry["valid"] == 1
    assert entry["lkey"] == 0x1001
    assert entry["rkey"] == 0x2001
    assert entry["virtual_base_addr"] == 0x1000_0000
    assert entry["physical_base_addr"] == 0x8000_0000
    assert entry["length"] == 0x1000
    assert entry["pd_id"] == 3
    assert entry["owner_function"] == 1
    assert entry["refcount"] == 0
    assert resp["status"] == MR_TABLE_STATUS_OK
    assert resp["error"] == MR_REG_ERR_NONE
    assert resp["lkey"] == 0x1001
    assert resp["rkey"] == 0x2001
    assert resp["index"] == 0
    assert resp["seq"] == 0x55


@cocotb.test()
async def zero_length_is_rejected(dut):
    await reset_dut(dut)

    await send_register(dut, length=0)
    resp = await wait_response(dut)

    assert resp["status"] == MR_TABLE_STATUS_LENGTH
    assert resp["error"] == MR_REG_ERR_LENGTH


@cocotb.test()
async def invalid_page_size_is_rejected(dut):
    await reset_dut(dut)

    await send_register(dut, page_size=13)
    resp = await wait_response(dut)

    assert resp["status"] == MR_TABLE_STATUS_INVALID
    assert resp["error"] == MR_REG_ERR_PAGE_SIZE


@cocotb.test()
async def unaligned_virtual_base_is_rejected(dut):
    await reset_dut(dut)

    await send_register(dut, va=0x1000_0001)
    resp = await wait_response(dut)

    assert resp["status"] == MR_TABLE_STATUS_INVALID
    assert resp["error"] == MR_REG_ERR_VA_ALIGN


@cocotb.test()
async def zero_sg_entry_count_is_rejected(dut):
    await reset_dut(dut)

    await send_register(dut, sg_count=0)
    resp = await wait_response(dut)

    assert resp["status"] == MR_TABLE_STATUS_INVALID
    assert resp["error"] == MR_REG_ERR_SG_COUNT


@cocotb.test()
async def lkey_or_rkey_alias_from_table_is_rejected(dut):
    await reset_dut(dut)

    await send_register(dut)
    await respond_sg_fetch(dut)
    _ = await respond_table_write(dut, status=MR_TABLE_STATUS_ALIAS)
    resp = await wait_response(dut)

    assert resp["status"] == MR_TABLE_STATUS_ALIAS
    assert resp["error"] == MR_REG_ERR_ALIAS


@cocotb.test()
async def sg_fetch_error_is_rejected(dut):
    await reset_dut(dut)

    await send_register(dut)
    await respond_sg_fetch(dut, error=1)
    resp = await wait_response(dut)

    assert resp["status"] == MR_TABLE_STATUS_MISS
    assert resp["error"] == MR_REG_ERR_SG_FETCH


@cocotb.test()
async def sg_length_smaller_than_mr_length_is_rejected(dut):
    await reset_dut(dut)

    await send_register(dut, length=0x2000)
    await respond_sg_fetch(dut, sg=pack_sg_entry(length=0x1000))
    resp = await wait_response(dut)

    assert resp["status"] == MR_TABLE_STATUS_LENGTH
    assert resp["error"] == MR_REG_ERR_LENGTH


@cocotb.test()
async def table_full_is_rejected(dut):
    await reset_dut(dut)
    dut.alloc_bitmap_reg.value = (1 << 1024) - 1

    await send_register(dut)
    resp = await wait_response(dut)

    assert resp["status"] == MR_TABLE_STATUS_FULL


@cocotb.test()
async def successful_response_returns_lkey_rkey_and_allocated_index(dut):
    await reset_dut(dut)
    dut.alloc_bitmap_reg.value = 0x1

    await send_register(dut, lkey=0x3001, rkey=0x4001, seq=0x99)
    await respond_sg_fetch(dut)
    _ = await respond_table_write(dut, status=MR_TABLE_STATUS_OK)
    resp = await wait_response(dut)

    assert resp["status"] == MR_TABLE_STATUS_OK
    assert resp["lkey"] == 0x3001
    assert resp["rkey"] == 0x4001
    assert resp["index"] == 1
    assert resp["seq"] == 0x99
