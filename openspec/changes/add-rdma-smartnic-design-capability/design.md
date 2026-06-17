## 背景

本变更定义一套全新的 RDMA SmartNIC 设计能力。目标系统是一款可原型验证的高性能智能网卡，通过 PCIe Gen5 x16 与主机连接，向软件暴露 RDMA Verbs 语义，并以硬件处理 RoCEv2 流量。

系统划分为四个实现层次：

1. 硬件 RTL：PCIe 端点、BAR/CSR 寄存器块、Doorbell 捕获、QP/CQ/MR 管理器、Scatter-Gather DMA、数据包解析器/构造器、RoCEv2 传输、完成引擎、MSI-X、SR-IOV、PFC/ECN/DCQCN，以及顶层集成。
2. Linux 内核驱动：PCIe probe/remove、CSR 邮箱命令提交、字符设备控制面、资源生命周期管理、mmap Doorbell、DMA 内存管理、MSI-X 中断、SR-IOV 以及面向 RDMA 的操作接口。
3. 用户态 Verbs 库：与 libibverbs 兼容的 provider 接口，涵盖设备发现、上下文管理、PD/CQ/QP/MR/AH 生命周期、工作请求提交、CQ 轮询、通知和异步事件。
4. 验证与兼容性：Cocotb/Verilator 仿真、PCIe/以太网 BFM、主机内存模型、记分板、覆盖率、协议一致性测试，以及 perftest、UCX、libfabric 验证。

首个实现目标为 FPGA 原型验证，在需要时使用厂商的 PCIe/MAC IP 封装。内部架构必须保持厂商中立，使同一套 RTL 划分可以后续硬化用于 ASIC，同时不改变软件可见的 ABI。

## 目标 / 非目标

目标：

- 定义模块化的 RDMA SmartNIC 架构，支持增量实现和验证。
- 支持 PCIe Gen5 x16 主机连接、BAR/CSR 控制、Doorbell 提交、MSI-X 中断和 SR-IOV 虚拟化。
- 支持基于以太网的 RoCEv2，支持 RC 和 UD QP 类型。
- 支持 RDMA Read、RDMA Write、Send、Recv 操作。
- 支持 QP、CQ、MR、PD、AH、Completion Queue 和 Doorbell 生命周期管理，覆盖硬件、驱动和用户态。
- 支持 Scatter-Gather DMA，含 MR 地址转换、访问权限检查、PMTU 分段和错误完成通知。
- 提供 Linux 内核驱动控制面，包含字符设备 ioctl 和 mmap Doorbell 页。
- 提供与 libibverbs 兼容的用户态 API，适用于 perftest、UCX 和 libfabric 兼容性测试。
- 提供 Cocotb/Verilator 验证计划，包含 BFM、记分板、覆盖率、协议测试和端到端测试。

非目标：

- InfiniBand 原生链路层支持；v1 仅支持基于以太网的 RoCEv2。
- iWARP 支持。
- GPU Direct 或点对点设备内存（v1 不做）。
- 首个里程碑中不做 Linux 主线化；初始驱动可以是树外驱动，但遵循主线编码规范。
- v1 不支持多端口网卡。
- 不做完整的 ASIC 物理设计、时序收敛、DFT、封装设计或量产签核。

## 硬件架构

硬件按分层数据通路加独立控制面的方式组织。RTL 顶层模块为 smartnic_top，将 PCIe、控制、RDMA 状态、DMA、数据包处理和 MAC 侧接口绑定在一起。

```text
                            Host CPU / Memory
                                  |
                         PCIe Gen5 x16 Endpoint
                                  |
        +-------------------------+-------------------------+
        |                                                   |
  BAR/CSR/doorbell control                         DMA read/write TLPs
        |                                                   |
  +-----v------+     +----------+     +---------+     +------v------+
  | reg_block  |---->| qp_mgr   |---->| dma_eng |<--->| mr_mgr      |
  | csr_mailbox|     | cq_mgr   |     | sg dma  |     | translation |
  +-----+------+     +-----+----+     +----+----+     +-------------+
        |                  |               |
        |                  |               v
        |                  |       +---------------+
        |                  +------>| cmpl_engine   |----> CQE DMA writes
        |                          +---------------+
        |
        v
  +-------------+     +---------------+     +----------------+
  | doorbell    |---->| roce_engine   |---->| packet_builder |
  | decoder     |     | RC / UD       |     +-------+--------+
  +-------------+     +-------+-------+             |
                              ^                     v
                       +------+-------+      100GbE MAC/PHY wrapper
                       | packet_parser|
                       +--------------+
```

