#!/usr/bin/env python3
"""Focused static tests for SmartNIC driver lifecycle and failure paths."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def require(text: str, needle: str, label: str) -> None:
    assert needle in text, f"missing {label}: {needle}"


def require_order(text: str, first: str, second: str, label: str) -> None:
    a = text.rfind(first)
    b = text.rfind(second)
    assert a >= 0 and b >= 0 and a < b, f"bad order for {label}: {first} before {second}"


def main() -> None:
    pci_c = read(ROOT / "smartnic_pci.c")
    chrdev_c = read(ROOT / "smartnic_chrdev.c")
    mbox_c = read(ROOT / "smartnic_mbox.c")
    irq_c = read(ROOT / "smartnic_irq.c")
    dma_c = read(ROOT / "smartnic_dma.c")
    queue_c = read(ROOT / "smartnic_queue.c")
    kunit_c = read(ROOT / "smartnic_kunit.c")
    makefile = read(ROOT / "Makefile")
    shell_test = read(REPO / "tests/smartnic_driver_test.sh")
    selftest = read(REPO / "tools/testing/selftests/smartnic/smartnic_driver_smoke.sh")
    tasks = read(REPO / "openspec/changes/add-rdma-smartnic-design-capability/tasks.md")

    # Probe/remove and unwind coverage.
    for needle in [
        "pci_enable_device_mem",
        "pci_request_regions",
        "smartnic_setup_dma_mask",
        "smartnic_map_bar",
        "smartnic_irq_setup",
        "smartnic_chrdev_register",
        "err_irq_teardown:",
        "err_unmap_bars:",
        "err_release_regions:",
        "err_disable_device:",
        "smartnic_chrdev_unregister",
        "smartnic_irq_teardown",
        "smartnic_unmap_bars",
    ]:
        require(pci_c, needle, f"probe/remove path {needle}")

    require_order(pci_c, "smartnic_chrdev_unregister(sdev)", "smartnic_irq_teardown(sdev)",
                  "remove quiesces userspace before IRQ teardown")
    require_order(pci_c, "smartnic_irq_teardown(sdev)", "smartnic_unmap_bars(sdev)",
                  "IRQ teardown before BAR unmap")

    # Mailbox behavior coverage.
    for needle in [
        "mutex_lock(&sdev->mbox_lock)",
        "readl_poll_timeout",
        "return -ETIMEDOUT",
        "return -EOPNOTSUPP",
        "return -EINVAL",
        "return -EACCES",
        "return -EBUSY",
        "return -ENOSPC",
        "smartnic_mbox_clear_status",
        "smartnic_mbox_write_args",
        "SMARTNIC_MBOX_CTRL_GO",
    ]:
        require(mbox_c, needle, f"mailbox behavior {needle}")

    # Character device, ioctl, mmap, and poll coverage.
    for needle in [
        "smartnic_chrdev_open",
        "smartnic_chrdev_release",
        "return -ENOTTY",
        "copy_from_user",
        "copy_to_user",
        "req.struct_size != sizeof(req)",
        "return -EINVAL",
        "return -EPERM",
        "smartnic_queue_mmap",
        "POLLERR | POLLHUP",
        "POLLIN | POLLRDNORM",
        "POLLOUT | POLLWRNORM",
    ]:
        require(chrdev_c, needle, f"char device behavior {needle}")

    # IRQ failure and ISR behavior coverage.
    for needle in [
        "pci_alloc_irq_vectors",
        "goto err_free_irqs",
        "while (--i >= 0)",
        "free_irq",
        "pci_free_irq_vectors",
        "return IRQ_NONE",
        "return IRQ_HANDLED",
        "SMARTNIC_INTR_ACK",
        "SMARTNIC_INTR_MAILBOX_DONE",
        "SMARTNIC_INTR_CQ_EVENT",
        "wake_up_interruptible(&sdev->event_wq)",
    ]:
        require(irq_c, needle, f"IRQ behavior {needle}")

    # DMA and queue lifecycle coverage.
    for needle in [
        "dma_alloc_coherent",
        "dma_free_coherent",
        "is_power_of_2",
        "check_mul_overflow",
        "SMARTNIC_DMA_RING_MAX_BYTES",
        "return -EINVAL",
        "return -ENOMEM",
    ]:
        require(dma_c, needle, f"DMA behavior {needle}")

    for needle in [
        "smartnic_file_destroy",
        "list_for_each_entry_safe",
        "smartnic_queue_free_locked",
        "smartnic_dma_ring_free",
        "dma_mmap_coherent",
        "SMARTNIC_IOCTL_QUEUE_CREATE",
        "SMARTNIC_IOCTL_QUEUE_DESTROY",
        "SMARTNIC_IOCTL_QUEUE_QUERY",
    ]:
        require(queue_c, needle, f"queue behavior {needle}")

    # KUnit and selftest hooks.
    for needle in [
        "kunit_test_suite",
        "KUNIT_CASE",
        "smartnic_kunit_uapi_layout",
        "smartnic_kunit_dma_limits",
        "smartnic_kunit_irq_bits",
    ]:
        require(kunit_c, needle, f"KUnit hook {needle}")

    require(makefile, "smartnic-$(CONFIG_SMARTNIC_KUNIT) += smartnic_kunit.o",
            "optional KUnit object")
    require(makefile, "test_smartnic_driver_lifecycle_static.py",
            "driver lifecycle static test target")
    require(shell_test, "No /dev/smartnic device present; hardware smoke tests skipped",
            "hardware skip message")
    require(selftest, "run_driver_integration.sh", "selftest delegates to integration test")
    require(tasks, "- [x] 12.7 Implement driver tests", "12.7 task completion")

    print("smartnic driver lifecycle static tests passed")


if __name__ == "__main__":
    main()
