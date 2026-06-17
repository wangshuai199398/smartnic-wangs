## 背景与动机

现代数据中心存储、AI/ML 训练、分布式数据库和 HPC 工作负载需要低延迟、高吞吐量且支持 CPU 旁路的网络传输。本变更引入完整的 RDMA SmartNIC 设计能力，使项目能够从 RTL 到 Linux 驱动程序和用户态 Verbs 集成，完整地规格定义、实现、原型验证一款高性能 RoCEv2 智能网卡。

## 变更内容

- 定义一款可原型验证的 RDMA SmartNIC 芯片架构，具备 PCIe Gen5 x16 主机接口和 100GbE 级别的 RoCEv2 数据包通路。
- 新增硬件 RTL 模块边界划分：PCIe 端点、BAR/CSR 寄存器块、Doorbell 捕获、QP/CQ/MR 管理器、Scatter-Gather DMA 引擎、RoCEv2 解析器/构造器、RC/UD 传输引擎、完成引擎、MSI-X、SR-IOV、PFC/ECN/DCQCN，以及顶层集成。
- 定义 RDMA 操作：RDMA Read、RDMA Write、Send、Recv，支持 RC 和 UD QP 类型。
- 定义 QP、CQ、MR、PD、AH、Completion Queue 和 Doorbell 的生命周期语义，覆盖硬件、内核驱动和用户态库各层。
- 定义 Linux 内核驱动控制面：PCIe probe/remove、字符设备 ioctl、mmap Doorbell 页、资源分配、MSI-X 中断处理、SR-IOV 管理以及 RDMA 子系统对接接口。
- 定义与 libibverbs 兼容的用户态 Verbs API 接口：设备发现、上下文管理、PD/CQ/QP/MR/AH 操作、工作请求提交、完成轮询和异步事件。
- 定义基于 Cocotb/Verilator 的仿真与验证策略：包含 PCIe 和以太网 BFM、主机内存模型、记分板、覆盖率、模块级测试、集成测试和协议一致性测试。
- 定义面向 perftest、UCX 和 libfabric 工作负载的兼容性验证目标。

## 能力

### 新增能力

- rdma-smartnic：完整的 RDMA SmartNIC 设计能力，涵盖硬件架构、软件接口、用户态 Verbs API、验证和兼容性验证。

### Modified Capabilities

None.

## Impact

- **OpenSpec**: 新增 rdma-smartnic 能力规格和实现任务计划。
- **RTL**: 未来实现将添加 SystemVerilog 模块，涵盖 PCIe、DMA、QP/CQ/MR、RoCEv2 传输、完成、中断、虚拟化、拥塞控制和顶层集成。
- **Linux driver**: 未来实现将添加内核驱动，包含字符设备控制面、mmap Doorbell 支持、资源生命周期管理、MSI-X 和 SR-IOV 支持。
- **Userspace library**: 用户态库：未来实现将添加与 libibverbs 兼容的 provider 库，暴露标准 Verbs API。
- **Verification**: 验证：未来实现将添加 Cocotb/Verilator 测试平台、BFM、记分板、覆盖率、协议测试，以及 perftest、UCX 和 libfabric 的兼容性测试。
