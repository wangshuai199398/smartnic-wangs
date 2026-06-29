# SPDX-License-Identifier: MIT
"""Byte-addressable host memory model for DMA-visible verification.

The model is deliberately independent from RDMA scoreboard policy. It owns
only deterministic allocation, byte storage, DMA read/write visibility,
transaction logging, and integrity helpers. Cocotb tests can bind
`service_pcie_tlp()` to a DUT PCIe DMA TLP stream or call `dma_read()` /
`dma_write()` directly from protocol-specific helpers.
"""

from __future__ import annotations

import hashlib
import random
from dataclasses import dataclass
from enum import Enum
from typing import Callable, Iterable, List, Optional

from .pcie_bfm import PcieCompletion, PcieCompletionStatus, PcieTlp, PcieTlpType


class HostMemoryError(ValueError):
    """Raised for invalid host-memory allocation or DMA access."""


class PatternKind(str, Enum):
    ZERO = "zero"
    CONSTANT = "constant"
    INCREMENTING = "incrementing"
    WALKING_BIT = "walking-bit"
    RANDOM = "random"


@dataclass(frozen=True)
class DmaBuffer:
    handle: int
    dma_addr: int
    size: int
    alignment: int
    name: str = ""

    @property
    def end_addr(self) -> int:
        return self.dma_addr + self.size


@dataclass(frozen=True)
class DmaTransaction:
    order: int
    kind: str
    addr: int
    length: int
    data: bytes = b""
    byte_enable: Optional[tuple[bool, ...]] = None
    tag: Optional[int] = None
    timestamp: int = 0


def _align_up(value: int, alignment: int) -> int:
    if alignment <= 0 or alignment & (alignment - 1):
        raise HostMemoryError("alignment must be a nonzero power of two")
    return (value + alignment - 1) & ~(alignment - 1)


def _normalize_mask(byte_enable: Optional[int | Iterable[bool]], length: int) -> Optional[List[bool]]:
    if byte_enable is None:
        return None
    if isinstance(byte_enable, int):
        return [bool(byte_enable & (1 << idx)) for idx in range(length)]
    mask = list(byte_enable)
    if len(mask) != length:
        raise HostMemoryError("byte enable mask length does not match write length")
    return [bool(bit) for bit in mask]


