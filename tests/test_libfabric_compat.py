#!/usr/bin/env python3
"""Static checks for the SmartNIC libfabric compatibility runner."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def require(text: str, needle: str, label: str) -> None:
    assert needle in text, f"missing {label}: {needle}"


def main() -> None:
    script = read(ROOT / "tests/run_libfabric_compat.sh")
    makefile = read(ROOT / "Makefile")
    regression = read(ROOT / "tests/run_rdma_regression.sh")
    docs = read(ROOT / "docs/testing.md")
    tasks = read(ROOT / "openspec/changes/add-rdma-smartnic-design-capability/tasks.md")

    for needle in [
        "SMARTNIC_LIBFABRIC_PROVIDER",
        "SMARTNIC_LIBFABRIC_DEVICE",
        "SMARTNIC_LIBFABRIC_DOMAIN",
        "SMARTNIC_LIBFABRIC_FABRIC",
        "SMARTNIC_LIBFABRIC_SERVICE",
        "SMARTNIC_LIBFABRIC_SERVER",
        "SMARTNIC_LIBFABRIC_SIZE",
        "SMARTNIC_LIBFABRIC_ITERS",
        "SMARTNIC_LIBFABRIC_QD",
        "SMARTNIC_LIBFABRIC_EXTRA_ARGS",
        "SMARTNIC_LIBFABRIC_OPS",
        "SMARTNIC_LIBFABRIC_TIMEOUT",
        "FI_VERBS_IFACE",
    ]:
        require(script, needle, f"libfabric env {needle}")

    for needle in [
        "fi_info",
        "fi_pingpong",
        "fi_rma_pingpong",
        "send,write,read",
        "--role client|server",
        "--dry-run",
        "--force",
        "verbs-backed libfabric provider unavailable",
        "libfabric command not found",
        "client mode needs SMARTNIC_LIBFABRIC_SERVER",
        "timeout \"${TIMEOUT_SEC}\"",
        "build/libfabric-compat",
        "-o\" \"${op}\"",
    ]:
        require(script, needle, f"libfabric runner behavior {needle}")

    for needle in [
        "compat-libfabric:",
        "libfabric: compat-libfabric",
        "bash tests/run_libfabric_compat.sh",
    ]:
        require(makefile, needle, f"Makefile libfabric target {needle}")

    require(regression, "compatibility: libfabric verbs smoke", "regression libfabric hook")
    require(regression, "tests/run_libfabric_compat.sh", "regression libfabric script path")

    for needle in [
        "Libfabric Compatibility",
        "make compat-libfabric",
        "fi_info",
        "fi_pingpong",
        "fi_rma_pingpong",
        "SMARTNIC_LIBFABRIC_SERVER",
        "SMARTNIC_LIBFABRIC_PROVIDER",
        "SMARTNIC_LIBFABRIC_OPS",
        "build/libfabric-compat",
    ]:
        require(docs, needle, f"libfabric docs {needle}")

    require(tasks, "- [x] 15.4 Add libfabric compatibility smoke tests", "15.4 task completion")
    print("libfabric compatibility checks passed")


if __name__ == "__main__":
    main()
