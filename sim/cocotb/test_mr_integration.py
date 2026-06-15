# SPDX-License-Identifier: MIT
"""MR manager 最小集成测试。

本测试使用 Python mock/stub 串起 6.1-6.7 已实现模块的接口语义：
REGISTER_MR -> MR table -> key direction -> access permission -> PD check ->
VA 到 PA 转换 -> refcount -> DEREGISTER_MR，以及 parent MR -> MW bind ->
remote rkey access -> unbind。它不建模真实 DMA Engine、IOMMU、page walk
或 RoCEv2 transport。
"""

from dataclasses import dataclass

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


MR_ACCESS_LOCAL_READ = 0x01
MR_ACCESS_LOCAL_WRITE = 0x02
MR_ACCESS_REMOTE_READ = 0x04
MR_ACCESS_REMOTE_WRITE = 0x08
MR_ACCESS_REMOTE_ATOMIC = 0x10
MR_ACCESS_MW_BIND = 0x20

MR_OP_LOCAL_READ = 0
MR_OP_LOCAL_WRITE = 1
MR_OP_LOCAL_RECV_WRITE = 2
MR_OP_REMOTE_READ = 3
MR_OP_REMOTE_WRITE = 4
MR_OP_REMOTE_ATOMIC = 5
MR_OP_MW_BIND = 6


@dataclass
class MrEntry:
    valid: bool = True
    lkey: int = 0x1001
    rkey: int = 0x2001
    virtual_base_addr: int = 0x1000_0000
    physical_base_addr: int = 0x8000_0000
    length: int = 0x2000
    access_flags: int = MR_ACCESS_LOCAL_READ | MR_ACCESS_LOCAL_WRITE
    pd_id: int = 3
    owner_function: int = 1
    refcount: int = 0
    pending_deregister: bool = False
    memory_window: bool = False
    invalidating: bool = False
    bound_qpn: int = 0
    parent_mr_key: int = 0


class MrModel:
    def __init__(self):
        self.entries = []

    def register_mr(self, entry: MrEntry) -> MrEntry:
        assert entry.valid
        assert entry.length > 0
        assert entry.lkey != 0
        assert entry.rkey != 0
        assert entry.virtual_base_addr % 4096 == 0
        assert self.find_by_lkey(entry.lkey, allow_pending=True) is None
        assert self.find_by_rkey(entry.rkey, allow_pending=True) is None
        self.entries.append(entry)
        return entry

    def find_by_lkey(self, lkey: int, *, allow_pending=False):
        for entry in self.entries:
            if entry.valid and entry.lkey == lkey:
                if not allow_pending and (entry.pending_deregister or entry.invalidating):
                    return None
                return entry
        return None

    def find_by_rkey(self, rkey: int, *, allow_pending=False):
        for entry in self.entries:
            if entry.valid and entry.rkey == rkey:
                if not allow_pending and (entry.pending_deregister or entry.invalidating):
                    return None
                return entry
        return None

    def lookup(self, *, key: int, is_remote: bool):
        return self.find_by_rkey(key) if is_remote else self.find_by_lkey(key)

    def access(
        self,
        *,
        key: int,
        is_remote: bool,
        operation: int,
        owner_function: int,
        qp_pd_id: int,
        va: int,
        length: int,
    ):
        entry = self.lookup(key=key, is_remote=is_remote)
        assert entry is not None
        assert entry.owner_function == owner_function
        assert entry.pd_id == qp_pd_id
        assert length > 0
        assert va >= entry.virtual_base_addr
        assert va + length <= entry.virtual_base_addr + entry.length

        required = {
            MR_OP_LOCAL_READ: MR_ACCESS_LOCAL_READ,
            MR_OP_LOCAL_WRITE: MR_ACCESS_LOCAL_WRITE,
            MR_OP_LOCAL_RECV_WRITE: MR_ACCESS_LOCAL_WRITE,
            MR_OP_REMOTE_READ: MR_ACCESS_REMOTE_READ,
            MR_OP_REMOTE_WRITE: MR_ACCESS_REMOTE_WRITE,
            MR_OP_REMOTE_ATOMIC: MR_ACCESS_REMOTE_ATOMIC,
            MR_OP_MW_BIND: MR_ACCESS_MW_BIND,
        }[operation]
        assert entry.access_flags & required

        return entry.physical_base_addr + (va - entry.virtual_base_addr)

    def ref_inc(self, entry: MrEntry):
        entry.refcount += 1
        return entry.refcount

    def ref_dec(self, entry: MrEntry):
        assert entry.refcount > 0
        entry.refcount -= 1
        return entry.refcount

    def deregister(self, *, lkey: int):
        entry = self.find_by_lkey(lkey, allow_pending=True)
        assert entry is not None
        entry.pending_deregister = True
        if entry.refcount == 0:
            entry.valid = False
            entry.pending_deregister = False
        return entry

    def drain_deregister(self, entry: MrEntry):
        assert entry.pending_deregister
        assert entry.refcount == 0
        entry.valid = False
        entry.pending_deregister = False

    def bind_mw(
        self,
        *,
        parent_lkey: int,
        mw_rkey: int,
        qpn: int,
        va: int,
        length: int,
        access_flags: int,
        owner_function: int,
        pd_id: int,
    ):
        parent = self.find_by_lkey(parent_lkey)
        assert parent is not None
        assert not parent.memory_window
        assert parent.owner_function == owner_function
        assert parent.pd_id == pd_id
        assert length > 0
        assert va >= parent.virtual_base_addr
        assert va + length <= parent.virtual_base_addr + parent.length
        assert mw_rkey != 0
        assert self.find_by_rkey(mw_rkey, allow_pending=True) is None
        assert (access_flags & ~parent.access_flags) == 0
        assert (access_flags & MR_ACCESS_MW_BIND) == 0

        mw = MrEntry(
            valid=True,
            lkey=0,
            rkey=mw_rkey,
            virtual_base_addr=va,
            physical_base_addr=parent.physical_base_addr + (va - parent.virtual_base_addr),
            length=length,
            access_flags=access_flags,
            pd_id=parent.pd_id,
            owner_function=parent.owner_function,
            memory_window=True,
            bound_qpn=qpn,
            parent_mr_key=parent.lkey,
        )
        self.entries.append(mw)
        return mw

    def unbind_mw(self, *, mw_rkey: int):
        mw = self.find_by_rkey(mw_rkey, allow_pending=True)
        assert mw is not None
        assert mw.memory_window
        mw.pending_deregister = True
        mw.invalidating = True
        if mw.refcount == 0:
            mw.valid = False
            mw.pending_deregister = False
            mw.invalidating = False
        return mw


