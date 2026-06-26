#!/usr/bin/env python3
"""Check driver docs and examples reference current UAPI names."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def require(text: str, needle: str, label: str) -> None:
    assert needle in text, f"missing {label}: {needle}"


def main() -> None:
    driver = read(ROOT / "docs/driver.md")
    uapi = read(ROOT / "docs/uapi.md")
    troubleshooting = read(ROOT / "docs/troubleshooting.md")
    ex_ioctl = read(ROOT / "examples/smartnic_ioctl_example.c")
    ex_poll = read(ROOT / "examples/smartnic_poll_example.c")
    tasks = read(ROOT / "openspec/changes/add-rdma-smartnic-design-capability/tasks.md")

    combined_docs = "\n".join([driver, uapi, troubleshooting])
    for needle in [
        "SMARTNIC_IOCTL_MBOX_EXEC",
        "SMARTNIC_IOCTL_QUEUE_CREATE",
        "SMARTNIC_IOCTL_QUEUE_DESTROY",
        "SMARTNIC_IOCTL_QUEUE_QUERY",
        "SMARTNIC_CSR_RESET",
        "SMARTNIC_INTR_STATUS",
    ]:
        require(combined_docs, needle, f"doc reference {needle}")

    for needle in [
        "PCIe Probe 与 Remove",
        "BAR 与 CSR 映射",
        "CSR Mailbox",
        "字符设备",
        "DMA Ring 生命周期",
        "MSI-X 中断处理",
    ]:
        require(driver, needle, f"driver overview {needle}")

    for needle in [
        "struct smartnic_ioctl_mbox",
        "struct smartnic_ioctl_queue",
        "POLLIN | POLLRDNORM",
        "-ENOTTY",
        "-EINVAL",
    ]:
        require(uapi, needle, f"UAPI reference {needle}")

    for needle in [
        "Probe 失败",
        "BAR 映射失败",
        "DMA 掩码设置失败",
        "Mailbox 超时",
        "MSI-X 分配失败",
        "使用中设备被移除",
    ]:
        require(troubleshooting, needle, f"troubleshooting {needle}")

    for source in [ex_ioctl, ex_poll]:
        require(source, "#include <linux/smartnic_ioctl.h>", "example UAPI include")

    require(ex_ioctl, "SMARTNIC_IOCTL_MBOX_EXEC", "mailbox example")
    require(ex_ioctl, "SMARTNIC_IOCTL_QUEUE_CREATE", "queue create example")
    require(ex_ioctl, "SMARTNIC_IOCTL_QUEUE_DESTROY", "queue destroy example")
    require(ex_poll, "poll(&pfd", "poll example")
    require(ex_poll, "mmap(NULL", "mmap example")
    require(tasks, "- [x] 12.8 Implement driver documentation", "12.8 task completion")

    print("smartnic driver documentation checks passed")


if __name__ == "__main__":
    main()
