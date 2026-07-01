// SPDX-License-Identifier: GPL-2.0-only
/*
 * PCIe probe/remove lifecycle for the prototype RDMA SmartNIC.
 *
 * This file intentionally stops at device bring-up and teardown. CSR mailbox,
 * char device, mmap, MSI-X setup, and data-path logic are added by later
 * OpenSpec tasks.
 */

#include <linux/delay.h>
#include <linux/device.h>
#include <linux/dma-mapping.h>
#include <linux/err.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/slab.h>

#include "smartnic_chrdev.h"
#include "smartnic_irq.h"
#include "smartnic_pci.h"
#include "smartnic_regs.h"

static const struct pci_device_id smartnic_pci_id_table[] = {
	{ PCI_DEVICE(SMARTNIC_PCI_VENDOR_ID, SMARTNIC_PCI_DEVICE_ID) },
	{ 0, }
};
MODULE_DEVICE_TABLE(pci, smartnic_pci_id_table);

/**
 * smartnic_csr_read() - 读取 control BAR 中的 SmartNIC CSR。
 * @sdev: SmartNIC 设备实例。
 * @offset: control BAR 内的 CSR 偏移。
 *
 * 返回指定 CSR 的 32 位寄存器值。
 */
static u32 smartnic_csr_read(struct smartnic_dev *sdev, u32 offset)
{
	return readl(sdev->control_bar.addr + offset);
}

/**
 * smartnic_csr_write() - 写入 control BAR 中的 SmartNIC CSR。
 * @sdev: SmartNIC 设备实例。
 * @offset: control BAR 内的 CSR 偏移。
 * @value: 要写入的 32 位寄存器值。
 */
static void smartnic_csr_write(struct smartnic_dev *sdev, u32 offset, u32 value)
{
	writel(value, sdev->control_bar.addr + offset);
}

/**
 * smartnic_setup_dma_mask() - 配置 PCI 设备 coherent DMA 地址掩码。
 * @sdev: SmartNIC 设备实例。
 *
 * 优先尝试 64 位 DMA mask；如果失败则回退到 32 位 DMA mask，并在
 * 设备状态中记录最终使用的 DMA 地址宽度。
 *
 * 成功返回 0，失败返回负 errno。
 */
static int smartnic_setup_dma_mask(struct smartnic_dev *sdev)
{
	struct device *dev = sdev->dev;
	int err;

	err = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(64));
	if (!err) {
		sdev->dma_64bit = true;
		dev_dbg(dev, "using 64-bit coherent DMA mask\n");
		return 0;
	}

	dev_dbg(dev, "64-bit DMA mask failed, trying 32-bit fallback: %d\n", err);

	err = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32));
	if (!err) {
		sdev->dma_64bit = false;
		dev_info(dev, "using 32-bit coherent DMA mask fallback\n");
		return 0;
	}

	dev_err(dev, "failed to set coherent DMA mask: %d\n", err);
	return err;
}

/**
 * smartnic_map_bar() - 映射一个 PCI BAR 到内核虚拟地址空间。
 * @sdev: SmartNIC 设备实例。
 * @bar: 要映射的 BAR 编号。
 * @mapped: 接收映射结果的 BAR 描述结构。
 * @required: 指示该 BAR 是否为必需资源。
 *
 * 检查 BAR 是否存在且为 MMIO，记录物理起始地址和长度，并通过
 * pci_iomap() 建立内核映射。可选 BAR 缺失时不会报错。
 *
 * 成功返回 0，失败返回负 errno。
 */
static int smartnic_map_bar(struct smartnic_dev *sdev, int bar,
			    struct smartnic_bar *mapped, bool required)
{
	struct pci_dev *pdev = sdev->pdev;
	resource_size_t len;

	mapped->index = bar;
	mapped->addr = NULL;
	mapped->start = pci_resource_start(pdev, bar);
	mapped->len = pci_resource_len(pdev, bar);

	if (!(pci_resource_flags(pdev, bar) & IORESOURCE_MEM) || !mapped->len) {
		if (required) {
			dev_err(sdev->dev, "BAR%d is missing or not MMIO\n", bar);
			return -ENODEV;
		}

		dev_dbg(sdev->dev, "optional BAR%d is not present\n", bar);
		return 0;
	}

	len = mapped->len;
	mapped->addr = pci_iomap(pdev, bar, 0);
	if (!mapped->addr) {
		if (required) {
			dev_err(sdev->dev, "failed to map required BAR%d\n", bar);
			return -ENOMEM;
		}

		dev_dbg(sdev->dev, "optional BAR%d mapping skipped\n", bar);
		return 0;
	}

	dev_info(sdev->dev, "mapped BAR%d start=%pa len=%pa\n",
		 bar, &mapped->start, &len);
	return 0;
}

/**
 * smartnic_unmap_bar() - 解除一个已映射 PCI BAR 的内核映射。
 * @sdev: SmartNIC 设备实例。
 * @mapped: 待解除映射的 BAR 描述结构。
 *
 * 如果 BAR 已映射，则调用 pci_iounmap() 并清空保存的 BAR 元数据。
 */
