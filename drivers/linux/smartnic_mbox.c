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

/**
 * smartnic_mbox_read() - 读取 mailbox 相关 CSR 寄存器。
 * @sdev: SmartNIC 设备实例。
 * @offset: control BAR 内的寄存器偏移。
 *
 * 返回指定 mailbox CSR 的 32 位寄存器值。
 */
static u32 smartnic_mbox_read(struct smartnic_dev *sdev, u32 offset)
{
	return readl(sdev->control_bar.addr + offset);
}

/**
 * smartnic_mbox_write() - 写入 mailbox 相关 CSR 寄存器。
 * @sdev: SmartNIC 设备实例。
 * @offset: control BAR 内的寄存器偏移。
 * @value: 要写入的 32 位寄存器值。
 */
static void smartnic_mbox_write(struct smartnic_dev *sdev, u32 offset, u32 value)
{
	writel(value, sdev->control_bar.addr + offset);
}

/**
 * smartnic_mbox_check_ready() - 检查 mailbox 当前是否可用。
 * @sdev: SmartNIC 设备实例。
 *
 * 在设备状态锁保护下检查设备是否已移除、正在静默、正在复位，或
 * control BAR 是否未映射。
 *
 * mailbox 可用时返回 0，失败返回负 errno。
 */
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

/**
 * smartnic_mbox_device_error_to_errno() - 将设备 mailbox 错误码映射为 errno。
 * @dev_error: 设备返回的 mailbox 错误码。
 *
 * 返回与设备错误最接近的 Linux 负 errno；未知硬件错误映射为 -EIO。
 */
int smartnic_mbox_device_error_to_errno(u32 dev_error)
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

/**
 * smartnic_mbox_validate_bufs() - 校验 mailbox 输入和输出缓冲区参数。
 * @in_buf: 输入参数缓冲区。
 * @in_len: 输入参数字节数。
 * @out_buf: 输出参数缓冲区。
 * @out_len: 输出参数字节数。
 *
 * mailbox 参数窗口以 32 位 dword 为单位，因此输入和输出长度必须
 * dword 对齐，并且不能超过设备支持的最大参数窗口。
 *
 * 参数合法时返回 0，失败返回负 errno。
 */
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

/**
 * smartnic_mbox_clear_status() - 清理 mailbox 的旧完成和错误状态。
 * @sdev: SmartNIC 设备实例。
 *
 * 在发起新命令前清空状态寄存器、错误寄存器，并写入 CLEAR_STATUS 控制位。
 */
static void smartnic_mbox_clear_status(struct smartnic_dev *sdev)
{
	smartnic_mbox_write(sdev, SMARTNIC_MBOX_STATUS, 0);
	smartnic_mbox_write(sdev, SMARTNIC_MBOX_ERROR, SMARTNIC_MBOX_ERR_NONE);
	smartnic_mbox_write(sdev, SMARTNIC_MBOX_CONTROL,
			    SMARTNIC_MBOX_CTRL_CLEAR_STATUS);
}

/**
 * smartnic_mbox_write_args() - 将输入参数写入 mailbox 参数窗口。
 * @sdev: SmartNIC 设备实例。
 * @in_buf: little-endian dword 格式的输入参数缓冲区。
 * @in_len: 输入参数字节数。
 *
 * 未被本次命令使用的参数 dword 会写 0，避免旧命令残留参数影响硬件。
 */
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

/**
 * smartnic_mbox_read_args() - 从 mailbox 参数窗口读取输出参数。
 * @sdev: SmartNIC 设备实例。
 * @out_buf: 接收 little-endian dword 输出的缓冲区。
 * @out_len: 输出参数字节数。
 */
static void smartnic_mbox_read_args(struct smartnic_dev *sdev,
				    void *out_buf, size_t out_len)
{
	__le32 *args = out_buf;
	int i;

	for (i = 0; i < out_len / sizeof(u32); i++)
		args[i] = cpu_to_le32(smartnic_mbox_read(sdev,
							 SMARTNIC_MBOX_ARG(i)));
}

/**
 * smartnic_mbox_exec() - 串行执行一条 SmartNIC CSR mailbox 命令。
 * @sdev: SmartNIC 设备实例。
 * @opcode: mailbox 命令 opcode。
 * @in_buf: 输入参数缓冲区。
 * @in_len: 输入参数字节数。
 * @out_buf: 输出参数缓冲区。
 * @out_len: 输出参数字节数。
 *
 * 校验参数和设备状态后，持有 mailbox 互斥锁，清理旧状态，写入输入参数
 * 与命令 opcode，触发硬件执行，并轮询 DONE/ERROR 位直到完成或超时。
 * 命令成功时读取输出参数；设备错误会映射为 Linux errno。
 *
 * 成功返回 0，失败返回负 errno。
 */
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
		err = smartnic_mbox_device_error_to_errno(dev_error);
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
