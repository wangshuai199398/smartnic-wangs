/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Coherent DMA ring helpers for SmartNIC queue/control buffers.
 */

#ifndef _SMARTNIC_DMA_H
#define _SMARTNIC_DMA_H

#include <linux/dma-mapping.h>
#include <linux/spinlock.h>
#include <linux/types.h>

struct smartnic_dev;

#define SMARTNIC_DMA_RING_MAX_BYTES    (16U * 1024U * 1024U)
#define SMARTNIC_DMA_DESC_ALIGN        8U

struct smartnic_dma_ring {
	void *cpu_addr;
	dma_addr_t dma_addr;
	size_t size;
	u32 depth;
	u32 desc_size;
	u32 producer_index;
	u32 consumer_index;
	spinlock_t lock;
	bool allocated;
};

int smartnic_dma_ring_alloc(struct smartnic_dev *sdev,
			    struct smartnic_dma_ring *ring,
			    u32 depth, u32 desc_size);
void smartnic_dma_ring_free(struct smartnic_dev *sdev,
			    struct smartnic_dma_ring *ring);

#endif /* _SMARTNIC_DMA_H */
