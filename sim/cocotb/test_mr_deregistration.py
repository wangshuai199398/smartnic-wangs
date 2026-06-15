# SPDX-License-Identifier: MIT
"""MR deregistration manager 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


MR_TABLE_STATUS_OK = 0
MR_TABLE_STATUS_MISS = 1
MR_TABLE_STATUS_PERMISSION = 2
MR_TABLE_STATUS_INVALID = 5
MR_TABLE_STATUS_PENDING = 10

MR_DEREG_ERR_NONE = 0
MR_DEREG_ERR_LOOKUP_MISS = 2
MR_DEREG_ERR_PERMISSION = 3
MR_DEREG_ERR_PD_MISMATCH = 4
MR_DEREG_ERR_PENDING = 5
MR_DEREG_ERR_TIMEOUT = 6


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

    dut.dereg_req_valid.value = 0
    dut.dereg_req_owner_function.value = 0
    dut.dereg_req_key.value = 0
    dut.dereg_req_is_remote_key.value = 0
    dut.dereg_req_pd_id.value = 0
    dut.dereg_req_force.value = 0
    dut.dereg_req_cmd_sequence.value = 0
    dut.dereg_resp_ready.value = 0

    dut.mr_entry_read_ready.value = 1
    dut.mr_entry_read_rsp_valid.value = 0
    dut.mr_entry_read_hit.value = 0
    dut.mr_entry_read_data.value = 0
    dut.mr_entry_read_status.value = MR_TABLE_STATUS_MISS

    dut.mr_entry_write_ready.value = 1
    dut.mr_entry_write_rsp_valid.value = 0
    dut.mr_entry_write_status.value = MR_TABLE_STATUS_OK

    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_deregister(dut, *, owner=1, key=0x1001, remote=0, pd=3, force=0, seq=0x44):
    dut.dereg_req_valid.value = 1
    dut.dereg_req_owner_function.value = owner
    dut.dereg_req_key.value = key
    dut.dereg_req_is_remote_key.value = remote
    dut.dereg_req_pd_id.value = pd
    dut.dereg_req_force.value = force
    dut.dereg_req_cmd_sequence.value = seq
    await RisingEdge(dut.clk)
    dut.dereg_req_valid.value = 0


async def respond_read(dut, *, hit=True, status=MR_TABLE_STATUS_OK, entry=None):
    for _ in range(16):
        await Timer(1, units="ns")
        if int(dut.mr_entry_read_valid.value) == 1:
            break
        await RisingEdge(dut.clk)

    assert int(dut.mr_entry_read_valid.value) == 1
    await RisingEdge(dut.clk)
    dut.mr_entry_read_rsp_valid.value = 1
    dut.mr_entry_read_hit.value = 1 if hit else 0
    dut.mr_entry_read_status.value = status
    dut.mr_entry_read_data.value = entry if entry is not None else pack_mr_entry()
    await RisingEdge(dut.clk)
    dut.mr_entry_read_rsp_valid.value = 0


async def respond_write(dut, *, status=MR_TABLE_STATUS_OK):
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


async def wait_response(dut, max_cycles=32):
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        if int(dut.dereg_resp_valid.value) == 1:
            result = {
                "status": int(dut.dereg_resp_status.value),
                "error": int(dut.dereg_resp_error_code.value),
                "key": int(dut.dereg_resp_key.value),
                "seq": int(dut.dereg_resp_cmd_sequence.value),
            }
            dut.dereg_resp_ready.value = 1
            await RisingEdge(dut.clk)
            dut.dereg_resp_ready.value = 0
            return result
    raise AssertionError("mr_deregistration_manager did not produce response")


@cocotb.test()
async def refcount_zero_deregister_succeeds_and_clears_entry(dut):
    await reset_dut(dut)

    await send_deregister(dut)
    await respond_read(dut, entry=pack_mr_entry(refcount=0))
    pending = await respond_write(dut)
    cleared = await respond_write(dut)
    resp = await wait_response(dut)

    assert pending["pending_deregister"] == 1
    assert pending["valid"] == 1
    assert cleared["valid"] == 0
    assert cleared["pending_deregister"] == 0
    assert cleared["refcount"] == 0
    assert cleared["access_flags"] == 0
    assert resp["status"] == MR_TABLE_STATUS_OK
    assert resp["error"] == MR_DEREG_ERR_NONE
    assert resp["key"] == 0x1001
    assert resp["seq"] == 0x44


@cocotb.test()
async def refcount_nonzero_marks_pending_and_waits(dut):
    await reset_dut(dut)

    await send_deregister(dut)
    await respond_read(dut, entry=pack_mr_entry(refcount=2))
    pending = await respond_write(dut)

    assert pending["pending_deregister"] == 1
    assert pending["valid"] == 1
    await Timer(1, units="ns")
    assert int(dut.dereg_resp_valid.value) == 0


@cocotb.test()
async def refcount_drain_to_zero_clears_entry(dut):
    await reset_dut(dut)

    await send_deregister(dut)
    await respond_read(dut, entry=pack_mr_entry(refcount=2))
    _ = await respond_write(dut)
    await respond_read(dut, entry=pack_mr_entry(refcount=0, pending_deregister=1))
    cleared = await respond_write(dut)
    resp = await wait_response(dut)

    assert cleared["valid"] == 0
    assert resp["status"] == MR_TABLE_STATUS_OK


@cocotb.test()
async def lookup_miss_returns_error(dut):
    await reset_dut(dut)

    await send_deregister(dut)
    await respond_read(dut, hit=False, status=MR_TABLE_STATUS_MISS, entry=0)
    resp = await wait_response(dut)

    assert resp["status"] == MR_TABLE_STATUS_MISS
    assert resp["error"] == MR_DEREG_ERR_LOOKUP_MISS


@cocotb.test()
async def cross_function_deregister_is_rejected(dut):
    await reset_dut(dut)

    await send_deregister(dut, owner=2)
    await respond_read(dut, hit=True, status=MR_TABLE_STATUS_PERMISSION, entry=pack_mr_entry())
    resp = await wait_response(dut)

    assert resp["status"] == MR_TABLE_STATUS_PERMISSION
    assert resp["error"] == MR_DEREG_ERR_PERMISSION


@cocotb.test()
async def pd_mismatch_is_rejected(dut):
    await reset_dut(dut)

    await send_deregister(dut, pd=4)
    await respond_read(dut, entry=pack_mr_entry(pd_id=3))
    resp = await wait_response(dut)

    assert resp["status"] == MR_TABLE_STATUS_INVALID
    assert resp["error"] == MR_DEREG_ERR_PD_MISMATCH


@cocotb.test()
async def timeout_returns_error(dut):
    await reset_dut(dut)

    await send_deregister(dut)
    await respond_read(dut, entry=pack_mr_entry(refcount=1))
    _ = await respond_write(dut)

    resp = await wait_response(dut, max_cycles=1100)
    assert resp["status"] == MR_TABLE_STATUS_INVALID
    assert resp["error"] == MR_DEREG_ERR_TIMEOUT


@cocotb.test()
async def repeated_deregister_pending_mr_returns_pending_error(dut):
    await reset_dut(dut)

    await send_deregister(dut)
    await respond_read(dut, entry=pack_mr_entry(refcount=1, pending_deregister=1))
    resp = await wait_response(dut)

    assert resp["status"] == MR_TABLE_STATUS_PENDING
    assert resp["error"] == MR_DEREG_ERR_PENDING
