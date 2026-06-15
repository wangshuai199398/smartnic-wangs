# SPDX-License-Identifier: MIT
"""Memory Window manager 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


MR_TABLE_STATUS_OK = 0
MR_TABLE_STATUS_MISS = 1
MR_TABLE_STATUS_ALIAS = 3
MR_TABLE_STATUS_INVALID = 5
MR_TABLE_STATUS_BOUNDS = 6
MR_TABLE_STATUS_LENGTH = 7
MR_TABLE_STATUS_PENDING = 10

MW_ERR_NONE = 0
MW_ERR_PARENT_MISS = 1
MW_ERR_PARENT_PENDING = 2
MW_ERR_PARENT_IS_MW = 3
MW_ERR_RANGE = 4
MW_ERR_LENGTH = 5
MW_ERR_RKEY = 6
MW_ERR_ALIAS = 7
MW_ERR_PERMISSION_SUBSET = 8
MW_ERR_NOT_MW = 0x000C

MR_ACCESS_REMOTE_READ = 0x04
MR_ACCESS_REMOTE_WRITE = 0x08
MR_ACCESS_REMOTE_ATOMIC = 0x10
MR_ACCESS_MW_BIND = 0x20


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
        "length": 0x2000,
        "page_size": 12,
        "access_flags": MR_ACCESS_REMOTE_READ | MR_ACCESS_REMOTE_WRITE | MR_ACCESS_REMOTE_ATOMIC,
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

    dut.mw_bind_req_valid.value = 0
    dut.mw_bind_req_owner_function.value = 0
    dut.mw_bind_req_pd_id.value = 0
    dut.mw_bind_req_qpn.value = 0
    dut.mw_bind_req_parent_lkey.value = 0
    dut.mw_bind_req_mw_rkey.value = 0
    dut.mw_bind_req_virtual_base_addr.value = 0
    dut.mw_bind_req_length.value = 0
    dut.mw_bind_req_access_flags.value = 0
    dut.mw_bind_req_cmd_sequence.value = 0

    dut.mw_unbind_req_valid.value = 0
    dut.mw_unbind_req_owner_function.value = 0
    dut.mw_unbind_req_pd_id.value = 0
    dut.mw_unbind_req_mw_rkey.value = 0
    dut.mw_unbind_req_cmd_sequence.value = 0

    dut.qp_error_invalidate_valid.value = 0
    dut.qp_error_qpn.value = 0
    dut.qp_error_owner_function.value = 0
    dut.qp_error_pd_id.value = 0
    dut.qp_error_reason.value = 0
    dut.mw_resp_ready.value = 0

    dut.mr_entry_read_ready.value = 1
    dut.mr_entry_read_rsp_valid.value = 0
    dut.mr_entry_read_hit.value = 0
    dut.mr_entry_read_data.value = 0
    dut.mr_entry_read_status.value = MR_TABLE_STATUS_MISS

    dut.mr_entry_write_ready.value = 1
    dut.mr_entry_write_rsp_valid.value = 0
    dut.mr_entry_write_status.value = MR_TABLE_STATUS_OK

    dut.mw_scan_req_ready.value = 1
    dut.mw_scan_rsp_valid.value = 0
    dut.mw_scan_hit.value = 0
    dut.mw_scan_entry.value = 0
    dut.mw_scan_done.value = 0

    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_bind(dut, *, length=0x1000, flags=MR_ACCESS_REMOTE_READ, rkey=0x3001, va=0x1000_0100):
    dut.mw_bind_req_valid.value = 1
    dut.mw_bind_req_owner_function.value = 1
    dut.mw_bind_req_pd_id.value = 3
    dut.mw_bind_req_qpn.value = 0x55
    dut.mw_bind_req_parent_lkey.value = 0x1001
    dut.mw_bind_req_mw_rkey.value = rkey
    dut.mw_bind_req_virtual_base_addr.value = va
    dut.mw_bind_req_length.value = length
    dut.mw_bind_req_access_flags.value = flags
    dut.mw_bind_req_cmd_sequence.value = 0x44
    await RisingEdge(dut.clk)
    dut.mw_bind_req_valid.value = 0


async def send_unbind(dut, *, rkey=0x3001):
    dut.mw_unbind_req_valid.value = 1
    dut.mw_unbind_req_owner_function.value = 1
    dut.mw_unbind_req_pd_id.value = 3
    dut.mw_unbind_req_mw_rkey.value = rkey
    dut.mw_unbind_req_cmd_sequence.value = 0x55
    await RisingEdge(dut.clk)
    dut.mw_unbind_req_valid.value = 0


async def send_qp_error(dut):
    dut.qp_error_invalidate_valid.value = 1
    dut.qp_error_qpn.value = 0x55
    dut.qp_error_owner_function.value = 1
    dut.qp_error_pd_id.value = 3
    dut.qp_error_reason.value = 0x99
    await RisingEdge(dut.clk)
    dut.qp_error_invalidate_valid.value = 0


async def respond_read(dut, *, hit=True, status=MR_TABLE_STATUS_OK, entry=None):
    for _ in range(32):
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
    for _ in range(32):
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


async def respond_scan(dut, *, hit=True, done=False, entry=None):
    for _ in range(32):
        await Timer(1, units="ns")
        if int(dut.mw_scan_req_valid.value) == 1:
            break
        await RisingEdge(dut.clk)
    assert int(dut.mw_scan_req_valid.value) == 1
    await RisingEdge(dut.clk)
    dut.mw_scan_rsp_valid.value = 1
    dut.mw_scan_hit.value = 1 if hit else 0
    dut.mw_scan_done.value = 1 if done else 0
    dut.mw_scan_entry.value = entry if entry is not None else pack_mr_entry(
        rkey=0x3001, memory_window=1, bound_qpn=0x55, parent_mr_key=0x1001
    )
    await RisingEdge(dut.clk)
    dut.mw_scan_rsp_valid.value = 0


async def wait_response(dut, max_cycles=64):
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        if int(dut.mw_resp_valid.value) == 1:
            result = {
                "status": int(dut.mw_resp_status.value),
                "error": int(dut.mw_resp_error_code.value),
                "rkey": int(dut.mw_resp_mw_rkey.value),
                "seq": int(dut.mw_resp_cmd_sequence.value),
            }
            dut.mw_resp_ready.value = 1
            await RisingEdge(dut.clk)
            dut.mw_resp_ready.value = 0
            return result
    raise AssertionError("mr_memory_window_manager did not produce response")


@cocotb.test()
async def legal_bind_creates_memory_window_entry(dut):
    await reset_dut(dut)

    await send_bind(dut)
    await respond_read(dut, entry=pack_mr_entry())
    await respond_read(dut, hit=False, status=MR_TABLE_STATUS_MISS, entry=0)
    mw = await respond_write(dut)
    resp = await wait_response(dut)

    assert mw["valid"] == 1
    assert mw["memory_window"] == 1
    assert mw["rkey"] == 0x3001
    assert mw["parent_mr_key"] == 0x1001
    assert mw["bound_qpn"] == 0x55
    assert mw["physical_base_addr"] == 0x8000_0100
    assert resp["status"] == MR_TABLE_STATUS_OK
    assert resp["error"] == MW_ERR_NONE


@cocotb.test()
async def bind_validation_errors_are_reported(dut):
    await reset_dut(dut)
    await send_bind(dut, length=0)
    resp = await wait_response(dut)
    assert resp["error"] == MW_ERR_LENGTH

    await send_bind(dut, rkey=0)
    resp = await wait_response(dut)
    assert resp["error"] == MW_ERR_RKEY

    await send_bind(dut, va=0x1000_1F00, length=0x2000)
    await respond_read(dut, entry=pack_mr_entry())
    resp = await wait_response(dut)
    assert resp["error"] == MW_ERR_RANGE


@cocotb.test()
async def parent_pending_parent_mw_permission_subset_and_alias_are_rejected(dut):
    await reset_dut(dut)

    await send_bind(dut)
    await respond_read(dut, entry=pack_mr_entry(pending_deregister=1))
    assert (await wait_response(dut))["error"] == MW_ERR_PARENT_PENDING

    await send_bind(dut)
    await respond_read(dut, entry=pack_mr_entry(memory_window=1))
    assert (await wait_response(dut))["error"] == MW_ERR_PARENT_IS_MW

    await send_bind(dut, flags=MR_ACCESS_REMOTE_ATOMIC)
    await respond_read(dut, entry=pack_mr_entry(access_flags=MR_ACCESS_REMOTE_READ))
    assert (await wait_response(dut))["error"] == MW_ERR_PERMISSION_SUBSET

    await send_bind(dut)
    await respond_read(dut, entry=pack_mr_entry())
    await respond_read(dut, hit=True, status=MR_TABLE_STATUS_OK, entry=pack_mr_entry(rkey=0x3001))
    assert (await wait_response(dut))["error"] == MW_ERR_ALIAS


@cocotb.test()
async def legal_unbind_clears_memory_window(dut):
    await reset_dut(dut)

    mw_entry = pack_mr_entry(rkey=0x3001, memory_window=1, parent_mr_key=0x1001)
    await send_unbind(dut)
    await respond_read(dut, entry=mw_entry)
    pending = await respond_write(dut)
    cleared = await respond_write(dut)
    resp = await wait_response(dut)

    assert pending["pending_deregister"] == 1
    assert pending["invalidating"] == 1
    assert cleared["valid"] == 0
    assert resp["error"] == MW_ERR_NONE


@cocotb.test()
async def unbind_non_mw_is_rejected_and_refcount_drain_waits(dut):
    await reset_dut(dut)

    await send_unbind(dut)
    await respond_read(dut, entry=pack_mr_entry(memory_window=0))
    assert (await wait_response(dut))["error"] == MW_ERR_NOT_MW

    await send_unbind(dut)
    await respond_read(dut, entry=pack_mr_entry(rkey=0x3001, memory_window=1, refcount=2))
    pending = await respond_write(dut)
    await respond_read(dut, entry=pack_mr_entry(rkey=0x3001, memory_window=1, refcount=0, pending_deregister=1, invalidating=1))
    cleared = await respond_write(dut)
    resp = await wait_response(dut)

    assert pending["invalidating"] == 1
    assert cleared["valid"] == 0
    assert resp["error"] == MW_ERR_NONE


@cocotb.test()
async def qp_error_invalidates_bound_memory_window(dut):
    await reset_dut(dut)

    await send_qp_error(dut)
    await respond_scan(dut, hit=True, entry=pack_mr_entry(rkey=0x3001, memory_window=1, bound_qpn=0x55))
    pending = await respond_write(dut)
    cleared = await respond_write(dut)
    resp = await wait_response(dut)

    assert pending["invalidating"] == 1
    assert cleared["valid"] == 0
    assert resp["error"] == MW_ERR_NONE
    assert resp["seq"] == 0x99
