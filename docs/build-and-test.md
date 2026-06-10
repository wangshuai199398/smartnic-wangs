# 构建与测试入口

本文档说明当前项目的顶层 `make` 目标。当前阶段只建立统一入口，不实现新的 RDMA 功能逻辑；这些目标先作为可执行占位，方便后续逐步接入 RTL、Linux driver、用户态库和仿真验证。

## 总体设计

顶层 `Makefile` 位于项目根目录，负责把不同层次的构建和验证流程收敛到固定命令中：

```text
make lint
make verilator
make cocotb
make driver
make userspace
make regression
make coverage
make clean
```

这样设计的原因是 RDMA SmartNIC 横跨硬件 RTL、Linux 内核驱动、用户态 Verbs 库和 Cocotb/Verilator 验证环境。如果每一层都使用完全不同的命令，后续做回归测试和持续集成会很难管理。先固定入口，再逐步把真实逻辑接入进去，能让学习和实现都保持清晰。

## make lint

`make lint` 是 RTL 静态检查入口。

当前它会检查公共 package 文件 `rtl/common/smartnic_pkg.sv` 是否存在，并打印占位信息。后续可以在这里接入：

- Verilator lint；
- svlint；
- 商业 EDA 工具的 SystemVerilog 静态检查；
- 编码风格检查。

它支撑的验证目标是尽早发现 RTL 语法、位宽、未连接信号和风格问题。

## make verilator

`make verilator` 是 Verilator 仿真构建入口。

当前它只打印占位信息。后续会用于编译 `smartnic_top` 或模块级 RTL 测试平台，生成可执行仿真模型。

它支撑的验证目标是让 RTL 在不依赖真实 FPGA 板卡的情况下先跑起来，方便做快速迭代。

## make cocotb

`make cocotb` 是 Cocotb 测试入口。

当前它只打印占位信息。后续会运行 `verif/cocotb` 下的 Python 测试，包括 PCIe BFM、Ethernet/RoCEv2 BFM、host memory model、scoreboard 和覆盖率采集。

它支撑的验证目标是用 Python 测试激励验证 Doorbell、QP、CQ、MR、DMA、RoCEv2 packet 和 completion 等模块行为。

## make driver

`make driver` 是 Linux driver 构建入口。

顶层目标会进入 `drivers/linux` 子目录，并调用该目录下的最小 `Makefile`。当前子目录 Makefile 只打印占位信息，后续会接入 out-of-tree Kbuild，用于构建 SmartNIC PCIe 驱动、字符设备控制面、mmap Doorbell 和 MSI-X 中断处理代码。

它支撑的验证目标是保证软件控制面可以被独立构建和检查。

## make userspace

`make userspace` 是 `libsmartnic` 用户态库构建入口。

顶层目标会进入 `lib/libsmartnic` 子目录，并调用该目录下的最小 `Makefile`。当前子目录 Makefile 只打印占位信息，后续会构建 Verbs 兼容用户态库。

它支撑的验证目标是保证用户态 API、WQE 构造、CQE 解析和 Doorbell 快路径代码可以被独立构建和测试。

## make regression

`make regression` 是组合回归入口。

当前它依次运行：

```text
make lint
make verilator
make cocotb
```

这样设计是因为早期硬件验证的主线通常是：先静态检查，再构建仿真模型，最后运行 Cocotb 测试。等后续 driver 和 userspace 更完整后，可以把软件单元测试、兼容性测试和端到端测试加入更大的 regression 流程。

## make coverage

`make coverage` 是覆盖率报告入口。

当前它只打印占位信息。后续会汇总：

- Cocotb 功能覆盖率；
- Verilator line/toggle coverage；
- opcode、QP state、completion status、MR permission、SGE count、QP type 等协议覆盖点。

它支撑的验证目标是回答“测试是否覆盖了规格要求中的关键场景”。

## make clean

`make clean` 是清理入口。

当前它会调用 driver 和 userspace 子目录的 `clean` 目标，并删除常见构建目录，例如 `build`、`coverage` 和 `.pytest_cache`。

它的作用是让开发者可以回到干净状态，避免旧构建产物影响后续验证结果。

## 与 verification requirement 的关系

`spec.md` 中的 Cocotb/Verilator Verification requirement 要求项目包含模块测试、集成测试、scoreboard、BFM、覆盖率和回归自动化。当前 1.6 阶段还不实现这些测试本身，但已经建立了它们未来要挂接的位置：

- `make lint` 对应 RTL 静态质量检查；
- `make verilator` 对应 Verilator 仿真模型构建；
- `make cocotb` 对应 Cocotb 模块级和集成测试执行；
- `make regression` 对应自动化回归入口；
- `make coverage` 对应覆盖率报告入口；
- `make driver` 和 `make userspace` 为后续 perftest、UCX、libfabric 兼容性测试准备软件构建入口。

因此，这一步的重点不是验证 RDMA 功能已经正确，而是先把验证流程的“门”建好。后续每实现一个模块，就可以把对应测试接到这些固定入口下面。
