# SmartNIC Linux 驱动指南

本文档是当前 Linux SmartNIC 原型驱动的实用指南，覆盖 PCIe probe/remove、CSR mailbox、字符设备、DMA ring、mmap、poll、MSI-X、测试和常见故障排查。它描述的是当前已实现代码，不承诺尚未实现的完整 RDMA verbs 数据面。

## 架构

```text
PCI core
  -> smartnic_pci_probe()
      -> pci_enable_device_mem()
      -> pci_request_regions()
      -> dma_set_mask_and_coherent(64-bit, fallback 32-bit)
      -> pci_set_master()
      -> pci_iomap(BAR0 control/MMIO)
      -> optional pci_iomap(BAR2 doorbell/MMIO)
      -> SMARTNIC_CSR_RESET
      -> SMARTNIC_CSR_VERSION / FEATURES / CAPS / STATUS
      -> smartnic_irq_setup()
      -> smartnic_chrdev_register()

userspace
  -> open("/dev/smartnic0")
  -> ioctl(SMARTNIC_IOCTL_MBOX_EXEC)
  -> ioctl(SMARTNIC_IOCTL_QUEUE_CREATE / QUERY / DESTROY)
  -> mmap(queue ring or approved doorbell/MMIO aperture)
  -> poll(event readiness, command readiness, remove/hangup)
```

驱动拆分为多个小文件：

| 文件 | 职责 |
| --- | --- |
| `drivers/linux/smartnic_pci.c` | PCI probe/remove、BAR 映射、DMA 掩码设置、复位、特性发现 |
| `drivers/linux/smartnic_mbox.c` | CSR mailbox 命令辅助函数、超时和硬件错误映射 |
| `drivers/linux/smartnic_chrdev.c` | `/dev/smartnicX` 的 open/release/ioctl/mmap/poll |
| `drivers/linux/smartnic_irq.c` | MSI-X 向量分配、ISR、事件唤醒、销毁 |
| `drivers/linux/smartnic_dma.c` | coherent DMA ring 分配/释放及参数校验 |
| `drivers/linux/smartnic_queue.c` | 每文件描述符的队列生命周期和队列 mmap |
| `include/uapi/linux/smartnic_ioctl.h` | Linux 用户态 ABI |

## 构建与加载

当 Linux 内核头文件可用时，构建树外模块：

```bash
make -C drivers/linux KDIR=/lib/modules/$(uname -r)/build
```

如果缺少内核头文件，Makefile 仍会运行驱动静态检查并跳过 Kbuild。在匹配硬件支持的 Linux 主机上加载和卸载：

```bash
sudo insmod drivers/linux/smartnic.ko
dmesg | tail -n 50
ls -l /dev/smartnic*
sudo rmmod smartnic
```

可选的 KUnit 测试由 `CONFIG_SMARTNIC_KUNIT` 控制。在启用 KUnit 的内核树中，选择：

```text
CONFIG_SMARTNIC=m
CONFIG_KUNIT=y
CONFIG_SMARTNIC_KUNIT=y
```

12.10 还在 `CONFIG_SMARTNIC_KUNIT` 下定义了仅用于测试的 fault hook 字段，覆盖 BAR 映射、DMA 掩码设置、mailbox 完成、字符设备注册和 MSI-X 分配。生产构建不携带这些测试状态。

设备节点权限由系统策略管理。本地调试时可检查：

```bash
ls -l /dev/smartnic0
udevadm info --query=all --name=/dev/smartnic0
```

## Probe 与 Remove 流程

Probe 按依赖顺序初始化资源。unwind 标签仅释放已成功申请的资源：

```text
enable PCI
request regions
setup DMA mask
set bus master
map BARs
reset + discover features
setup IRQ
register char device
```

Remove 先静默用户态，再拆除中断和 PCI 资源：

```text
smartnic_quiesce()
smartnic_chrdev_unregister()
smartnic_irq_teardown()
smartnic_unmap_bars()
pci_clear_master()
pci_release_regions()
pci_disable_device()
```

如果在 remove 期间仍有文件打开，`smartnic_chrdev_unregister()` 会唤醒 poll 等待者，并等待 `open_count` 降为零后才最终释放私有状态。

## BAR 与 CSR 访问

当前代码映射：

