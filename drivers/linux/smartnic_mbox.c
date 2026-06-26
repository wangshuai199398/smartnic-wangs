// SPDX-License-Identifier: GPL-2.0-only
/*
 * CSR mailbox command helper.
 *
 * The hardware mailbox is a small MMIO command window. This helper serializes
 * commands, validates the dword argument window, waits for completion, and
 * translates device error codes to Linux errno values. ioctl and resource
 * management layers are intentionally left for later tasks.
 */

#include <linux/device.h>
#include <linux/errno.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/kernel.h>
#include <linux/mutex.h>
#include <linux/string.h>

#include "smartnic_mbox.h"
#include "smartnic_pci.h"
#include "smartnic_regs.h"

static u32 smartnic_mbox_read(struct smartnic_dev *sdev, u32 offset)
{
	return readl(sdev->control_bar.addr + offset);
}

static void smartnic_mbox_write(struct smartnic_dev *sdev, u32 offset, u32 value)
{
	writel(value, sdev->control_bar.addr + offset);
}

static int smartnic_mbox_check_ready(struct smartnic_dev *sdev)
{
	int err = 0;

	mutex_lock(&sdev->state_lock);
	if (sdev->state == SMARTNIC_DEV_REMOVED ||
	    sdev->state == SMARTNIC_DEV_QUIESCING)
		err = -ENODEV;
	else if (sdev->reset_active)
		err = -EAGAIN;
	else if (!sdev->control_bar.addr)
		err = -ENODEV;
	mutex_unlock(&sdev->state_lock);

	return err;
}

static int smartnic_mbox_map_error(u32 dev_error)
{
	switch (dev_error) {
	case SMARTNIC_MBOX_ERR_NONE:
		return 0;
	case SMARTNIC_MBOX_ERR_INVALID_CMD:
		return -EOPNOTSUPP;
	case SMARTNIC_MBOX_ERR_INVALID_ARG:
		return -EINVAL;
	case SMARTNIC_MBOX_ERR_PERMISSION:
		return -EACCES;
	case SMARTNIC_MBOX_ERR_BAD_STATE:
		return -EPERM;
	case SMARTNIC_MBOX_ERR_BUSY:
		return -EBUSY;
	case SMARTNIC_MBOX_ERR_NO_RESOURCE:
		return -ENOSPC;
	case SMARTNIC_MBOX_ERR_TIMEOUT:
		return -ETIMEDOUT;
	case SMARTNIC_MBOX_ERR_HW:
	default:
		return -EIO;
	}
}

static int smartnic_mbox_validate_bufs(const void *in_buf, size_t in_len,
				       const void *out_buf, size_t out_len)
{
	if (in_len > SMARTNIC_MBOX_MAX_DATA_BYTES ||
	    out_len > SMARTNIC_MBOX_MAX_DATA_BYTES)
		return -EINVAL;

	if ((in_len & (sizeof(u32) - 1)) || (out_len & (sizeof(u32) - 1)))
		return -EINVAL;

	if (in_len && !in_buf)
		return -EINVAL;

	if (out_len && !out_buf)
		return -EINVAL;

	return 0;
}

static void smartnic_mbox_clear_status(struct smartnic_dev *sdev)
{
	smartnic_mbox_write(sdev, SMARTNIC_MBOX_STATUS, 0);
	smartnic_mbox_write(sdev, SMARTNIC_MBOX_ERROR, SMARTNIC_MBOX_ERR_NONE);
	smartnic_mbox_write(sdev, SMARTNIC_MBOX_CONTROL,
			    SMARTNIC_MBOX_CTRL_CLEAR_STATUS);
}

static void smartnic_mbox_write_args(struct smartnic_dev *sdev,
				     const void *in_buf, size_t in_len)
{
	const __le32 *args = in_buf;
	int i;

	for (i = 0; i < SMARTNIC_MBOX_MAX_DATA_DWORDS; i++) {
		u32 value = 0;

		if ((i + 1) * sizeof(u32) <= in_len)
			value = le32_to_cpu(args[i]);

		smartnic_mbox_write(sdev, SMARTNIC_MBOX_ARG(i), value);
	}
}

static void smartnic_mbox_read_args(struct smartnic_dev *sdev,
				    void *out_buf, size_t out_len)
{
	__le32 *args = out_buf;
	int i;

	for (i = 0; i < out_len / sizeof(u32); i++)
		args[i] = cpu_to_le32(smartnic_mbox_read(sdev,
							 SMARTNIC_MBOX_ARG(i)));
}

int smartnic_mbox_exec(struct smartnic_dev *sdev, u16 opcode,
		       const void *in_buf, size_t in_len,
		       void *out_buf, size_t out_len)
{
	u32 control;
	u32 dev_error;
	int err;

	if (!sdev)
		return -ENODEV;

	err = smartnic_mbox_validate_bufs(in_buf, in_len, out_buf, out_len);
	if (err)
		return err;

	err = smartnic_mbox_check_ready(sdev);
	if (err)
		return err;

	mutex_lock(&sdev->mbox_lock);

	err = smartnic_mbox_check_ready(sdev);
	if (err)
		goto out_unlock;

	dev_dbg(sdev->dev, "mailbox opcode=0x%04x in=%zu out=%zu\n",
		opcode, in_len, out_len);

	smartnic_mbox_clear_status(sdev);
	smartnic_mbox_write_args(sdev, in_buf, in_len);
	smartnic_mbox_write(sdev, SMARTNIC_MBOX_COMMAND, opcode);
	smartnic_mbox_write(sdev, SMARTNIC_MBOX_CONTROL,
			    SMARTNIC_MBOX_CTRL_GO);

	err = readl_poll_timeout(sdev->control_bar.addr + SMARTNIC_MBOX_CONTROL,
				 control,
				 control & (SMARTNIC_MBOX_CTRL_DONE |
					    SMARTNIC_MBOX_CTRL_ERROR),
				 SMARTNIC_MBOX_POLL_US,
				 SMARTNIC_MBOX_TIMEOUT_US);
	if (err) {
		dev_err(sdev->dev,
			"mailbox opcode=0x%04x timed out control=0x%08x\n",
			opcode, smartnic_mbox_read(sdev,
						   SMARTNIC_MBOX_CONTROL));
		err = -ETIMEDOUT;
		goto out_unlock;
	}

	if (control & SMARTNIC_MBOX_CTRL_ERROR) {
		dev_error = smartnic_mbox_read(sdev, SMARTNIC_MBOX_ERROR);
		err = smartnic_mbox_map_error(dev_error);
		dev_err(sdev->dev,
			"mailbox opcode=0x%04x failed dev_error=0x%08x errno=%d\n",
			opcode, dev_error, err);
		goto out_unlock;
	}

	if (!(control & SMARTNIC_MBOX_CTRL_DONE)) {
		dev_err(sdev->dev,
			"mailbox opcode=0x%04x completed without DONE control=0x%08x\n",
			opcode, control);
		err = -EIO;
		goto out_unlock;
	}

	smartnic_mbox_read_args(sdev, out_buf, out_len);
	err = 0;

out_unlock:
	mutex_unlock(&sdev->mbox_lock);
	return err;
}
