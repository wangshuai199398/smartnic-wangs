// SPDX-License-Identifier: GPL-2.0-only
/*
 * MSI-X allocation and ISR handling.
 *
 * The hardware event model is still minimal. Each ISR reads a shared
 * interrupt status CSR, acknowledges handled bits, marks userspace-visible
 * events, and wakes poll/ioctl waiters. CQ-specific delivery is added later.
 */

#include <linux/device.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/pci.h>
#include <linux/sprintf.h>

#include "smartnic_irq.h"
#include "smartnic_pci.h"
#include "smartnic_regs.h"

static u32 smartnic_irq_read(struct smartnic_dev *sdev, u32 offset)
{
	return readl(sdev->control_bar.addr + offset);
}

static void smartnic_irq_write(struct smartnic_dev *sdev, u32 offset, u32 value)
{
	writel(value, sdev->control_bar.addr + offset);
}

static const char *smartnic_irq_role(int vector)
{
	switch (vector) {
	case SMARTNIC_IRQ_ADMIN_VECTOR:
		return "admin";
	case SMARTNIC_IRQ_EVENT_VECTOR:
		return "event";
	default:
		return "cq";
	}
}

u32 smartnic_irq_filter_status(u32 status)
{
	return status & SMARTNIC_INTR_ALL_EVENTS;
}

static irqreturn_t smartnic_irq_handler(int irq, void *data)
{
	struct smartnic_dev *sdev = data;
	unsigned long flags;
	u32 status;
	u32 handled;

	if (!sdev || !sdev->control_bar.addr)
		return IRQ_NONE;

	status = smartnic_irq_read(sdev, SMARTNIC_INTR_STATUS);
	handled = smartnic_irq_filter_status(status);
	if (!handled)
		return IRQ_NONE;

	smartnic_irq_write(sdev, SMARTNIC_INTR_ACK, handled);

	spin_lock_irqsave(&sdev->irq_lock, flags);
	sdev->irq_last_status = handled;
	if (handled & SMARTNIC_INTR_MAILBOX_DONE)
		atomic_set(&sdev->mbox_event_pending, 1);
	if (handled & SMARTNIC_INTR_CQ_EVENT)
		atomic_set(&sdev->cq_event_pending, 1);
	if (handled & (SMARTNIC_INTR_MAILBOX_DONE |
		       SMARTNIC_INTR_ADMIN_EVENT |
		       SMARTNIC_INTR_CQ_EVENT |
		       SMARTNIC_INTR_FATAL_ERROR))
		atomic_set(&sdev->event_pending, 1);
	spin_unlock_irqrestore(&sdev->irq_lock, flags);

	wake_up_interruptible(&sdev->event_wq);
	wake_up_interruptible(&sdev->admin_wq);

	dev_dbg(sdev->dev, "irq %d status=0x%08x handled=0x%08x\n",
		irq, status, handled);
	return IRQ_HANDLED;
}

static void smartnic_irq_enable_hw(struct smartnic_dev *sdev)
{
	u32 mask = SMARTNIC_INTR_ALL_EVENTS;

	smartnic_irq_write(sdev, SMARTNIC_INTR_ACK, mask);
	smartnic_irq_write(sdev, SMARTNIC_INTR_ENABLE, mask);
}

void smartnic_irq_disable(struct smartnic_dev *sdev)
{
	int i;

	if (!sdev || !sdev->irq_initialized)
		return;

	if (sdev->control_bar.addr) {
		smartnic_irq_write(sdev, SMARTNIC_INTR_ENABLE, 0);
		smartnic_irq_write(sdev, SMARTNIC_INTR_ACK,
				   SMARTNIC_INTR_ALL_EVENTS);
	}

	for (i = 0; i < sdev->irq_vector_count; i++) {
		if (sdev->irq_entries[i].requested)
			synchronize_irq(sdev->irq_entries[i].irq);
	}
}

int smartnic_irq_setup(struct smartnic_dev *sdev)
{
	int vectors;
	int i;
	int err;

	vectors = pci_alloc_irq_vectors(sdev->pdev, SMARTNIC_MIN_IRQ_VECTORS,
					SMARTNIC_MAX_IRQ_VECTORS,
					PCI_IRQ_MSIX);
	if (vectors < 0) {
		dev_err(sdev->dev, "failed to allocate MSI-X vectors: %d\n",
			vectors);
		return vectors;
	}

	sdev->irq_vector_count = vectors;
	for (i = 0; i < vectors; i++) {
		struct smartnic_irq_entry *entry = &sdev->irq_entries[i];

		entry->irq = pci_irq_vector(sdev->pdev, i);
		scnprintf(entry->name, sizeof(entry->name), "%s-%s%d",
			  SMARTNIC_DRV_NAME, smartnic_irq_role(i), i);
		err = request_irq(entry->irq, smartnic_irq_handler, 0,
				  entry->name, sdev);
		if (err) {
			dev_err(sdev->dev,
				"failed to request IRQ vector %d irq %d: %d\n",
				i, entry->irq, err);
			goto err_free_irqs;
		}

		entry->requested = true;
		dev_info(sdev->dev, "registered IRQ vector %d (%s) irq=%d\n",
			 i, smartnic_irq_role(i), entry->irq);
	}

	sdev->irq_initialized = true;
	smartnic_irq_enable_hw(sdev);
	return 0;

err_free_irqs:
	while (--i >= 0) {
		if (sdev->irq_entries[i].requested) {
			free_irq(sdev->irq_entries[i].irq, sdev);
			sdev->irq_entries[i].requested = false;
		}
	}
	pci_free_irq_vectors(sdev->pdev);
	sdev->irq_vector_count = 0;
	return err;
}

void smartnic_irq_teardown(struct smartnic_dev *sdev)
{
	int i;

	if (!sdev || !sdev->irq_initialized)
		return;

	smartnic_irq_disable(sdev);

	for (i = 0; i < sdev->irq_vector_count; i++) {
		if (!sdev->irq_entries[i].requested)
			continue;

		free_irq(sdev->irq_entries[i].irq, sdev);
		sdev->irq_entries[i].requested = false;
		sdev->irq_entries[i].irq = 0;
	}

	pci_free_irq_vectors(sdev->pdev);
	sdev->irq_vector_count = 0;
	sdev->irq_initialized = false;
}