| 宏 | BAR | 含义 |
| --- | --- | --- |
| `SMARTNIC_BAR_CONTROL` | BAR0 | CSR 辅助函数使用的控制/MMIO 窗口 |
| `SMARTNIC_BAR_DOORBELL` | BAR2 | 可选的 doorbell/MMIO 窗口，用于 mmap |

重要的 CSR 寄存器组：

| 寄存器 | 用途 |
| --- | --- |
| `SMARTNIC_CSR_RESET` | 复位请求和 done 位 |
| `SMARTNIC_CSR_VERSION` | 硬件/RTL 版本 |
| `SMARTNIC_CSR_FEATURES` | 特性位 |
| `SMARTNIC_CSR_CAPS` | 能力位 |
| `SMARTNIC_CSR_STATUS` | 设备状态 |
| `SMARTNIC_MBOX_*` | mailbox 命令窗口 |
| `SMARTNIC_INTR_STATUS` / `ENABLE` / `ACK` | MSI-X 事件状态、使能和确认 |

预期的 probe 日志片段：

```text
smartnic ... mapped BAR0 start=... len=...
smartnic ... version=0x... features=0x... caps=0x... status=0x...
smartnic ... created /dev/smartnic0
```

## CSR Mailbox 通路

用户态通过 `SMARTNIC_IOCTL_MBOX_EXEC` 提交 mailbox 命令。驱动通路为：

```text
smartnic_chrdev_ioctl()
  -> smartnic_ioctl_mbox_exec()
      -> smartnic_mbox_exec()
          -> validate dword-aligned in/out length
          -> lock mbox_lock
          -> clear stale status
          -> write args
          -> write opcode
          -> set SMARTNIC_MBOX_CTRL_GO
          -> readl_poll_timeout(DONE | ERROR)
          -> map hardware error to errno
          -> copy output dwords
```

硬件错误码映射集中在 `smartnic_mbox_device_error_to_errno()` 中。示例如下：

| 设备错误 | Linux errno |
| --- | --- |
| `SMARTNIC_MBOX_ERR_INVALID_CMD` | `-EOPNOTSUPP` |
| `SMARTNIC_MBOX_ERR_INVALID_ARG` | `-EINVAL` |
| `SMARTNIC_MBOX_ERR_PERMISSION` | `-EACCES` |
| `SMARTNIC_MBOX_ERR_BUSY` | `-EBUSY` |
| `SMARTNIC_MBOX_ERR_NO_RESOURCE` | `-ENOSPC` |
| `SMARTNIC_MBOX_ERR_TIMEOUT` | `-ETIMEDOUT` |

## UAPI 摘要

始终包含 Linux UAPI 头文件：

```c
#include <linux/smartnic_ioctl.h>
```

已实现的 ioctl 命令：

| 命令 | 方向 | 结构体 |
| --- | --- | --- |
| `SMARTNIC_IOCTL_MBOX_EXEC` | `_IOWR` | `struct smartnic_ioctl_mbox` |
| `SMARTNIC_IOCTL_QUEUE_CREATE` | `_IOWR` | `struct smartnic_ioctl_queue` |
| `SMARTNIC_IOCTL_QUEUE_QUERY` | `_IOWR` | `struct smartnic_ioctl_queue` |
| `SMARTNIC_IOCTL_QUEUE_DESTROY` | `_IOW` | `struct smartnic_ioctl_queue_destroy` |

所有 ioctl 结构体使用 `struct_size` 进行 ABI 校验。未知命令返回 `-ENOTTY`。

## DMA 队列与 mmap 规则

`SMARTNIC_IOCTL_QUEUE_CREATE` 分配 coherent DMA 内存并返回安全的元数据：

- `queue_id`
- `mmap_offset`
- `ring_size`
- `dma_addr`
- producer/consumer 索引

校验规则：

- depth 必须非零且为 2 的幂；
- 描述符大小必须非零且 8 字节对齐；
- `depth * desc_size` 不得溢出；
- 总大小不得超过 `SMARTNIC_DMA_RING_MAX_BYTES`；
- 内核虚拟地址从不暴露给用户态。

队列 mmap 使用 `dma_mmap_coherent()`，要求：

- `offset == mmap_offset`（队列创建时返回的值）；
- 通过拥有该队列的同一文件描述符映射；
- 映射大小不超过 `ring_size`。

Doorbell/MMIO 的 mmap 仅允许用于已授权的 doorbell BAR 范围，使用非缓存 IO 映射。

