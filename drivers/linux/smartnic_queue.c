// SPDX-License-Identifier: GPL-2.0-only
/*
 * Queue/ring lifecycle for coherent userspace-visible buffers.
 */

#include <linux/atomic.h>
#include <linux/dma-mapping.h>
#include <linux/errno.h>
#include <linux/list.h>
#include <linux/slab.h>
#include <linux/uaccess.h>

#include <uapi/linux/smartnic_ioctl.h>

#include "smartnic_pci.h"
#include "smartnic_queue.h"

static atomic_t smartnic_queue_next_id = ATOMIC_INIT(1);

struct smartnic_file *smartnic_file_create(struct smartnic_dev *sdev)
{
	struct smartnic_file *ctx;

	ctx = kzalloc(sizeof(*ctx), GFP_KERNEL);
	if (!ctx)
		return NULL;

	ctx->sdev = sdev;
	INIT_LIST_HEAD(&ctx->queues);
	mutex_init(&ctx->queues_lock);
	return ctx;
}

static void smartnic_queue_free_locked(struct smartnic_queue *queue)
{
	list_del(&queue->node);
	queue->active = false;
	smartnic_dma_ring_free(queue->owner->sdev, &queue->ring);
	kfree(queue);
}

void smartnic_file_destroy(struct smartnic_file *ctx)
{
	struct smartnic_queue *queue;
	struct smartnic_queue *tmp;

	if (!ctx)
		return;

	mutex_lock(&ctx->queues_lock);
	list_for_each_entry_safe(queue, tmp, &ctx->queues, node)
		smartnic_queue_free_locked(queue);
	mutex_unlock(&ctx->queues_lock);
	kfree(ctx);
}

static struct smartnic_queue *smartnic_queue_find_locked(struct smartnic_file *ctx,
							 u32 queue_id)
{
	struct smartnic_queue *queue;

	list_for_each_entry(queue, &ctx->queues, node) {
		if (queue->id == queue_id && queue->active)
			return queue;
	}

	return NULL;
}

static int smartnic_queue_type_valid(u32 type)
{
	return type == SMARTNIC_QUEUE_TYPE_SQ ||
	       type == SMARTNIC_QUEUE_TYPE_RQ ||
	       type == SMARTNIC_QUEUE_TYPE_CQ ||
	       type == SMARTNIC_QUEUE_TYPE_DESC;
}

static long smartnic_ioctl_queue_create(struct smartnic_file *ctx,
					unsigned long arg)
{
	struct smartnic_ioctl_queue req;
	struct smartnic_queue *queue;
	int err;

	if (copy_from_user(&req, (void __user *)arg, sizeof(req)))
		return -EFAULT;

	if (req.struct_size != sizeof(req) || !smartnic_queue_type_valid(req.type))
		return -EINVAL;

	queue = kzalloc(sizeof(*queue), GFP_KERNEL);
	if (!queue)
		return -ENOMEM;

	queue->owner = ctx;
	queue->type = req.type;
	queue->id = (u32)atomic_inc_return(&smartnic_queue_next_id);
	queue->mmap_offset = SMARTNIC_QUEUE_MMAP_OFFSET(queue->id);

	err = smartnic_dma_ring_alloc(ctx->sdev, &queue->ring, req.depth,
				      req.desc_size);
	if (err)
		goto err_free_queue;

	queue->active = true;

	mutex_lock(&ctx->queues_lock);
	list_add_tail(&queue->node, &ctx->queues);
	mutex_unlock(&ctx->queues_lock);

	req.queue_id = queue->id;
	req.mmap_offset = queue->mmap_offset;
	req.ring_size = queue->ring.size;
	req.dma_addr = queue->ring.dma_addr;

	if (copy_to_user((void __user *)arg, &req, sizeof(req))) {
		mutex_lock(&ctx->queues_lock);
		smartnic_queue_free_locked(queue);
		mutex_unlock(&ctx->queues_lock);
		return -EFAULT;
	}

	return 0;

err_free_queue:
	kfree(queue);
	return err;
}

static long smartnic_ioctl_queue_destroy(struct smartnic_file *ctx,
					 unsigned long arg)
{
	struct smartnic_ioctl_queue_destroy req;
	struct smartnic_queue *queue;

	if (copy_from_user(&req, (void __user *)arg, sizeof(req)))
		return -EFAULT;

	if (req.struct_size != sizeof(req))
		return -EINVAL;

	mutex_lock(&ctx->queues_lock);
	queue = smartnic_queue_find_locked(ctx, req.queue_id);
	if (!queue) {
		mutex_unlock(&ctx->queues_lock);
		return -ENOENT;
	}

	smartnic_queue_free_locked(queue);
	mutex_unlock(&ctx->queues_lock);
	return 0;
}

static long smartnic_ioctl_queue_query(struct smartnic_file *ctx,
				       unsigned long arg)
{
	struct smartnic_ioctl_queue req;
	struct smartnic_queue *queue;

	if (copy_from_user(&req, (void __user *)arg, sizeof(req)))
		return -EFAULT;

	if (req.struct_size != sizeof(req))
		return -EINVAL;

	mutex_lock(&ctx->queues_lock);
	queue = smartnic_queue_find_locked(ctx, req.queue_id);
	if (!queue) {
		mutex_unlock(&ctx->queues_lock);
		return -ENOENT;
	}

	req.type = queue->type;
	req.depth = queue->ring.depth;
	req.desc_size = queue->ring.desc_size;
	req.ring_size = queue->ring.size;
	req.mmap_offset = queue->mmap_offset;
	req.dma_addr = queue->ring.dma_addr;
	req.producer_index = queue->ring.producer_index;
	req.consumer_index = queue->ring.consumer_index;
	mutex_unlock(&ctx->queues_lock);

	if (copy_to_user((void __user *)arg, &req, sizeof(req)))
		return -EFAULT;

	return 0;
}

long smartnic_queue_ioctl(struct smartnic_file *ctx, unsigned int cmd,
			  unsigned long arg)
{
	switch (cmd) {
	case SMARTNIC_IOCTL_QUEUE_CREATE:
		return smartnic_ioctl_queue_create(ctx, arg);
	case SMARTNIC_IOCTL_QUEUE_DESTROY:
		return smartnic_ioctl_queue_destroy(ctx, arg);
	case SMARTNIC_IOCTL_QUEUE_QUERY:
		return smartnic_ioctl_queue_query(ctx, arg);
	default:
		return -ENOTTY;
	}
}

int smartnic_queue_mmap(struct smartnic_file *ctx, struct vm_area_struct *vma)
{
	struct smartnic_queue *queue;
	unsigned long size = vma->vm_end - vma->vm_start;
	u64 mmap_offset = (u64)vma->vm_pgoff << PAGE_SHIFT;
	int err = -EINVAL;

	if (!ctx || !size)
		return -EINVAL;

	mutex_lock(&ctx->queues_lock);
	list_for_each_entry(queue, &ctx->queues, node) {
		if (!queue->active || queue->mmap_offset != mmap_offset)
			continue;

		if (size > queue->ring.size) {
			err = -EINVAL;
			goto out_unlock;
		}

		err = dma_mmap_coherent(ctx->sdev->dev, vma,
					queue->ring.cpu_addr,
					queue->ring.dma_addr,
					queue->ring.size);
		goto out_unlock;
	}

	err = -EPERM;

out_unlock:
	mutex_unlock(&ctx->queues_lock);
	return err;
}
