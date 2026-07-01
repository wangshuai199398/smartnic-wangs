// SPDX-License-Identifier: GPL-2.0-only
/*
 * Coherent DMA ring allocation helpers.
 */

#include <linux/dma-mapping.h>
#include <linux/errno.h>
#include <linux/log2.h>
#include <linux/overflow.h>
#include <linux/string.h>

#include "smartnic_dma.h"
#include "smartnic_pci.h"

/**
 * smartnic_dma_ring_validate_params() - 校验 DMA ring 的创建参数。
 * @depth: ring 中描述符的数量，必须为非零的 2 的幂。
 * @desc_size: 单个描述符大小，必须满足 SMARTNIC_DMA_DESC_ALIGN 对齐。
 * @size: 成功时返回计算得到的 ring 总字节数。
 *
 * 校验 depth、描述符大小、乘法溢出以及最大 ring 字节数限制。
 *
 * 成功返回 0，失败返回负 errno。
 */
int smartnic_dma_ring_validate_params(u32 depth, u32 desc_size, size_t *size)
{
	size_t bytes;

	if (!depth || !desc_size)
		return -EINVAL;

	if (!is_power_of_2(depth))
		return -EINVAL;

	if (desc_size & (SMARTNIC_DMA_DESC_ALIGN - 1))
		return -EINVAL;

	if (check_mul_overflow((size_t)depth, (size_t)desc_size, &bytes))
		return -EOVERFLOW;

	if (!bytes || bytes > SMARTNIC_DMA_RING_MAX_BYTES)
		return -EINVAL;

	*size = bytes;
	return 0;
}

/**
 * smartnic_dma_ring_alloc() - 分配一块 coherent DMA ring。
 * @sdev: SmartNIC 设备实例。
 * @ring: 接收分配结果的 DMA ring 描述结构。
 * @depth: ring 中描述符的数量。
 * @desc_size: 单个描述符大小。
 *
 * 先校验 ring 参数，再初始化 ring 元数据和锁，最后通过
 * dma_alloc_coherent() 分配设备可见的一致性 DMA 内存。
 *
 * 成功返回 0，失败返回负 errno。
 */
int smartnic_dma_ring_alloc(struct smartnic_dev *sdev,
			    struct smartnic_dma_ring *ring,
			    u32 depth, u32 desc_size)
{
	size_t size;
	int err;

	if (!sdev || !ring)
		return -EINVAL;

	err = smartnic_dma_ring_validate_params(depth, desc_size, &size);
	if (err)
		return err;

	memset(ring, 0, sizeof(*ring));
	spin_lock_init(&ring->lock);

	ring->cpu_addr = dma_alloc_coherent(sdev->dev, size, &ring->dma_addr,
					    GFP_KERNEL);
	if (!ring->cpu_addr)
		return -ENOMEM;

	ring->size = size;
	ring->depth = depth;
	ring->desc_size = desc_size;
	ring->allocated = true;
	return 0;
}

/**
 * smartnic_dma_ring_free() - 释放 coherent DMA ring。
 * @sdev: SmartNIC 设备实例。
 * @ring: 待释放的 DMA ring 描述结构。
 *
 * 如果 ring 已成功分配，则释放 coherent DMA 内存，并清零 ring
 * 元数据；未分配或参数为空时直接返回。
 */
void smartnic_dma_ring_free(struct smartnic_dev *sdev,
			    struct smartnic_dma_ring *ring)
{
	if (!sdev || !ring || !ring->allocated)
		return;

	dma_free_coherent(sdev->dev, ring->size, ring->cpu_addr,
			  ring->dma_addr);
	memset(ring, 0, sizeof(*ring));
}
