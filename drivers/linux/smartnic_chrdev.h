/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Character device control surface for the prototype RDMA SmartNIC driver.
 */

#ifndef _SMARTNIC_CHRDEV_H
#define _SMARTNIC_CHRDEV_H

#include <linux/poll.h>

#include "smartnic_pci.h"

struct smartnic_dev;

__poll_t smartnic_chrdev_poll_mask(enum smartnic_dev_state state,
				   bool reset_active, bool event_pending);
int smartnic_chrdev_register(struct smartnic_dev *sdev);
void smartnic_chrdev_unregister(struct smartnic_dev *sdev);

#endif /* _SMARTNIC_CHRDEV_H */
