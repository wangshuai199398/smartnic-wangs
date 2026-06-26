# SmartNIC Linux 驱动发布检查清单

本检查清单用于确认当前 Linux SmartNIC 驱动切片的完成状态。范围限定于已实现的 PCIe 控制驱动、CSR mailbox、字符设备、DMA 队列 ring、mmap、poll、MSI-X 中断通路、测试以及用户态控制示例。

## 构建目标

快速静态合约检查：

```bash
make driver-static-check
```

驱动构建入口：

```bash
make driver
```

发布就绪检查：

```bash
make driver-release-check
```

发布检查执行以下步骤：

- 从 `drivers/linux` 进行干净重建；
- 驱动静态测试；
- 文档/UAPI/示例一致性检查；
- 驱动集成测试脚本；
- `git diff --check`；
- 当 Linux 内核头文件可用时，可选的 `W=1` Kbuild；
- 当可用时，可选的 `sparse` 和 `checkpatch.pl`；
- 当可用时，可选的 `shellcheck`（驱动 shell 脚本）。

## 内核配置

普通模块构建：

```text
CONFIG_SMARTNIC=m
```

可选 KUnit 自测：

```text
CONFIG_KUNIT=y
CONFIG_SMARTNIC=m
CONFIG_SMARTNIC_KUNIT=y
```

`CONFIG_SMARTNIC_KUNIT` 是当前驱动唯一使用的测试/调试配置项。仅用于测试的 fault hook 布局由此配置项控制，不在普通生产构建中出现。

## 模块构建

在拥有匹配内核头文件的 Linux 主机上：

```bash
make -C drivers/linux KDIR=/lib/modules/$(uname -r)/build W=1
```

干净重建：

```bash
make -C drivers/linux clean
make -C drivers/linux KDIR=/lib/modules/$(uname -r)/build W=1
```

可选静态工具：

```bash
make -C drivers/linux sparse-check
make -C drivers/linux checkpatch
```

如果内核头文件、`sparse` 或 `checkpatch.pl` 不可用，项目脚本会报告 `SKIP` 而非隐藏该条件。

## 加载/卸载烟雾测试

有硬件时：

```bash
sudo insmod drivers/linux/smartnic.ko
dmesg | tail -n 80
ls -l /dev/smartnic*
sudo SMARTNIC_DEV=/dev/smartnic0 bash tests/run_driver_integration.sh
sudo rmmod smartnic
dmesg | tail -n 80
```

预期的 dmesg 信号包括：

```text
mapped BAR0 ...
version=0x...
registered IRQ vector ...
created /dev/smartnic0
SmartNIC PCIe device probed successfully
removing SmartNIC PCIe device
```

## 用户态烟雾测试

在 Linux 上构建工具和示例：

```bash
make -C tools
make -C examples
```

运行：

```bash
tools/smartnicctl --device /dev/smartnic0 info
tools/smartnicctl --device /dev/smartnic0 reset
examples/smartnic_ioctl_example /dev/smartnic0
examples/smartnic_poll_example /dev/smartnic0
examples/smartnic_user_flow_example /dev/smartnic0
```

示例覆盖内容：

- 打开 `/dev/smartnicX`；
- `SMARTNIC_IOCTL_MBOX_EXEC`；
- 队列 create/query/destroy 元数据；
- coherent ring `mmap`；
- `poll()` 就绪和销毁事件；
- 常见 errno 上报。

## 资源生命周期检查清单

实现预期的配对关系：

| 资源 | 申请 | 释放 |
| --- | --- | --- |
| PCI 设备 | `pci_enable_device_mem()` | `pci_disable_device()` |
| PCI regions | `pci_request_regions()` | `pci_release_regions()` |
| Bus mastering | `pci_set_master()` | `pci_clear_master()` |
| BAR 映射 | `pci_iomap()` | `pci_iounmap()` |
| MSI-X 向量 | `pci_alloc_irq_vectors()` | `pci_free_irq_vectors()` |
| IRQ 处理程序 | `request_irq()` | `synchronize_irq()` + `free_irq()` |
| 字符设备 | `alloc_chrdev_region()` + `cdev_add()` + `device_create()` | `device_destroy()` + `cdev_del()` + `unregister_chrdev_region()` |
| DMA ring | `dma_alloc_coherent()` | `dma_free_coherent()` |
| 每文件队列 | `SMARTNIC_IOCTL_QUEUE_CREATE` | `SMARTNIC_IOCTL_QUEUE_DESTROY` 或文件 `release` |

Remove 顺序有意保守：

```text
quiesce userspace
unregister char device and wake poll waiters
teardown IRQ/MSI-X
unmap BARs
clear bus master
release PCI regions
disable PCI device
free private state
```

## UAPI 一致性检查清单

发布前确认：

- ioctl 编号仅来自 `include/uapi/linux/smartnic_ioctl.h`；
- 文档中提到了 `SMARTNIC_IOCTL_MBOX_EXEC`、`SMARTNIC_IOCTL_QUEUE_CREATE`、`SMARTNIC_IOCTL_QUEUE_QUERY` 和 `SMARTNIC_IOCTL_QUEUE_DESTROY`；
- 示例包含 `<linux/smartnic_ioctl.h>` 且不重复定义 UAPI；
- 每个 ioctl 结构体都设置了 `struct_size`；
- mmap 文档与 `SMARTNIC_QUEUE_MMAP_OFFSET(queue_id)` 和 `dma_mmap_coherent()` 一致；
- poll 文档与 `POLLIN | POLLRDNORM`、`POLLOUT | POLLWRNORM` 和 `POLLERR | POLLHUP` 一致；
- mailbox errno 映射与 `smartnic_mbox_device_error_to_errno()` 一致。

## 已知边界

- 驱动仅支持 Linux。
- 当前模块是原型控制驱动，不是完整的 RDMA verbs provider。
- 当 `/dev/smartnic*` 不存在时，仅依赖硬件的检查会明确跳过。
- 在任何声称硬件就绪的交接之前，应在 Linux 上实际运行 Kbuild、示例和硬件烟雾测试。