### RTL 模块划分

| 模块 | 职责 | 关键输入 | 关键输出 |
| --- | --- | --- | --- |
| `pcie_ep` | PCIe Gen5 端点封装，配置空间，入站/出站 TLP 适配 | PCIe 硬核 IP 流、配置读写、DMA 完成 | BAR 访问、DMA 请求、MSI-X TLP、功能标识 |
| `bar_mapper` | 解析 BAR0/BAR2/BAR4 地址和偏移量 | 入站 Memory Read/Write TLP | Doorbell 写入、CSR 访问、MSI-X 表访问 |
| `reg_block` | CSR 寄存器文件和邮箱命令分发 | BAR2 CSR 读写、命令参数 | QP/CQ/MR/AH 命令、状态、错误 |
| `doorbell_decoder` | 解析 mmap Doorbell 写入 | BAR0 写入（含请求者/功能标识） | SQ 生产者更新、RQ 生产者更新、CQ arm 请求 |
| `sriov_guard` | 强制 PF/VF 所有权和资源隔离 | 请求者 ID、功能 ID、QPN/CQN/MR 句柄、BAR 偏移量 | 允许/拒绝、安全/错误计数器 |
| `qp_mgr` | QP 上下文表、状态机、SQ/RQ 引擎 | CSR 命令、Doorbell、入站数据包元数据 | WQE 分发、Recv 缓冲区描述符、QP 状态更新 |
| `cq_mgr` | CQ 上下文表、生产者/消费者状态、arm 和中断调节 | 完成事件、CQ arm 写入、消费者更新 | CQE 写入请求、MSI-X 请求、溢出状态 |
| `mr_mgr` | MR/MW 表、lkey/rkey 查找、权限和 PD 检查 | MR 命令、DMA 查找请求、远程访问请求 | 物理地址转换、访问允许/拒绝、MR 引用计数 |
| `dma_engine` | Scatter-Gather 主机内存读写引擎 | WQE 描述符、SGE 列表、MR 转换结果 | PCIe MemRd/MemWr 请求、有效载荷流、DMA 错误 |
| `packet_parser` | 解析以太网/IPv4/UDP/BTH/扩展 RoCEv2 头部 | RX MAC 流 | 操作码、QPN、PSN、RETH/AETH/DETH/ImmDt、有效载荷流 |
| `packet_builder` | 构造 RoCEv2 数据包和响应 | TX 描述符、有效载荷流、ACK/NAK/CNP 请求 | TX MAC 流 |
| `roce_engine` | RC/UD 传输语义 | 解析后的数据包、QP 上下文、WQE 分发 | DMA 命令、ACK/NAK/CNP、完成通知 |
| `dcqcn_pfc` | ECN/CNP/DCQCN 和 PFC 感知调度 | ECN 标记、CNP 数据包、PFC 暂停状态 | 速率更新、令牌速率控制、TX 背压 |
| `cmpl_engine` | 归一化完成事件并格式化 CQE | QP/DMA/传输结果 | 64 字节 CQE 和 CQ 写入请求 |
| `top_integration` | 时钟/复位、跨时钟域、模块互连、封装 | 板级 PCIe/MAC 时钟和复位 | 集成后的 SmartNIC 数据通路 |

### 内部接口

RTL 应在模块间使用显式的 ready/valid 流式接口，而非隐式共享状态。主要内部接口有：

