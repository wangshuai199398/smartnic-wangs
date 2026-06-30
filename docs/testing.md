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

## Perftest Compatibility

15.2 添加了标准 RDMA perftest 兼容性 smoke runner：

```bash
make compat-perftest
```

它调用 `tests/run_perftest_compat.sh`，默认覆盖 RC Send、RDMA Write 和 RDMA Read 对应的 perftest 命令：

| 操作 | 默认工具 |
| --- | --- |
| RC Send | `ib_send_bw` |
| RDMA Write | `ib_write_bw` |
| RDMA Read | `ib_read_bw` |

该 runner 是硬件可选的兼容性入口，不是完整 benchmark。缺少 perftest 工具、缺少 `ibv_devices`、没有 RDMA 设备、client 模式没有指定 server 时会输出 `SKIP` 并以 0 退出；使用 `--force` 时这些情况会变成失败。每个命令的日志写到 `build/perftest-compat/`，可通过 `SMARTNIC_PERFTEST_OUT` 或 `--out` 覆盖。

常用环境变量：

| 变量 | 说明 | 默认值 |
| --- | --- | --- |
| `SMARTNIC_PERFTEST_DEVICE` | 传给 perftest `-d` 的 RDMA device name | 空，使用 perftest 默认设备 |
| `SMARTNIC_PERFTEST_PORT` | RDMA port | `1` |
| `SMARTNIC_PERFTEST_GID_INDEX` | RoCE GID index | `0` |
| `SMARTNIC_PERFTEST_SERVER` | client 模式连接的 server 地址 | 空 |
| `SMARTNIC_PERFTEST_ROLE` | `client` 或 `server` | `client` |
| `SMARTNIC_PERFTEST_SIZE` | message size | `64` |
| `SMARTNIC_PERFTEST_ITERS` | iteration count | `100` |
| `SMARTNIC_PERFTEST_QD` | queue depth | `8` |
| `SMARTNIC_PERFTEST_MTU` | 可选 MTU 参数 | 空 |
| `SMARTNIC_PERFTEST_OPS` | `send,write,read` 的子集 | `send,write,read` |
| `SMARTNIC_PERFTEST_EXTRA_ARGS` | 追加到每条 perftest 命令的参数 | 空 |
| `SMARTNIC_PERFTEST_TIMEOUT` | 单条命令 timeout 秒数 | `20` |

两机或两端口测试时，一端先启动 server：

```bash
SMARTNIC_PERFTEST_ROLE=server \
SMARTNIC_PERFTEST_DEVICE=smartnic0 \
SMARTNIC_PERFTEST_OPS=send \
make compat-perftest
```

另一端运行 client：

```bash
SMARTNIC_PERFTEST_ROLE=client \
SMARTNIC_PERFTEST_SERVER=192.0.2.10 \
SMARTNIC_PERFTEST_DEVICE=smartnic0 \
SMARTNIC_PERFTEST_GID_INDEX=0 \
SMARTNIC_PERFTEST_OPS=send,write,read \
make compat-perftest
```

也可以直接调用脚本调单项：

```bash
tests/run_perftest_compat.sh --op write --server 192.0.2.10 --device smartnic0 --size 64 --iters 100 --qp-depth 8
tests/run_perftest_compat.sh --op read --dry-run
```

`tests/run_rdma_regression.sh --mode full compatibility` 会调用该 runner；普通 smoke 回归不会强制运行硬件依赖的 perftest。当前目标只覆盖 perftest RC Send/RDMA Write/RDMA Read 兼容性冒烟，不包含 15.3 UCX、15.4 libfabric，也不替代正式性能 benchmark。

## UCX Compatibility

15.3 添加了 UCX 兼容性 smoke runner：

```bash
make compat-ucx
```

它调用 `tests/run_ucx_compat.sh`，默认使用 `ucx_perftest` 覆盖 SmartNIC 当前支持的 RC 操作语义：

| 操作 | UCX perftest test |
| --- | --- |
| RC Send | `tag_bw` |
| RDMA Write | `put_bw` |
| RDMA Read | `get_bw` |

该 runner 仍是 bring-up smoke，不是完整 UCX benchmark。缺少 `ucx_perftest`、client 模式没有指定 server、或 UCX 环境不可用时会输出 `SKIP` 并以 0 退出；使用 `--force` 时变为失败。日志写到 `build/ucx-compat/`，可通过 `SMARTNIC_UCX_OUT` 或 `--out` 覆盖。

常用环境变量：

