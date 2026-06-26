// SPDX-License-Identifier: GPL-2.0-only
/*
 * Optional KUnit smoke tests for pure SmartNIC driver constants.
 *
 * These tests intentionally avoid hardware access. Out-of-tree builds can add
 * CONFIG_SMARTNIC_KUNIT=y in a kernel tree that has KUnit enabled.
 */

#include <linux/errno.h>
#include <kunit/test.h>

#include <uapi/linux/smartnic_ioctl.h>

#include "smartnic_chrdev.h"
#include "smartnic_dma.h"
#include "smartnic_irq.h"
#include "smartnic_mbox.h"
#include "smartnic_pci.h"
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

static void smartnic_kunit_mailbox_error_mapping(struct kunit *test)
{
	KUNIT_EXPECT_EQ(test,
			smartnic_mbox_device_error_to_errno(SMARTNIC_MBOX_ERR_NONE),
			0);
	KUNIT_EXPECT_EQ(test,
			smartnic_mbox_device_error_to_errno(SMARTNIC_MBOX_ERR_INVALID_CMD),
			-EOPNOTSUPP);
	KUNIT_EXPECT_EQ(test,
			smartnic_mbox_device_error_to_errno(SMARTNIC_MBOX_ERR_INVALID_ARG),
			-EINVAL);
	KUNIT_EXPECT_EQ(test,
			smartnic_mbox_device_error_to_errno(SMARTNIC_MBOX_ERR_PERMISSION),
			-EACCES);
	KUNIT_EXPECT_EQ(test,
			smartnic_mbox_device_error_to_errno(SMARTNIC_MBOX_ERR_BUSY),
			-EBUSY);
	KUNIT_EXPECT_EQ(test,
			smartnic_mbox_device_error_to_errno(SMARTNIC_MBOX_ERR_NO_RESOURCE),
			-ENOSPC);
	KUNIT_EXPECT_EQ(test,
			smartnic_mbox_device_error_to_errno(SMARTNIC_MBOX_ERR_TIMEOUT),
			-ETIMEDOUT);
	KUNIT_EXPECT_EQ(test, smartnic_mbox_device_error_to_errno(0xffff),
			-EIO);
}

static void smartnic_kunit_dma_param_validation(struct kunit *test)
{
	size_t size = 0;

	KUNIT_EXPECT_EQ(test, smartnic_dma_ring_validate_params(64, 64, &size),
			0);
	KUNIT_EXPECT_EQ(test, size, (size_t)4096);
	KUNIT_EXPECT_EQ(test, smartnic_dma_ring_validate_params(0, 64, &size),
			-EINVAL);
	KUNIT_EXPECT_EQ(test, smartnic_dma_ring_validate_params(63, 64, &size),
			-EINVAL);
	KUNIT_EXPECT_EQ(test, smartnic_dma_ring_validate_params(64, 7, &size),
			-EINVAL);
	KUNIT_EXPECT_EQ(test,
			smartnic_dma_ring_validate_params(1024 * 1024, 64, &size),
			-EINVAL);
}

static void smartnic_kunit_poll_masks(struct kunit *test)
{
	KUNIT_EXPECT_EQ(test,
			smartnic_chrdev_poll_mask(SMARTNIC_DEV_READY, false, false),
			(__poll_t)(POLLOUT | POLLWRNORM));
	KUNIT_EXPECT_EQ(test,
			smartnic_chrdev_poll_mask(SMARTNIC_DEV_READY, false, true),
			(__poll_t)(POLLIN | POLLRDNORM | POLLOUT | POLLWRNORM));
	KUNIT_EXPECT_EQ(test,
			smartnic_chrdev_poll_mask(SMARTNIC_DEV_READY, true, true),
			(__poll_t)(POLLIN | POLLRDNORM));
	KUNIT_EXPECT_EQ(test,
			smartnic_chrdev_poll_mask(SMARTNIC_DEV_REMOVED, false, true),
			(__poll_t)(POLLERR | POLLHUP));
}

static void smartnic_kunit_irq_filtering(struct kunit *test)
{
	KUNIT_EXPECT_EQ(test, smartnic_irq_filter_status(0), 0U);
	KUNIT_EXPECT_EQ(test,
			smartnic_irq_filter_status(SMARTNIC_INTR_MAILBOX_DONE |
						   0x80000000U),
			SMARTNIC_INTR_MAILBOX_DONE);
	KUNIT_EXPECT_EQ(test,
			smartnic_irq_filter_status(SMARTNIC_INTR_ALL_EVENTS),
			SMARTNIC_INTR_ALL_EVENTS);
}

static void smartnic_kunit_fault_hook_layout(struct kunit *test)
{
	struct smartnic_test_faults faults = { 0 };

	faults.fail_bar_mapping = true;
	faults.fail_dma_mask_setup = true;
	faults.fail_mailbox_completion = true;
	faults.fail_chrdev_registration = true;
	faults.fail_msix_allocation = true;

	KUNIT_EXPECT_TRUE(test, faults.fail_bar_mapping);
	KUNIT_EXPECT_TRUE(test, faults.fail_dma_mask_setup);
	KUNIT_EXPECT_TRUE(test, faults.fail_mailbox_completion);
	KUNIT_EXPECT_TRUE(test, faults.fail_chrdev_registration);
	KUNIT_EXPECT_TRUE(test, faults.fail_msix_allocation);
}

static struct kunit_case smartnic_kunit_cases[] = {
	KUNIT_CASE(smartnic_kunit_uapi_layout),
	KUNIT_CASE(smartnic_kunit_mmap_offsets),
	KUNIT_CASE(smartnic_kunit_dma_limits),
	KUNIT_CASE(smartnic_kunit_irq_bits),
	KUNIT_CASE(smartnic_kunit_mailbox_error_mapping),
	KUNIT_CASE(smartnic_kunit_dma_param_validation),
	KUNIT_CASE(smartnic_kunit_poll_masks),
	KUNIT_CASE(smartnic_kunit_irq_filtering),
	KUNIT_CASE(smartnic_kunit_fault_hook_layout),
	{}
};

static struct kunit_suite smartnic_kunit_suite = {
	.name = "smartnic-driver",
	.test_cases = smartnic_kunit_cases,
};
kunit_test_suite(smartnic_kunit_suite);

MODULE_LICENSE("GPL");
