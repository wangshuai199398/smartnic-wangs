/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Character device control surface for the prototype RDMA SmartNIC driver.
 */

#ifndef _SMARTNIC_CHRDEV_H
#define _SMARTNIC_CHRDEV_H

struct smartnic_dev;

int smartnic_chrdev_register(struct smartnic_dev *sdev);
void smartnic_chrdev_unregister(struct smartnic_dev *sdev);

#endif /* _SMARTNIC_CHRDEV_H */
