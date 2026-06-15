# SPDX-License-Identifier: MIT
"""MR access permission checker 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


MR_ACCESS_LOCAL_READ = 0x01
MR_ACCESS_LOCAL_WRITE = 0x02
MR_ACCESS_REMOTE_READ = 0x04
MR_ACCESS_REMOTE_WRITE = 0x08
MR_ACCESS_REMOTE_ATOMIC = 0x10
MR_ACCESS_MW_BIND = 0x20
MR_ACCESS_ALL = 0x3F

MR_OP_LOCAL_READ = 0
MR_OP_LOCAL_WRITE = 1
MR_OP_LOCAL_RECV_WRITE = 2
MR_OP_REMOTE_READ = 3
MR_OP_REMOTE_WRITE = 4
MR_OP_REMOTE_ATOMIC = 5
MR_OP_MW_BIND = 6

MR_ACCESS_ERR_NONE = 0
MR_ACCESS_ERR_INVALID_ENTRY = 1
MR_ACCESS_ERR_PENDING = 2
MR_ACCESS_ERR_PERMISSION = 3
MR_ACCESS_ERR_LENGTH = 4
MR_ACCESS_ERR_BOUNDS = 5
MR_ACCESS_ERR_ADDR_OVERFLOW = 6
MR_ACCESS_ERR_ACCESS_DENIED = 7
MR_ACCESS_ERR_UNKNOWN_OPERATION = 8
MR_ACCESS_ERR_MW_PARENT = 9


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
        "access_flags": MR_ACCESS_ALL,
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

    dut.access_check_valid.value = 0
    dut.access_check_operation.value = 0
    dut.access_check_entry.value = 0
    dut.access_check_va.value = 0
    dut.access_check_len.value = 0
    dut.access_check_is_remote.value = 0
    dut.access_check_owner_function.value = 0
    dut.access_check_pd_id.value = 0
    dut.access_parent_permission_mask.value = 0
    dut.access_parent_permission_valid.value = 0
    dut.access_check_resp_ready.value = 0

    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def check_access(
    dut,
    *,
    operation=MR_OP_LOCAL_READ,
    entry=None,
    va=0x1000_0040,
    length=64,
    remote=0,
    owner=1,
    pd=3,
    parent_mask=0,
    parent_valid=0,
):
    dut.access_check_valid.value = 1
    dut.access_check_operation.value = operation
    dut.access_check_entry.value = entry if entry is not None else pack_mr_entry()
    dut.access_check_va.value = va
    dut.access_check_len.value = length
    dut.access_check_is_remote.value = remote
    dut.access_check_owner_function.value = owner
    dut.access_check_pd_id.value = pd
    dut.access_parent_permission_mask.value = parent_mask
    dut.access_parent_permission_valid.value = parent_valid
    await RisingEdge(dut.clk)
    dut.access_check_valid.value = 0

    for _ in range(4):
        await RisingEdge(dut.clk)
        if int(dut.access_check_resp_valid.value) == 1:
            result = {
                "allowed": int(dut.access_allowed.value),
                "pa": int(dut.access_physical_addr.value),
                "flags": int(dut.access_flags_used.value),
                "error": int(dut.access_error_code.value),
            }
            dut.access_check_resp_ready.value = 1
            await RisingEdge(dut.clk)
            dut.access_check_resp_ready.value = 0
            return result
    raise AssertionError("mr_access_checker did not produce response")


@cocotb.test()
async def local_read_with_local_read_permission_succeeds(dut):
    await reset_dut(dut)

    resp = await check_access(dut, operation=MR_OP_LOCAL_READ, entry=pack_mr_entry(access_flags=MR_ACCESS_LOCAL_READ))

    assert resp["allowed"] == 1
    assert resp["error"] == MR_ACCESS_ERR_NONE
    assert resp["flags"] == MR_ACCESS_LOCAL_READ
    assert resp["pa"] == 0x8000_0040


@cocotb.test()
async def local_write_with_local_write_permission_succeeds(dut):
    await reset_dut(dut)

    resp = await check_access(dut, operation=MR_OP_LOCAL_WRITE, entry=pack_mr_entry(access_flags=MR_ACCESS_LOCAL_WRITE))

    assert resp["allowed"] == 1
    assert resp["flags"] == MR_ACCESS_LOCAL_WRITE


@cocotb.test()
async def local_recv_write_with_local_write_permission_succeeds(dut):
    await reset_dut(dut)

    resp = await check_access(dut, operation=MR_OP_LOCAL_RECV_WRITE, entry=pack_mr_entry(access_flags=MR_ACCESS_LOCAL_WRITE))

    assert resp["allowed"] == 1
    assert resp["flags"] == MR_ACCESS_LOCAL_WRITE


@cocotb.test()
async def remote_read_with_remote_read_permission_succeeds(dut):
    await reset_dut(dut)

    resp = await check_access(
        dut,
        operation=MR_OP_REMOTE_READ,
        remote=1,
        entry=pack_mr_entry(access_flags=MR_ACCESS_REMOTE_READ),
    )

    assert resp["allowed"] == 1
    assert resp["flags"] == MR_ACCESS_REMOTE_READ


@cocotb.test()
async def remote_write_with_remote_write_permission_succeeds(dut):
    await reset_dut(dut)

    resp = await check_access(
        dut,
        operation=MR_OP_REMOTE_WRITE,
        remote=1,
        entry=pack_mr_entry(access_flags=MR_ACCESS_REMOTE_WRITE),
    )

    assert resp["allowed"] == 1
    assert resp["flags"] == MR_ACCESS_REMOTE_WRITE


@cocotb.test()
async def remote_atomic_with_remote_atomic_permission_succeeds(dut):
    await reset_dut(dut)

    resp = await check_access(
        dut,
        operation=MR_OP_REMOTE_ATOMIC,
        remote=1,
        entry=pack_mr_entry(access_flags=MR_ACCESS_REMOTE_ATOMIC),
    )

    assert resp["allowed"] == 1
    assert resp["flags"] == MR_ACCESS_REMOTE_ATOMIC


@cocotb.test()
async def mw_bind_with_mw_bind_permission_succeeds(dut):
    await reset_dut(dut)

    resp = await check_access(dut, operation=MR_OP_MW_BIND, entry=pack_mr_entry(access_flags=MR_ACCESS_MW_BIND))

    assert resp["allowed"] == 1
    assert resp["flags"] == MR_ACCESS_MW_BIND


@cocotb.test()
async def missing_required_permission_is_rejected(dut):
    await reset_dut(dut)

    cases = [
        (MR_OP_LOCAL_READ, 0, MR_ACCESS_LOCAL_WRITE),
        (MR_OP_LOCAL_WRITE, 0, MR_ACCESS_LOCAL_READ),
        (MR_OP_REMOTE_READ, 1, MR_ACCESS_REMOTE_WRITE),
        (MR_OP_REMOTE_WRITE, 1, MR_ACCESS_REMOTE_READ),
        (MR_OP_REMOTE_ATOMIC, 1, MR_ACCESS_REMOTE_READ),
        (MR_OP_MW_BIND, 0, MR_ACCESS_LOCAL_READ),
    ]

    for operation, remote, flags in cases:
        resp = await check_access(dut, operation=operation, remote=remote, entry=pack_mr_entry(access_flags=flags))
        assert resp["allowed"] == 0
        assert resp["error"] == MR_ACCESS_ERR_ACCESS_DENIED


@cocotb.test()
async def invalid_pending_zero_length_bounds_and_owner_are_rejected(dut):
    await reset_dut(dut)

    invalid = await check_access(dut, entry=pack_mr_entry(valid=0))
    pending = await check_access(dut, entry=pack_mr_entry(pending_deregister=1))
    invalidating_mw = await check_access(
        dut,
        operation=MR_OP_REMOTE_READ,
        remote=1,
        entry=pack_mr_entry(
            memory_window=1,
            invalidating=1,
            access_flags=MR_ACCESS_REMOTE_READ,
        ),
    )
    zero_len = await check_access(dut, length=0)
    bounds = await check_access(dut, va=0x1000_0FF0, length=0x20)
    owner = await check_access(dut, owner=2)

    assert invalid["error"] == MR_ACCESS_ERR_INVALID_ENTRY
    assert pending["error"] == MR_ACCESS_ERR_PENDING
    assert invalidating_mw["error"] == MR_ACCESS_ERR_PENDING
    assert zero_len["error"] == MR_ACCESS_ERR_LENGTH
    assert bounds["error"] == MR_ACCESS_ERR_BOUNDS
    assert owner["error"] == MR_ACCESS_ERR_PERMISSION


@cocotb.test()
async def address_overflow_unknown_operation_and_mw_parent_are_rejected(dut):
    await reset_dut(dut)

    overflow_entry = pack_mr_entry(virtual_base_addr=(1 << 64) - 16, physical_base_addr=0x8000_0000, length=64)
    overflow = await check_access(dut, entry=overflow_entry, va=(1 << 64) - 8, length=32)
    unknown = await check_access(dut, operation=15)
    parent = await check_access(
        dut,
        operation=MR_OP_MW_BIND,
        entry=pack_mr_entry(access_flags=MR_ACCESS_MW_BIND, memory_window=1),
        parent_mask=MR_ACCESS_LOCAL_READ,
        parent_valid=1,
    )

    assert overflow["error"] == MR_ACCESS_ERR_ADDR_OVERFLOW
    assert unknown["error"] == MR_ACCESS_ERR_UNKNOWN_OPERATION
    assert parent["error"] == MR_ACCESS_ERR_MW_PARENT
