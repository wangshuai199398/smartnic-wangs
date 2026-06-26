/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
/*
 * Prototype SmartNIC userspace control ABI.
 *
 * This header only defines the minimal mailbox passthrough used by task 12.3.
 * Resource lifecycle ioctls are intentionally added by later tasks.
 */

#ifndef _UAPI_LINUX_SMARTNIC_IOCTL_H
#define _UAPI_LINUX_SMARTNIC_IOCTL_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define SMARTNIC_IOCTL_MAGIC           'S'
#define SMARTNIC_IOCTL_MAX_DATA_DWORDS 4

struct smartnic_ioctl_mbox {
	__u32 struct_size;
	__u16 opcode;
	__u16 flags;
	__u32 in_len;
	__u32 out_len;
	__u32 data[SMARTNIC_IOCTL_MAX_DATA_DWORDS];
	__s32 status;
	__u32 reserved;
};

#define SMARTNIC_IOCTL_MBOX_EXEC \
	_IOWR(SMARTNIC_IOCTL_MAGIC, 0x01, struct smartnic_ioctl_mbox)

#endif /* _UAPI_LINUX_SMARTNIC_IOCTL_H */
