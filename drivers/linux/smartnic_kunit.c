// SPDX-License-Identifier: GPL-2.0-only
/*
 * Optional KUnit smoke tests for pure SmartNIC driver constants.
 *
 * These tests intentionally avoid hardware access. Out-of-tree builds can add
 * CONFIG_SMARTNIC_KUNIT=y in a kernel tree that has KUnit enabled.
 */

#include <kunit/test.h>

#include <uapi/linux/smartnic_ioctl.h>

#include "smartnic_dma.h"
#include "smartnic_regs.h"

static void smartnic_kunit_uapi_layout(struct kunit *test)
{
	KUNIT_EXPECT_EQ(test, SMARTNIC_IOCTL_MAX_DATA_DWORDS, 4);
	KUNIT_EXPECT_EQ(test, sizeof(struct smartnic_ioctl_mbox),
			(size_t)40);
	KUNIT_EXPECT_EQ(test, SMARTNIC_QUEUE_TYPE_SQ, 1);
	KUNIT_EXPECT_EQ(test, SMARTNIC_QUEUE_TYPE_RQ, 2);
	KUNIT_EXPECT_EQ(test, SMARTNIC_QUEUE_TYPE_CQ, 3);
}

static void smartnic_kunit_mmap_offsets(struct kunit *test)
{
	KUNIT_EXPECT_EQ(test, SMARTNIC_QUEUE_MMAP_OFFSET(1),
			SMARTNIC_QUEUE_MMAP_BASE + SMARTNIC_QUEUE_MMAP_STRIDE);
	KUNIT_EXPECT_GT(test, SMARTNIC_QUEUE_MMAP_OFFSET(2),
			SMARTNIC_QUEUE_MMAP_OFFSET(1));
}

static void smartnic_kunit_dma_limits(struct kunit *test)
{
	KUNIT_EXPECT_EQ(test, SMARTNIC_DMA_DESC_ALIGN, 8U);
	KUNIT_EXPECT_GT(test, SMARTNIC_DMA_RING_MAX_BYTES, 0U);
}

static void smartnic_kunit_irq_bits(struct kunit *test)
{
	KUNIT_EXPECT_TRUE(test, !!(SMARTNIC_INTR_ALL_EVENTS &
				  SMARTNIC_INTR_MAILBOX_DONE));
	KUNIT_EXPECT_TRUE(test, !!(SMARTNIC_INTR_ALL_EVENTS &
				  SMARTNIC_INTR_CQ_EVENT));
}

static struct kunit_case smartnic_kunit_cases[] = {
	KUNIT_CASE(smartnic_kunit_uapi_layout),
	KUNIT_CASE(smartnic_kunit_mmap_offsets),
	KUNIT_CASE(smartnic_kunit_dma_limits),
	KUNIT_CASE(smartnic_kunit_irq_bits),
	{}
};

static struct kunit_suite smartnic_kunit_suite = {
	.name = "smartnic-driver",
	.test_cases = smartnic_kunit_cases,
};
kunit_test_suite(smartnic_kunit_suite);

MODULE_LICENSE("GPL");
