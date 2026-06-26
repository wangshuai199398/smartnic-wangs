/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Per-file SmartNIC queue/ring ownership helpers.
 */

#ifndef _SMARTNIC_QUEUE_H
#define _SMARTNIC_QUEUE_H

#include <linux/list.h>
#include <linux/mm_types.h>
#include <linux/mutex.h>
#include <linux/types.h>

#include "smartnic_dma.h"

struct file;
struct smartnic_dev;

#define SMARTNIC_MMAP_QUEUE_BASE_PGOFF 0x100000UL

struct smartnic_file {
	struct smartnic_dev *sdev;
	struct list_head queues;
	struct mutex queues_lock;
};

struct smartnic_queue {
	u32 id;
	u32 type;
	u64 mmap_offset;
	bool active;
	struct smartnic_file *owner;
	struct smartnic_dma_ring ring;
	struct list_head node;
};

struct smartnic_file *smartnic_file_create(struct smartnic_dev *sdev);
void smartnic_file_destroy(struct smartnic_file *ctx);

long smartnic_queue_ioctl(struct smartnic_file *ctx, unsigned int cmd,
			  unsigned long arg);
int smartnic_queue_mmap(struct smartnic_file *ctx, struct vm_area_struct *vma);

#endif /* _SMARTNIC_QUEUE_H */