| 变量 | 说明 | 默认值 |
| --- | --- | --- |
| `SMARTNIC_UCX_DEVICE` | `UCX_NET_DEVICES`，例如 `mlx5_0:1` 或未来 SmartNIC verbs device | 继承 `UCX_NET_DEVICES` |
| `SMARTNIC_UCX_TLS` | `UCX_TLS`，建议限制到 RC transports | `rc,rc_x` |
| `SMARTNIC_UCX_GID_INDEX` | `UCX_IB_GID_INDEX` | `0` |
| `SMARTNIC_UCX_SERVER` | client 模式连接的 server 地址 | 空 |
| `SMARTNIC_UCX_ROLE` | `client` 或 `server` | `client` |
| `SMARTNIC_UCX_SIZE` | message size | `64` |
| `SMARTNIC_UCX_ITERS` | iteration count | `100` |
| `SMARTNIC_UCX_OPS` | `send,write,read` 的子集 | `send,write,read` |
| `SMARTNIC_UCX_EXTRA_ARGS` | 追加到每条 `ucx_perftest` 命令的参数 | 空 |
| `SMARTNIC_UCX_TIMEOUT` | 单条命令 timeout 秒数 | `20` |

server 端示例：

```bash
SMARTNIC_UCX_ROLE=server \
SMARTNIC_UCX_DEVICE=smartnic0:1 \
SMARTNIC_UCX_TLS=rc,rc_x \
SMARTNIC_UCX_OPS=send \
make compat-ucx
```

client 端示例：

```bash
SMARTNIC_UCX_ROLE=client \
SMARTNIC_UCX_SERVER=192.0.2.10 \
SMARTNIC_UCX_DEVICE=smartnic0:1 \
SMARTNIC_UCX_GID_INDEX=0 \
SMARTNIC_UCX_OPS=send,write,read \
make compat-ucx
```

也可以直接调单项：

```bash
tests/run_ucx_compat.sh --op write --server 192.0.2.10 --device smartnic0:1 --size 64 --iters 100
tests/run_ucx_compat.sh --op read --dry-run
```

`tests/run_rdma_regression.sh --mode full compatibility` 会调用该 runner；普通 smoke 回归不会强制运行硬件依赖的 UCX 测试。当前目标只覆盖 UCX RC Send/RDMA Write/RDMA Read 冒烟，不包含 15.4 libfabric。

## Libfabric Compatibility

15.4 添加了 verbs-backed libfabric 兼容性 smoke runner：

```bash
make compat-libfabric
```

它调用 `tests/run_libfabric_compat.sh`，先用 `fi_info` 做 provider discovery，再按操作运行常见 fabtests：

| 操作 | 默认工具 |
| --- | --- |
| Send/Recv message | `fi_pingpong` |
| RDMA Write | `fi_rma_pingpong -o write` |
| RDMA Read | `fi_rma_pingpong -o read` |

该 runner 只做兼容性 bring-up，不做完整 benchmark。缺少 libfabric 工具、verbs-backed provider 不可用、RDMA device 不存在或 client 模式没有指定 server 时，会输出 `SKIP` 并以 0 退出；使用 `--force` 时变为失败。每个阶段的日志写到 `build/libfabric-compat/`，包括 `fi_info.log`、`send.log`、`write.log`、`read.log` 和 `summary.txt`。

需要的依赖：

- libfabric runtime；
- fabtests 工具，例如 `fi_info`、`fi_pingpong`、`fi_rma_pingpong`；
- 如果本机需要编译自定义 libfabric smoke binary，需安装 libfabric headers，但当前 runner 默认只调用标准工具；
- verbs-backed libfabric provider，以及可被该 provider 发现的 SmartNIC/RDMA device。

常用环境变量：

| 变量 | 说明 | 默认值 |
| --- | --- | --- |
| `SMARTNIC_LIBFABRIC_PROVIDER` | libfabric provider name | `verbs` |
| `SMARTNIC_LIBFABRIC_DEVICE` | verbs interface/device hint，导出为 `FI_VERBS_IFACE` | 继承 `FI_VERBS_IFACE` |
| `SMARTNIC_LIBFABRIC_DOMAIN` | 可选 libfabric domain | 空 |
| `SMARTNIC_LIBFABRIC_FABRIC` | 可选 libfabric fabric | 空 |
| `SMARTNIC_LIBFABRIC_SERVICE` | service/port | `7471` |
| `SMARTNIC_LIBFABRIC_SERVER` | client 模式连接的 server 地址 | 空 |
| `SMARTNIC_LIBFABRIC_ROLE` | `client` 或 `server` | `client` |
| `SMARTNIC_LIBFABRIC_SIZE` | message size | `64` |
| `SMARTNIC_LIBFABRIC_ITERS` | iteration count | `100` |
| `SMARTNIC_LIBFABRIC_QD` | queue depth/window hint | `8` |
| `SMARTNIC_LIBFABRIC_OPS` | `send,write,read` 的子集 | `send,write,read` |
| `SMARTNIC_LIBFABRIC_EXTRA_ARGS` | 追加到每条 fabtests 命令的参数 | 空 |
| `SMARTNIC_LIBFABRIC_TIMEOUT` | 单条命令 timeout 秒数 | `20` |

Provider discovery：

```bash
FI_VERBS_IFACE=smartnic0 fi_info -p verbs
```

server 端示例：

