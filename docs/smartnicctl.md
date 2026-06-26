# SmartNIC Userspace Control Tool

12.4 新增一个很小的用户态控制层，用来教学式验证 12.3 暴露的字符设备 ABI。它不是 libibverbs provider，也不实现 QP/CQ/MR 资源生命周期；那些仍由后续 13.x 和驱动资源任务完成。

## 文件

| 文件 | 作用 |
| --- | --- |
| `tools/libsmartnic.c` / `tools/libsmartnic.h` | 打开/关闭 `/dev/smartnicX`，封装 mailbox ioctl，提供 query/reset helper |
| `tools/smartnicctl.c` | 命令行工具，支持 list/info/reset/mbox 和 CSR unsupported 提示 |
| `tools/Makefile` | 用户态库和 CLI 的独立构建目标 |
| `include/uapi/linux/smartnic_ioctl.h` | 复用 12.3 的唯一 ioctl 定义，不复制 ABI |

## 命令

```text
smartnicctl list
smartnicctl --device /dev/smartnic0 info
smartnicctl --device /dev/smartnic0 reset
smartnicctl --device /dev/smartnic0 mbox 0x0001
```

`read-csr` 和 `write-csr` 目前会返回 unsupported，因为 12.3 的 UAPI 只公开 mailbox passthrough，没有公开任意 CSR 读写 ABI。这样可以避免用户态绕过驱动策略直接访问控制寄存器。

## Error Model

library wrapper 使用标准 `errno` 报错：

- 打开不存在的设备：`open()` 设置的 errno；
- ioctl 不支持或硬件不支持命令：驱动返回的 errno；
- 输入 dword 数量超过 UAPI 上限：`EINVAL`；
- read/write CSR：CLI 明确打印当前 UAPI 不支持。

## Build And Test

```bash
make userspace
make -C tools test
tools/smartnicctl --help
```

这些工具面向 Linux 构建环境，依赖 Linux UAPI headers，例如 `linux/ioctl.h` 和 `linux/types.h`。如果本机没有加载 SmartNIC 内核模块，`info`/`reset` 会清楚打印打开设备失败；这也是当前测试覆盖的负路径。
