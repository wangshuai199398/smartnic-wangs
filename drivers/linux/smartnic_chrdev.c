// SPDX-License-Identifier: GPL-2.0-only
/*
 * Minimal character device control surface.
 *
 * This task exposes open/release/ioctl/mmap/poll plumbing. It deliberately
 * keeps the ABI small: ioctl dispatch only forwards mailbox commands, mmap
 * only maps the approved doorbell/MMIO aperture, and poll reports command
 * readiness plus teardown/error state.
 */

#include <linux/atomic.h>
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/errno.h>
#include <linux/fs.h>
#include <linux/io.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/poll.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/version.h>

#include <uapi/linux/smartnic_ioctl.h>

#include "smartnic_chrdev.h"
#include "smartnic_mbox.h"
#include "smartnic_pci.h"
#include "smartnic_queue.h"
#include "smartnic_regs.h"

static DEFINE_MUTEX(smartnic_class_lock);
static struct class *smartnic_class;
static unsigned int smartnic_class_users;
static atomic_t smartnic_chrdev_next_index = ATOMIC_INIT(0);

/**
 * smartnic_chrdev_check_ready() - 检查字符设备是否可以处理用户请求。
 * @sdev: SmartNIC 设备实例。
 *
 * 设备可用时返回 0；设备已移除或正在静默时返回 -ENODEV；
 * 复位正在进行时返回 -EAGAIN。
 */
static int smartnic_chrdev_check_ready(struct smartnic_dev *sdev)
{
	int err = 0;

	mutex_lock(&sdev->state_lock);
	if (sdev->state == SMARTNIC_DEV_REMOVED ||
	    sdev->state == SMARTNIC_DEV_QUIESCING)
		err = -ENODEV;
	else if (sdev->reset_active)
		err = -EAGAIN;
	mutex_unlock(&sdev->state_lock);

	return err;
}

/**
 * smartnic_chrdev_poll_mask() - 将设备状态转换为 poll(2) 就绪掩码。
 * @state: 当前设备状态。
 * @reset_active: 复位正在进行时为 true。
 * @event_pending: 存在待用户态处理的中断或事件时为 true。
 *
 * 返回上报给用户态的 poll 掩码。
 */
__poll_t smartnic_chrdev_poll_mask(enum smartnic_dev_state state,
				   bool reset_active, bool event_pending)
{
	__poll_t mask = 0;

	if (state == SMARTNIC_DEV_REMOVED || state == SMARTNIC_DEV_QUIESCING)
		return POLLERR | POLLHUP;

	if (event_pending)
		mask |= POLLIN | POLLRDNORM;

	if (!reset_active)
		mask |= POLLOUT | POLLWRNORM;

	return mask;
}

/**
 * smartnic_chrdev_open() - 打开 /dev/smartnicX 并分配每文件状态。
 * @inode: 字符设备 inode。
 * @filp: 接收私有上下文的文件对象。
 *
 * 成功返回 0，失败返回负 errno。
 */
static int smartnic_chrdev_open(struct inode *inode, struct file *filp)
{
	struct smartnic_dev *sdev;
	struct smartnic_file *ctx;
	int err;

	sdev = container_of(inode->i_cdev, struct smartnic_dev, cdev);
	err = smartnic_chrdev_check_ready(sdev);
	if (err)
		return err;

	ctx = smartnic_file_create(sdev);
	if (!ctx)
		return -ENOMEM;

	atomic_inc(&sdev->open_count);
	filp->private_data = ctx;
	dev_dbg(sdev->dev, "character device opened, open_count=%d\n",
		atomic_read(&sdev->open_count));
	return 0;
}

/**
 * smartnic_chrdev_release() - 释放每文件状态及其拥有的队列。
 * @inode: 字符设备 inode。
 * @filp: 持有私有上下文的文件对象。
 *
 * 返回 0；剩余的每文件资源会在 release 阶段销毁。
 */
