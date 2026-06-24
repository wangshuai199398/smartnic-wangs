# SPDX-License-Identifier: MIT
"""Address Handle table tests for task 9.7."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


AH_TABLE_STATUS_OK = 0
AH_TABLE_STATUS_MISS = 1
AH_TABLE_STATUS_ALIAS = 2
AH_TABLE_STATUS_PERMISSION = 3
AH_TABLE_STATUS_INVALID = 5


AH_FIELDS = [
    ("valid", 1), ("owner_func", 16), ("ah_id", 24), ("pd_id", 24),
    ("dst_mac", 48), ("dst_ipv4", 32), ("udp_src_port", 16),
    ("udp_dst_port", 16), ("pkey", 16), ("qkey", 32),
    ("traffic_class", 8), ("hop_limit", 8), ("service_level", 3),
    ("dgid_hi", 64), ("dgid_lo", 64), ("sgid_index", 8), ("flow_label", 20),
]


def pack_fields(fields, values):
    packed = 0
    for name, width in fields:
        packed = (packed << width) | (values.get(name, 0) & ((1 << width) - 1))
    return packed


def extract_field(fields, packed, name):
    bit = sum(width for _, width in fields)
    for field_name, width in fields:
        bit -= width
        if field_name == name:
            return (packed >> bit) & ((1 << width) - 1)
    raise KeyError(name)


def pack_ah(**overrides):
    values = {
        "valid": 1,
        "owner_func": 1,
        "ah_id": 0x22,
        "pd_id": 7,
        "dst_mac": 0xAABBCCDDEEFF,
        "dst_ipv4": 0x0A000002,
        "udp_src_port": 0xC001,
        "udp_dst_port": 4791,
        "pkey": 0xFFFF,
        "qkey": 0x11223344,
        "traffic_class": 0x2A,
        "hop_limit": 64,
        "service_level": 5,
        "dgid_hi": 0xFE80000000000000,
        "dgid_lo": 0x0000000000000002,
        "sgid_index": 3,
        "flow_label": 0x12345,
    }
    values.update(overrides)
    return pack_fields(AH_FIELDS, values)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.create_valid.value = 0
    dut.create_entry.value = 0
    dut.create_rsp_ready.value = 1
    dut.update_valid.value = 0
    dut.update_ah_id.value = 0
    dut.update_owner_function.value = 0
    dut.update_pd_id.value = 0
    dut.update_entry.value = 0
    dut.update_rsp_ready.value = 1
    dut.lookup_valid.value = 0
    dut.lookup_ah_id.value = 0
    dut.lookup_owner_function.value = 0
    dut.lookup_pd_id.value = 0
    dut.lookup_rsp_ready.value = 1
    dut.delete_valid.value = 0
    dut.delete_ah_id.value = 0
    dut.delete_owner_function.value = 0
    dut.delete_pd_id.value = 0
    dut.delete_rsp_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def wait_for(dut, name, cycles=32):
    sig = getattr(dut, name)
    for _ in range(cycles):
        await Timer(1, units="ns")
        if int(sig.value) == 1:
            await RisingEdge(dut.clk)
            return
        await RisingEdge(dut.clk)
    raise AssertionError(f"{name} not asserted")


async def create_ah(dut, entry=None):
    dut.create_entry.value = pack_ah() if entry is None else entry
    dut.create_valid.value = 1
    await RisingEdge(dut.clk)
    dut.create_valid.value = 0
    await wait_for(dut, "create_rsp_valid")
    return int(dut.create_status.value)


async def lookup_ah(dut, ah_id=0x22, owner=1, pd=7):
    dut.lookup_ah_id.value = ah_id
    dut.lookup_owner_function.value = owner
    dut.lookup_pd_id.value = pd
    dut.lookup_valid.value = 1
    await RisingEdge(dut.clk)
    dut.lookup_valid.value = 0
    await wait_for(dut, "lookup_rsp_valid")
    return int(dut.lookup_status.value), int(dut.lookup_hit.value), int(dut.lookup_entry.value)


@cocotb.test()
async def create_and_lookup_preserves_gid_and_service_metadata(dut):
    await reset_dut(dut)
    assert await create_ah(dut) == AH_TABLE_STATUS_OK
    status, hit, entry = await lookup_ah(dut)
    assert status == AH_TABLE_STATUS_OK
    assert hit == 1
    assert extract_field(AH_FIELDS, entry, "dst_mac") == 0xAABBCCDDEEFF
    assert extract_field(AH_FIELDS, entry, "qkey") == 0x11223344
    assert extract_field(AH_FIELDS, entry, "service_level") == 5
    assert extract_field(AH_FIELDS, entry, "dgid_hi") == 0xFE80000000000000
    assert extract_field(AH_FIELDS, entry, "dgid_lo") == 0x0000000000000002
    assert extract_field(AH_FIELDS, entry, "sgid_index") == 3
    assert extract_field(AH_FIELDS, entry, "flow_label") == 0x12345


@cocotb.test()
async def update_replaces_existing_entry(dut):
    await reset_dut(dut)
    assert await create_ah(dut) == AH_TABLE_STATUS_OK
    dut.update_ah_id.value = 0x22
    dut.update_owner_function.value = 1
    dut.update_pd_id.value = 7
    dut.update_entry.value = pack_ah(dst_ipv4=0x0A000099, service_level=2)
    dut.update_valid.value = 1
    await RisingEdge(dut.clk)
    dut.update_valid.value = 0
    await wait_for(dut, "update_rsp_valid")
    assert int(dut.update_status.value) == AH_TABLE_STATUS_OK
    status, hit, entry = await lookup_ah(dut)
    assert status == AH_TABLE_STATUS_OK and hit == 1
    assert extract_field(AH_FIELDS, entry, "dst_ipv4") == 0x0A000099
    assert extract_field(AH_FIELDS, entry, "service_level") == 2


@cocotb.test()
async def delete_removes_entry(dut):
    await reset_dut(dut)
    assert await create_ah(dut) == AH_TABLE_STATUS_OK
    dut.delete_ah_id.value = 0x22
    dut.delete_owner_function.value = 1
    dut.delete_pd_id.value = 7
    dut.delete_valid.value = 1
    await RisingEdge(dut.clk)
    dut.delete_valid.value = 0
    await wait_for(dut, "delete_rsp_valid")
    assert int(dut.delete_status.value) == AH_TABLE_STATUS_OK
    status, hit, _ = await lookup_ah(dut)
    assert status == AH_TABLE_STATUS_MISS
    assert hit == 0


@cocotb.test()
async def duplicate_and_permission_errors_are_reported(dut):
    await reset_dut(dut)
    assert await create_ah(dut) == AH_TABLE_STATUS_OK
    assert await create_ah(dut) == AH_TABLE_STATUS_ALIAS
    status, hit, _ = await lookup_ah(dut, owner=2)
    assert status == AH_TABLE_STATUS_PERMISSION
    assert hit == 0


@cocotb.test()
async def invalid_entry_is_rejected(dut):
    await reset_dut(dut)
    assert await create_ah(dut, pack_ah(qkey=0)) == AH_TABLE_STATUS_INVALID
