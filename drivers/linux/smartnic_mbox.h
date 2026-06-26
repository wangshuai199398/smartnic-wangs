/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Driver-side CSR mailbox helper for the prototype RDMA SmartNIC.
 */

#ifndef _SMARTNIC_MBOX_H
#define _SMARTNIC_MBOX_H

#include <linux/types.h>

struct smartnic_dev;

int smartnic_mbox_device_error_to_errno(u32 dev_error);
int smartnic_mbox_exec(struct smartnic_dev *sdev, u16 opcode,
		       const void *in_buf, size_t in_len,
		       void *out_buf, size_t out_len);

#endif /* _SMARTNIC_MBOX_H */
