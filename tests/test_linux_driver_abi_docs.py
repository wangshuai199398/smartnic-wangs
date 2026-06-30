# SPDX-License-Identifier: MIT
"""Static checks for the 16.2 Linux driver ABI documentation."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def test_driver_abi_doc_has_required_sections() -> None:
    doc = read("docs/26-linux-driver-abi.md")

    for heading in (
        "# Linux 驱动 ABI",
        "## 设备节点与入口点",
        "## Probe / Remove 生命周期",
        "## ioctl ABI 概览",
        "## `SMARTNIC_IOCTL_MBOX_EXEC`",
        "## Queue ioctl ABI",
        "## mmap ABI",
        "## 资源生命周期",
        "## Memory Registration 与 DMA 规则",
        "## Queue 与 Doorbell ABI",
        "## 错误码与失败行为",
        "## 示例",
        "## 已知限制",
    ):
        assert heading in doc


def test_documented_uapi_names_match_header() -> None:
    doc = read("docs/26-linux-driver-abi.md")
    header = read("include/uapi/linux/smartnic_ioctl.h")

    for token in (
        "SMARTNIC_IOCTL_MAGIC",
        "SMARTNIC_IOCTL_MAX_DATA_DWORDS",
        "SMARTNIC_QUEUE_MMAP_BASE",
        "SMARTNIC_QUEUE_MMAP_STRIDE",
        "SMARTNIC_QUEUE_MMAP_OFFSET",
        "SMARTNIC_QUEUE_TYPE_SQ",
        "SMARTNIC_QUEUE_TYPE_RQ",
        "SMARTNIC_QUEUE_TYPE_CQ",
        "SMARTNIC_QUEUE_TYPE_DESC",
        "struct smartnic_ioctl_mbox",
        "struct smartnic_ioctl_queue",
        "struct smartnic_ioctl_queue_destroy",
        "SMARTNIC_IOCTL_MBOX_EXEC",
        "SMARTNIC_IOCTL_QUEUE_CREATE",
        "SMARTNIC_IOCTL_QUEUE_DESTROY",
        "SMARTNIC_IOCTL_QUEUE_QUERY",
    ):
        assert token in header
        assert token in doc


def test_documented_driver_paths_exist() -> None:
    doc = read("docs/26-linux-driver-abi.md")
    refs = sorted(set(re.findall(r"`((?:drivers|include|examples|docs)/[^`]+)`", doc)))
    assert refs

    for ref in refs:
        assert (ROOT / ref).exists(), f"missing documented path: {ref}"


def test_error_codes_and_mmap_rules_are_documented() -> None:
    doc = read("docs/26-linux-driver-abi.md")

    for token in (
        "-ENOTTY",
        "-EINVAL",
        "-EFAULT",
        "-ENODEV",
        "-EAGAIN",
        "-ENOMEM",
        "-EOVERFLOW",
        "-ENOENT",
        "-EPERM",
        "-EACCES",
        "-EOPNOTSUPP",
        "-EBUSY",
        "-ENOSPC",
        "-ETIMEDOUT",
        "-EIO",
        "dma_mmap_coherent",
        "io_remap_pfn_range",
        "pgprot_noncached",
        "VM_IO | VM_DONTEXPAND | VM_DONTDUMP",
    ):
        assert token in doc


def test_docs_index_and_task_status_are_consistent() -> None:
    index = read("docs/README.md")
    tasks = read("openspec/changes/add-rdma-smartnic-design-capability/tasks.md")

    assert "26-linux-driver-abi.md" in index
    assert "16.2" in index
    assert "- [x] 16.2 Document Linux driver ioctl ABI" in tasks
    assert "- [ ] 16.3 Document userspace Verbs API compatibility" in tasks
    assert "- [ ] 16.4 Document verification strategy" in tasks


def run_all() -> None:
    test_driver_abi_doc_has_required_sections()
    test_documented_uapi_names_match_header()
    test_documented_driver_paths_exist()
    test_error_codes_and_mmap_rules_are_documented()
    test_docs_index_and_task_status_are_consistent()


if __name__ == "__main__":
    run_all()
    print("Linux driver ABI documentation checks passed")
