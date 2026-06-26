# SmartNIC 驱动测试

12.7 为 12.1 至 12.6 构建的驱动层添加测试。当前仓库并非完整的 Linux 内核树，因此测试分为不依赖硬件的静态检查、可选的 KUnit 源文件以及 Linux selftest 烟雾测试包装脚本。

## 测试层次

| 测试 | 覆盖范围 |
| --- | --- |
| `drivers/linux/tests/test_smartnic_pci_driver_static.py` | 检查驱动是否包含 probe/remove、mailbox、字符设备、IRQ、DMA 和队列相关的钩子函数 |
| `drivers/linux/tests/test_smartnic_driver_lifecycle_static.py` | 聚焦失败路径和生命周期覆盖：unwind 标签、mailbox 超时/错误、poll 掩码、IRQ unwind、DMA 校验、队列清理 |
| `drivers/linux/smartnic_kunit.c` | 可选的 KUnit 烟雾测试，在支持 KUnit 的内核树中构建时校验常量和 UAPI 内存布局 |
| `tests/smartnic_driver_test.sh` | 项目级烟雾测试运行器，无需硬件即可运行；当 `/dev/smartnic*` 不存在时自动跳过硬件检查 |
| `tools/testing/selftests/smartnic/smartnic_driver_smoke.sh` | Linux selftest 入口，委托给项目级烟雾测试运行器 |

## 覆盖内容

- PCI probe 成功路径结构以及 probe 失败时的 unwind 标签；
- remove 顺序：字符设备销毁、IRQ 销毁、BAR 取消映射、PCI 禁用；
- DMA 掩码回退和 BAR 映射检查；
- mailbox 成功路径结构、超时轮询、设备错误映射以及 mutex 串行化；
- 字符设备 open/release/ioctl/mmap/poll 的管线逻辑；
- 未知 ioctl 和无效 size 的检查；
- MSI-X 分配、部分请求 IRQ 的 unwind、ISR 返回 `IRQ_NONE`/`IRQ_HANDLED`、ACK 以及 poll 唤醒；
- 一致性 DMA 环形缓冲区参数校验与分配/释放；
- release 时按文件描述符清理队列，以及使用 `dma_mmap_coherent` 进行队列 mmap；
- 用户态烟雾测试：`smartnicctl --help`、无效设备路径，以及有硬件时的功能/复位命令。

## 运行方式

```bash
make -C drivers/linux syntax-check
tests/smartnic_driver_test.sh
```

在启用了 KUnit 的 Linux 内核树中，可通过 `CONFIG_SMARTNIC_KUNIT=y` 将 `smartnic_kunit.c` 接入，覆盖常量/UAPI 的烟雾测试。当 `/dev/smartnic*` 不存在时，依赖硬件的检查会被有意跳过。
