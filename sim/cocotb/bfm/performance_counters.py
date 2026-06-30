# SPDX-License-Identifier: MIT
"""Lightweight simulation performance counters for RDMA bring-up.

The counters are intentionally testbench-side only. Monitors can call the
record_* hooks when they observe doorbells, WQE acceptance, packets, DMA
transactions, and CQEs. No DUT behavior changes are required.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Optional, Tuple


class PerformanceCounterError(ValueError):
    """Raised for invalid counter configuration or impossible observations."""


TransactionKey = Tuple[int, int]


@dataclass
class LatencyStats:
    name: str
    count: int = 0
    total_cycles: int = 0
    min_cycles: Optional[int] = None
    max_cycles: Optional[int] = None
    unavailable: int = 0

    @property
    def avg_cycles(self) -> Optional[float]:
        if self.count == 0:
            return None
        return self.total_cycles / self.count

    def sample(self, latency_cycles: int) -> None:
        if latency_cycles < 0:
            raise PerformanceCounterError(f"{self.name} latency cannot be negative")
        self.count += 1
        self.total_cycles += latency_cycles
        self.min_cycles = latency_cycles if self.min_cycles is None else min(self.min_cycles, latency_cycles)
        self.max_cycles = latency_cycles if self.max_cycles is None else max(self.max_cycles, latency_cycles)

    def mark_unavailable(self) -> None:
        self.unavailable += 1

    def to_dict(self) -> dict:
        return {
            "count": self.count,
            "min_cycles": self.min_cycles,
            "max_cycles": self.max_cycles,
            "avg_cycles": self.avg_cycles,
            "total_cycles": self.total_cycles,
            "unavailable": self.unavailable,
        }


@dataclass
class RateCounter:
    name: str
    unit: str
    total: int = 0
    events: int = 0

    def add(self, amount: int = 1) -> None:
        if amount < 0:
            raise PerformanceCounterError(f"{self.name} amount cannot be negative")
        self.total += amount
        self.events += 1

    def per_cycle(self, window_cycles: int) -> Optional[float]:
        if window_cycles <= 0:
            return None
        return self.total / window_cycles

    def per_second(self, window_cycles: int, clock_hz: Optional[float]) -> Optional[float]:
        rate = self.per_cycle(window_cycles)
        if rate is None or clock_hz is None:
            return None
        return rate * clock_hz

    def to_dict(self, window_cycles: int, clock_hz: Optional[float]) -> dict:
        return {
            "total": self.total,
            "events": self.events,
            "unit": self.unit,
            "per_cycle": self.per_cycle(window_cycles),
            "per_second": self.per_second(window_cycles, clock_hz),
        }


class SimulationPerformanceCounters:
    """Reusable event-correlated simulation performance counters."""

    def __init__(
        self,
        enabled: bool = False,
        clock_hz: Optional[float] = None,
        output_path: Optional[str | Path] = None,
        strict: bool = False,
    ) -> None:
        self.enabled = enabled
        self.clock_hz = clock_hz
        self.output_path = Path(output_path) if output_path else None
        self.strict = strict
        self.reset()

    @classmethod
    def from_env(cls) -> "SimulationPerformanceCounters":
        enabled = os.environ.get("SMARTNIC_SIM_PERF", "0").lower() in {"1", "true", "yes", "on"}
        clock_text = os.environ.get("SMARTNIC_SIM_PERF_CLOCK_HZ", "")
        output_path = os.environ.get("SMARTNIC_SIM_PERF_OUT", "")
        strict = os.environ.get("SMARTNIC_SIM_PERF_STRICT", "0").lower() in {"1", "true", "yes", "on"}
        clock_hz = float(clock_text) if clock_text else None
        return cls(enabled=enabled, clock_hz=clock_hz, output_path=output_path or None, strict=strict)

    def reset(self) -> None:
        self.window_start_cycle: Optional[int] = None
        self.window_end_cycle: Optional[int] = None
        self.doorbell_to_cqe = LatencyStats("doorbell_to_cqe")
        self.doorbell_to_wire = LatencyStats("doorbell_to_wire")
        self.dma_read_bytes = RateCounter("dma_read_bytes", "bytes")
        self.dma_write_bytes = RateCounter("dma_write_bytes", "bytes")
        self.packet_count = RateCounter("packet_count", "packets")
        self.completion_count = RateCounter("completion_count", "completions")
        self._doorbells: Dict[TransactionKey, int] = {}
        self._wire_seen: set[TransactionKey] = set()
        self.warnings: list[str] = []

    def record_doorbell(self, cycle: int, qpn: int, wr_id: int, opcode: str = "") -> None:
        if not self.enabled:
            return
        self._touch_window(cycle)
        self._doorbells[(qpn, wr_id)] = cycle

    def record_wqe_accept(self, cycle: int, qpn: int, wr_id: int, opcode: str = "") -> None:
        self.record_doorbell(cycle, qpn, wr_id, opcode)

    def record_wire_packet(self, cycle: int, qpn: int, wr_id: int, byte_len: int = 0, opcode: str = "") -> None:
        if not self.enabled:
            return
        self._touch_window(cycle)
        key = (qpn, wr_id)
        self.packet_count.add(1)
        if key in self._wire_seen:
            return
        start = self._doorbells.get(key)
        if start is None:
            self._unavailable(self.doorbell_to_wire, f"wire packet without matching doorbell qpn=0x{qpn:x} wr_id=0x{wr_id:x}")
            return
        self.doorbell_to_wire.sample(cycle - start)
        self._wire_seen.add(key)

    def record_dma_read(self, cycle: int, byte_len: int, qpn: int = 0, wr_id: int = 0) -> None:
        if not self.enabled:
            return
        self._touch_window(cycle)
        self.dma_read_bytes.add(byte_len)

    def record_dma_write(self, cycle: int, byte_len: int, qpn: int = 0, wr_id: int = 0) -> None:
        if not self.enabled:
            return
        self._touch_window(cycle)
        self.dma_write_bytes.add(byte_len)

    def record_cqe(self, cycle: int, qpn: int, wr_id: int, opcode: str = "") -> None:
        if not self.enabled:
            return
        self._touch_window(cycle)
        key = (qpn, wr_id)
        self.completion_count.add(1)
        start = self._doorbells.get(key)
        if start is None:
            self._unavailable(self.doorbell_to_cqe, f"CQE without matching doorbell qpn=0x{qpn:x} wr_id=0x{wr_id:x}")
            return
        self.doorbell_to_cqe.sample(cycle - start)
        self._doorbells.pop(key, None)

    @property
    def window_cycles(self) -> int:
        if self.window_start_cycle is None or self.window_end_cycle is None:
            return 0
        return max(0, self.window_end_cycle - self.window_start_cycle)

    def to_dict(self) -> dict:
        window = self.window_cycles
        return {
            "enabled": self.enabled,
            "clock_hz": self.clock_hz,
            "window": {
                "start_cycle": self.window_start_cycle,
                "end_cycle": self.window_end_cycle,
                "cycles": window,
            },
            "latency": {
                "doorbell_to_cqe": self.doorbell_to_cqe.to_dict(),
                "doorbell_to_wire": self.doorbell_to_wire.to_dict(),
            },
            "throughput": {
                "dma_read_bytes": self.dma_read_bytes.to_dict(window, self.clock_hz),
                "dma_write_bytes": self.dma_write_bytes.to_dict(window, self.clock_hz),
                "packet_rate": self.packet_count.to_dict(window, self.clock_hz),
                "completion_rate": self.completion_count.to_dict(window, self.clock_hz),
            },
            "warnings": list(self.warnings),
        }

    def report_text(self) -> str:
        data = self.to_dict()
        lines = [
            "Simulation performance counters",
            f"enabled: {data['enabled']}",
            (
                "window: "
                f"start={data['window']['start_cycle']} cycles, "
                f"end={data['window']['end_cycle']} cycles, "
                f"duration={data['window']['cycles']} cycles"
            ),
        ]
        if self.clock_hz:
            lines.append(f"clock_hz: {self.clock_hz:g}")
        for name, stats in data["latency"].items():
            lines.append(
                f"latency {name}: count={stats['count']} min={stats['min_cycles']} cycles "
                f"max={stats['max_cycles']} cycles avg={stats['avg_cycles']} cycles unavailable={stats['unavailable']}"
            )
        for name, stats in data["throughput"].items():
            line = (
                f"rate {name}: total={stats['total']} {stats['unit']} events={stats['events']} "
                f"per_cycle={stats['per_cycle']}"
            )
            if stats["per_second"] is not None:
                line += f" per_second={stats['per_second']}"
            lines.append(line)
        for warning in self.warnings:
            lines.append(f"warning: {warning}")
        return "\n".join(lines)

    def write_report(self, path: Optional[str | Path] = None) -> Optional[Path]:
        target = Path(path) if path else self.output_path
        if target is None:
            return None
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(self.to_dict(), indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return target

    def _touch_window(self, cycle: int) -> None:
        if cycle < 0:
            raise PerformanceCounterError("cycle cannot be negative")
        if self.window_start_cycle is None:
            self.window_start_cycle = cycle
        if self.window_end_cycle is not None and cycle < self.window_end_cycle:
            # Out-of-order observations can happen across monitors, but the
            # aggregate window must remain monotonic.
            self.warnings.append(f"out-of-order event cycle={cycle} previous={self.window_end_cycle}")
        self.window_end_cycle = max(cycle, self.window_end_cycle or cycle)

    def _unavailable(self, stats: LatencyStats, warning: str) -> None:
        stats.mark_unavailable()
        self.warnings.append(warning)
        if self.strict:
            raise PerformanceCounterError(warning)
