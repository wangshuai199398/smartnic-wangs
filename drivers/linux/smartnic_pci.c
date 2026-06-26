// SPDX-License-Identifier: GPL-2.0-only
/*
 * PCIe probe/remove lifecycle for the prototype RDMA SmartNIC.
 *
 * This file intentionally stops at device bring-up and teardown. CSR mailbox,
 * char device, mmap, MSI-X setup, and data-path logic are added by later
 * OpenSpec tasks.
 */

#include <linux/delay.h>
#include <linux/device.h>
#include <linux/dma-mapping.h>
#include <linux/err.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/slab.h>

#include "smartnic_pci.h"
#include "smartnic_regs.h"

static const struct pci_device_id smartnic_pci_id_table[] = {
	{ PCI_DEVICE(SMARTNIC_PCI_VENDOR_ID, SMARTNIC_PCI_DEVICE_ID) },
	{ 0, }
};
MODULE_DEVICE_TABLE(pci, smartnic_pci_id_table);

static u32 smartnic_csr_read(struct smartnic_dev *sdev, u32 offset)
{
	return readl(sdev->control_bar.addr + offset);
}

static void smartnic_csr_write(struct smartnic_dev *sdev, u32 offset, u32 value)
{
	writel(value, sdev->control_bar.addr + offset);
}

static int smartnic_setup_dma_mask(struct smartnic_dev *sdev)
{
	struct device *dev = sdev->dev;
	int err;

	err = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(64));
	if (!err) {
		sdev->dma_64bit = true;
		dev_dbg(dev, "using 64-bit coherent DMA mask\n");
		return 0;
	}

	dev_dbg(dev, "64-bit DMA mask failed, trying 32-bit fallback: %d\n", err);

	err = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32));
	if (!err) {
		sdev->dma_64bit = false;
		dev_info(dev, "using 32-bit coherent DMA mask fallback\n");
		return 0;
	}

	dev_err(dev, "failed to set coherent DMA mask: %d\n", err);
	return err;
}

static int smartnic_map_bar(struct smartnic_dev *sdev, int bar,
			    struct smartnic_bar *mapped, bool required)
{
	struct pci_dev *pdev = sdev->pdev;
	resource_size_t len;

	mapped->index = bar;
	mapped->addr = NULL;
	mapped->start = pci_resource_start(pdev, bar);
	mapped->len = pci_resource_len(pdev, bar);

	if (!(pci_resource_flags(pdev, bar) & IORESOURCE_MEM) || !mapped->len) {
		if (required) {
			dev_err(sdev->dev, "BAR%d is missing or not MMIO\n", bar);
			return -ENODEV;
		}

		dev_dbg(sdev->dev, "optional BAR%d is not present\n", bar);
		return 0;
	}

	len = mapped->len;
	mapped->addr = pci_iomap(pdev, bar, 0);
	if (!mapped->addr) {
		if (required) {
			dev_err(sdev->dev, "failed to map required BAR%d\n", bar);
			return -ENOMEM;
		}

		dev_dbg(sdev->dev, "optional BAR%d mapping skipped\n", bar);
		return 0;
	}

	dev_info(sdev->dev, "mapped BAR%d start=%pa len=%pa\n",
		 bar, &mapped->start, &len);
	return 0;
}

static void smartnic_unmap_bar(struct smartnic_dev *sdev,
			       struct smartnic_bar *mapped)
{
	if (!mapped->addr)
		return;

	pci_iounmap(sdev->pdev, mapped->addr);
	mapped->addr = NULL;
	mapped->start = 0;
	mapped->len = 0;
}

static void smartnic_unmap_bars(struct smartnic_dev *sdev)
{
	smartnic_unmap_bar(sdev, &sdev->doorbell_bar);
	smartnic_unmap_bar(sdev, &sdev->control_bar);
}

static void smartnic_hw_reset(struct smartnic_dev *sdev)
{
	u32 status;
	int waited_us = 0;

	if (!sdev->control_bar.addr)
		return;

	dev_dbg(sdev->dev, "requesting device reset\n");
	mutex_lock(&sdev->state_lock);
	sdev->reset_active = true;
	mutex_unlock(&sdev->state_lock);

	smartnic_csr_write(sdev, SMARTNIC_CSR_RESET, SMARTNIC_RESET_REQUEST);

	do {
		usleep_range(SMARTNIC_RESET_POLL_US,
			     SMARTNIC_RESET_POLL_US * 2);
		waited_us += SMARTNIC_RESET_POLL_US;
		status = smartnic_csr_read(sdev, SMARTNIC_CSR_RESET);
		if (status & SMARTNIC_RESET_DONE) {
			dev_dbg(sdev->dev, "device reset completed\n");
			mutex_lock(&sdev->state_lock);
			sdev->reset_active = false;
			mutex_unlock(&sdev->state_lock);
			return;
		}
	} while (waited_us < SMARTNIC_RESET_TIMEOUT_US);

	mutex_lock(&sdev->state_lock);
	sdev->reset_active = false;
	mutex_unlock(&sdev->state_lock);
	dev_dbg(sdev->dev, "reset done bit not observed before timeout\n");
}

