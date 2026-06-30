#!/usr/bin/env python3
"""Static checks for the SmartNIC UCX compatibility runner."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def require(text: str, needle: str, label: str) -> None:
    assert needle in text, f"missing {label}: {needle}"


def main() -> None:
    script = read(ROOT / "tests/run_ucx_compat.sh")
    makefile = read(ROOT / "Makefile")
    regression = read(ROOT / "tests/run_rdma_regression.sh")
    docs = read(ROOT / "docs/testing.md")
    tasks = read(ROOT / "openspec/changes/add-rdma-smartnic-design-capability/tasks.md")

    for needle in [
        "SMARTNIC_UCX_DEVICE",
        "SMARTNIC_UCX_TLS",
        "SMARTNIC_UCX_GID_INDEX",
        "SMARTNIC_UCX_SERVER",
        "SMARTNIC_UCX_SIZE",
        "SMARTNIC_UCX_ITERS",
        "SMARTNIC_UCX_EXTRA_ARGS",
        "SMARTNIC_UCX_OPS",
        "SMARTNIC_UCX_TIMEOUT",
        "UCX_NET_DEVICES",
        "UCX_IB_GID_INDEX",
    ]:
        require(script, needle, f"UCX env {needle}")

    for needle in [
        "ucx_perftest",
        "ucx_info",
        "tag_bw",
        "put_bw",
        "get_bw",
        "send,write,read",
        "--role client|server",
        "--dry-run",
        "--force",
        "UCX command not found",
        "client mode needs SMARTNIC_UCX_SERVER",
        "timeout \"${TIMEOUT_SEC}\"",
        "build/ucx-compat",
    ]:
        require(script, needle, f"UCX runner behavior {needle}")

    for needle in [
        "compat-ucx:",
        "ucx: compat-ucx",
        "bash tests/run_ucx_compat.sh",
    ]:
        require(makefile, needle, f"Makefile UCX target {needle}")

    require(regression, "compatibility: UCX RC smoke", "regression UCX hook")
    require(regression, "tests/run_ucx_compat.sh", "regression UCX script path")

    for needle in [
        "UCX Compatibility",
        "make compat-ucx",
        "ucx_perftest",
        "tag_bw",
        "put_bw",
        "get_bw",
        "SMARTNIC_UCX_SERVER",
        "SMARTNIC_UCX_DEVICE",
        "SMARTNIC_UCX_OPS",
        "build/ucx-compat",
    ]:
        require(docs, needle, f"UCX docs {needle}")

    require(tasks, "- [x] 15.3 Add UCX compatibility smoke tests", "15.3 task completion")
    print("UCX compatibility checks passed")


if __name__ == "__main__":
    main()
