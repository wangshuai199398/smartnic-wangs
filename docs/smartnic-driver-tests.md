# SmartNIC 驱动测试

12.7 为 12.1 至 12.6 构建的驱动层添加基础测试。12.10 进一步补充 error-path self-tests、故障注入钩子检查和集成测试入口。当前仓库并非完整的 Linux 内核树，因此测试分为不依赖硬件的静态检查、可选的 KUnit 源文件以及 Linux selftest 烟雾测试包装脚本。

## 测试层次

| 测试 | 覆盖范围 |
| --- | --- |
| `drivers/linux/tests/test_smartnic_pci_driver_static.py` | 检查驱动是否包含 probe/remove、mailbox、字符设备、IRQ、DMA 和队列相关的钩子函数 |
| `drivers/linux/tests/test_smartnic_driver_lifecycle_static.py` | 聚焦失败路径和生命周期覆盖：unwind 标签、mailbox 超时/错误、poll 掩码、IRQ unwind、DMA 校验、队列清理 |
| `drivers/linux/tests/test_smartnic_driver_error_paths_static.py` | 12.10 error-path 合同测试：probe unwind、BAR/DMA/reset/feature failure、mailbox errno、ioctl/mmap/poll、DMA mmap、MSI-X teardown 和 fault-injection 钩子 |
| `drivers/linux/smartnic_kunit.c` | 可选的 KUnit 烟雾测试，在支持 KUnit 的内核树中构建时校验常量、UAPI 内存布局、mailbox errno 映射、DMA 参数校验、poll 掩码、IRQ 过滤和测试故障钩子 |
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

## 12.10 Error-Path Self-Tests

12.10 的重点不是新增用户可见功能，而是把驱动错误路径变成可检查的合同：

- PCIe probe 成功路径和每个失败 unwind 标签都必须保留；
- BAR 映射失败、DMA mask 设置失败、reset timeout、feature discovery 失败路径必须有可观察的日志或清理结构；
- CSR mailbox 的 timeout、硬件错误码映射、无效参数和 mutex 串行化必须可测试；
- 字符设备 open/release 引用计数、未知 ioctl、结构体大小校验、mmap 范围校验和 poll 掩码必须可测试；
- DMA ring 参数校验、分配失败、mmap 边界以及 release 时的队列清理必须可测试；
- MSI-X 分配、部分 `request_irq()` 失败 unwind、ISR dispatch、completion/mailbox 通知和 teardown 必须可测试；
- `CONFIG_SMARTNIC_KUNIT` 下提供 test-only fault hook 字段，用于记录 BAR、DMA mask、mailbox completion、char device registration 和 MSI-X allocation 的故障注入点。生产构建不会携带这些字段。

## 运行方式

```bash
make -C drivers/linux syntax-check
tests/smartnic_driver_test.sh
```

在启用了 KUnit 的 Linux 内核树中，可通过 `CONFIG_SMARTNIC_KUNIT=y` 将 `smartnic_kunit.c` 接入，覆盖常量/UAPI、mailbox 错误映射、DMA 参数边界、poll readiness、IRQ status 过滤和 test-only fault hook。当 `/dev/smartnic*` 不存在时，依赖硬件的检查会被有意跳过。