static int smartnic_chrdev_release(struct inode *inode, struct file *filp)
{
	struct smartnic_file *ctx = filp->private_data;
	struct smartnic_dev *sdev;

	if (!ctx)
		return 0;

	sdev = ctx->sdev;
	filp->private_data = NULL;
	smartnic_file_destroy(ctx);
	if (atomic_dec_and_test(&sdev->open_count))
		wake_up_all(&sdev->open_wq);

	dev_dbg(sdev->dev, "character device released, open_count=%d\n",
		atomic_read(&sdev->open_count));
	return 0;
}

/**
 * smartnic_ioctl_mbox_exec() - 执行一条用户态 CSR mailbox 命令。
 * @sdev: SmartNIC 设备实例。
 * @arg: 指向 struct smartnic_ioctl_mbox 的用户态指针。
 *
 * 从用户态拷贝请求，校验 UAPI 结构体，执行 mailbox 命令，并在成功后
 * 将命令输出拷贝回用户态。
 *
 * 成功返回 0，失败返回负 errno。
 */
static long smartnic_ioctl_mbox_exec(struct smartnic_dev *sdev,
				     unsigned long arg)
{
	struct smartnic_ioctl_mbox req;
	size_t max_len = sizeof(req.data);
	int err;

	if (copy_from_user(&req, (void __user *)arg, sizeof(req)))
		return -EFAULT;

	if (req.struct_size != sizeof(req))
		return -EINVAL;

	if (req.in_len > max_len || req.out_len > max_len)
		return -EINVAL;

	err = smartnic_mbox_exec(sdev, req.opcode, req.data, req.in_len,
				 req.data, req.out_len);
	req.status = err;
	if (err)
		return err;

	if (copy_to_user((void __user *)arg, &req, sizeof(req)))
		return -EFAULT;

	return 0;
}

/**
 * smartnic_chrdev_ioctl() - 分发 SmartNIC 字符设备 ioctl。
 * @filp: 包含每文件 SmartNIC 上下文的文件对象。
 * @cmd: ioctl 命令号。
 * @arg: 用户态 ioctl 参数。
 *
 * 成功返回 0 或命令特定返回值，失败返回负 errno。
 */
static long smartnic_chrdev_ioctl(struct file *filp, unsigned int cmd,
				  unsigned long arg)
{
	struct smartnic_file *ctx = filp->private_data;
	struct smartnic_dev *sdev;
	int err;

	if (!ctx)
		return -ENODEV;

	sdev = ctx->sdev;
	err = smartnic_chrdev_check_ready(sdev);
	if (err)
		return err;

	if (_IOC_TYPE(cmd) != SMARTNIC_IOCTL_MAGIC)
		return -ENOTTY;

	switch (cmd) {
	case SMARTNIC_IOCTL_MBOX_EXEC:
		return smartnic_ioctl_mbox_exec(sdev, arg);
	case SMARTNIC_IOCTL_QUEUE_CREATE:
	case SMARTNIC_IOCTL_QUEUE_DESTROY:
	case SMARTNIC_IOCTL_QUEUE_QUERY:
		return smartnic_queue_ioctl(ctx, cmd, arg);
	default:
		dev_dbg(sdev->dev, "unknown ioctl cmd=0x%x\n", cmd);
		return -ENOTTY;
	}
}

#ifdef CONFIG_COMPAT
/**
 * smartnic_chrdev_compat_ioctl() - compat ioctl 转发入口。
 * @filp: 包含每文件 SmartNIC 上下文的文件对象。
 * @cmd: ioctl 命令号。
 * @arg: compat 用户态 ioctl 参数。
 *
 * UAPI 结构体使用固定宽度字段，因此 compat 分发可以复用原生 ioctl 实现。
 *
 * 返回原生 ioctl 的执行结果。
 */
static long smartnic_chrdev_compat_ioctl(struct file *filp, unsigned int cmd,
					 unsigned long arg)
{
	return smartnic_chrdev_ioctl(filp, cmd, arg);
}
#endif

