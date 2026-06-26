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
#define SMARTNIC_QUEUE_MMAP_BASE       0x100000000ULL
#define SMARTNIC_QUEUE_MMAP_STRIDE     0x00100000ULL
#define SMARTNIC_QUEUE_MMAP_OFFSET(_id) \
	(SMARTNIC_QUEUE_MMAP_BASE + ((__u64)(_id) * SMARTNIC_QUEUE_MMAP_STRIDE))

#define SMARTNIC_QUEUE_TYPE_SQ         1
#define SMARTNIC_QUEUE_TYPE_RQ         2
#define SMARTNIC_QUEUE_TYPE_CQ         3
#define SMARTNIC_QUEUE_TYPE_DESC       4

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

struct smartnic_ioctl_queue {
	__u32 struct_size;
	__u32 type;
	__u32 depth;
	__u32 desc_size;
	__u32 flags;
	__u32 queue_id;
	__u64 mmap_offset;
	__u64 ring_size;
	__u64 dma_addr;
	__u32 producer_index;
	__u32 consumer_index;
	__u32 reserved[4];
};

struct smartnic_ioctl_queue_destroy {
	__u32 struct_size;
	__u32 queue_id;
};

#define SMARTNIC_IOCTL_MBOX_EXEC \
	_IOWR(SMARTNIC_IOCTL_MAGIC, 0x01, struct smartnic_ioctl_mbox)
#define SMARTNIC_IOCTL_QUEUE_CREATE \
	_IOWR(SMARTNIC_IOCTL_MAGIC, 0x20, struct smartnic_ioctl_queue)
#define SMARTNIC_IOCTL_QUEUE_DESTROY \
	_IOW(SMARTNIC_IOCTL_MAGIC, 0x21, struct smartnic_ioctl_queue_destroy)
#define SMARTNIC_IOCTL_QUEUE_QUERY \
	_IOWR(SMARTNIC_IOCTL_MAGIC, 0x22, struct smartnic_ioctl_queue)

#endif /* _UAPI_LINUX_SMARTNIC_IOCTL_H */