- **CSR command interface**: `cmd_valid`, `cmd_opcode`, `cmd_func`, `cmd_args`, `cmd_ready`, `rsp_valid`, `rsp_status`, `rsp_data`.
- **Doorbell interface**: `db_valid`, `db_type`, `db_func`, `db_qpn_or_cqn`, `db_producer_idx`, `db_consumer_idx`, `db_solicited_only`.
- **WQE dispatch interface**: `wqe_valid`, `qpn`, `opcode`, `wr_id`, `sge_count`, `remote_va`, `rkey`, `length`, `flags`.
- **MR lookup interface**: `lookup_valid`, `lookup_is_local`, `lookup_key`, `lookup_pd`, `lookup_va`, `lookup_len`, `lookup_perm`, `lookup_hit`, `lookup_pa`, `lookup_error`.
- **DMA command interface**: `dma_cmd_valid`, `op`, `qpn`, `wr_id`, `sge_list_ref`, `remote_meta`, `dma_done`, `dma_error`.
- **Packet metadata interface**: `pkt_meta_valid`, `opcode`, `qpn`, `psn`, `pkey`, `reth`, `aeth`, `deth`, `imm_data`, `payload_len`.
- **Completion interface**: `cmpl_valid`, `cqn`, `qpn`, `wr_id`, `opcode`, `status`, `byte_count`, `src_qpn`, `imm_data`.

## Data Path Design

### Send / RDMA Write TX Path

```text
userspace WQE write
  -> SQ Doorbell MMIO
  -> doorbell_decoder
  -> qp_mgr SQ engine
  -> DMA local SGE reads through mr_mgr
  -> roce_engine assigns PSN and transport metadata
  -> packet_builder emits RoCEv2 frames
  -> MAC TX
  -> cmpl_engine writes send completion when signaled and transport rules allow
```

Send 操作从本地 SGE 读取数据，送到对端的 RQ。RDMA Write 通过 DMA 读取本地数据，用 RETH 携带远程虚拟地址和 rkey 组包发送。RC QP 需要 PSN 追踪和 ACK/NAK 处理；UD QP 使用 AH/DETH 元数据，不维护 RC 序列状态。

### Receive / Send 接收路径

```text
MAC RX
  -> packet_parser
  -> roce_engine validates QP, opcode, P_Key/Q_Key, PSN
  -> qp_mgr RQ engine consumes Recv WQE
  -> dma_engine writes payload into local SGEs through mr_mgr
  -> cmpl_engine formats receive CQE
  -> cq_mgr writes CQE and optionally triggers MSI-X
```

入站数据包在确认对目标 QP 有效之前不得消耗 RQ 条目。无效数据包在产生 DMA 副作用前即被丢弃。RC 序列错误会触发 ACK/NAK 行为，不会将乱序数据写入主机内存。

### RDMA Read Path

RDMA Read 有两个不对称的半边：

- **Requester side**: SQ 引擎分发 RDMA Read，packet_builder 发送 Read Request，响应数据包按 QP/PSN 匹配，DMA 将响应载荷写入本地 SGE，所有请求字节到达后生成完成通知。
- **Responder side**: parser 接收 Read Request，mr_mgr 验证远程 rkey 和访问权限，dma_engine 读取本地内存，packet_builder 发送一个或多个 Read Response 数据包。

请求方必须跟踪每个 QP 未完成的 Read 请求，并将响应匹配到原始 WR。响应方必须按 PMTU 分段响应，并遵守 RC 序列规则。

### CQE 和中断路径

来自 QP、DMA 和传输的完成事件由 cmpl_engine 归一化处理。cq_mgr 通过 DMA/PCIe MemWr 将 64 字节 CQE 写入主机内存，并更新 CQ 生产者索引。MSI-X 在以下情况下产生：

- CQ 处于 arm 状态，且完成事件满足 arm 条件
- 中断调节计数器达到配置阈值
- 调节定时器到期
- 发生异步事件（如 QP 致命错误、CQ 溢出或设备移除）

## Control Path Design

控制流量使用 BAR2 CSR 空间和邮箱命令模型。驱动写入命令参数，写 GO 位，轮询或等待 DONE，然后读取状态/错误字段。

```text
driver ioctl
  -> smartnic_csr_cmd()
  -> BAR2 mailbox writes
  -> reg_block command decoder
  -> target manager command interface
  -> status/error response
  -> driver returns ioctl result
```

控制面覆盖：

- 设备复位和特性发现
- PD 分配与释放
- CQ 创建、销毁、查询和 arm 配置
- QP 创建、修改、查询、销毁和错误状态转换
- MR 注册、注销、查询和内存窗口操作
- AH 创建与销毁（用于 UD 寻址）
- MSI-X 向量配置和事件队列控制
- SR-IOV VF 启用、配额分配及每功能清理
- PFC/ECN/DCQCN 参数配置

