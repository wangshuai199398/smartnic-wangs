# SPDX-License-Identifier: MIT
"""MR table 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


MR_TABLE_STATUS_OK = 0
MR_TABLE_STATUS_MISS = 1
MR_TABLE_STATUS_PERMISSION = 2
MR_TABLE_STATUS_ALIAS = 3
MR_TABLE_STATUS_BOUNDS = 6
MR_TABLE_STATUS_LENGTH = 7
MR_TABLE_STATUS_REF_OVER = 8
MR_TABLE_STATUS_REF_UNDER = 9
MR_TABLE_STATUS_PENDING = 10


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

    dut.lookup_valid.value = 0
    dut.lookup_key.value = 0
    dut.lookup_is_remote.value = 0
    dut.lookup_owner_function.value = 0
    dut.lookup_pd_id.value = 0
    dut.lookup_admin_bypass.value = 0
    dut.lookup_rsp_ready.value = 0

    dut.check_valid.value = 0
    dut.check_key.value = 0
    dut.check_va.value = 0
    dut.check_len.value = 0
    dut.check_is_remote.value = 0
    dut.check_owner_function.value = 0
    dut.check_pd_id.value = 0
    dut.check_admin_bypass.value = 0
    dut.check_rsp_ready.value = 0

    dut.entry_write_valid.value = 0
    dut.entry_write_use_index.value = 0
    dut.entry_write_index.value = 0
    dut.entry_write_key.value = 0
    dut.entry_write_is_remote.value = 0
    dut.entry_write_owner_function.value = 0
    dut.entry_write_admin_bypass.value = 0
    dut.entry_write_data.value = 0
    dut.entry_write_rsp_ready.value = 0

    dut.entry_read_valid.value = 0
    dut.entry_read_key.value = 0
    dut.entry_read_is_remote.value = 0
    dut.entry_read_owner_function.value = 0
    dut.entry_read_pd_id.value = 0
    dut.entry_read_admin_bypass.value = 0
    dut.entry_read_rsp_ready.value = 0

    dut.ref_inc_valid.value = 0
    dut.ref_dec_valid.value = 0
    dut.ref_key.value = 0
    dut.ref_is_remote.value = 0
    dut.ref_owner_function.value = 0
    dut.ref_admin_bypass.value = 0
    dut.ref_update_rsp_ready.value = 0

    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def clear_response(dut, ready_name):
    getattr(dut, ready_name).value = 1
    await RisingEdge(dut.clk)
    getattr(dut, ready_name).value = 0


async def write_entry(dut, *, index=0, entry=None, owner=1, key=0x1001, is_remote=0):
    dut.entry_write_valid.value = 1
    dut.entry_write_use_index.value = 1
    dut.entry_write_index.value = index
    dut.entry_write_key.value = key
    dut.entry_write_is_remote.value = is_remote
    dut.entry_write_owner_function.value = owner
    dut.entry_write_admin_bypass.value = 0
    dut.entry_write_data.value = entry if entry is not None else pack_mr_entry(owner_function=owner)
    await RisingEdge(dut.clk)
    dut.entry_write_valid.value = 0
    status = int(dut.entry_write_status.value)
    await clear_response(dut, "entry_write_rsp_ready")
    return status


async def lookup_key(dut, *, key=0x1001, remote=0, owner=1, pd=3):
    dut.lookup_valid.value = 1
    dut.lookup_key.value = key
    dut.lookup_is_remote.value = remote
    dut.lookup_owner_function.value = owner
    dut.lookup_pd_id.value = pd
    await RisingEdge(dut.clk)
    dut.lookup_valid.value = 0
    result = {
        "status": int(dut.lookup_error_code.value),
        "hit": int(dut.lookup_hit.value),
        "entry": int(dut.lookup_entry.value),
    }
    await clear_response(dut, "lookup_rsp_ready")
    return result


async def check_range(dut, *, key=0x1001, remote=0, owner=1, pd=3, va=0x1000_0000, length=64):
    dut.check_valid.value = 1
    dut.check_key.value = key
    dut.check_is_remote.value = remote
    dut.check_owner_function.value = owner
    dut.check_pd_id.value = pd
    dut.check_va.value = va
    dut.check_len.value = length
    await RisingEdge(dut.clk)
    dut.check_valid.value = 0
    result = {
        "status": int(dut.check_error_code.value),
        "hit": int(dut.check_hit.value),
        "pa": int(dut.check_pa.value),
    }
    await clear_response(dut, "check_rsp_ready")
    return result


async def ref_update(dut, *, inc=0, dec=0, key=0x1001, remote=0, owner=1):
    dut.ref_inc_valid.value = inc
    dut.ref_dec_valid.value = dec
    dut.ref_key.value = key
    dut.ref_is_remote.value = remote
    dut.ref_owner_function.value = owner
    await RisingEdge(dut.clk)
    dut.ref_inc_valid.value = 0
    dut.ref_dec_valid.value = 0
    result = {
        "status": int(dut.ref_update_status.value),
        "refcount": int(dut.refcount_out.value),
        "zero": int(dut.refcount_zero.value),
    }
    await clear_response(dut, "ref_update_rsp_ready")
    return result


@cocotb.test()
async def write_and_lookup_mr_entry(dut):
    await reset_dut(dut)

    assert await write_entry(dut) == MR_TABLE_STATUS_OK
    result = await lookup_key(dut, key=0x1001, remote=0)

    assert result["status"] == MR_TABLE_STATUS_OK
    assert result["hit"] == 1
    assert extract_field(result["entry"], "lkey") == 0x1001
    assert extract_field(result["entry"], "rkey") == 0x2001


@cocotb.test()
async def lkey_lookup_and_rkey_lookup_succeed(dut):
    await reset_dut(dut)

    assert await write_entry(dut) == MR_TABLE_STATUS_OK
    lkey_result = await lookup_key(dut, key=0x1001, remote=0)
    rkey_result = await lookup_key(dut, key=0x2001, remote=1)

    assert lkey_result["status"] == MR_TABLE_STATUS_OK
    assert rkey_result["status"] == MR_TABLE_STATUS_OK
    assert extract_field(rkey_result["entry"], "rkey") == 0x2001


@cocotb.test()
async def lookup_does_not_fallback_between_lkey_and_rkey(dut):
    await reset_dut(dut)

    assert await write_entry(dut) == MR_TABLE_STATUS_OK
    local_using_rkey = await lookup_key(dut, key=0x2001, remote=0)
    remote_using_lkey = await lookup_key(dut, key=0x1001, remote=1)

    assert local_using_rkey["status"] == MR_TABLE_STATUS_MISS
    assert local_using_rkey["hit"] == 0
    assert remote_using_lkey["status"] == MR_TABLE_STATUS_MISS
    assert remote_using_lkey["hit"] == 0


@cocotb.test()
async def lookup_miss_returns_miss(dut):
    await reset_dut(dut)

    result = await lookup_key(dut, key=0xDEAD, remote=0)

    assert result["status"] == MR_TABLE_STATUS_MISS
    assert result["hit"] == 0


@cocotb.test()
async def duplicate_lkey_or_rkey_is_rejected(dut):
    await reset_dut(dut)

    assert await write_entry(dut, index=0) == MR_TABLE_STATUS_OK
    dup_lkey = pack_mr_entry(mr_id=8, lkey=0x1001, rkey=0x2002)
    dup_rkey = pack_mr_entry(mr_id=9, lkey=0x1002, rkey=0x2001)

    assert await write_entry(dut, index=1, entry=dup_lkey) == MR_TABLE_STATUS_ALIAS
    assert await write_entry(dut, index=2, entry=dup_rkey) == MR_TABLE_STATUS_ALIAS


@cocotb.test()
async def va_in_range_translates_to_pa(dut):
    await reset_dut(dut)

    assert await write_entry(dut) == MR_TABLE_STATUS_OK
    result = await check_range(dut, va=0x1000_0040, length=128)

    assert result["status"] == MR_TABLE_STATUS_OK
    assert result["hit"] == 1
    assert result["pa"] == 0x8000_0000 + 0x40


@cocotb.test()
async def va_below_base_is_rejected(dut):
    await reset_dut(dut)

    assert await write_entry(dut) == MR_TABLE_STATUS_OK
    result = await check_range(dut, va=0x0FFF_FFFF, length=1)

    assert result["status"] == MR_TABLE_STATUS_BOUNDS
    assert result["hit"] == 0


@cocotb.test()
async def va_plus_len_past_end_is_rejected(dut):
    await reset_dut(dut)

    assert await write_entry(dut) == MR_TABLE_STATUS_OK
    result = await check_range(dut, va=0x1000_0FF0, length=0x20)

    assert result["status"] == MR_TABLE_STATUS_BOUNDS
    assert result["hit"] == 0


@cocotb.test()
async def zero_length_check_is_rejected(dut):
    await reset_dut(dut)

    assert await write_entry(dut) == MR_TABLE_STATUS_OK
    result = await check_range(dut, va=0x1000_0000, length=0)

    assert result["status"] == MR_TABLE_STATUS_LENGTH
    assert result["hit"] == 0


@cocotb.test()
async def cross_function_access_is_denied(dut):
    await reset_dut(dut)

    assert await write_entry(dut, owner=2, entry=pack_mr_entry(owner_function=2)) == MR_TABLE_STATUS_OK
    result = await lookup_key(dut, key=0x1001, remote=0, owner=1)

    assert result["status"] == MR_TABLE_STATUS_PERMISSION
    assert result["hit"] == 0


@cocotb.test()
async def pending_deregister_rejects_new_lookup_and_check(dut):
    await reset_dut(dut)

    pending = pack_mr_entry(pending_deregister=1)
    assert await write_entry(dut, entry=pending) == MR_TABLE_STATUS_OK
    lookup = await lookup_key(dut, key=0x1001, remote=0)
    check = await check_range(dut, key=0x1001, remote=0)

    assert lookup["status"] == MR_TABLE_STATUS_PENDING
    assert lookup["hit"] == 0
    assert check["status"] == MR_TABLE_STATUS_PENDING
    assert check["hit"] == 0


@cocotb.test()
async def refcount_inc_and_dec_update_count(dut):
    await reset_dut(dut)

    assert await write_entry(dut) == MR_TABLE_STATUS_OK
    inc = await ref_update(dut, inc=1)
    dec = await ref_update(dut, dec=1)

    assert inc["status"] == MR_TABLE_STATUS_OK
    assert inc["refcount"] == 1
    assert inc["zero"] == 0
    assert dec["status"] == MR_TABLE_STATUS_OK
    assert dec["refcount"] == 0
    assert dec["zero"] == 1


@cocotb.test()
async def refcount_underflow_and_overflow_are_reported(dut):
    await reset_dut(dut)

    full_ref = pack_mr_entry(refcount=0xFFFF)
    assert await write_entry(dut, entry=full_ref) == MR_TABLE_STATUS_OK
    overflow = await ref_update(dut, inc=1)
    assert overflow["status"] == MR_TABLE_STATUS_REF_OVER

    zero_ref = pack_mr_entry(mr_id=8, lkey=0x1010, rkey=0x2020, refcount=0)
    assert await write_entry(dut, index=1, entry=zero_ref, key=0x1010) == MR_TABLE_STATUS_OK
    underflow = await ref_update(dut, dec=1, key=0x1010)
    assert underflow["status"] == MR_TABLE_STATUS_REF_UNDER
