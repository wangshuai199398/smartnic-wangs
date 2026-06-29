# SPDX-License-Identifier: MIT
"""Host-side PCIe BFM primitives for SmartNIC cocotb tests.

The model is intentionally transport-independent: it keeps PCIe transaction
encoding, config-space behavior, completion matching, MSI-X table state, and
function identity in Python objects. Later cocotb tests can bind the callbacks
to DUT AXI-stream or vendor PCIe wrapper signals without changing the test API.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import IntEnum
from typing import Callable, Dict, Iterable, List, Optional


class PcieCompletionTimeout(TimeoutError):
    """Raised when an outstanding Memory Read completion is not observed."""


class PcieTlpType(IntEnum):
    CFG_READ = 0
    CFG_WRITE = 1
    MEM_READ = 2
    MEM_WRITE = 3
    CPL = 4
    CPLD = 5
    MSIX = 6


class PcieCompletionStatus(IntEnum):
    SUCCESS = 0
    UNSUPPORTED_REQUEST = 1
    COMPLETER_ABORT = 2
    TIMEOUT = 3
    MALFORMED = 4


@dataclass(frozen=True)
class PcieFunctionIdentity:
    bus: int = 0
    device: int = 0
    function: int = 0
    vendor_id: int = 0x1D0F
    device_id: int = 0x5A10
    subsystem_vendor_id: int = 0x1D0F
    subsystem_id: int = 0x0001
    class_code: int = 0x020000
    revision_id: int = 0x01
    is_pf: bool = True
    vf_number: int = 0

    @property
    def requester_id(self) -> int:
        return ((self.bus & 0xFF) << 8) | ((self.device & 0x1F) << 3) | (self.function & 0x7)


@dataclass
class PcieBar:
    index: int
    size: int
    base: int = 0
    is_64bit: bool = False
    prefetchable: bool = False
    memory: bytearray = field(default_factory=bytearray)
    sink: Optional[Callable[["PcieTlp"], None]] = None

    def __post_init__(self) -> None:
        if self.size <= 0 or self.size & (self.size - 1):
            raise ValueError("BAR size must be a nonzero power of two")
        if not self.memory:
            self.memory = bytearray(self.size)

    @property
    def mask(self) -> int:
        return ~(self.size - 1) & 0xFFFF_FFF0

    def contains(self, addr: int) -> bool:
        return self.base != 0 and self.base <= addr < self.base + self.size

    def offset(self, addr: int) -> int:
        if not self.contains(addr):
            raise ValueError(f"address 0x{addr:x} does not target BAR{self.index}")
        return addr - self.base


@dataclass
class PcieTlp:
    tlp_type: PcieTlpType
    address: int = 0
    data: bytes = b""
    length: int = 0
    tag: int = 0
    first_be: int = 0xF
    last_be: int = 0xF
    requester_id: int = 0
    completer_id: int = 0
    function: int = 0
    bar: Optional[int] = None
    status: PcieCompletionStatus = PcieCompletionStatus.SUCCESS


@dataclass
class PcieCompletion:
    tag: int
    data: bytes
    status: PcieCompletionStatus = PcieCompletionStatus.SUCCESS
    byte_count: int = 0
    lower_address: int = 0
    requester_id: int = 0
    completer_id: int = 0


@dataclass
class PcieMsixVector:
    address: int = 0
    data: int = 0
    masked: bool = True
    pending: bool = False


class PcieHostBfm:
    """Reusable host-side PCIe transaction model.

    The BFM provides synchronous APIs for unit tests and can be driven from
    cocotb coroutines by wrapping calls around clock edges. Unsupported DUT
    details such as vendor-specific TLP sideband fields are kept behind
    callbacks (`bar.sink` and `on_tlp`) so later tests can bind real signals.
    """

    CFG_VENDOR_DEVICE = 0x00
    CFG_COMMAND_STATUS = 0x04
    CFG_CLASS_REV = 0x08
    CFG_BAR0 = 0x10
    CFG_SUBSYS = 0x2C
    CFG_CAP_PTR = 0x34
    CFG_MSIX_CAP = 0x60

    COMMAND_MEMORY = 0x0002
    COMMAND_BUS_MASTER = 0x0004

    def __init__(
        self,
        identity: Optional[PcieFunctionIdentity] = None,
        bars: Optional[Iterable[PcieBar]] = None,
        msix_vectors: int = 8,
        completion_timeout_cycles: int = 32,
    ) -> None:
        self.identity = identity or PcieFunctionIdentity()
        self.completion_timeout_cycles = completion_timeout_cycles
        self.on_tlp: Optional[Callable[[PcieTlp], None]] = None
        self._tag_next = 0
        self._outstanding: Dict[int, PcieTlp] = {}
        self._completion_queues: Dict[int, List[PcieCompletion]] = {}
        self._msix_observed: List[int] = []
        self._msix_vectors: List[PcieMsixVector] = [PcieMsixVector() for _ in range(msix_vectors)]
        self._config: Dict[int, int] = {}
        self.bars: Dict[int, PcieBar] = {}
        self.reset()
        for bar in bars or (
            PcieBar(0, 256 * 1024 * 1024),
            PcieBar(2, 64 * 1024),
            PcieBar(4, 16 * 1024),
        ):
            self.add_bar(bar)

    def reset(self) -> None:
        self._tag_next = 0
        self._outstanding.clear()
        self._completion_queues.clear()
        self._msix_observed.clear()
        for vector in self._msix_vectors:
            vector.pending = False
        self._config = {
            self.CFG_VENDOR_DEVICE: (self.identity.device_id << 16) | self.identity.vendor_id,
            self.CFG_COMMAND_STATUS: 0x0010_0000,
            self.CFG_CLASS_REV: (self.identity.class_code << 8) | self.identity.revision_id,
            self.CFG_SUBSYS: (self.identity.subsystem_id << 16) | self.identity.subsystem_vendor_id,
            self.CFG_CAP_PTR: self.CFG_MSIX_CAP,
            self.CFG_MSIX_CAP: 0x0000_0011,
            self.CFG_MSIX_CAP + 4: 0x0000_0004,
            self.CFG_MSIX_CAP + 8: 0x0000_0804,
        }

    def add_bar(self, bar: PcieBar) -> None:
        self.bars[bar.index] = bar
        self._config[self.CFG_BAR0 + bar.index * 4] = bar.base & 0xFFFF_FFF0

    def cfg_read(self, offset: int, size: int = 4) -> int:
        base = offset & ~0x3
        shift = (offset & 0x3) * 8
        value = self._config.get(base, 0)
        mask = (1 << (size * 8)) - 1
        return (value >> shift) & mask

    def cfg_write(self, offset: int, value: int, size: int = 4, byte_enable: int = 0xF) -> None:
        base = offset & ~0x3
        old = self._config.get(base, 0)
        merged = old
        for byte in range(size):
            absolute = (offset & 0x3) + byte
            if byte_enable & (1 << absolute):
                merged &= ~(0xFF << (absolute * 8))
                merged |= ((value >> (byte * 8)) & 0xFF) << (absolute * 8)
        self._config[base] = merged & 0xFFFF_FFFF

        if self.CFG_BAR0 <= base <= self.CFG_BAR0 + 5 * 4:
            bar_index = (base - self.CFG_BAR0) // 4
            bar = self.bars.get(bar_index)
            if not bar:
                return
            if value == 0xFFFF_FFFF:
                self._config[base] = bar.mask
            else:
                bar.base = value & 0xFFFF_FFF0
                self._config[base] = bar.base

    def enable_memory_and_bus_master(self) -> None:
        command_status = self._config[self.CFG_COMMAND_STATUS]
        command_status |= self.COMMAND_MEMORY | self.COMMAND_BUS_MASTER
        self._config[self.CFG_COMMAND_STATUS] = command_status

    def probe_bar_size(self, bar_index: int) -> int:
        reg = self.CFG_BAR0 + bar_index * 4
        old = self.cfg_read(reg)
        self.cfg_write(reg, 0xFFFF_FFFF)
        mask = self.cfg_read(reg)
        self.cfg_write(reg, old)
        return (~(mask & 0xFFFF_FFF0) + 1) & 0xFFFF_FFFF

    def program_bar(self, bar_index: int, base: int) -> None:
        self.cfg_write(self.CFG_BAR0 + bar_index * 4, base)

    def mem_write(self, addr: int, data: bytes, byte_enable: int = 0xF) -> None:
        bar = self._find_bar(addr)
        offset = bar.offset(addr)
        if offset + len(data) > bar.size:
            raise ValueError("MMIO write crosses BAR boundary")
        bar.memory[offset : offset + len(data)] = data
        tlp = PcieTlp(
            PcieTlpType.MEM_WRITE,
            address=addr,
            data=bytes(data),
            length=len(data),
            first_be=byte_enable,
            requester_id=self.identity.requester_id,
            function=self.identity.function,
            bar=bar.index,
        )
        self._emit_tlp(tlp, bar)

    def mem_read(self, addr: int, length: int) -> bytes:
        if length <= 0:
            raise ValueError("read length must be positive")
        bar = self._find_bar(addr)
        offset = bar.offset(addr)
        if offset + length > bar.size:
            raise ValueError("MMIO read crosses BAR boundary")
        tag = self._alloc_tag()
        tlp = PcieTlp(
            PcieTlpType.MEM_READ,
            address=addr,
            length=length,
            tag=tag,
            requester_id=self.identity.requester_id,
            function=self.identity.function,
            bar=bar.index,
        )
        self._outstanding[tag] = tlp
        self._emit_tlp(tlp, bar)
        default_data = bytes(bar.memory[offset : offset + length])
        self.push_completion(
            PcieCompletion(
                tag=tag,
                data=default_data,
                byte_count=length,
                lower_address=addr & 0x7F,
                requester_id=self.identity.requester_id,
                completer_id=self.identity.requester_id,
            )
        )
        return self._wait_completion(tag)

    def issue_mem_read_no_completion(self, addr: int, length: int) -> int:
        bar = self._find_bar(addr)
        tag = self._alloc_tag()
        tlp = PcieTlp(
            PcieTlpType.MEM_READ,
            address=addr,
            length=length,
            tag=tag,
            requester_id=self.identity.requester_id,
            function=self.identity.function,
            bar=bar.index,
        )
        self._outstanding[tag] = tlp
        self._emit_tlp(tlp, bar)
        return tag

    def push_completion(self, completion: PcieCompletion) -> None:
        if completion.tag not in self._outstanding:
            raise ValueError(f"unexpected completion tag {completion.tag}")
        self._completion_queues.setdefault(completion.tag, []).append(completion)

    def wait_for_completion(self, tag: int) -> bytes:
        return self._wait_completion(tag)

    def program_msix_vector(self, vector: int, address: int, data: int, masked: bool = False) -> None:
        entry = self._msix_vectors[vector]
        entry.address = address
        entry.data = data
        entry.masked = masked
        entry.pending = False

    def observe_msix_write(self, address: int, data: int) -> Optional[int]:
        for index, vector in enumerate(self._msix_vectors):
            if vector.address == address and vector.data == data:
                if vector.masked:
                    vector.pending = True
                    return None
                self._msix_observed.append(index)
                return index
        raise ValueError(f"unexpected MSI-X write addr=0x{address:x} data=0x{data:x}")

    def wait_msix(self, vector: int) -> int:
        if vector not in self._msix_observed:
            raise PcieCompletionTimeout(f"MSI-X vector {vector} was not observed")
        self._msix_observed.remove(vector)
        return vector

    def unmask_msix_vector(self, vector: int) -> None:
        entry = self._msix_vectors[vector]
        entry.masked = False
        if entry.pending:
            entry.pending = False
            self._msix_observed.append(vector)

    def _alloc_tag(self) -> int:
        for _ in range(256):
            tag = self._tag_next
            self._tag_next = (self._tag_next + 1) & 0xFF
            if tag not in self._outstanding:
                return tag
        raise RuntimeError("no PCIe tags available")

    def _wait_completion(self, tag: int) -> bytes:
        request = self._outstanding.get(tag)
        if request is None:
            raise ValueError(f"tag {tag} is not outstanding")
        queue = self._completion_queues.get(tag)
        if not queue:
            raise PcieCompletionTimeout(f"completion timeout for tag {tag}")
        completion = queue.pop(0)
        if completion.status != PcieCompletionStatus.SUCCESS:
            self._outstanding.pop(tag, None)
            raise RuntimeError(f"PCIe completion failed: {completion.status.name}")
        if completion.byte_count not in (0, request.length) or len(completion.data) != request.length:
            self._outstanding.pop(tag, None)
            raise RuntimeError("malformed PCIe completion length")
        if completion.requester_id != request.requester_id:
            self._outstanding.pop(tag, None)
            raise RuntimeError("PCIe completion requester ID mismatch")
        self._outstanding.pop(tag, None)
        return completion.data

    def _find_bar(self, addr: int) -> PcieBar:
        for bar in self.bars.values():
            if bar.contains(addr):
                return bar
        raise ValueError(f"address 0x{addr:x} does not hit a programmed BAR")

    def _emit_tlp(self, tlp: PcieTlp, bar: PcieBar) -> None:
        if bar.sink:
            bar.sink(tlp)
        if self.on_tlp:
            self.on_tlp(tlp)
