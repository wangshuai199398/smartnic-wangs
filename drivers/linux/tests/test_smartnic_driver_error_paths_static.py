#!/usr/bin/env python3
"""Static self-tests for SmartNIC Linux driver error paths and test hooks."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def require(text: str, needle: str, label: str) -> None:
    assert needle in text, f"missing {label}: {needle}"


def require_order(text: str, *needles: str, label: str) -> None:
    pos = -1
    for needle in needles:
        next_pos = text.find(needle, pos + 1)
        assert next_pos >= 0, f"missing {label}: {needle}"
        assert next_pos > pos, f"bad order for {label}: {needle}"
        pos = next_pos


def main() -> None:
    pci_c = read(ROOT / "smartnic_pci.c")
    pci_h = read(ROOT / "smartnic_pci.h")
    mbox_c = read(ROOT / "smartnic_mbox.c")
    mbox_h = read(ROOT / "smartnic_mbox.h")
    chrdev_c = read(ROOT / "smartnic_chrdev.c")
    chrdev_h = read(ROOT / "smartnic_chrdev.h")
    dma_c = read(ROOT / "smartnic_dma.c")
    dma_h = read(ROOT / "smartnic_dma.h")
    irq_c = read(ROOT / "smartnic_irq.c")
    irq_h = read(ROOT / "smartnic_irq.h")
    queue_c = read(ROOT / "smartnic_queue.c")
    kunit_c = read(ROOT / "smartnic_kunit.c")
    makefile = read(ROOT / "Makefile")
    docs = read(REPO / "docs/smartnic-driver-tests.md")
    tasks = read(REPO / "openspec/changes/add-rdma-smartnic-design-capability/tasks.md")

    # PCIe probe/remove failure unwind and partial-remove safety.
    for needle in [
        "err_irq_teardown:",
        "err_mark_quiescing:",
        "err_unmap_bars:",
        "err_clear_master:",
        "err_release_regions:",
        "err_disable_device:",
        "err_free_sdev:",
        "smartnic_chrdev_unregister(sdev)",
        "smartnic_irq_teardown(sdev)",
        "smartnic_unmap_bars(sdev)",
        "pci_clear_master(pdev)",
        "pci_release_regions(pdev)",
        "pci_disable_device(pdev)",
    ]:
        require(pci_c, needle, f"PCIe probe/remove cleanup {needle}")

    require_order(
        pci_c,
        "smartnic_irq_setup(sdev)",
        "smartnic_chrdev_register(sdev)",
        "SmartNIC PCIe device probed successfully",
        label="probe success path",
    )
    require_order(
        pci_c,
        "smartnic_chrdev_unregister(sdev)",
        "smartnic_irq_teardown(sdev)",
        "smartnic_unmap_bars(sdev)",
        "pci_disable_device(pdev)",
        "kfree(sdev)",
        label="remove cleanup order",
    )
    for needle in [
        "failed to set coherent DMA mask",
        "BAR%d is missing or not MMIO",
        "failed to map required BAR%d",
        "reset done bit not observed before timeout",
        "smartnic_discover_features",
    ]:
        require(pci_c, needle, f"probe fault coverage {needle}")

    # Fault-injection hooks are guarded so production state stays clean.
    for needle in [
        "#ifdef CONFIG_SMARTNIC_KUNIT",
        "struct smartnic_test_faults",
        "fail_bar_mapping",
        "fail_dma_mask_setup",
        "fail_mailbox_completion",
        "fail_chrdev_registration",
        "fail_msix_allocation",
    ]:
        require(pci_h, needle, f"fault injection hook {needle}")

    # CSR mailbox timeout, error-code mapping, invalid argument, and locking.
    for needle in [
        "int smartnic_mbox_device_error_to_errno",
        "SMARTNIC_MBOX_ERR_INVALID_CMD",
        "return -EOPNOTSUPP",
        "SMARTNIC_MBOX_ERR_INVALID_ARG",
        "return -EINVAL",
        "SMARTNIC_MBOX_ERR_PERMISSION",
        "return -EACCES",
        "SMARTNIC_MBOX_ERR_BUSY",
        "return -EBUSY",
        "SMARTNIC_MBOX_ERR_TIMEOUT",
        "return -ETIMEDOUT",
        "readl_poll_timeout",
        "mutex_lock(&sdev->mbox_lock)",
        "mutex_unlock(&sdev->mbox_lock)",
        "smartnic_mbox_validate_bufs",
    ]:
        require(mbox_c, needle, f"mailbox error path {needle}")
    require(mbox_h, "smartnic_mbox_device_error_to_errno", "mailbox pure helper")

    # Character device validation and poll/mmap contracts.
    for needle in [
        "smartnic_chrdev_poll_mask",
        "atomic_inc(&sdev->open_count)",
        "atomic_dec_and_test(&sdev->open_count)",
        "_IOC_TYPE(cmd) != SMARTNIC_IOCTL_MAGIC",
        "return -ENOTTY",
        "req.struct_size != sizeof(req)",
        "copy_from_user",
        "copy_to_user",
        "if (!size",
        "return -EPERM",
        "io_remap_pfn_range",
        "POLLERR | POLLHUP",
        "POLLIN | POLLRDNORM",
        "POLLOUT | POLLWRNORM",
    ]:
        require(chrdev_c, needle, f"char device error path {needle}")
    require(chrdev_h, "smartnic_chrdev_poll_mask", "poll mask test helper")

    # DMA allocation, mmap, and partial initialization cleanup.
    for needle in [
        "smartnic_dma_ring_validate_params",
        "return -EINVAL",
        "return -EOVERFLOW",
        "return -ENOMEM",
        "dma_alloc_coherent",
        "dma_free_coherent",
        "memset(ring, 0, sizeof(*ring))",
    ]:
        require(dma_c, needle, f"DMA error path {needle}")
    require(dma_h, "smartnic_dma_ring_validate_params", "DMA validation helper")

    for needle in [
        "err_free_queue:",
        "smartnic_queue_free_locked(queue)",
        "dma_mmap_coherent",
        "size > queue->ring.size",
        "err = -EPERM",
        "list_for_each_entry_safe",
    ]:
        require(queue_c, needle, f"queue cleanup/mmap path {needle}")

    # MSI-X setup, ISR dispatch, notification, and teardown.
    for needle in [
        "pci_alloc_irq_vectors",
        "request_irq",
        "goto err_free_irqs",
        "while (--i >= 0)",
        "smartnic_irq_filter_status",
        "return IRQ_NONE",
        "return IRQ_HANDLED",
        "SMARTNIC_INTR_ACK",
        "atomic_set(&sdev->mbox_event_pending, 1)",
        "atomic_set(&sdev->cq_event_pending, 1)",
        "wake_up_interruptible(&sdev->event_wq)",
        "synchronize_irq",
        "free_irq",
        "pci_free_irq_vectors",
    ]:
        require(irq_c, needle, f"IRQ/MSI-X path {needle}")
    require(irq_h, "smartnic_irq_filter_status", "IRQ filter helper")

    # Optional kernel-style tests should cover the newly exposed pure helpers.
    for needle in [
        "smartnic_kunit_mailbox_error_mapping",
        "smartnic_kunit_dma_param_validation",
        "smartnic_kunit_poll_masks",
        "smartnic_kunit_irq_filtering",
        "smartnic_kunit_fault_hook_layout",
        "KUNIT_CASE(smartnic_kunit_mailbox_error_mapping)",
        "KUNIT_CASE(smartnic_kunit_dma_param_validation)",
        "KUNIT_CASE(smartnic_kunit_poll_masks)",
        "KUNIT_CASE(smartnic_kunit_irq_filtering)",
        "KUNIT_CASE(smartnic_kunit_fault_hook_layout)",
    ]:
        require(kunit_c, needle, f"KUnit error-path case {needle}")

    require(makefile, "test_smartnic_driver_error_paths_static.py",
            "error-path static test in syntax-check")
    require(docs, "12.10", "12.10 documentation")
    require(tasks, "- [x] 12.10 Implement driver self-tests", "12.10 task completion")

    print("smartnic driver error-path static tests passed")


if __name__ == "__main__":
    main()
