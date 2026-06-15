# SPDX-License-Identifier: MIT
"""MR key direction checker 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


MR_TABLE_STATUS_OK = 0
MR_TABLE_STATUS_MISS = 1
MR_TABLE_STATUS_PERMISSION = 2
MR_TABLE_STATUS_BOUNDS = 6
MR_TABLE_STATUS_LENGTH = 7
MR_TABLE_STATUS_PENDING = 10

MR_OP_LOCAL_DMA_READ = 0
MR_OP_LOCAL_DMA_WRITE = 1
MR_OP_LOCAL_RECV_WRITE = 2
MR_OP_REMOTE_RDMA_READ = 3
MR_OP_REMOTE_RDMA_WRITE = 4
MR_OP_REMOTE_ATOMIC = 5
MR_OP_MW_BIND = 6

MR_KEY_CHECK_ERR_NONE = 0
MR_KEY_CHECK_ERR_INVALID_KEY = 1
MR_KEY_CHECK_ERR_LOCAL_KEY_REQUIRED = 2
MR_KEY_CHECK_ERR_REMOTE_KEY_REQUIRED = 3
MR_KEY_CHECK_ERR_LOOKUP_MISS = 5
MR_KEY_CHECK_ERR_PERMISSION = 6
MR_KEY_CHECK_ERR_PENDING = 7
MR_KEY_CHECK_ERR_LENGTH = 8
MR_KEY_CHECK_ERR_BOUNDS = 9


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


def extract_field(packed, field_name):
    offset = 0
    for name, width in reversed(MR_ENTRY_FIELDS):
        if name == field_name:
            return (int(packed) >> offset) & ((1 << width) - 1)
        offset += width
    raise KeyError(field_name)


def pack_mr_entry(**overrides):
    values = {
        "valid": 1,
        "mr_id": 7,
        "lkey": 0x1001,
        "rkey": 0x2001,
        "virtual_base_addr": 0x1000_0000,
        "physical_base_addr": 0x8000_0000,
        "length": 0x1000,
        "page_size": 12,
        "access_flags": 0x0F,
        "pd_id": 3,
        "owner_function": 1,
        "refcount": 0,
        "pending_deregister": 0,
        "memory_window": 0,
        "invalidating": 0,
        "bound_qpn": 0,
        "parent_mr_key": 0,
        "error_state": 0,
        "error_code": 0,
    }
    values.update(overrides)
    return pack_fields(MR_ENTRY_FIELDS, values)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0

    dut.key_check_valid.value = 0
    dut.key_check_key.value = 0
    dut.key_check_is_remote.value = 0
    dut.key_check_operation.value = 0
    dut.key_check_owner_function.value = 0
    dut.key_check_pd_id.value = 0
    dut.key_check_va.value = 0
    dut.key_check_len.value = 0
    dut.key_check_resp_ready.value = 0

    dut.mr_check_ready.value = 1
    dut.mr_check_rsp_valid.value = 0
    dut.mr_check_hit.value = 0
    dut.mr_check_entry.value = 0
    dut.mr_check_pa.value = 0
    dut.mr_check_error_code.value = MR_TABLE_STATUS_MISS

    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_check(
    dut,
    *,
    key=0x1001,
    remote=0,
    operation=MR_OP_LOCAL_DMA_READ,
    owner=1,
    pd=3,
    va=0x1000_0040,
    length=64,
):
    dut.key_check_valid.value = 1
    dut.key_check_key.value = key
    dut.key_check_is_remote.value = remote
    dut.key_check_operation.value = operation
    dut.key_check_owner_function.value = owner
    dut.key_check_pd_id.value = pd
    dut.key_check_va.value = va
    dut.key_check_len.value = length
    await RisingEdge(dut.clk)
    dut.key_check_valid.value = 0


async def respond_table(
    dut,
    *,
    hit=True,
    status=MR_TABLE_STATUS_OK,
    entry=None,
    pa=0x8000_0040,
):
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.mr_check_valid.value) == 1:
            break
        await RisingEdge(dut.clk)

    assert int(dut.mr_check_valid.value) == 1
    await RisingEdge(dut.clk)
    dut.mr_check_rsp_valid.value = 1
    dut.mr_check_hit.value = 1 if hit else 0
    dut.mr_check_entry.value = entry if entry is not None else pack_mr_entry()
    dut.mr_check_pa.value = pa
    dut.mr_check_error_code.value = status
    await RisingEdge(dut.clk)
    dut.mr_check_rsp_valid.value = 0


async def wait_response(dut, max_cycles=32):
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        if int(dut.key_check_resp_valid.value) == 1:
            result = {
                "allowed": int(dut.key_check_allowed.value),
                "entry": int(dut.key_check_entry.value),
                "pa": int(dut.key_check_physical_addr.value),
                "error": int(dut.key_check_error_code.value),
            }
            dut.key_check_resp_ready.value = 1
            await RisingEdge(dut.clk)
            dut.key_check_resp_ready.value = 0
            return result
    raise AssertionError("mr_key_checker did not produce response")


@cocotb.test()
async def local_operation_with_lkey_succeeds(dut):
    await reset_dut(dut)

    await send_check(dut, key=0x1001, remote=0, operation=MR_OP_LOCAL_DMA_READ)
    await respond_table(dut, hit=True, status=MR_TABLE_STATUS_OK)
    resp = await wait_response(dut)

    assert int(dut.mr_check_is_remote.value) == 0
    assert int(dut.mr_check_key.value) == 0x1001
    assert resp["allowed"] == 1
    assert resp["error"] == MR_KEY_CHECK_ERR_NONE
    assert resp["pa"] == 0x8000_0040
    assert extract_field(resp["entry"], "lkey") == 0x1001


@cocotb.test()
async def remote_operation_with_rkey_succeeds(dut):
    await reset_dut(dut)

    await send_check(dut, key=0x2001, remote=1, operation=MR_OP_REMOTE_RDMA_WRITE)
    await respond_table(dut, hit=True, status=MR_TABLE_STATUS_OK)
    resp = await wait_response(dut)

    assert int(dut.mr_check_is_remote.value) == 1
    assert int(dut.mr_check_key.value) == 0x2001
    assert resp["allowed"] == 1
    assert resp["error"] == MR_KEY_CHECK_ERR_NONE
    assert extract_field(resp["entry"], "rkey") == 0x2001


@cocotb.test()
async def local_operation_using_rkey_is_rejected(dut):
    await reset_dut(dut)

    await send_check(dut, key=0x2001, remote=1, operation=MR_OP_LOCAL_DMA_WRITE)
    resp = await wait_response(dut)

    assert resp["allowed"] == 0
    assert resp["error"] == MR_KEY_CHECK_ERR_LOCAL_KEY_REQUIRED
    assert int(dut.mr_check_valid.value) == 0


@cocotb.test()
async def remote_operation_using_lkey_is_rejected(dut):
    await reset_dut(dut)

    await send_check(dut, key=0x1001, remote=0, operation=MR_OP_REMOTE_RDMA_READ)
    resp = await wait_response(dut)

    assert resp["allowed"] == 0
    assert resp["error"] == MR_KEY_CHECK_ERR_REMOTE_KEY_REQUIRED
    assert int(dut.mr_check_valid.value) == 0


@cocotb.test()
async def lookup_miss_is_reported(dut):
    await reset_dut(dut)

    await send_check(dut, key=0xDEAD, remote=0)
    await respond_table(dut, hit=False, status=MR_TABLE_STATUS_MISS, entry=0, pa=0)
    resp = await wait_response(dut)

    assert resp["allowed"] == 0
    assert resp["error"] == MR_KEY_CHECK_ERR_LOOKUP_MISS


@cocotb.test()
async def pending_deregister_is_rejected(dut):
    await reset_dut(dut)

    await send_check(dut, key=0x1001, remote=0)
    await respond_table(
        dut,
        hit=False,
        status=MR_TABLE_STATUS_PENDING,
        entry=pack_mr_entry(pending_deregister=1),
        pa=0,
    )
    resp = await wait_response(dut)

    assert resp["allowed"] == 0
    assert resp["error"] == MR_KEY_CHECK_ERR_PENDING


@cocotb.test()
async def cross_function_access_is_denied(dut):
    await reset_dut(dut)

    await send_check(dut, key=0x1001, remote=0, owner=2)
    await respond_table(dut, hit=False, status=MR_TABLE_STATUS_PERMISSION, pa=0)
    resp = await wait_response(dut)

    assert resp["allowed"] == 0
    assert resp["error"] == MR_KEY_CHECK_ERR_PERMISSION


@cocotb.test()
async def zero_length_is_rejected(dut):
    await reset_dut(dut)

    await send_check(dut, key=0x1001, remote=0, length=0)
    await respond_table(dut, hit=False, status=MR_TABLE_STATUS_LENGTH, pa=0)
    resp = await wait_response(dut)

    assert resp["allowed"] == 0
    assert resp["error"] == MR_KEY_CHECK_ERR_LENGTH


@cocotb.test()
async def bounds_error_is_rejected(dut):
    await reset_dut(dut)

    await send_check(dut, key=0x1001, remote=0, va=0x1000_0FF0, length=0x20)
    await respond_table(dut, hit=False, status=MR_TABLE_STATUS_BOUNDS, pa=0)
    resp = await wait_response(dut)

    assert resp["allowed"] == 0
    assert resp["error"] == MR_KEY_CHECK_ERR_BOUNDS


@cocotb.test()
async def invalid_key_is_rejected_before_table_lookup(dut):
    await reset_dut(dut)

    await send_check(dut, key=0, remote=0)
    resp = await wait_response(dut)

    assert resp["allowed"] == 0
    assert resp["error"] == MR_KEY_CHECK_ERR_INVALID_KEY
    assert int(dut.mr_check_valid.value) == 0
