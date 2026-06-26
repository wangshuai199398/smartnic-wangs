/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * PCIe lifecycle state for the prototype RDMA SmartNIC Linux driver.
 */

#ifndef _SMARTNIC_PCI_H
#define _SMARTNIC_PCI_H

#include <linux/atomic.h>
#include <linux/cdev.h>
#include <linux/io.h>
#include <linux/mutex.h>
#include <linux/pci.h>
#include <linux/spinlock.h>
#include <linux/types.h>
#include <linux/wait.h>

enum smartnic_dev_state {
	SMARTNIC_DEV_PROBING = 0,
	SMARTNIC_DEV_READY,
	SMARTNIC_DEV_QUIESCING,
	SMARTNIC_DEV_REMOVED,
};

struct smartnic_bar {
	int index;
	void __iomem *addr;
	resource_size_t start;
	resource_size_t len;
};

struct smartnic_dev {
	struct pci_dev *pdev;
	struct device *dev;

	struct smartnic_bar control_bar;
	struct smartnic_bar doorbell_bar;

	struct mutex state_lock;
	struct mutex mbox_lock;
	spinlock_t irq_lock;
	wait_queue_head_t admin_wq;
	wait_queue_head_t event_wq;
	wait_queue_head_t open_wq;

	enum smartnic_dev_state state;
	bool dma_64bit;
	bool irq_initialized;
	bool reset_active;
	bool chrdev_registered;
	atomic_t open_count;
	atomic_t event_pending;

	dev_t chrdev_devt;
	struct cdev cdev;
	struct device *chrdev_device;
	int chrdev_index;

	u32 version;
	u32 features;
	u32 caps;
	u32 status;
};

#endif /* _SMARTNIC_PCI_H */