static void smartnic_unmap_bar(struct smartnic_dev *sdev,
			       struct smartnic_bar *mapped)
{
	if (!mapped->addr)
		return;

	pci_iounmap(sdev->pdev, mapped->addr);
	mapped->addr = NULL;
	mapped->start = 0;
	mapped->len = 0;
}

/**
 * smartnic_unmap_bars() - 解除 SmartNIC 已映射的所有 BAR。
 * @sdev: SmartNIC 设备实例。
 *
 * 按当前驱动资源模型释放 doorbell BAR 和 control BAR 映射。
 */
static void smartnic_unmap_bars(struct smartnic_dev *sdev)
{
	smartnic_unmap_bar(sdev, &sdev->doorbell_bar);
	smartnic_unmap_bar(sdev, &sdev->control_bar);
}

/**
 * smartnic_hw_reset() - 请求硬件复位并轮询完成状态。
 * @sdev: SmartNIC 设备实例。
 *
 * 通过 reset CSR 发起设备复位，在复位期间设置 reset_active 状态，
 * 然后按固定间隔轮询 RESET_DONE 位直到完成或超时。当前 bring-up
 * 版本只记录超时调试信息，不把 reset 超时升级为 probe 失败。
 */
static void smartnic_hw_reset(struct smartnic_dev *sdev)
{
	u32 status;
	int waited_us = 0;

	if (!sdev->control_bar.addr)
		return;

	dev_dbg(sdev->dev, "requesting device reset\n");
	mutex_lock(&sdev->state_lock);
	sdev->reset_active = true;
	mutex_unlock(&sdev->state_lock);

	smartnic_csr_write(sdev, SMARTNIC_CSR_RESET, SMARTNIC_RESET_REQUEST);

	do {
		usleep_range(SMARTNIC_RESET_POLL_US,
			     SMARTNIC_RESET_POLL_US * 2);
		waited_us += SMARTNIC_RESET_POLL_US;
		status = smartnic_csr_read(sdev, SMARTNIC_CSR_RESET);
		if (status & SMARTNIC_RESET_DONE) {
			dev_dbg(sdev->dev, "device reset completed\n");
			mutex_lock(&sdev->state_lock);
			sdev->reset_active = false;
			mutex_unlock(&sdev->state_lock);
			return;
		}
	} while (waited_us < SMARTNIC_RESET_TIMEOUT_US);

	mutex_lock(&sdev->state_lock);
	sdev->reset_active = false;
	mutex_unlock(&sdev->state_lock);
	dev_dbg(sdev->dev, "reset done bit not observed before timeout\n");
}

/**
 * smartnic_discover_features() - 从 CSR 读取设备版本、特性和能力信息。
 * @sdev: SmartNIC 设备实例。
 *
 * 读取 VERSION、FEATURES、CAPS 和 STATUS CSR，并缓存到驱动设备状态中，
 * 供后续 ioctl、用户态工具和能力查询路径使用。
 */
static void smartnic_discover_features(struct smartnic_dev *sdev)
{
	if (!sdev->control_bar.addr)
		return;

	sdev->version = smartnic_csr_read(sdev, SMARTNIC_CSR_VERSION);
	sdev->features = smartnic_csr_read(sdev, SMARTNIC_CSR_FEATURES);
	sdev->caps = smartnic_csr_read(sdev, SMARTNIC_CSR_CAPS);
	sdev->status = smartnic_csr_read(sdev, SMARTNIC_CSR_STATUS);

	dev_info(sdev->dev,
		 "version=0x%08x features=0x%08x caps=0x%08x status=0x%08x\n",
		 sdev->version, sdev->features, sdev->caps, sdev->status);
}

/**
 * smartnic_quiesce() - 将设备切换到静默状态。
 * @sdev: SmartNIC 设备实例。
 *
 * 在 remove 或 probe 失败路径中阻止新的用户态操作进入；后续任务会在
 * 这里扩展队列、资源所有者和 mailbox 用户的停止流程。
 */
static void smartnic_quiesce(struct smartnic_dev *sdev)
{
	mutex_lock(&sdev->state_lock);
	if (sdev->state != SMARTNIC_DEV_REMOVED)
		sdev->state = SMARTNIC_DEV_QUIESCING;
	mutex_unlock(&sdev->state_lock);

	/* Later tasks will stop queues, resource owners, and mailbox users. */
	dev_dbg(sdev->dev, "device quiesced\n");
}

/**
 * smartnic_pci_probe() - PCI core 匹配设备后的 SmartNIC 初始化入口。
 * @pdev: PCI 设备实例。
 * @id: 匹配到的 PCI 设备 ID。
 *
 * 分配并初始化驱动私有状态，启用 PCI 设备，申请 BAR 资源，设置 DMA
 * mask，映射 control/doorbell BAR，执行硬件复位和能力发现，注册
 * MSI-X 中断以及字符设备节点。任一阶段失败都会按相反顺序释放已申请
 * 资源。
 *
 * 成功返回 0，失败返回负 errno。
 */