快速路径的 WQE 提交不使用 CSR 邮箱，而是通过 mmap 队列缓冲区加 Doorbell 写入实现。

## Register Interface

### BAR Layout

| BAR | Size | Purpose | Access |
| --- | --- | --- | --- |
| BAR0 | 256 MB target | SQ、RQ 和 CQ arm 页的 Doorbell 窗口 | mmap write-mostly |
| BAR2 | 64 KB target | CSR 寄存器和邮箱命令接口 | driver MMIO |
| BAR4 | 16 KB target | MSI-X 表和 pending-bit 数组 | kernel PCI/MSI-X |

The exact BAR sizes can be adjusted for FPGA prototype constraints, but software-visible offsets must remain stable once the ABI is published.

### BAR0 Doorbell Aperture

Doorbell 页面按资源和功能分配。推荐布局：

```text
BAR0 + function_base(func)
  + qpn * 0x1000
      + 0x000 SQ Doorbell: producer index + flags
      + 0x008 RQ Doorbell: producer index + flags
      + 0x010 CQ Arm Doorbell: consumer index + solicited_only
```

硬件从页面偏移量解码 QPN/CQN，并使用请求者/功能标识验证所有权。VF 在其分配窗口之外的 Doorbell 写入将被拒绝或忽略，不产生副作用。

### BAR2 CSR Register Groups

| Offset Range | Name | Purpose |
| --- | --- | --- |
| `0x0000-0x00ff` | 设备控制/状态 | reset, status, feature bits, version, health |
| `0x0100-0x01ff` | Mailbox command | command ID, GO/DONE, status, function ID, argument window |
| `0x0200-0x02ff` | Interrupt control | MSI-X vector mapping, event masks, moderation defaults |
| `0x0300-0x03ff` | Queue defaults | max QP/CQ/MR, queue depth limits, WQE/CQE size |
| `0x0400-0x04ff` | SR-IOV control | VF enable, VF quotas, VF BAR aperture base/limit |
| `0x0500-0x05ff` | Congestion control | DCQCN alpha/rate parameters, ECN/CNP counters, PFC config |
| `0x0600-0x06ff` | Statistics | packet counters, DMA counters, CQ overflow, QP errors |
| `0x0700-0x07ff` | Debug and trace | optional trace controls for prototype builds |

### Mailbox Command ABI

Mailbox commands use a common envelope:

| Field | Description |
| --- | --- |
| `cmd_id` | Operation such as CREATE_QP, MODIFY_QP, CREATE_CQ, REG_MR |
| `func_id` | PF/VF owner function |
| `seq` | Driver-assigned sequence number to match responses |
| `arg_len` | Number of valid argument bytes |
| `args[]` | Command-specific payload |
| `go` | Driver writes 1 to start command |
| `done` | Hardware writes 1 when command completes |
| `status` | success or failure code |
| `error_detail` | command-specific error detail |

Representative commands:

- `QUERY_DEVICE`
- `ALLOC_PD`, `DEALLOC_PD`
- `CREATE_CQ`, `DESTROY_CQ`, `QUERY_CQ`
- `CREATE_QP`, `MODIFY_QP`, `QUERY_QP`, `DESTROY_QP`
- `REG_MR`, `DEREG_MR`, `BIND_MW`, `INVALIDATE_MW`
- `CREATE_AH`, `DESTROY_AH`
- `CONFIG_MSIX`, `CONFIG_VF`, `CONFIG_DCQCN`, `READ_STATS`

## Software Stack

### Linux Kernel Driver

Linux 驱动负责设备初始化、特权资源管理、内存 pinning，以及将安全的快速路径区域映射给用户态。
Recommended file split:

