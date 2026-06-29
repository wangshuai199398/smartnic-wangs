# SmartNIC 测试

本文档描述当前驱动的集成与打包检查。

## 主入口

```bash
make driver-integration-test
```

该命令运行 `tests/run_driver_integration.sh`，该脚本会感知当前环境：

- 如果 Linux 内核头文件可用，则尝试以 `W=1` 进行树外模块构建；
- 如果 Linux UAPI 头文件可用，则构建 `tools/smartnicctl` 和示例程序；
- 如果 `/dev/smartnic*` 存在，则运行硬件烟雾测试；
- 否则，仅依赖硬件的检查会报告 `SKIP` 而非 `FAIL`。

## 检查内容

| 范围 | 覆盖 |
| --- | --- |
| 驱动静态检查 | probe/remove 路径、probe failure unwind、mailbox 超时/错误映射、字符设备、ioctl、mmap、poll、MSI-X、DMA 队列生命周期和 fault-injection 钩子 |
| 打包 | UAPI 头文件存在、没有重复的 UAPI 结构体定义、当 Linux 头文件存在时工具和示例程序可构建 |
| 模块生命周期 | 当 `smartnic.ko` 存在且脚本以 root 运行时，重复 `insmod`/`rmmod` 循环 |
| 硬件烟雾测试 | `/dev/smartnicX` 创建、特性查询、复位命令、队列创建/销毁、mmap、poll |
| 清理 | 队列 release 清理、IRQ 销毁钩子、mailbox 超时清理路径存在性 |

## 无硬件环境下运行

在无 SmartNIC 硬件的开发机上：

```bash
bash tests/run_driver_integration.sh
```

预期输出包含类似以下的行：

```text
SKIP: no /dev/smartnic* device; hardware probe/ioctl/poll/DMA smoke skipped
```

只要脚本退出码为 0，这就是一次成功的无硬件运行。

## 发布前检查

```bash
make driver-release-check
```

该入口运行 `tests/run_driver_release_checks.sh`，在 `driver-integration-test` 基础上增加 clean rebuild、`git diff --check`、可选 `W=1` Kbuild、可选 sparse/checkpatch、可选 shellcheck，以及 release checklist 文件存在性检查。

## 有硬件环境下运行

在已构建驱动且硬件插上的 Linux 主机上：

```bash
make -C drivers/linux
sudo insmod drivers/linux/smartnic.ko
make -C tools
make -C examples
sudo SMARTNIC_DEV=/dev/smartnic0 bash tests/run_driver_integration.sh
sudo rmmod smartnic
```

脚本检查特性查询、复位、mailbox 通路、队列创建/销毁、队列 mmap、poll 以及最近的 `dmesg` 警告。

## Minimal Verbs Bring-Up Example

15.1 添加了一个最小 RC Send/Recv 示例：

```bash
make -C examples smartnic_minimal_verbs_example
SMARTNIC_PROVIDER_DEVICE=/dev/smartnic0 ./examples/smartnic_minimal_verbs_example
```

该示例走现有 userspace provider API：打开设备、查询能力、创建 PD/CQ/RC QP、注册 send/recv MR、post Recv、post Send，并轮询 completion。它假设底层驱动/硬件支持 self-connected loopback RC QP bring-up；无设备或权限不足时返回退出码 77 并打印 `SKIP`。15.2 的 perftest 和 15.3 的 UCX 兼容性测试不属于该示例。

## KUnit

`drivers/linux/smartnic_kunit.c` 包含用于常量、UAPI 布局、mailbox errno、DMA 参数、poll 掩码和 IRQ 过滤的可选 KUnit 烟雾测试。在支持 KUnit 的 Linux 内核树中以 `CONFIG_SMARTNIC_KUNIT=y` 构建即可。