/**
 * smartnic_chrdev_mmap() - 映射 doorbell/MMIO 或队列 ring 内存。
 * @filp: 包含每文件 SmartNIC 上下文的文件对象。
 * @vma: 用户态请求的 VMA。
 *
 * 队列 mmap 偏移交给队列层处理。其他已批准的偏移会将 doorbell BAR
 * 窗口映射为不可缓存的 I/O 内存。
 *
 * 成功返回 0，失败返回负 errno。
 */
static int smartnic_chrdev_mmap(struct file *filp, struct vm_area_struct *vma)
{
	struct smartnic_file *ctx = filp->private_data;
	struct smartnic_dev *sdev;
	unsigned long size = vma->vm_end - vma->vm_start;
	resource_size_t offset;
	resource_size_t pfn;
	int err;

	if (!ctx)
		return -ENODEV;

	sdev = ctx->sdev;
	err = smartnic_chrdev_check_ready(sdev);
	if (err)
		return err;

	if (((u64)vma->vm_pgoff << PAGE_SHIFT) >= SMARTNIC_QUEUE_MMAP_BASE)
		return smartnic_queue_mmap(ctx, vma);

	if (!sdev->doorbell_bar.addr || !sdev->doorbell_bar.len)
		return -EPERM;

	offset = (resource_size_t)vma->vm_pgoff << PAGE_SHIFT;
	if (!size || offset >= sdev->doorbell_bar.len ||
	    size > sdev->doorbell_bar.len - offset)
		return -EINVAL;

	pfn = (sdev->doorbell_bar.start + offset) >> PAGE_SHIFT;
	vma->vm_page_prot = pgprot_noncached(vma->vm_page_prot);
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 3, 0)
	vm_flags_set(vma, VM_IO | VM_DONTEXPAND | VM_DONTDUMP);
#else
	vma->vm_flags |= VM_IO | VM_DONTEXPAND | VM_DONTDUMP;
#endif

	err = io_remap_pfn_range(vma, vma->vm_start, pfn, size,
				 vma->vm_page_prot);
	if (err)
		dev_err(sdev->dev, "doorbell mmap failed err=%d\n", err);

	return err;
}

/**
 * smartnic_chrdev_poll() - 向 poll(2) 上报事件和命令就绪状态。
 * @filp: 包含每文件 SmartNIC 上下文的文件对象。
 * @wait: poll 等待表。
 *
 * 返回由设备状态、复位状态和待处理事件状态推导出的 poll 掩码。
 */
static __poll_t smartnic_chrdev_poll(struct file *filp, poll_table *wait)
{
	struct smartnic_file *ctx = filp->private_data;
	struct smartnic_dev *sdev;
	__poll_t mask = 0;
	enum smartnic_dev_state state;
	bool reset_active;

	if (!ctx)
		return POLLERR | POLLHUP;

	sdev = ctx->sdev;
	poll_wait(filp, &sdev->event_wq, wait);

	mutex_lock(&sdev->state_lock);
	state = sdev->state;
	reset_active = sdev->reset_active;
	mutex_unlock(&sdev->state_lock);

	return smartnic_chrdev_poll_mask(state, reset_active,
					 atomic_read(&sdev->event_pending));
}

static const struct file_operations smartnic_fops = {
	.owner = THIS_MODULE,
	.open = smartnic_chrdev_open,
	.release = smartnic_chrdev_release,
	.unlocked_ioctl = smartnic_chrdev_ioctl,
#ifdef CONFIG_COMPAT
	.compat_ioctl = smartnic_chrdev_compat_ioctl,
#endif
	.mmap = smartnic_chrdev_mmap,
	.poll = smartnic_chrdev_poll,
	.llseek = no_llseek,
};

/**
 * smartnic_chrdev_get_class() - 获取共享的 SmartNIC 设备 class。
 *
 * 首次使用时创建设备 class，并递增 class 使用计数。
 *
 * 成功返回 0，失败返回负 errno。
 */
