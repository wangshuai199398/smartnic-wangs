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

void smartnic_dma_ring_free(struct smartnic_dev *sdev,
			    struct smartnic_dma_ring *ring)
{
	if (!sdev || !ring || !ring->allocated)
		return;

	dma_free_coherent(sdev->dev, ring->size, ring->cpu_addr,
			  ring->dma_addr);
	memset(ring, 0, sizeof(*ring));
}
