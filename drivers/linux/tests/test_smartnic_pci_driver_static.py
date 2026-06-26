#!/usr/bin/env python3
"""Static checks for the 12.1 SmartNIC PCIe probe/remove driver."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def require(text: str, needle: str, label: str) -> None:
    assert needle in text, f"missing {label}: {needle}"


def main() -> None:
    pci_c = read(ROOT / "smartnic_pci.c")
    pci_h = read(ROOT / "smartnic_pci.h")
    mbox_c = read(ROOT / "smartnic_mbox.c")
    mbox_h = read(ROOT / "smartnic_mbox.h")
    chrdev_c = read(ROOT / "smartnic_chrdev.c")
    chrdev_h = read(ROOT / "smartnic_chrdev.h")
    irq_c = read(ROOT / "smartnic_irq.c")
    irq_h = read(ROOT / "smartnic_irq.h")
    regs_h = read(ROOT / "smartnic_regs.h")
    makefile = read(ROOT / "Makefile")
    ioctl_h = read(REPO / "include/uapi/linux/smartnic_ioctl.h")
    tasks = read(REPO / "openspec/changes/add-rdma-smartnic-design-capability/tasks.md")

    for needle, label in [
        ("static const struct pci_device_id smartnic_pci_id_table", "PCI ID table"),
        ("MODULE_DEVICE_TABLE(pci, smartnic_pci_id_table)", "module device table"),
        ("static struct pci_driver smartnic_pci_driver", "pci_driver"),
        ("module_pci_driver(smartnic_pci_driver)", "pci_driver registration"),
        ("smartnic_pci_probe", "probe callback"),
        ("smartnic_pci_remove", "remove callback"),
    ]:
        require(pci_c, needle, label)

    for needle, label in [
        ("pci_enable_device_mem", "PCI enable"),
        ("pci_request_regions", "region request"),
        ("DMA_BIT_MASK(64)", "64-bit DMA mask"),
        ("DMA_BIT_MASK(32)", "32-bit DMA fallback"),
        ("pci_set_master", "bus mastering"),
        ("pci_iomap", "BAR mapping"),
        ("SMARTNIC_BAR_CONTROL", "control BAR mapping"),
        ("SMARTNIC_BAR_DOORBELL", "optional BAR mapping"),
        ("pci_set_drvdata", "private data storage"),
        ("SMARTNIC_CSR_RESET", "reset CSR"),
        ("smartnic_discover_features", "feature discovery"),
    ]:
        require(pci_c, needle, label)

    for needle, label in [
        ("err_unmap_bars:", "BAR unwind label"),
        ("err_release_regions:", "regions unwind label"),
        ("err_disable_device:", "device unwind label"),
        ("err_free_sdev:", "private state unwind label"),
        ("pci_iounmap", "BAR unmap"),
        ("pci_release_regions", "release regions"),
        ("pci_disable_device", "disable device"),
        ("kfree(sdev)", "private state free"),
    ]:
        require(pci_c, needle, label)

    for needle, label in [
        ("struct smartnic_dev", "private device struct"),
        ("struct smartnic_bar", "BAR state struct"),
        ("wait_queue_head_t admin_wq", "wait queue"),
        ("struct mutex state_lock", "state lock"),
        ("spinlock_t irq_lock", "IRQ lock"),
        ("struct mutex mbox_lock", "mailbox lock"),
        ("bool reset_active", "reset-active guard"),
        ("wait_queue_head_t event_wq", "poll wait queue"),
        ("wait_queue_head_t open_wq", "open lifetime wait queue"),
        ("atomic_t open_count", "open reference count"),
        ("atomic_t event_pending", "poll event flag"),
        ("atomic_t mbox_event_pending", "mailbox event flag"),
        ("atomic_t cq_event_pending", "CQ event flag"),
        ("struct cdev cdev", "cdev storage"),
        ("dev_t chrdev_devt", "char dev number"),
        ("irq_vector_count", "IRQ vector count"),
        ("irq_last_status", "last IRQ status"),
        ("struct smartnic_irq_entry irq_entries", "IRQ entries"),
    ]:
        require(pci_h, needle, label)

    for needle, label in [
        ("#define SMARTNIC_PCI_VENDOR_ID", "vendor id macro"),
        ("#define SMARTNIC_PCI_DEVICE_ID", "device id macro"),
        ("#define SMARTNIC_CSR_VERSION", "version CSR"),
        ("#define SMARTNIC_CSR_FEATURES", "features CSR"),
        ("#define SMARTNIC_CSR_CAPS", "caps CSR"),
        ("#define SMARTNIC_MBOX_COMMAND", "mailbox command CSR"),
        ("#define SMARTNIC_MBOX_CONTROL", "mailbox control CSR"),
        ("#define SMARTNIC_MBOX_STATUS", "mailbox status CSR"),
        ("#define SMARTNIC_MBOX_ERROR", "mailbox error CSR"),
        ("#define SMARTNIC_MBOX_ARG", "mailbox arg CSR helper"),
        ("#define SMARTNIC_INTR_STATUS", "interrupt status CSR"),
        ("#define SMARTNIC_INTR_ENABLE", "interrupt enable CSR"),
        ("#define SMARTNIC_INTR_ACK", "interrupt ack CSR"),
        ("#define SMARTNIC_INTR_MAILBOX_DONE", "mailbox interrupt bit"),
        ("#define SMARTNIC_INTR_CQ_EVENT", "CQ interrupt bit"),
        ("#define SMARTNIC_MAX_IRQ_VECTORS", "max IRQ vectors"),
    ]:
        require(regs_h, needle, label)

    require(makefile, "obj-m := smartnic.o", "Kbuild module object")
    require(makefile, "ccflags-y += -I$(src)/../../include", "UAPI include path")
    require(makefile, "smartnic-y := smartnic_pci.o smartnic_mbox.o smartnic_chrdev.o smartnic_irq.o", "driver object list")
    require(tasks, "- [x] 12.1 Implement PCIe driver probe/remove", "12.1 task completion")

    for needle, label in [
        ("int smartnic_mbox_exec", "mailbox public helper"),
        ("mutex_lock(&sdev->mbox_lock)", "mailbox serialization"),
        ("readl_poll_timeout", "mailbox timeout polling"),
        ("-ETIMEDOUT", "timeout errno"),
        ("smartnic_mbox_map_error", "device error mapping"),
        ("SMARTNIC_MBOX_CTRL_CLEAR_STATUS", "stale status clear"),
        ("smartnic_mbox_write_args", "input arguments before doorbell"),
        ("SMARTNIC_MBOX_CTRL_GO", "mailbox doorbell/start bit"),
        ("smartnic_mbox_read_args", "output read after done"),
        ("SMARTNIC_DEV_REMOVED", "safe remove guard"),
        ("reset_active", "reset-active guard"),
    ]:
        require(mbox_c, needle, label)

    for needle, label in [
        ("smartnic_mbox_exec", "mailbox helper declaration"),
        ("const void *in_buf", "mailbox input buffer"),
        ("void *out_buf", "mailbox output buffer"),
    ]:
        require(mbox_h, needle, label)

    require(tasks, "- [x] 12.2 Implement CSR mailbox helper", "12.2 task completion")

    for needle, label in [
        ("#define SMARTNIC_IOCTL_MAGIC", "ioctl magic"),
        ("struct smartnic_ioctl_mbox", "mailbox ioctl struct"),
        ("SMARTNIC_IOCTL_MBOX_EXEC", "mailbox ioctl command"),
        ("_IOWR", "read/write ioctl encoding"),
    ]:
        require(ioctl_h, needle, label)

    for needle, label in [
        ("alloc_chrdev_region", "char dev allocation"),
        ("cdev_init", "cdev init"),
        ("cdev_add", "cdev add"),
        ("class_create", "class create"),
        ("device_create", "device node create"),
        ("smartnic_chrdev_open", "open op"),
        ("smartnic_chrdev_release", "release op"),
        ("smartnic_chrdev_ioctl", "ioctl op"),
        ("smartnic_chrdev_mmap", "mmap op"),
        ("smartnic_chrdev_poll", "poll op"),
        ("compat_ioctl", "compat ioctl op"),
        ("copy_from_user", "safe user input copy"),
        ("copy_to_user", "safe user output copy"),
        ("-ENOTTY", "unknown ioctl error"),
        ("smartnic_mbox_exec", "mailbox dispatch"),
        ("io_remap_pfn_range", "IO mmap remap"),
        ("pgprot_noncached", "noncached mmap protection"),
        ("poll_wait", "poll wait queue"),
        ("POLLIN | POLLRDNORM", "readable poll mask"),
        ("POLLOUT | POLLWRNORM", "writable poll mask"),
        ("POLLERR | POLLHUP", "teardown poll mask"),
        ("wake_up_all(&sdev->event_wq)", "teardown poll wake"),
        ("wait_event(sdev->open_wq", "remove waits for open refs"),
        ("device_destroy", "device destroy"),
        ("unregister_chrdev_region", "char dev unregister"),
    ]:
        require(chrdev_c, needle, label)

    for needle, label in [
        ("smartnic_chrdev_register", "char dev register declaration"),
        ("smartnic_chrdev_unregister", "char dev unregister declaration"),
    ]:
        require(chrdev_h, needle, label)

    for needle, label in [
        ("smartnic_chrdev_register(sdev)", "probe char dev registration"),
        ("smartnic_chrdev_unregister(sdev)", "remove char dev cleanup"),
        ("smartnic_irq_setup(sdev)", "probe IRQ setup"),
        ("smartnic_irq_teardown(sdev)", "remove IRQ teardown"),
    ]:
        require(pci_c, needle, label)

    require(tasks, "- [x] 12.3 Implement character device open", "12.3 task completion")

    for needle, label in [
        ("pci_alloc_irq_vectors", "MSI-X vector allocation"),
        ("PCI_IRQ_MSIX", "MSI-X flag"),
        ("pci_irq_vector", "IRQ number lookup"),
        ("request_irq", "IRQ registration"),
        ("free_irq", "IRQ free"),
        ("pci_free_irq_vectors", "MSI-X vector free"),
        ("synchronize_irq", "IRQ synchronize on teardown"),
        ("static irqreturn_t smartnic_irq_handler", "ISR"),
        ("SMARTNIC_INTR_STATUS", "interrupt status read"),
        ("SMARTNIC_INTR_ACK", "interrupt ack write"),
        ("SMARTNIC_INTR_MAILBOX_DONE", "mailbox bit handling"),
        ("SMARTNIC_INTR_CQ_EVENT", "CQ bit handling"),
        ("wake_up_interruptible(&sdev->event_wq)", "poll wakeup"),
        ("IRQ_HANDLED", "handled IRQ return"),
        ("IRQ_NONE", "shared/unrelated IRQ return"),
        ("smartnic_irq_disable", "IRQ disable helper"),
        ("SMARTNIC_INTR_ENABLE, 0", "hardware interrupt disable"),
    ]:
        require(irq_c, needle, label)

    for needle, label in [
        ("smartnic_irq_setup", "IRQ setup declaration"),
        ("smartnic_irq_teardown", "IRQ teardown declaration"),
        ("smartnic_irq_disable", "IRQ disable declaration"),
    ]:
        require(irq_h, needle, label)

    require(tasks, "- [x] 12.5 Implement driver interrupt support", "12.5 task completion")

    print("smartnic PCI driver static checks passed")


if __name__ == "__main__":
    main()