static int smartnic_chrdev_get_class(void)
{
	int err = 0;

	mutex_lock(&smartnic_class_lock);
	if (!smartnic_class) {
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 4, 0)
		smartnic_class = class_create(SMARTNIC_DRV_NAME);
#else
		smartnic_class = class_create(THIS_MODULE, SMARTNIC_DRV_NAME);
#endif
		if (IS_ERR(smartnic_class)) {
			err = PTR_ERR(smartnic_class);
			smartnic_class = NULL;
			goto out_unlock;
		}
	}

	smartnic_class_users++;

out_unlock:
	mutex_unlock(&smartnic_class_lock);
	return err;
}

/**
 * smartnic_chrdev_put_class() - 释放共享 class 的一个引用。
 *
 * 当最后一个已注册的 SmartNIC 字符设备注销后，销毁该 class。
 */
static void smartnic_chrdev_put_class(void)
{
	mutex_lock(&smartnic_class_lock);
	if (smartnic_class_users)
		smartnic_class_users--;

	if (!smartnic_class_users && smartnic_class) {
		class_destroy(smartnic_class);
		smartnic_class = NULL;
	}
	mutex_unlock(&smartnic_class_lock);
}

/**
 * smartnic_chrdev_register() - 为设备注册 /dev/smartnicX。
 * @sdev: SmartNIC 设备实例。
 *
 * 分配字符设备号，按需创建共享 class，安装文件操作，并创建用户可见的
 * 设备节点。
 *
 * 成功返回 0，失败返回负 errno。
 */
int smartnic_chrdev_register(struct smartnic_dev *sdev)
{
	int err;

	err = alloc_chrdev_region(&sdev->chrdev_devt, 0, 1, SMARTNIC_DRV_NAME);
	if (err)
		return err;

	err = smartnic_chrdev_get_class();
	if (err)
		goto err_unregister_region;

	cdev_init(&sdev->cdev, &smartnic_fops);
	sdev->cdev.owner = THIS_MODULE;

	err = cdev_add(&sdev->cdev, sdev->chrdev_devt, 1);
	if (err)
		goto err_put_class;

	sdev->chrdev_index = atomic_inc_return(&smartnic_chrdev_next_index) - 1;
	sdev->chrdev_device = device_create(smartnic_class, sdev->dev,
					    sdev->chrdev_devt, sdev,
					    "smartnic%d",
					    sdev->chrdev_index);
	if (IS_ERR(sdev->chrdev_device)) {
		err = PTR_ERR(sdev->chrdev_device);
		sdev->chrdev_device = NULL;
		goto err_del_cdev;
	}

	sdev->chrdev_registered = true;
	dev_info(sdev->dev, "created /dev/smartnic%d\n", sdev->chrdev_index);
	return 0;

err_del_cdev:
	cdev_del(&sdev->cdev);
err_put_class:
	smartnic_chrdev_put_class();
err_unregister_region:
	unregister_chrdev_region(sdev->chrdev_devt, 1);
	return err;
}

/**
 * smartnic_chrdev_unregister() - 注销设备对应的 /dev/smartnicX。
 * @sdev: SmartNIC 设备实例。
 *
 * 唤醒等待者，移除设备节点和 cdev，释放共享 class 引用，并等待所有
 * 已打开的文件引用退出。
 */
void smartnic_chrdev_unregister(struct smartnic_dev *sdev)
{
	if (!sdev->chrdev_registered)
		return;

	sdev->chrdev_registered = false;
	atomic_set(&sdev->event_pending, 1);
	wake_up_all(&sdev->event_wq);

	device_destroy(smartnic_class, sdev->chrdev_devt);
	cdev_del(&sdev->cdev);
	unregister_chrdev_region(sdev->chrdev_devt, 1);
	smartnic_chrdev_put_class();

	wait_event(sdev->open_wq, atomic_read(&sdev->open_count) == 0);
	dev_dbg(sdev->dev, "character device unregistered\n");
}
