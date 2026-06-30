#!/usr/bin/env python3
"""Static checks for the SmartNIC perftest compatibility runner."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def require(text: str, needle: str, label: str) -> None:
    assert needle in text, f"missing {label}: {needle}"


def main() -> None:
    script = read(ROOT / "tests/run_perftest_compat.sh")
    makefile = read(ROOT / "Makefile")
    regression = read(ROOT / "tests/run_rdma_regression.sh")
    docs = read(ROOT / "docs/testing.md")
    tasks = read(ROOT / "openspec/changes/add-rdma-smartnic-design-capability/tasks.md")

    for needle in [
        "SMARTNIC_PERFTEST_DEVICE",
        "SMARTNIC_PERFTEST_PORT",
        "SMARTNIC_PERFTEST_GID_INDEX",
        "SMARTNIC_PERFTEST_SERVER",
        "SMARTNIC_PERFTEST_SIZE",
        "SMARTNIC_PERFTEST_ITERS",
        "SMARTNIC_PERFTEST_QD",
        "SMARTNIC_PERFTEST_MTU",
        "SMARTNIC_PERFTEST_EXTRA_ARGS",
        "SMARTNIC_PERFTEST_OPS",
        "SMARTNIC_PERFTEST_TIMEOUT",
    ]:
        require(script, needle, f"perftest env {needle}")

    for needle in [
        "ib_send_bw",
        "ib_write_bw",
        "ib_read_bw",
        "send,write,read",
        "--role client|server",
        "--dry-run",
        "--force",
        "ibv_devices",
        "if [ \"${DRY_RUN}\" -eq 0 ]; then",
        "perftest command not found",
        "RDMA device not found",
        "client mode needs SMARTNIC_PERFTEST_SERVER",
        "timeout \"${TIMEOUT_SEC}\"",
        "build/perftest-compat",
    ]:
        require(script, needle, f"perftest runner behavior {needle}")

    for needle in [
        "compat-perftest:",
        "perftest: compat-perftest",
        "bash tests/run_perftest_compat.sh",
    ]:
        require(makefile, needle, f"Makefile perftest target {needle}")

    require(regression, "compatibility: perftest RC smoke", "regression perftest hook")
    require(regression, "tests/run_perftest_compat.sh", "regression perftest script path")

    for needle in [
        "Perftest Compatibility",
        "make compat-perftest",
        "ib_send_bw",
        "ib_write_bw",
        "ib_read_bw",
        "SMARTNIC_PERFTEST_SERVER",
        "SMARTNIC_PERFTEST_DEVICE",
        "SMARTNIC_PERFTEST_OPS",
        "build/perftest-compat",
    ]:
        require(docs, needle, f"perftest docs {needle}")

    require(tasks, "- [x] 15.2 Add perftest compatibility target", "15.2 task completion")
    print("perftest compatibility checks passed")


if __name__ == "__main__":
    main()
