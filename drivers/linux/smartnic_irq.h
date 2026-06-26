/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * MSI-X interrupt support for the prototype RDMA SmartNIC driver.
 */

#ifndef _SMARTNIC_IRQ_H
#define _SMARTNIC_IRQ_H

struct smartnic_dev;

int smartnic_irq_setup(struct smartnic_dev *sdev);
void smartnic_irq_teardown(struct smartnic_dev *sdev);
void smartnic_irq_disable(struct smartnic_dev *sdev);

#endif /* _SMARTNIC_IRQ_H */