async def reset_stub(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def registered_mr_passes_protection_pipeline_and_deregisters_after_ref_drain(dut):
    await reset_stub(dut)

    table = MrModel()
    mr = table.register_mr(
        MrEntry(
            access_flags=MR_ACCESS_LOCAL_READ | MR_ACCESS_LOCAL_WRITE,
            virtual_base_addr=0x1000_0000,
            physical_base_addr=0x8000_0000,
            length=0x2000,
            pd_id=3,
            owner_function=1,
        )
    )

    assert table.lookup(key=mr.lkey, is_remote=False) is mr
    pa = table.access(
        key=mr.lkey,
        is_remote=False,
        operation=MR_OP_LOCAL_READ,
        owner_function=1,
        qp_pd_id=3,
        va=0x1000_0040,
        length=128,
    )
    assert pa == 0x8000_0040

    assert table.ref_inc(mr) == 1
    pending = table.deregister(lkey=mr.lkey)
    assert pending.valid is True
    assert pending.pending_deregister is True
    assert table.lookup(key=mr.lkey, is_remote=False) is None

    assert table.ref_dec(mr) == 0
    table.drain_deregister(mr)
    assert mr.valid is False
    assert table.lookup(key=mr.lkey, is_remote=False) is None


@cocotb.test()
async def memory_window_uses_subset_rkey_then_unbind_rejects_remote_access(dut):
    await reset_stub(dut)

    table = MrModel()
    parent = table.register_mr(
        MrEntry(
            access_flags=MR_ACCESS_REMOTE_READ | MR_ACCESS_REMOTE_WRITE | MR_ACCESS_REMOTE_ATOMIC,
            virtual_base_addr=0x2000_0000,
            physical_base_addr=0x9000_0000,
            length=0x4000,
            pd_id=5,
            owner_function=2,
        )
    )

    mw = table.bind_mw(
        parent_lkey=parent.lkey,
        mw_rkey=0x3001,
        qpn=0x55,
        va=0x2000_1000,
        length=0x1000,
        access_flags=MR_ACCESS_REMOTE_READ,
        owner_function=2,
        pd_id=5,
    )

    assert mw.valid is True
    assert mw.memory_window is True
    assert mw.parent_mr_key == parent.lkey
    assert mw.bound_qpn == 0x55

    pa = table.access(
        key=0x3001,
        is_remote=True,
        operation=MR_OP_REMOTE_READ,
        owner_function=2,
        qp_pd_id=5,
        va=0x2000_1080,
        length=64,
    )
    assert pa == 0x9000_1080

    rejected = False
    try:
        table.access(
            key=0x3001,
            is_remote=True,
            operation=MR_OP_REMOTE_WRITE,
            owner_function=2,
            qp_pd_id=5,
            va=0x2000_1080,
            length=64,
        )
    except AssertionError:
        rejected = True
    assert rejected is True

    table.unbind_mw(mw_rkey=0x3001)
    assert mw.valid is False
    assert table.lookup(key=0x3001, is_remote=True) is None
    assert parent.valid is True
    assert table.lookup(key=parent.lkey, is_remote=False) is parent


@cocotb.test()
async def qp_error_style_invalidation_marks_bound_mw_pending_before_drain(dut):
    await reset_stub(dut)

    table = MrModel()
    parent = table.register_mr(
        MrEntry(
            access_flags=MR_ACCESS_REMOTE_READ,
            virtual_base_addr=0x3000_0000,
            physical_base_addr=0xA000_0000,
            length=0x2000,
        )
    )
    mw = table.bind_mw(
        parent_lkey=parent.lkey,
        mw_rkey=0x4001,
        qpn=0x77,
        va=0x3000_0000,
        length=0x1000,
        access_flags=MR_ACCESS_REMOTE_READ,
        owner_function=1,
        pd_id=3,
    )

    table.ref_inc(mw)
    invalidating = table.unbind_mw(mw_rkey=0x4001)

    assert invalidating.valid is True
    assert invalidating.pending_deregister is True
    assert invalidating.invalidating is True
    assert table.lookup(key=0x4001, is_remote=True) is None

    table.ref_dec(mw)
    table.drain_deregister(mw)
    assert mw.valid is False