static void smartnic_discover_features(struct smartnic_dev *sdev)
{
	if (!sdev->control_bar.addr)
		return;

	sdev->version = smartnic_csr_read(sdev, SMARTNIC_CSR_VERSION);
	sdev->features = smartnic_csr_read(sdev, SMARTNIC_CSR_FEATURES);
	sdev->caps = smartnic_csr_read(sdev, SMARTNIC_CSR_CAPS);
	sdev->status = smartnic_csr_read(sdev, SMARTNIC_CSR_STATUS);

	dev_info(sdev->dev,
		 "version=0x%08x features=0x%08x caps=0x%08x status=0x%08x\n",
		 sdev->version, sdev->features, sdev->caps, sdev->status);
}

static void smartnic_disable_interrupts(struct smartnic_dev *sdev)
{
	if (!sdev->irq_initialized)
		return;

	/* MSI-X allocation and handlers are introduced in task 12.9. */
	sdev->irq_initialized = false;
}

static void smartnic_quiesce(struct smartnic_dev *sdev)
{
	mutex_lock(&sdev->state_lock);
	if (sdev->state != SMARTNIC_DEV_REMOVED)
		sdev->state = SMARTNIC_DEV_QUIESCING;
	mutex_unlock(&sdev->state_lock);

	/* Later tasks will stop queues, resource owners, and mailbox users. */
	dev_dbg(sdev->dev, "device quiesced\n");
}

static int smartnic_pci_probe(struct pci_dev *pdev,
			      const struct pci_device_id *id)
{
	struct smartnic_dev *sdev;
	int err;

	sdev = kzalloc(sizeof(*sdev), GFP_KERNEL);
	if (!sdev)
		return -ENOMEM;

	sdev->pdev = pdev;
	sdev->dev = &pdev->dev;
	sdev->state = SMARTNIC_DEV_PROBING;
	mutex_init(&sdev->state_lock);
	mutex_init(&sdev->mbox_lock);
	spin_lock_init(&sdev->irq_lock);
	init_waitqueue_head(&sdev->admin_wq);
	pci_set_drvdata(pdev, sdev);

	err = pci_enable_device_mem(pdev);
	if (err) {
		dev_err(&pdev->dev, "failed to enable PCI device: %d\n", err);
		goto err_free_sdev;
	}

	err = pci_request_regions(pdev, SMARTNIC_DRV_NAME);
	if (err) {
		dev_err(&pdev->dev, "failed to request PCI regions: %d\n", err);
		goto err_disable_device;
	}

	err = smartnic_setup_dma_mask(sdev);
	if (err)
		goto err_release_regions;

	pci_set_master(pdev);

	err = smartnic_map_bar(sdev, SMARTNIC_BAR_CONTROL,
			       &sdev->control_bar, true);
	if (err)
		goto err_clear_master;

	err = smartnic_map_bar(sdev, SMARTNIC_BAR_DOORBELL,
			       &sdev->doorbell_bar, false);
	if (err)
		goto err_unmap_bars;

	smartnic_hw_reset(sdev);
	smartnic_discover_features(sdev);

	mutex_lock(&sdev->state_lock);
	sdev->state = SMARTNIC_DEV_READY;
	mutex_unlock(&sdev->state_lock);

	dev_info(&pdev->dev, "SmartNIC PCIe device probed successfully\n");
	return 0;

err_unmap_bars:
	smartnic_unmap_bars(sdev);
err_clear_master:
	pci_clear_master(pdev);
err_release_regions:
	pci_release_regions(pdev);
err_disable_device:
	pci_disable_device(pdev);
err_free_sdev:
	pci_set_drvdata(pdev, NULL);
	kfree(sdev);
	return err;
}

static void smartnic_pci_remove(struct pci_dev *pdev)
{
	struct smartnic_dev *sdev = pci_get_drvdata(pdev);

	if (!sdev)
		return;

	dev_info(&pdev->dev, "removing SmartNIC PCIe device\n");

	smartnic_quiesce(sdev);
	smartnic_disable_interrupts(sdev);
	smartnic_unmap_bars(sdev);
	pci_clear_master(pdev);
	pci_release_regions(pdev);
	pci_disable_device(pdev);

	mutex_lock(&sdev->state_lock);
	sdev->state = SMARTNIC_DEV_REMOVED;
	mutex_unlock(&sdev->state_lock);

	pci_set_drvdata(pdev, NULL);
	kfree(sdev);
}

static struct pci_driver smartnic_pci_driver = {
	.name = SMARTNIC_DRV_NAME,
	.id_table = smartnic_pci_id_table,
	.probe = smartnic_pci_probe,
	.remove = smartnic_pci_remove,
};

module_pci_driver(smartnic_pci_driver);

MODULE_AUTHOR("RDMA SmartNIC OpenSpec prototype");
MODULE_DESCRIPTION("Prototype RDMA SmartNIC PCIe driver");
MODULE_LICENSE("GPL");
