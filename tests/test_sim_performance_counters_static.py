# SPDX-License-Identifier: MIT
"""Static checks for the 15.5 simulation performance counter integration."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def test_performance_counter_module_exports_expected_api() -> None:
    source = read("sim/cocotb/bfm/performance_counters.py")
    exports = read("sim/cocotb/bfm/__init__.py")

    for name in (
        "SimulationPerformanceCounters",
        "record_doorbell",
        "record_wqe_accept",
        "record_wire_packet",
        "record_dma_read",
        "record_dma_write",
        "record_cqe",
        "write_report",
    ):
        assert name in source

    assert "SimulationPerformanceCounters" in exports
    assert "PerformanceCounterError" in exports


def test_build_and_regression_targets_are_present() -> None:
    root_makefile = read("Makefile")
    cocotb_makefile = read("sim/cocotb/Makefile")
    regression = read("tests/run_rdma_regression.sh")

    assert "sim-perf-counters:" in root_makefile
    assert "perf-counters: sim-perf-counters" in root_makefile
    assert "test-sim-performance-counters:" in cocotb_makefile
    assert "python3 test_sim_performance_counters.py" in cocotb_makefile
    assert "perf          Run optional simulation performance counter smoke checks." in regression
    assert "RDMA_REGRESSION_ENABLE_PERF" in regression
    assert "run_perf_group" in regression


def test_documentation_describes_counters_and_configuration() -> None:
    docs = read("docs/testing.md")

    for token in (
        "Simulation Performance Counters",
        "Doorbell-to-CQE latency",
        "Doorbell-to-wire latency",
        "DMA bandwidth",
        "Packet rate",
        "Completion rate",
        "SMARTNIC_SIM_PERF",
        "SMARTNIC_SIM_PERF_CLOCK_HZ",
        "SMARTNIC_SIM_PERF_OUT",
        "SMARTNIC_SIM_PERF_STRICT",
    ):
        assert token in docs


def test_task_15_5_is_marked_complete() -> None:
    tasks = read("openspec/changes/add-rdma-smartnic-design-capability/tasks.md")

    assert "- [x] 15.5 Add simulation performance counters" in tasks


def run_all() -> None:
    test_performance_counter_module_exports_expected_api()
    test_build_and_regression_targets_are_present()
    test_documentation_describes_counters_and_configuration()
    test_task_15_5_is_marked_complete()


if __name__ == "__main__":
    run_all()
    print("simulation performance counter static checks passed")
