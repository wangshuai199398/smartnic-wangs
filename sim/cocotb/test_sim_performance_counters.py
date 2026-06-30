# SPDX-License-Identifier: MIT
"""Unit tests for simulation performance counters."""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

from bfm import PerformanceCounterError, SimulationPerformanceCounters


def test_disabled_counters_ignore_events() -> None:
    counters = SimulationPerformanceCounters(enabled=False)

    counters.record_doorbell(10, qpn=1, wr_id=1, opcode="SEND")
    counters.record_wire_packet(12, qpn=1, wr_id=1, byte_len=64, opcode="SEND")
    counters.record_dma_read(13, byte_len=64)
    counters.record_cqe(20, qpn=1, wr_id=1, opcode="SEND")

    data = counters.to_dict()
    assert data["window"]["cycles"] == 0
    assert data["latency"]["doorbell_to_cqe"]["count"] == 0
    assert data["throughput"]["dma_read_bytes"]["total"] == 0
    assert data["throughput"]["packet_rate"]["total"] == 0
    assert data["throughput"]["completion_rate"]["total"] == 0


def test_doorbell_to_cqe_and_wire_latency() -> None:
    counters = SimulationPerformanceCounters(enabled=True, clock_hz=1_000_000_000)

    counters.record_doorbell(10, qpn=7, wr_id=0x101, opcode="SEND")
    counters.record_wire_packet(16, qpn=7, wr_id=0x101, byte_len=128, opcode="SEND")
    counters.record_wire_packet(18, qpn=7, wr_id=0x101, byte_len=128, opcode="SEND")
    counters.record_cqe(42, qpn=7, wr_id=0x101, opcode="SEND")

    data = counters.to_dict()
    assert data["latency"]["doorbell_to_wire"]["count"] == 1
    assert data["latency"]["doorbell_to_wire"]["min_cycles"] == 6
    assert data["latency"]["doorbell_to_wire"]["avg_cycles"] == 6
    assert data["latency"]["doorbell_to_cqe"]["count"] == 1
    assert data["latency"]["doorbell_to_cqe"]["max_cycles"] == 32
    assert data["throughput"]["packet_rate"]["total"] == 2
    assert data["throughput"]["completion_rate"]["total"] == 1
    assert data["window"]["cycles"] == 32


def test_multiple_outstanding_wqes_are_correlated_by_qpn_and_wr_id() -> None:
    counters = SimulationPerformanceCounters(enabled=True)

    counters.record_wqe_accept(100, qpn=3, wr_id=0xaaa, opcode="RDMA_WRITE")
    counters.record_wqe_accept(110, qpn=3, wr_id=0xbbb, opcode="RDMA_READ")
    counters.record_wire_packet(120, qpn=3, wr_id=0xbbb, opcode="RDMA_READ")
    counters.record_cqe(140, qpn=3, wr_id=0xbbb, opcode="RDMA_READ")
    counters.record_wire_packet(160, qpn=3, wr_id=0xaaa, opcode="RDMA_WRITE")
    counters.record_cqe(180, qpn=3, wr_id=0xaaa, opcode="RDMA_WRITE")

    data = counters.to_dict()
    cqe = data["latency"]["doorbell_to_cqe"]
    wire = data["latency"]["doorbell_to_wire"]
    assert cqe["count"] == 2
    assert cqe["min_cycles"] == 30
    assert cqe["max_cycles"] == 80
    assert cqe["avg_cycles"] == 55
    assert wire["count"] == 2
    assert wire["min_cycles"] == 10
    assert wire["max_cycles"] == 60


