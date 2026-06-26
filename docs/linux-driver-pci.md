# Linux PCIe Driver Probe/Remove

本文档对应 tasks.md 的 12.1，只实现 Linux PCIe 驱动的最小生命周期：匹配设备、probe 初始化、BAR 映射、DMA mask 配置、复位/能力发现，以及 remove 清理。

## 文件

| 文件 | 作用 |
| --- | --- |
| `drivers/linux/smartnic_pci.c` | PCI ID table、`pci_driver` 注册、probe/remove、BAR 映射和清理 |
| `drivers/linux/smartnic_pci.h` | 驱动私有 `smartnic_dev`、BAR 状态、锁和设备状态 |
| `drivers/linux/smartnic_regs.h` | PCI vendor/device ID、BAR 编号和早期 CSR offset 宏 |
| `drivers/linux/tests/test_smartnic_pci_driver_static.py` | compile-only 前的静态结构检查 |

## Probe 流程

`smartnic_pci_probe()` 按 Linux PCIe 驱动常见顺序执行：

1. 分配并初始化 `struct smartnic_dev`。
2. `pci_enable_device_mem()` 使能 MMIO 设备。
3. `pci_request_regions()` 独占 PCI BAR 资源。
4. 先尝试 `DMA_BIT_MASK(64)`，失败后回退到 `DMA_BIT_MASK(32)`。
5. `pci_set_master()` 允许设备发起 DMA。
6. 映射 BAR0 作为当前 12.1 的 primary control/MMIO aperture。
7. 如果 BAR2 存在，则作为 optional doorbell/secondary MMIO aperture 映射。
8. 通过 reset CSR 发起原型复位，并读取 version/features/caps/status。
9. `pci_set_drvdata()` 保存私有状态，进入 READY。

硬件设计文档当前定义 BAR0 为 Doorbell、BAR2 为 CSR。12.1 的用户要求显式要求 BAR0 作为 CSR/control 并可选 BAR2，因此驱动先保持宽松映射。后续 12.2/12.3 建立稳定 ABI 时，可以把 CSR mailbox 绑定到 BAR2，同时把 BAR0 暴露给 mmap Doorbell。

## Remove 流程

`smartnic_pci_remove()` 做最小安全清理：

1. 标记设备 quiescing。
2. 关闭已初始化的中断占位。
3. unmap BAR。
4. `pci_clear_master()`、`pci_release_regions()`、`pci_disable_device()`。
5. 清除 `drvdata` 并释放私有状态。

后续 hot-remove、文件描述符资源回收、MSI-X 和 async event 会在 12.9/12.11 扩展。

## 错误回滚

probe 的每一步都有对应 `goto` unwind label：

- BAR 映射失败：unmap 已映射 BAR；
- DMA/BAR 之前失败：释放 PCI regions；
- 设备 enable 之后失败：disable PCI device；
- 任意失败：清除 `drvdata` 并释放 `smartnic_dev`。

## 当前 Stub/TODO

- reset CSR offset 是原型宏，后续需与 RTL CSR ABI 对齐；
- 中断只保留 `irq_initialized` 清理占位，MSI-X 初始化留给 12.9；
- mailbox、ioctl、mmap、poll、资源生命周期和 datapath 都未实现；
- 在非 Linux kernel header 环境下，`make driver` 会运行静态检查并跳过真实 Kbuild。