static int smartnic_pci_probe(struct pci_dev *pdev,
			      const struct pci_device_id *id)
{
	struct smartnic_dev *sdev;
	int err;

	sdev = kzalloc(sizeof(*sdev), GFP_KERNEL);
	if (!sdev)
		return -ENOMEM;

	sdev->pdev = pdev;
	sdev->dev = &pdev->dev;
	sdev->state = SMARTNIC_DEV_PROBING;
	mutex_init(&sdev->state_lock);
	mutex_init(&sdev->mbox_lock);
	spin_lock_init(&sdev->irq_lock);
	init_waitqueue_head(&sdev->admin_wq);
	init_waitqueue_head(&sdev->event_wq);
	init_waitqueue_head(&sdev->open_wq);
	atomic_set(&sdev->open_count, 0);
	atomic_set(&sdev->event_pending, 0);
	atomic_set(&sdev->mbox_event_pending, 0);
	atomic_set(&sdev->cq_event_pending, 0);
	pci_set_drvdata(pdev, sdev);

	err = pci_enable_device_mem(pdev);/* 只启用 MMIO memory 资源 */
	if (err) {
		dev_err(&pdev->dev, "failed to enable PCI device: %d\n", err);
		goto err_free_sdev;
	}

	err = pci_request_regions(pdev, SMARTNIC_DRV_NAME);/*向内核申请 硬件/PCI 枚举阶段决定的独占使用这个设备的 BAR 资源，防止别的驱动同时占用*/
	if (err) {
		dev_err(&pdev->dev, "failed to request PCI regions: %d\n", err);
		goto err_disable_device;
	}

	err = smartnic_setup_dma_mask(sdev);/*最多能访问多少位宽的 DMA 地址*/
	if (err)
		goto err_release_regions;

	pci_set_master(pdev);/*打开设备主动访问主机内存的能力*/

	err = smartnic_map_bar(sdev, SMARTNIC_BAR_CONTROL,
			       &sdev->control_bar, true);
	if (err)
		goto err_clear_master;

	err = smartnic_map_bar(sdev, SMARTNIC_BAR_DOORBELL,
			       &sdev->doorbell_bar, false);
	if (err)
		goto err_unmap_bars;

	smartnic_hw_reset(sdev);
	smartnic_discover_features(sdev);

	mutex_lock(&sdev->state_lock);
	sdev->state = SMARTNIC_DEV_READY;
	mutex_unlock(&sdev->state_lock);

	err = smartnic_irq_setup(sdev);
	if (err)
		goto err_mark_quiescing;

	err = smartnic_chrdev_register(sdev);
	if (err) {
		dev_err(&pdev->dev, "failed to register char device: %d\n", err);
		goto err_irq_teardown;
	}

	dev_info(&pdev->dev, "SmartNIC PCIe device probed successfully\n");
	return 0;

err_irq_teardown:
	smartnic_irq_teardown(sdev);
err_mark_quiescing:
	mutex_lock(&sdev->state_lock);
	sdev->state = SMARTNIC_DEV_QUIESCING;
	mutex_unlock(&sdev->state_lock);
	wake_up_all(&sdev->event_wq);
err_unmap_bars:
	smartnic_unmap_bars(sdev);
err_clear_master:
	pci_clear_master(pdev);
err_release_regions:
	pci_release_regions(pdev);
err_disable_device:
	pci_disable_device(pdev);
err_free_sdev:
	pci_set_drvdata(pdev, NULL);
	kfree(sdev);
	return err;
}

/**
 * smartnic_pci_remove() - PCI 设备移除时的 SmartNIC 清理入口。
 * @pdev: PCI 设备实例。
 *
 * 将设备静默，注销字符设备，释放 IRQ 和 BAR 映射，撤销 PCI bus
 * master/region/device 资源，标记设备已移除，并释放驱动私有状态。
 */
static void smartnic_pci_remove(struct pci_dev *pdev)
{
	struct smartnic_dev *sdev = pci_get_drvdata(pdev);

	if (!sdev)
		return;

	dev_info(&pdev->dev, "removing SmartNIC PCIe device\n");

	smartnic_quiesce(sdev);
	smartnic_chrdev_unregister(sdev);
	smartnic_irq_teardown(sdev);
	smartnic_unmap_bars(sdev);
	pci_clear_master(pdev);
	pci_release_regions(pdev);
	pci_disable_device(pdev);

	mutex_lock(&sdev->state_lock);
	sdev->state = SMARTNIC_DEV_REMOVED;
	mutex_unlock(&sdev->state_lock);

	pci_set_drvdata(pdev, NULL);
	kfree(sdev);
}

static struct pci_driver smartnic_pci_driver = {
	.name = SMARTNIC_DRV_NAME,
	.id_table = smartnic_pci_id_table,
	.probe = smartnic_pci_probe,
	.remove = smartnic_pci_remove,
};

module_pci_driver(smartnic_pci_driver);

MODULE_AUTHOR("RDMA SmartNIC OpenSpec prototype");
MODULE_DESCRIPTION("Prototype RDMA SmartNIC PCIe driver");
MODULE_LICENSE("GPL");
