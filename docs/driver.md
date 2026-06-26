# SmartNIC Linux 驱动

本文档说明当前 SmartNIC Linux 驱动的实现范围：PCIe probe/remove、BAR/CSR 映射、CSR mailbox、字符设备、ioctl/mmap/poll、MSI-X 中断和 coherent DMA ring 生命周期。它不是完整的 RDMA verbs 驱动；QP/CQ/MR/AH 的完整语义仍在后续阶段。

## 架构总览

```text
PCI core
  -> smartnic_pci_probe()
      -> pci_enable_device_mem()
      -> pci_request_regions()
      -> DMA mask setup
      -> pci_iomap(BAR0 control/MMIO)
      -> optional pci_iomap(BAR2 doorbell/MMIO)
      -> reset CSR + feature discovery
      -> MSI-X setup
      -> /dev/smartnicX char device

userspace
  -> open("/dev/smartnic0")
  -> ioctl(mailbox / queue create / queue query / queue destroy)
  -> mmap(doorbell BAR or queue ring)
  -> poll(event/teardown readiness)
```

## PCIe Probe 与 Remove

Probe 逻辑位于 `drivers/linux/smartnic_pci.c`。

成功路径如下：

1. 分配并初始化 `struct smartnic_dev`。
2. 通过 `pci_enable_device_mem()` 启用 PCI MMIO。
3. 申请 PCI 区域（regions）。
4. 配置 coherent DMA 掩码，优先使用 64 位，回退到 32 位。
5. 启用 bus mastering。
6. 映射 BAR0 作为当前的控制/MMIO 窗口。
7. 可选地映射 BAR2 作为 doorbell/第二 MMIO 窗口。
8. 通过 `SMARTNIC_CSR_RESET` 发出复位。
9. 读取 `SMARTNIC_CSR_VERSION`、`SMARTNIC_CSR_FEATURES`、`SMARTNIC_CSR_CAPS` 和 `SMARTNIC_CSR_STATUS`。
10. 分配 MSI-X 向量并注册中断处理程序。
11. 注册 `/dev/smartnicX`。

Remove 执行相反操作：静默状态、注销字符设备、拆除 IRQ、取消 BAR 映射、释放 PCI 区域、禁用设备、清除 `drvdata`，并释放私有状态。

## BAR 与 CSR 映射

当前驱动命名：

| 名称 | BAR | 当前用途 |
| --- | --- | --- |
| `SMARTNIC_BAR_CONTROL` | BAR0 | 早期 CSR 辅助函数使用的控制/MMIO 窗口 |
| `SMARTNIC_BAR_DOORBELL` | BAR2 | 可选的 doorbell/MMIO 窗口，用于 mmap |

RTL 设计文档将 BAR0 定为 Doorbell，BAR2 定为 CSR。早期驱动在 ABI 仍在教学与迭代阶段时保持映射的灵活性。

重要的 CSR 偏移量：

| CSR | 用途 |
| --- | --- |
| `SMARTNIC_CSR_VERSION` | 设备版本 |
| `SMARTNIC_CSR_FEATURES` | 特性位 |
| `SMARTNIC_CSR_CAPS` | 能力位 |
| `SMARTNIC_CSR_STATUS` | 健康/状态 |
| `SMARTNIC_CSR_RESET` | 复位请求/完成 |
| `SMARTNIC_MBOX_*` | CSR mailbox 命令窗口 |
| `SMARTNIC_INTR_*` | 中断状态/使能/确认 |

## CSR Mailbox

`smartnic_mbox_exec()` 使用 `mbox_lock` 串行化 mailbox 命令。

命令流程：

1. 校验输入/输出长度是否为 dword 对齐且不超过四个 dword。
2. 如果设备正在 removing、quiescing、reset-active 或已取消映射，则拒绝命令。
3. 清除残留的 status/error。
4. 写入输入 dword。
5. 写入命令操作码。
6. 置位 `SMARTNIC_MBOX_CTRL_GO`。
7. 轮询 `SMARTNIC_MBOX_CONTROL`，直到 DONE 或 ERROR。
8. 若 DONE，复制输出 dword。
9. 若 ERROR，将硬件错误码映射为 Linux errno。

## 字符设备

`smartnic_chrdev_register()` 创建 `/dev/smartnicX`。

文件操作：

| 操作 | 行为 |
| --- | --- |
| `open` | 创建 per-file 上下文，拒绝 remove/quiesce/reset 状态 |
| `release` | 释放该文件描述符拥有的所有队列 |
| `unlocked_ioctl` | 分发 mailbox 和 queue ioctl |
| `compat_ioctl` | 复用原生 ioctl 分发 |
| `mmap` | 映射已授权的 doorbell/MMIO BAR 范围或拥有的队列 ring |
| `poll` | 报告事件可读性、命令可写性和 teardown 错误 |

## DMA Ring 生命周期

队列 ring 使用 coherent DMA 内存。

`smartnic_dma_ring_alloc()` 校验：

- depth 非零且为 2 的幂；
- 描述符大小非零且 8 字节对齐；
- `depth * desc_size` 不溢出；
- 总分配量不超过 `SMARTNIC_DMA_RING_MAX_BYTES`。

`SMARTNIC_IOCTL_QUEUE_CREATE` 创建当前文件描述符拥有的 SQ/RQ/CQ/描述符 ring。驱动返回队列 ID、ring 大小、DMA 地址和 mmap 偏移量 cookie。`SMARTNIC_IOCTL_QUEUE_DESTROY` 释放一个队列。`release` 释放该 fd 仍然拥有的所有队列。

## MSI-X 中断处理

`smartnic_irq_setup()` 申请 1 到 4 个 MSI-X 向量，并为每个注册一个 ISR。

ISR 流程：

1. 读取 `SMARTNIC_INTR_STATUS`。
2. 若未设置任何已知位，返回 `IRQ_NONE`。
3. 将已处理位写入 `SMARTNIC_INTR_ACK`。
4. 设置 mailbox/CQ/event 的 pending 标志。
5. 唤醒 `event_wq` 和 `admin_wq`。

`smartnic_irq_teardown()` 禁用硬件中断生成、同步活跃 IRQ、释放处理程序并释放向量。

## 当前限制

- 尚无完整 RDMA 资源生命周期。
- 尚无真正的 CQ 事件队列；IRQ 仅标记 pending 标志。
- 无任意 CSR 读/写 ioctl。
- 队列 DMA 地址暴露给后续硬件编程使用，但内核虚拟地址从不暴露。
- 当 `/dev/smartnic*` 不存在时，依赖硬件的测试会被跳过。
