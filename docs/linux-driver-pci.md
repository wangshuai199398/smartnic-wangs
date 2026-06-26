# Linux PCIe Driver Probe/Remove

本文档对应 tasks.md 的 12.1，只实现 Linux PCIe 驱动的最小生命周期：匹配设备、probe 初始化、BAR 映射、DMA mask 配置、复位/能力发现，以及 remove 清理。

## 文件

| 文件 | 作用 |
| --- | --- |
| `drivers/linux/smartnic_pci.c` | PCI ID table、`pci_driver` 注册、probe/remove、BAR 映射和清理 |
| `drivers/linux/smartnic_pci.h` | 驱动私有 `smartnic_dev`、BAR 状态、锁和设备状态 |
| `drivers/linux/smartnic_mbox.c` | CSR mailbox 同步命令 helper、timeout、错误码映射和命令串行化 |
| `drivers/linux/smartnic_mbox.h` | mailbox helper 对后续 ioctl/resource 层暴露的内部 API |
| `drivers/linux/smartnic_chrdev.c` | `/dev/smartnicX` 字符设备、open/release/ioctl/mmap/poll |
| `drivers/linux/smartnic_chrdev.h` | 字符设备注册/注销接口 |
| `drivers/linux/smartnic_irq.c` | MSI-X 分配、ISR、状态 ACK、poll/event 唤醒和 teardown |
| `drivers/linux/smartnic_irq.h` | interrupt setup/teardown helper 接口 |
| `drivers/linux/smartnic_regs.h` | PCI vendor/device ID、BAR 编号和早期 CSR offset 宏 |
| `include/uapi/linux/smartnic_ioctl.h` | 用户态可见的最小 ioctl ABI |
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

## CSR Mailbox Helper

12.2 新增 `smartnic_mbox_exec()`，作为后续 ioctl 和资源管理代码的内部控制通道。它的顺序是：

1. 校验输入/输出 buffer 必须按 32-bit 对齐，且最多 4 个 dword；
2. 检查设备没有处于 remove/quiesce/reset；
3. 获取 `mbox_lock`，确保同一时间只有一个 mailbox transaction；
4. 清除旧的 DONE/ERROR/status；
5. 写入参数寄存器和 command opcode；
6. 写 `SMARTNIC_MBOX_CTRL_GO` 触发硬件；
7. 使用 `readl_poll_timeout()` 等待 DONE 或 ERROR；
8. DONE 后读取输出参数，ERROR 后把设备错误码映射为 Linux errno。

当前错误码映射为：

| 设备错误 | Linux errno |
| --- | --- |
| invalid command | `-EOPNOTSUPP` |
| invalid argument | `-EINVAL` |
| permission | `-EACCES` |
| bad state | `-EPERM` |
| busy | `-EBUSY` |
| no resource | `-ENOSPC` |
| timeout | `-ETIMEDOUT` |
| hardware/internal | `-EIO` |

这个 helper 暂时只处理寄存器窗口中的小参数，不实现 ioctl ABI、大块 DMA 参数缓冲区或异步完成。

## Character Device

12.3 新增 `/dev/smartnicX` 控制入口。probe 成功后调用 `smartnic_chrdev_register()`：

1. `alloc_chrdev_region()` 分配动态 major/minor；
2. 初始化 `cdev` 和 file operations；
3. 创建 `class` 与 `device_create()` 节点；
4. remove 时先删除 device/cdev，再唤醒 poll waiters，并等待已打开 fd 的 `open_count` 归零。

当前 file operations 的语义：

| 操作 | 当前行为 |
| --- | --- |
| `open` | 检查设备没有 remove/quiesce/reset，设置 `file->private_data=sdev` 并增加 open 引用 |
| `release` | 清除 private_data，减少 open 引用，最后一个 fd 唤醒 remove 等待 |
| `unlocked_ioctl` | 只识别 `SMARTNIC_IOCTL_MBOX_EXEC`，其他命令返回 `-ENOTTY` |
| `compat_ioctl` | 复用 native ioctl dispatch |
| `mmap` | 只允许映射已批准的 optional doorbell/MMIO BAR 区间，校验 offset/size，并使用 noncached IO 映射 |
| `poll` | 有事件时返回 `POLLIN|POLLRDNORM`，可提交命令时返回 `POLLOUT|POLLWRNORM`，teardown 时返回 `POLLERR|POLLHUP` |

`SMARTNIC_IOCTL_MBOX_EXEC` 使用固定大小结构，包含 `struct_size`、opcode、输入/输出 dword 数组和 status。它是 12.3 的教学型最小 ABI；后续 12.4～12.8 会添加资源生命周期 ioctl，而不是把完整 verbs 语义塞进这个 mailbox passthrough。

## Interrupt Support

12.5 新增 MSI-X 中断路径。probe 在 BAR、reset、feature discovery 之后调用 `smartnic_irq_setup()`：

1. `pci_alloc_irq_vectors()` 请求 1 到 4 个 MSI-X vector；
2. 每个 vector 使用 `request_irq()` 注册同一个 ISR，并用名字区分 admin/event/CQ；
3. 清除旧 interrupt status，写 `SMARTNIC_INTR_ENABLE` 打开 mailbox、admin event、CQ event 和 fatal error 位；
4. probe 后续失败时调用 `smartnic_irq_teardown()` 回滚已经申请的 vector。

ISR 的最小行为：

- 读取 `SMARTNIC_INTR_STATUS`；
- 如果没有属于本设备的位，返回 `IRQ_NONE`；
- 对已处理位写 `SMARTNIC_INTR_ACK`；
- mailbox done / admin event / CQ event / fatal error 都会设置 `event_pending`；
- mailbox 和 CQ 另有独立 pending flag，便于后续 ioctl/CQ event path 消费；
- 使用 `wake_up_interruptible()` 唤醒 `poll()` 等待者。

remove 时先让 char device 进入 teardown，然后 `smartnic_irq_teardown()` 会关闭硬件中断、`synchronize_irq()`、`free_irq()` 并释放 MSI-X vectors。真实 CQ event queue、CQ vector routing 和 per-CQ moderation 仍留给后续资源/中断任务扩展。