## poll 语义

`poll()` 返回：

| 掩码 | 含义 |
| --- | --- |
| `POLLIN \| POLLRDNORM` | mailbox/事件/CQ 通知就绪 |
| `POLLOUT \| POLLWRNORM` | 可以提交命令（复位未处于活跃状态） |
| `POLLERR \| POLLHUP` | 设备正在静默或已移除 |

在 remove 期间，驱动唤醒等待者，使被阻塞的用户态可以观察到 `POLLERR | POLLHUP`。

## MSI-X 中断通路

`smartnic_irq_setup()` 使用 `PCI_IRQ_MSIX` 申请 `SMARTNIC_MIN_IRQ_VECTORS` 到 `SMARTNIC_MAX_IRQ_VECTORS` 范围内的向量。每个向量注册同一个 ISR。

ISR 行为：

1. 读取 `SMARTNIC_INTR_STATUS`；
2. 用 `smartnic_irq_filter_status()` 过滤已知位；
3. 若没有设置任何 SmartNIC 事件位，返回 `IRQ_NONE`；
4. 通过 `SMARTNIC_INTR_ACK` 确认已处理的位；
5. 设置 mailbox/CQ/事件的 pending 标志；
6. 唤醒 `event_wq` 和 `admin_wq`；
7. 返回 `IRQ_HANDLED`。

销毁流程：禁用硬件中断生成、调用 `synchronize_irq()`、释放处理程序、释放向量。

## 用户态示例程序

在 Linux 上以 UAPI 头文件构建示例：

```bash
make -C examples
```

可用示例：

| 示例 | 演示内容 |
| --- | --- |
| `examples/smartnic_ioctl_example.c` | 打开设备、查询 mailbox、创建/销毁队列 |
| `examples/smartnic_poll_example.c` | 创建队列、mmap ring、poll 事件 |
| `examples/smartnic_user_flow_example.c` | 组合 ioctl + mmap + poll 流程，含常见 errno 处理 |

最小 mailbox 查询：

```c
struct smartnic_ioctl_mbox mbox = {0};
mbox.struct_size = sizeof(mbox);
mbox.opcode = 0x0001;
mbox.out_len = sizeof(mbox.data);
if (ioctl(fd, SMARTNIC_IOCTL_MBOX_EXEC, &mbox) < 0)
    perror("SMARTNIC_IOCTL_MBOX_EXEC");
```

最小队列 mmap：

```c
void *ring = mmap(NULL, queue.ring_size, PROT_READ | PROT_WRITE,
                  MAP_SHARED, fd, (off_t)queue.mmap_offset);
```

## 故障排查

Probe 失败：

```bash
lspci -nn | grep -i smartnic
dmesg | grep -i smartnic
```

BAR 映射失败：

```bash
lspci -vv -s <bus:dev.fn>
dmesg | grep -i "BAR"
```

DMA 掩码失败：

```bash
dmesg | grep -i "DMA mask"
```

Reset 超时：

```bash
dmesg | grep -i "reset done bit"
```

CSR mailbox 超时：

```bash
dmesg | grep -i mailbox
tools/smartnicctl --device /dev/smartnic0 mbox 0x0000
```

无效 ioctl：

- 检查 `struct_size`；
- 检查程序是否包含了 `include/uapi/linux/smartnic_ioctl.h`；
- 未知命令预期返回 `-ENOTTY`。

mmap 失败：

- 验证 fd 是否拥有该队列；
- 验证 `mmap_offset` 和 `ring_size`；
- 无效偏移量预期返回 `-EPERM`，超大小映射预期返回 `-EINVAL`。

缺失 MSI-X 中断：

```bash
lspci -vv -s <bus:dev.fn> | grep -i msi
dmesg | grep -i "IRQ\\|MSI-X\\|smartnic"
```

Remove/unload 清理问题：

- 关闭所有 `/dev/smartnicX` 文件描述符；
- 用 `lsof /dev/smartnic0` 检查持有该节点的进程；
- poll 等待者应被唤醒并收到 `POLLERR | POLLHUP`。

## 测试

运行不依赖硬件的检查：

```bash
make -C drivers/linux syntax-check
make driver-integration-test
```

在有硬件的 Linux 主机上：

```bash
sudo SMARTNIC_DEV=/dev/smartnic0 bash tests/run_driver_integration.sh
```