| File | Responsibility |
| --- | --- |
| `smartnic_main.c` | module init/exit, PCI driver registration |
| `smartnic_pci.c` | probe/remove, BAR mapping, DMA mask, reset |
| `smartnic_csr.c` | CSR mailbox helpers and command serialization |
| `smartnic_cdev.c` | character device open/release/ioctl/poll |
| `smartnic_mmap.c` | mmap offset allocator and VMA mapping validation |
| `smartnic_resource.c` | PD/CQ/QP/MR/AH handle allocators and ownership |
| `smartnic_qp.c` | QP create/modify/query/destroy command handling |
| `smartnic_cq.c` | CQ create/destroy/query, event and interrupt integration |
| `smartnic_mr.c` | page pinning, DMA mapping, MR registration and deregistration |
| `smartnic_ah.c` | address handle lifecycle |
| `smartnic_intr.c` | MSI-X handlers and async event queue |
| `smartnic_sriov.c` | VF enable/disable, quotas, per-function cleanup |
| `smartnic_sysfs.c` | counters, device attributes, congestion parameters |

Driver responsibilities:

- 映射 BAR0/BAR2/BAR4，仅暴露已授权的 mmap 区域
- Pin 住用户态页面用于 MR 注册，转换为硬件 MR 表条目
- 为 SQ、RQ、CQ 分配一致性或 DMA 映射的队列缓冲区
- 跟踪每个 PD、CQ、QP、MR、AH、Doorbell 页和 mmap 偏移量在文件描述符和 PF/VF 维度的所有权
- 在进程退出、设备热移除、驱动卸载和 VF 禁用时清理资源
- 将邮箱状态码映射为 Linux errno 兼容的错误返回

### 字符设备和 ioctl 接口

The first implementation can expose `/dev/smartnicX` or `/dev/infiniband/uverbsX`-compatible control. The stable ioctl set should include:

| ioctl | Purpose | Key Outputs |
| --- | --- | --- |
| `QUERY_DEVICE` | 读取设备能力 | max QP/CQ/MR, WQE/CQE sizes, feature bits |
| `ALLOC_PD` / `DEALLOC_PD` | 管理保护域 | PD handle |
| `CREATE_CQ` / `DESTROY_CQ` | 管理完成队列 | CQN, CQ mmap offset, CQ arm Doorbell offset |
| `CREATE_QP` / `MODIFY_QP` / `QUERY_QP` / `DESTROY_QP` | 管理队列对 | QPN, SQ/RQ mmap offsets, Doorbell offsets |
| `REG_MR` / `DEREG_MR` | 注册与注销内存 | MR handle, lkey, rkey |
| `CREATE_AH` / `DESTROY_AH` | 管理 UD 地址句柄 | AH handle |
| `GET_EVENT` | 获取异步事件 | event type, QPN/CQN/port |

### mmap Model

驱动向用户态返回不透明的 mmap 偏移量，用户态不得自行构造偏移量。VMA fault 或 mmap 处理程序验证：

- 文件描述符拥有该资源
- 资源仍然存活
- PF/VF 功能匹配所有者
- 请求的大小和保护位匹配映射类型

Mapping types:

- SQ buffer
- RQ buffer
- CQ buffer
- QP SQ Doorbell page
- QP RQ Doorbell page
- CQ arm Doorbell page

### 用户态 Verbs 库

用户态库将 Verbs API 调用转换为驱动 ioctl 和快速路径 mmap 写入。API 包括：

- device discovery: `ibv_get_device_list`, `ibv_free_device_list`, `ibv_get_device_name`
- context: `ibv_open_device`, `ibv_close_device`
- query: `ibv_query_device`, `ibv_query_port`, `ibv_query_gid`, `ibv_query_pkey`
- PD: `ibv_alloc_pd`, `ibv_dealloc_pd`
- CQ: `ibv_create_cq`, `ibv_destroy_cq`, `ibv_poll_cq`, `ibv_req_notify_cq`
- QP: `ibv_create_qp`, `ibv_modify_qp`, `ibv_query_qp`, `ibv_destroy_qp`
- MR: `ibv_reg_mr`, `ibv_dereg_mr`
- AH: `ibv_create_ah`, `ibv_destroy_ah`
- WR posting: `ibv_post_send`, `ibv_post_recv`
- async events: `ibv_get_async_event`, `ibv_ack_async_event`

Fast-path rules:

- ibv_post_send 将一个或多个硬件 WQE 格式化写入 SQ 缓冲区，使用 release barrier，然后为该批次写一次 SQ Doorbell
- ibv_post_recv 将一个或多个接收 WQE 格式化写入 RQ 缓冲区，使用 release barrier，然后为该批次写一次 RQ Doorbell
- ibv_poll_cq 从 mmap CQ 缓冲区读取 CQE，转换为 ibv_wc，推进消费者索引，可选择性更新硬件可见的消费者状态
- ibv_req_notify_cq 写入 CQ arm Doorbell，携带消费者索引和 solicited-only 状态