```bash
SMARTNIC_LIBFABRIC_ROLE=server \
SMARTNIC_LIBFABRIC_PROVIDER=verbs \
SMARTNIC_LIBFABRIC_DEVICE=smartnic0 \
SMARTNIC_LIBFABRIC_OPS=send \
make compat-libfabric
```

client 端示例：

```bash
SMARTNIC_LIBFABRIC_ROLE=client \
SMARTNIC_LIBFABRIC_SERVER=192.0.2.10 \
SMARTNIC_LIBFABRIC_PROVIDER=verbs \
SMARTNIC_LIBFABRIC_DEVICE=smartnic0 \
SMARTNIC_LIBFABRIC_OPS=send,write,read \
make compat-libfabric
```

也可以直接调单项或只验证命令生成：

```bash
tests/run_libfabric_compat.sh --op write --server 192.0.2.10 --device smartnic0 --size 64 --iters 100
tests/run_libfabric_compat.sh --op read --dry-run
```

`tests/run_rdma_regression.sh --mode full compatibility` 会调用该 runner；普通 smoke 回归不会强制运行硬件依赖的 libfabric 测试。当前目标只覆盖 verbs-backed Send/Recv、RDMA Write 和 RDMA Read smoke，不实现新的 provider 功能，也不替代 libfabric 完整测试矩阵。

## Simulation Performance Counters

15.5 添加了轻量级仿真性能计数器，位于 `sim/cocotb/bfm/performance_counters.py`。这些计数器只在 Cocotb/testbench 侧记录事件，不改变 DUT RTL 功能行为，也不设置默认性能阈值。

计数器覆盖：

| 计数器 | 起点 | 终点或累计点 | 输出 |
| --- | --- | --- | --- |
| Doorbell-to-CQE latency | Doorbell 观察或 WQE accept | 匹配的 CQE/completion | count、min、max、avg，单位 cycles |
| Doorbell-to-wire latency | Doorbell 观察或 WQE accept | 匹配的首个 wire/MAC packet | count、min、max、avg，单位 cycles |
| DMA bandwidth | DMA read/write 事件 | DMA byte 计数 | read bytes、write bytes、bytes/cycle，可选 bytes/second |
| Packet rate | TX packet emission | packet 计数 | packets、packets/cycle，可选 packets/second |
| Completion rate | CQE generation 或 completion observation | completion 计数 | completions、completions/cycle，可选 completions/second |

相关性默认使用 `(qpn, wr_id)`。如果某个 monitor 没有足够字段把 Doorbell/WQE 与 CQE 或 wire packet 对上，计数器会把该样本记为 `unavailable` 并输出 warning；只有启用 strict 模式时才把这种情况当作失败。

运行 smoke：

```bash
make sim-perf-counters
tests/run_rdma_regression.sh perf
RDMA_REGRESSION_ENABLE_PERF=1 tests/run_rdma_regression.sh --mode smoke
```

常用环境变量：

| 变量 | 说明 | 默认值 |
| --- | --- | --- |
| `SMARTNIC_SIM_PERF` | 在测试中启用性能计数器 | `0` |
| `SMARTNIC_SIM_PERF_CLOCK_HZ` | 仿真时钟频率，用于换算每秒速率 | 空，仅报告 per-cycle |
| `SMARTNIC_SIM_PERF_OUT` | JSON 报告输出路径 | 空，不写文件 |
| `SMARTNIC_SIM_PERF_STRICT` | 缺少相关性或 unavailable 样本时报错 | `0` |
| `RDMA_REGRESSION_ENABLE_PERF` | 将 `perf` 组加入 smoke/full 回归展开 | `0` |

JSON 报告包含 `window`、`latency`、`throughput` 和 `warnings` 字段；文本报告包含相同数据并明确单位。当前实现提供可复用的记录钩子：`record_doorbell()`、`record_wqe_accept()`、`record_wire_packet()`、`record_dma_read()`、`record_dma_write()` 和 `record_cqe()`。后续更完整的 integration tests 可以在现有 monitors 中调用这些钩子来得到真实 Doorbell-to-CQE、Doorbell-to-wire、DMA、packet 和 completion 数据。

限制：

- 当模块测试没有 Doorbell、wire packet 或 CQE monitor 时，对应 latency 会显示 unavailable，而不是让功能测试失败。
- 多包消息的 Doorbell-to-wire 只记录第一个匹配 wire packet，用于衡量首包发出延迟。
- DMA bandwidth、packet rate 和 completion rate 使用观察窗口内的 cycle 差计算；没有配置 `SMARTNIC_SIM_PERF_CLOCK_HZ` 时不会输出每秒换算。
- 这些计数器服务于仿真 bring-up 可见性，不替代 15.2/15.3/15.4 的外部兼容性或真实性能测试。

## KUnit

`drivers/linux/smartnic_kunit.c` 包含用于常量、UAPI 布局、mailbox errno、DMA 参数、poll 掩码和 IRQ 过滤的可选 KUnit 烟雾测试。在支持 KUnit 的 Linux 内核树中以 `CONFIG_SMARTNIC_KUNIT=y` 构建即可。