class HostMemoryModel:
    """Deterministic host memory model with DMA transaction visibility."""

    def __init__(
        self,
        base_addr: int = 0x1000_0000,
        size: int = 16 * 1024 * 1024,
        clear_on_reset: bool = True,
        strict_allocations: bool = True,
        history_limit: int = 1024,
    ) -> None:
        if base_addr < 0 or size <= 0:
            raise HostMemoryError("host memory base and size must be positive")
        self.base_addr = base_addr
        self.size = size
        self.clear_on_reset = clear_on_reset
        self.strict_allocations = strict_allocations
        self.history_limit = history_limit
        self._memory = bytearray(size)
        self._alloc_next = 0
        self._next_handle = 1
        self._buffers: dict[int, DmaBuffer] = {}
        self._free_list: List[tuple[int, int]] = []
        self._history: List[DmaTransaction] = []
        self._order = 0
        self._time = 0

    @property
    def history(self) -> tuple[DmaTransaction, ...]:
        return tuple(self._history)

    @property
    def buffers(self) -> tuple[DmaBuffer, ...]:
        return tuple(self._buffers.values())

    def reset(self, clear_memory: Optional[bool] = None, clear_allocations: bool = True) -> None:
        should_clear = self.clear_on_reset if clear_memory is None else clear_memory
        self._history.clear()
        self._order = 0
        self._time = 0
        if should_clear:
            self._memory[:] = bytes(self.size)
        if clear_allocations:
            self._alloc_next = 0
            self._next_handle = 1
            self._buffers.clear()
            self._free_list.clear()

    def allocate(
        self,
        size: int,
        alignment: int = 64,
        init: Optional[bytes | int] = None,
        pattern: PatternKind | str = PatternKind.ZERO,
        name: str = "",
    ) -> DmaBuffer:
        if size <= 0:
            raise HostMemoryError("allocation size must be positive")
        offset = self._find_free_region(size, alignment)
        if offset is None:
            offset = _align_up(self._alloc_next, alignment)
            if offset + size > self.size:
                raise HostMemoryError("host memory allocation exceeds model size")
            self._alloc_next = offset + size
        handle = self._next_handle
        self._next_handle += 1
        buffer = DmaBuffer(handle, self.base_addr + offset, size, alignment, name)
        self._buffers[handle] = buffer
        if init is not None:
            data = init if isinstance(init, bytes) else init.to_bytes(size, "little", signed=False)
            if len(data) > size:
                raise HostMemoryError("initial data is larger than allocation")
            self.write(buffer.dma_addr, data + bytes(size - len(data)))
        else:
            self.write(buffer.dma_addr, self.pattern_bytes(size, pattern))
        return buffer

    def free(self, buffer: DmaBuffer | int) -> None:
        handle = buffer if isinstance(buffer, int) else buffer.handle
        item = self._buffers.pop(handle, None)
        if item is None:
            raise HostMemoryError("unknown DMA buffer handle")
        self._free_list.append((item.dma_addr - self.base_addr, item.size))

    def read(self, addr: int, length: int) -> bytes:
        offset = self._checked_offset(addr, length)
        return bytes(self._memory[offset : offset + length])

    def write(self, addr: int, data: bytes, byte_enable: Optional[int | Iterable[bool]] = None) -> None:
        offset = self._checked_offset(addr, len(data))
        mask = _normalize_mask(byte_enable, len(data))
        if mask is None:
            self._memory[offset : offset + len(data)] = data
            return
        for idx, enabled in enumerate(mask):
            if enabled:
                self._memory[offset + idx] = data[idx]

    def dma_read(self, addr: int, length: int, tag: Optional[int] = None) -> bytes:
        data = self.read(addr, length)
        self._record("read", addr, length, data, tag=tag)
        return data

    def dma_write(self, addr: int, data: bytes, byte_enable: Optional[int | Iterable[bool]] = None, tag: Optional[int] = None) -> None:
        mask = _normalize_mask(byte_enable, len(data))
        self.write(addr, data, mask)
        self._record("write", addr, len(data), data, mask, tag)

    def service_pcie_tlp(self, tlp: PcieTlp) -> Optional[PcieCompletion]:
        """Service a DUT-originated PCIe Memory Read/Write TLP.

        Memory Reads return a completion object. Memory Writes update the
        backing store and return None. Config/MSI-X/MMIO TLPs are outside this
        host-memory model boundary.
        """

        if tlp.tlp_type == PcieTlpType.MEM_READ:
            data = self.dma_read(tlp.address, tlp.length, tag=tlp.tag)
            return PcieCompletion(
                tag=tlp.tag,
                data=data,
                status=PcieCompletionStatus.SUCCESS,
                byte_count=tlp.length,
                lower_address=tlp.address & 0x7F,
                requester_id=tlp.requester_id,
                completer_id=tlp.completer_id,
            )
        if tlp.tlp_type == PcieTlpType.MEM_WRITE:
            self.dma_write(tlp.address, tlp.data, byte_enable=tlp.first_be, tag=tlp.tag)
            return None
        raise HostMemoryError("host memory model only services PCIe Memory Read/Write TLPs")

    def compare(self, addr: int, expected: bytes) -> None:
        actual = self.read(addr, len(expected))
        if actual != expected:
            raise AssertionError(self._mismatch_message(addr, expected, actual))

    def compare_masked(self, addr: int, expected: bytes, mask: int | Iterable[bool]) -> None:
        actual = self.read(addr, len(expected))
        mask_bits = _normalize_mask(mask, len(expected)) or []
        for idx, enabled in enumerate(mask_bits):
            if enabled and actual[idx] != expected[idx]:
                raise AssertionError(self._mismatch_message(addr + idx, expected[idx : idx + 1], actual[idx : idx + 1]))

    def digest(self, addr: int, length: int, algorithm: str = "sha256") -> str:
        h = hashlib.new(algorithm)
        h.update(self.read(addr, length))
        return h.hexdigest()

    def pattern_bytes(self, length: int, pattern: PatternKind | str = PatternKind.ZERO, seed: int = 1, constant: int = 0xA5) -> bytes:
        kind = PatternKind(pattern)
        if length < 0:
            raise HostMemoryError("pattern length must be nonnegative")
        if kind == PatternKind.ZERO:
            return bytes(length)
        if kind == PatternKind.CONSTANT:
            return bytes([constant & 0xFF]) * length
        if kind == PatternKind.INCREMENTING:
            return bytes(idx & 0xFF for idx in range(length))
        if kind == PatternKind.WALKING_BIT:
            return bytes(1 << (idx & 0x7) for idx in range(length))
        rng = random.Random(seed)
        return bytes(rng.randrange(0, 256) for _ in range(length))

    def assert_dma_read(self, addr: int, length: Optional[int] = None) -> DmaTransaction:
        return self._find_transaction("read", addr, length)

    def assert_dma_write(self, addr: int, length: Optional[int] = None) -> DmaTransaction:
        return self._find_transaction("write", addr, length)

    def attach_pcie_sink(self, callback: Callable[[PcieCompletion], None]) -> Callable[[PcieTlp], None]:
        """Return a callback suitable for PCIe BFM `on_tlp` wiring."""

        def sink(tlp: PcieTlp) -> None:
            completion = self.service_pcie_tlp(tlp)
            if completion is not None:
                callback(completion)

        return sink

    def _find_free_region(self, size: int, alignment: int) -> Optional[int]:
        for idx, (offset, free_size) in enumerate(self._free_list):
            aligned = _align_up(offset, alignment)
            padding = aligned - offset
            if padding + size <= free_size:
                del self._free_list[idx]
                before = padding
                after = free_size - padding - size
                if before:
                    self._free_list.append((offset, before))
                if after:
                    self._free_list.append((aligned + size, after))
                return aligned
        return None

    def _checked_offset(self, addr: int, length: int) -> int:
        if length < 0:
            raise HostMemoryError("access length must be nonnegative")
        if length == 0:
            return addr - self.base_addr
        if addr < self.base_addr or addr + length > self.base_addr + self.size:
            raise HostMemoryError(f"DMA access out of range: addr=0x{addr:x} length={length}")
        if self.strict_allocations and not self._covered_by_allocation(addr, length):
            raise HostMemoryError(f"DMA access targets unallocated memory: addr=0x{addr:x} length={length}")
        return addr - self.base_addr

    def _covered_by_allocation(self, addr: int, length: int) -> bool:
        return any(buffer.dma_addr <= addr and addr + length <= buffer.end_addr for buffer in self._buffers.values())

    def _record(
        self,
        kind: str,
        addr: int,
        length: int,
        data: bytes,
        byte_enable: Optional[Iterable[bool]] = None,
        tag: Optional[int] = None,
    ) -> None:
        self._order += 1
        self._time += 1
        tx = DmaTransaction(
            order=self._order,
            kind=kind,
            addr=addr,
            length=length,
            data=bytes(data),
            byte_enable=tuple(byte_enable) if byte_enable is not None else None,
            tag=tag,
            timestamp=self._time,
        )
        self._history.append(tx)
        if self.history_limit > 0 and len(self._history) > self.history_limit:
            self._history = self._history[-self.history_limit :]

    def _find_transaction(self, kind: str, addr: int, length: Optional[int]) -> DmaTransaction:
        for tx in self._history:
            if tx.kind == kind and tx.addr == addr and (length is None or tx.length == length):
                return tx
        raise AssertionError(f"expected DMA {kind} addr=0x{addr:x} length={length}")

    @staticmethod
    def _mismatch_message(addr: int, expected: bytes, actual: bytes) -> str:
        for idx, (exp, got) in enumerate(zip(expected, actual)):
            if exp != got:
                return f"memory mismatch at 0x{addr + idx:x}: expected 0x{exp:02x}, got 0x{got:02x}"
        if len(expected) != len(actual):
            return f"memory length mismatch at 0x{addr:x}: expected {len(expected)}, got {len(actual)}"
        return f"memory mismatch at 0x{addr:x}"