兼容性目标：

- perftest: RC Send, RDMA Write, RDMA Read
- UCX: verbs-backed RC smoke tests
- libfabric: verbs provider smoke tests for supported operations
- UD: basic Send/Recv and AH behavior

## 验证架构

验证环境使用 Cocotb/Verilator 进行开发反馈和回归测试。

测试平台组件：

- PCIe BFM：配置周期、Memory Read/Write TLP、完成、MSI-X、请求者/功能标识
- 以太网/RoCE BFM：RoCEv2 操作码的数据包构造与解析、ACK/NAK、CNP、无效数据包注入
- 主机内存模型：字节可寻址内存，支持 DMA 读写和 CQ 缓冲区观察
- 记分板：WR 到 CQE 匹配、载荷比较、PSN 追踪、重试行为、CQ 溢出和错误状态检查
- 覆盖率模型：操作码、QP 状态、QP 类型、完成状态、MR 权限、消息大小、SGE 数量、拥塞事件和 SR-IOV 访问场景

验证阶段：

1. 模块测试：PCIe、BAR、CSR、Doorbell、QP、CQ、MR、DMA、数据包解析器/构造器、RC/UD 和拥塞模块
2. 集成测试：Doorbell 到 CQE、RC Send/Recv、RDMA Write、RDMA Read、UD Send/Recv、MSI-X 和 SR-IOV 隔离
3. 协议一致性测试：RoCEv2 头部、ACK/NAK、RNR、DETH/RETH/AETH、立即数据、无效数据包丢弃和 ICRC 行为
4. 兼容性测试：使用用户态示例程序、perftest、UCX 和 libfabric（在仿真/原型环境允许的情况下）
5. 性能测试：Doorbell 到 CQE 延迟、Doorbell 到线缆延迟、DMA 带宽、数据包速率、完成速率和中断调节行为

## 设计决策

### D1：分层 RTL 架构

RTL 必须拆分为 PCIe、寄存器/控制、DMA、QP 管理器、CQ 管理器、MR 管理器、数据包解析器、数据包构造器、RoCEv2 引擎、完成引擎、拥塞控制、虚拟化和顶层集成模块。

理由：PCIe 传输、RDMA 状态、内存保护和数据包处理具有不同的时序和验证关注点。分层使得模块级测试切实可行，并允许增量集成。

备选方案（已否决）：单块 RDMA 引擎——使协议、DMA 和资源管理类 bug 难以隔离。

### D2: 基于 Doorbell 的快速路径

用户态库必须 mmap Doorbell 页和队列缓冲区。工作请求写入主机可见队列，通过单次 MMIO Doorbell 写入提交。

理由：遵循标准 RDMA 快速路径，避免每个工作请求产生系统调用开销。

备选方案（已否决）：每个 WR 使用 ioctl 提交——无法满足 RDMA 低延迟和高吞吐量的要求。

### D3: 硬件管理 QP/CQ/MR 状态，软件管理控制面

驱动负责资源创建、销毁、内存 pinning 和策略。硬件负责数据通路使用的 QP 状态、CQE 生成、MR key/地址/权限检查和 DMA 执行。

理由：这种划分使低频控制操作在软件中保持灵活，同时将高频数据包和 DMA 操作保留在硬件中。

### D4: CSR 邮箱用于资源管理

驱动必须使用 CSR 邮箱命令协议进行 QP/CQ/MR/AH/PD 管理命令。每条命令包含操作 ID、参数、所有者/功能标识、GO/DONE 状态和错误报告。

理由：邮箱为驱动提供稳定的硬件 ABI，同时允许内部 RTL 模块独立演进。

### D5: 兼容 libibverbs 的用户态接口

用户态库必须提供熟悉的 Verbs API，包括设备发现、open/close、查询、PD/CQ/QP/MR/AH 生命周期、post_send、post_recv、poll_cq、req_notify_cq 和异步事件。

理由：与 perftest、UCX 和 libfabric 的兼容性是核心采用需求。

### D6: Cocotb/Verilator 优先的验证策略

