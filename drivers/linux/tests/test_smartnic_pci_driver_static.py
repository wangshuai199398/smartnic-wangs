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
    regs_h = read(ROOT / "smartnic_regs.h")
    makefile = read(ROOT / "Makefile")
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
    ]:
        require(pci_h, needle, label)

    for needle, label in [
        ("#define SMARTNIC_PCI_VENDOR_ID", "vendor id macro"),
        ("#define SMARTNIC_PCI_DEVICE_ID", "device id macro"),
        ("#define SMARTNIC_CSR_VERSION", "version CSR"),
        ("#define SMARTNIC_CSR_FEATURES", "features CSR"),
        ("#define SMARTNIC_CSR_CAPS", "caps CSR"),
    ]:
        require(regs_h, needle, label)

    require(makefile, "obj-m := smartnic.o", "Kbuild module object")
    require(makefile, "smartnic-y := smartnic_pci.o", "driver object list")
    require(tasks, "- [x] 12.1 Implement PCIe driver probe/remove", "12.1 task completion")

    print("smartnic PCI driver static checks passed")


if __name__ == "__main__":
    main()
