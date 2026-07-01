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

/**
 * smartnic_file_create() - 创建字符设备每文件上下文。
 * @sdev: SmartNIC 设备实例。
 *
 * 分配并初始化 smartnic_file，上下文用于跟踪该文件描述符创建的队列资源。
 *
 * 成功返回上下文指针，失败返回 NULL。
 */
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

/**
 * smartnic_queue_free_locked() - 在持有队列锁时释放队列资源。
 * @queue: 待释放的队列对象。
 *
 * 从文件上下文队列链表中删除队列，标记为非活跃，释放 coherent DMA ring，
 * 并释放队列对象本身。调用者必须已经持有 owner->queues_lock。
 */
static void smartnic_queue_free_locked(struct smartnic_queue *queue)
{
	list_del(&queue->node);
	queue->active = false;
	smartnic_dma_ring_free(queue->owner->sdev, &queue->ring);
	kfree(queue);
}

/**
 * smartnic_file_destroy() - 销毁字符设备每文件上下文及其队列。
 * @ctx: 待销毁的每文件上下文。
 *
 * 释放该文件描述符仍然持有的所有队列和 DMA ring，然后释放上下文本身。
 */
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

/**
 * smartnic_queue_find_locked() - 在每文件队列链表中查找活跃队列。
 * @ctx: 每文件 SmartNIC 上下文。
 * @queue_id: 要查找的队列 ID。
 *
 * 调用者必须已经持有 ctx->queues_lock。
 *
 * 找到活跃队列时返回队列指针，否则返回 NULL。
 */
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

/**
 * smartnic_queue_type_valid() - 校验用户请求的队列类型是否受支持。
 * @type: UAPI 队列类型编号。
 *
 * 支持 SQ、RQ、CQ 和描述符/control 队列类型。
 *
 * 类型有效时返回 true，否则返回 false。
 */
static int smartnic_queue_type_valid(u32 type)
{
	return type == SMARTNIC_QUEUE_TYPE_SQ ||
	       type == SMARTNIC_QUEUE_TYPE_RQ ||
	       type == SMARTNIC_QUEUE_TYPE_CQ ||
	       type == SMARTNIC_QUEUE_TYPE_DESC;
}

/**
 * smartnic_ioctl_queue_create() - 处理队列创建 ioctl。
 * @ctx: 每文件 SmartNIC 上下文。
 * @arg: 指向 struct smartnic_ioctl_queue 的用户态指针。
 *
 * 从用户态读取队列创建参数，校验结构体大小和队列类型，分配队列对象和
 * coherent DMA ring，加入文件上下文队列链表，并把 queue_id、mmap 偏移、
 * ring 大小和 DMA 地址返回给用户态。
 *
 * 成功返回 0，失败返回负 errno。
 */
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

/**
 * smartnic_ioctl_queue_destroy() - 处理队列销毁 ioctl。
 * @ctx: 每文件 SmartNIC 上下文。
 * @arg: 指向 struct smartnic_ioctl_queue_destroy 的用户态指针。
 *
 * 根据用户传入的 queue_id 查找该文件描述符拥有的活跃队列，并释放队列
 * 及其 DMA ring。
 *
 * 成功返回 0，失败返回负 errno。
 */
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

/**
 * smartnic_ioctl_queue_query() - 处理队列查询 ioctl。
 * @ctx: 每文件 SmartNIC 上下文。
 * @arg: 指向 struct smartnic_ioctl_queue 的用户态指针。
 *
 * 根据 queue_id 查询队列类型、深度、描述符大小、ring 大小、mmap 偏移、
 * DMA 地址以及生产者/消费者索引，并把结果拷贝回用户态。
 *
 * 成功返回 0，失败返回负 errno。
 */
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

/**
 * smartnic_queue_ioctl() - 分发队列相关 ioctl 命令。
 * @ctx: 每文件 SmartNIC 上下文。
 * @cmd: ioctl 命令号。
 * @arg: 用户态 ioctl 参数。
 *
 * 支持队列创建、销毁和查询；未知命令返回 -ENOTTY。
 *
 * 成功返回 0 或命令特定返回值，失败返回负 errno。
 */
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

/**
 * smartnic_queue_mmap() - 将用户拥有的队列 DMA ring 映射到用户态。
 * @ctx: 每文件 SmartNIC 上下文。
 * @vma: 用户态 mmap 请求的 VMA。
 *
 * 使用 VMA 偏移匹配当前文件描述符创建的队列，只允许映射对应队列的
 * coherent DMA ring。映射大小不能超过 ring 大小。
 *
 * 成功返回 0，失败返回负 errno。
 */
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
