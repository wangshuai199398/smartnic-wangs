# SmartNIC 驱动故障排查

本文档覆盖当前原型阶段的 Linux 驱动。

## Probe 失败

常见原因：

- PCI ID 与 `SMARTNIC_PCI_VENDOR_ID` / `SMARTNIC_PCI_DEVICE_ID` 不匹配。
- PCI 设备被固件禁用或未被枚举。
- `pci_enable_device_mem()` 或 `pci_request_regions()` 失败。

排查方法：

```bash
lspci -nn | grep -i smartnic
dmesg | grep -i smartnic
```

## BAR 映射失败

常见原因：

- 必需的 BAR0 缺失、长度为零或不是 MMIO 类型。
- 与其他驱动存在 PCI 资源冲突。
- 原型比特流暴露了不同的 BAR 布局。

排查方法：

```bash
lspci -vv -s <bus:dev.fn>
dmesg | grep -i "BAR"
```

当前驱动将 BAR0 映射为主控制/MMIO 窗口，BAR2 映射为可选的 doorbell/MMIO 窗口。

## DMA 掩码设置失败

常见原因：

- 平台无法提供 64 位或 32 位的 coherent DMA 寻址。
- IOMMU 或 DMA 限制配置错误。

排查方法：

```bash
dmesg | grep -i "DMA mask"
```

驱动优先尝试 64 位，失败后回退到 32 位。

如果 32 位也失败，probe 会 unwind 已申请的 PCI regions 并禁用设备。

## Reset 超时

常见原因：

- `SMARTNIC_CSR_RESET` 偏移与 RTL 不匹配。
- 硬件没有置位 `SMARTNIC_RESET_DONE`。
- PCIe BAR 已映射但控制通路没有响应。

排查方法：

```bash
dmesg | grep -i "reset"
devmem <bar0 + 0x10>
```

当前驱动将 reset timeout 记录为 debug 日志，并继续读取 feature CSR，便于早期原型阶段观察硬件状态。

## MSI-X 分配失败

常见原因：

- 平台禁用了 MSI-X。
- 可用的向量数量不足。
- 中断重映射/IOMMU 设置阻止了 MSI-X。

排查方法：

```bash
lspci -vv -s <bus:dev.fn> | grep -i msi
dmesg | grep -i "MSI-X"
```

驱动可接受少于默认数量的向量，最低到 `SMARTNIC_MIN_IRQ_VECTORS`。

## 缺失 MSI-X 中断

常见原因：

- MSI-X capability 未启用或平台禁用了中断重映射。
- `SMARTNIC_INTR_ENABLE` 未成功写入。
- 硬件没有置位 `SMARTNIC_INTR_STATUS` 的已知事件位。
- ISR 收到共享/无关中断并返回 `IRQ_NONE`。

排查方法：

```bash
lspci -vv -s <bus:dev.fn> | grep -i msi
dmesg | grep -Ei "smartnic|IRQ|MSI-X"
```

驱动在 teardown 时会先禁用设备中断，再 `synchronize_irq()`，最后 `free_irq()` 和 `pci_free_irq_vectors()`。

## Mailbox 超时

常见原因：

- 硬件未设置 DONE 或 ERROR。
- CSR 偏移量映射与 RTL 不匹配。
- 设备复位处于活跃状态或控制通路卡死。

排查方法：

```bash
dmesg | grep -i mailbox
tools/smartnicctl --device /dev/smartnic0 mbox 0x0000
```

超时返回 `-ETIMEDOUT`。

## ioctl 返回 `-ENOTTY`

常见原因：

- 未知的 ioctl 命令。
- 用户程序使用了过期的 ioctl 编号，而非包含 `include/uapi/linux/smartnic_ioctl.h`。
- 命令属于尚未实现的后续 ABI。

排查方法：

```bash
grep SMARTNIC_IOCTL include/uapi/linux/smartnic_ioctl.h
```

## ioctl 返回 `-EINVAL`

常见原因：

- `struct_size` 未设置为 `sizeof(struct ...)`。
- 队列深度不是 2 的幂。
- 描述符大小不是 8 字节对齐。
- Mailbox 输入/输出长度不是 dword 对齐或超过 16 字节。

## mmap 权限或大小错误

常见原因：

- 偏移量与创建时返回的 `mmap_offset` 不匹配。
- 队列属于另一个文件描述符。
- 请求的大小大于 ring 大小。
- Doorbell BAR 不存在。

排查方法：

```c
printf("mmap_offset=0x%llx ring_size=%llu\n", q.mmap_offset, q.ring_size);
```

队列 ring 的 mmap 使用 `dma_mmap_coherent()`。Doorbell/MMIO 的 mmap 使用非缓存 IO 映射。

## 使用中设备被移除

预期行为：

- `poll()` 返回 `POLLERR | POLLHUP`。
- 新的 open/ioctl 调用失败并返回 `-ENODEV`。
- remove 会等待所有打开的文件引用关闭后再释放设备状态。

如果有进程一直保持设备打开，unload/remove 会等待其 release。关闭所有文件描述符后重试。

## 无硬件环境

烟雾测试和示例程序不应给出模糊不明的失败。它们应报告 `/dev/smartnic*` 不存在，并跳过仅依赖硬件的操作。

## 12.10 测试和故障注入钩子

`CONFIG_SMARTNIC_KUNIT` 启用时，驱动暴露 test-only fault hook 布局，用于记录这些故障注入点：

- BAR mapping failure；
- DMA mask setup failure；
- mailbox completion failure；
- char device registration failure；
- MSI-X allocation failure。

这些字段只用于测试合同，生产构建不携带该状态。