def test_dma_bandwidth_packet_rate_and_completion_rate() -> None:
    counters = SimulationPerformanceCounters(enabled=True, clock_hz=250_000_000)

    counters.record_dma_read(0, byte_len=256)
    counters.record_dma_read(10, byte_len=768)
    counters.record_dma_write(20, byte_len=512)
    counters.record_wire_packet(30, qpn=1, wr_id=2, byte_len=64)
    counters.record_cqe(40, qpn=1, wr_id=2)

    data = counters.to_dict()
    assert data["throughput"]["dma_read_bytes"]["total"] == 1024
    assert data["throughput"]["dma_read_bytes"]["events"] == 2
    assert data["throughput"]["dma_read_bytes"]["per_cycle"] == 25.6
    assert data["throughput"]["dma_read_bytes"]["per_second"] == 6_400_000_000
    assert data["throughput"]["dma_write_bytes"]["total"] == 512
    assert data["throughput"]["packet_rate"]["total"] == 1
    assert data["throughput"]["completion_rate"]["total"] == 1


def test_unavailable_correlation_warns_or_raises_in_strict_mode() -> None:
    counters = SimulationPerformanceCounters(enabled=True)
    counters.record_wire_packet(50, qpn=9, wr_id=0x55, byte_len=32)
    counters.record_cqe(60, qpn=9, wr_id=0x55)

    data = counters.to_dict()
    assert data["latency"]["doorbell_to_wire"]["unavailable"] == 1
    assert data["latency"]["doorbell_to_cqe"]["unavailable"] == 1
    assert len(data["warnings"]) == 2

    strict = SimulationPerformanceCounters(enabled=True, strict=True)
    try:
        strict.record_cqe(70, qpn=1, wr_id=2)
    except PerformanceCounterError as exc:
        assert "without matching doorbell" in str(exc)
    else:
        raise AssertionError("strict mode did not reject missing correlation")


def test_report_text_and_json_output_are_parsable() -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
        report_path = Path(tmpdir) / "perf.json"
        counters = SimulationPerformanceCounters(enabled=True, output_path=report_path)
        counters.record_doorbell(1, qpn=1, wr_id=1, opcode="SEND")
        counters.record_dma_read(2, byte_len=128)
        counters.record_wire_packet(3, qpn=1, wr_id=1, byte_len=128)
        counters.record_cqe(5, qpn=1, wr_id=1)

        text = counters.report_text()
        assert "Simulation performance counters" in text
        assert "latency doorbell_to_cqe" in text
        assert "rate dma_read_bytes" in text

        written = counters.write_report()
        assert written == report_path
        loaded = json.loads(report_path.read_text(encoding="utf-8"))
        assert loaded["latency"]["doorbell_to_cqe"]["avg_cycles"] == 4
        assert loaded["throughput"]["dma_read_bytes"]["total"] == 128


def test_environment_configuration() -> None:
    saved = {
        "SMARTNIC_SIM_PERF": os.environ.get("SMARTNIC_SIM_PERF"),
        "SMARTNIC_SIM_PERF_CLOCK_HZ": os.environ.get("SMARTNIC_SIM_PERF_CLOCK_HZ"),
        "SMARTNIC_SIM_PERF_OUT": os.environ.get("SMARTNIC_SIM_PERF_OUT"),
        "SMARTNIC_SIM_PERF_STRICT": os.environ.get("SMARTNIC_SIM_PERF_STRICT"),
    }
    try:
        os.environ["SMARTNIC_SIM_PERF"] = "1"
        os.environ["SMARTNIC_SIM_PERF_CLOCK_HZ"] = "156250000"
        os.environ["SMARTNIC_SIM_PERF_OUT"] = "build/perf/smoke.json"
        os.environ["SMARTNIC_SIM_PERF_STRICT"] = "true"

        counters = SimulationPerformanceCounters.from_env()
        assert counters.enabled is True
        assert counters.clock_hz == 156_250_000
        assert counters.output_path == Path("build/perf/smoke.json")
        assert counters.strict is True
    finally:
        for name, value in saved.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value


def run_all() -> None:
    test_disabled_counters_ignore_events()
    test_doorbell_to_cqe_and_wire_latency()
    test_multiple_outstanding_wqes_are_correlated_by_qpn_and_wr_id()
    test_dma_bandwidth_packet_rate_and_completion_rate()
    test_unavailable_correlation_warns_or_raises_in_strict_mode()
    test_report_text_and_json_output_are_parsable()
    test_environment_configuration()


if __name__ == "__main__":
    run_all()
    print("simulation performance counter tests passed")