项目必须使用 Cocotb/Verilator 作为主要开发验证环境，包含 PCIe 和以太网的 Python BFM、主机内存模型、记分板和覆盖率。

理由：基于 Python 的验证加速数据包生成、随机化测试和记分板开发。商用仿真器和形式化工具可在后续签核阶段加入。

### D7: 增量原型里程碑

实现应按里程碑推进：

1. CSR/Doorbell/QP/CQ 最小完成环路
2. DMA 内存读写回环
3. 仿真中 RC Send/Recv
4. 仿真中 RDMA Write/Read
5. UD Send/Recv
6. 驱动与用户态集成
7. perftest/UCX/libfabric 兼容性
8. FPGA 原型

理由：完整的 RDMA NIC 有太多活动部件，无法一次性全部验证。分阶段计划使每个里程碑都可观测。

### D8: 厂商中立核心 + FPGA 封装

核心 RTL 必须使用厂商中立的内部流和命令接口。厂商特定的 PCIe 和 MAC IP 应隔离在封装层之后。

理由：FPGA 原型可能使用 Xilinx 或 Intel 硬核 IP，但 SmartNIC 架构应保持可移植性，为 ASIC 就绪。

### D9: 硬件强制 SR-IOV 隔离

PF/VF 所有权必须在硬件可见的资源表中记录，并在 CSR、Doorbell 和数据通路访问中检查。

理由：VF 隔离不能仅依赖驱动分配策略。即使软件受到攻击或存在 bug，硬件也必须拒绝跨功能访问。

## 风险与权衡

- 范围规模：完整 SmartNIC 涵盖 RTL、驱动、用户态和验证 -> 缓解：按里程碑顺序实现，每个里程碑保持独立的验收测试
- PCIe Gen5 和 100GbE IP 依赖：FPGA 平台可能需要厂商 PCIe/MAC 封装 -> 缓解：定义厂商中立的内部接口，隔离封装层
- RoCEv2 互操作性：真实网卡和交换机在边缘行为上存在差异 -> 缓解：包含协议一致性测试和 soft-roce、perftest 兼容性测试
- libibverbs ABI 漂移：手写的 provider 可能偏离预期的 Verbs 语义 -> 缓解：尽早用 perftest、UCX 和 libfabric 进行测试
- 仿真性能：全系统 Verilator 测试可能很慢 -> 缓解：优先模块级测试，使用记分板，将长时间测试留到回归阶段
- SR-IOV 隔离：VF 隔离必须在硬件中强制执行，不能仅靠驱动策略 -> 缓解：在 CSR、Doorbell 和资源表中包含请求者/功能所有权
- MR 安全性和正确性：错误的 key、PD 或边界检查可能破坏主机内存 -> 缓解：保持 MR 查找集中化，要求所有 DMA 路径使用
- 寄存器 ABI 稳定性：早期 CSR 布局变更可能破坏驱动和用户态测试 -> 缓解：对 ABI 进行版本管理，每个寄存器组预留空间

## 迁移计划

这是一个全新能力，不存在运行时迁移。实现应从创建源码树和测试基础设施开始，然后按照 D7 中的里程碑序列推进。

实现变更的回滚策略按里程碑执行：每个里程碑必须保持其测试通过才能进入下一个里程碑。如果某个里程碑失败，回滚或仅禁用该里程碑的新集成，同时保持低层模块测试不受影响。

## 待解决问题

- 首个 FPGA 原型目标板卡：Xilinx Alveo、Intel Agilex 还是其他平台？
- FPGA 原型构建中 100GbE MAC 和 PCIe 端点 IP 封装应使用哪个？
- 用户态库是否先作为独立的 libsmartnic 适配层，还是一开始就做正式的 libibverbs provider 插件？
- perftest、UCX 和 libfabric 的最低兼容性矩阵是什么，原型才算可用？
- v1 FPGA 原型的 QP/CQ/MR 规模要求与最终 ASIC 目标有何不同？
- BAR0 应该为每个 QP/CQ 暴露一个 4KB Doorbell 页，还是使用压缩窗口并在 Doorbell 载荷中携带显式资源 ID？
- CQ 消费者索引更新应通过 CQ Doorbell 写入，还是纯在主机内存中维护并由硬件周期性读取？
