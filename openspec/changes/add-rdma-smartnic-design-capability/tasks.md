## 1. 项目结构与共享定义

- [x] 1.1 创建 RTL 目录结构，包含 `pcie`、`reg`、`dma`、`qp`、`cq`、`mr`、`packet`、`transport`、`congestion`、`virt`、`completion`、`common` 和 `top`。
- [x] 1.2 创建 Linux 驱动目录结构，包含 PCIe 核心、CSR mailbox、字符设备、mmap、资源管理、中断、SR-IOV、sysfs/debugfs 以及 RDMA 操作接口等文件。
- [x] 1.3 创建用户态库目录结构，包含设备/上下文、PD、CQ、QP、MR、AH、工作请求提交、CQ 轮询、Doorbell 辅助函数以及 provider 元数据。
- [x] 1.4 创建 Cocotb/Verilator 验证目录结构，包含 BFM、主机内存模型、scoreboard、单元测试、集成测试、协议一致性测试、兼容性测试、覆盖率统计以及回归脚本。
- [x] 1.5 定义 WQE、CQE、QP context、CQ context、MR entry、AH entry、CSR 命令、Doorbell payload、操作码以及完成状态的共享常量和 packed 格式。
- [x] 1.6 添加顶层构建目标，包括 RTL lint、Verilator 仿真、Cocotb 测试、驱动构建、用户态库构建、回归测试以及覆盖率报告。

## 2. PCIe Endpoint 与寄存器控制面

- [x] 2.1 实现 PCIe endpoint wrapper 接口，涵盖配置空间、入站 TLP、出站 TLP、DMA 请求/完成、MSI-X 以及 function 身份标识。
- [x] 2.2 实现 PCIe 配置空间，包含 Type 0 头以及所需的 PCIe/MSI-X/SR-IOV/AER/ATS capability 结构。
- [x] 2.3 实现 BAR 解码器，将 BAR0 Doorbell aperture、BAR2 CSR 空间和 BAR4 MSI-X table/PBA 空间进行路由。
- [x] 2.4 实现 CSR mailbox 命令协议，包含命令 ID、参数、GO/DONE、状态、错误码、超时以及 owner function 等字段。
- [x] 2.5 实现 MSI-X 表、pending-bit 数组、向量屏蔽、中断仲裁以及出站 MSI-X 事务生成。
- [x] 2.6 实现 SR-IOV function 身份标识机制以及 CSR 和 Doorbell 路径的逐 function 访问检查。
- [x] 2.7 添加 PCIe endpoint 单元测试，覆盖配置空间读取、BAR 路由、CSR 命令生命周期、MSI-X 屏蔽以及 VF 访问拒绝。

## 3. Doorbell 与队列提交路径

- [x] 3.1 实现 Doorbell 地址解码器，将 BAR0 偏移映射为 QP SQ、QP RQ 和 CQ arm 操作。
- [x] 3.2 实现逐 function 的 Doorbell aperture 检查，区分 PF 和 VF 所有权。
- [x] 3.3 实现 SQ Doorbell payload 解析以及 QP producer index 更新。
- [x] 3.4 实现 RQ Doorbell payload 解析以及 QP producer index 更新。
- [x] 3.5 实现 CQ arm Doorbell 解析，含 consumer index 和 solicited-only 标志位。
- [x] 3.6 添加 Doorbell 单元测试，覆盖 SQ、RQ、CQ arm、producer 回绕、非法 QPN 以及跨 VF 拒绝访问。

## 4. QP 管理器

- [x] 4.1 实现 QP context 表，包含 QPN tag 匹配、QP 类型、状态、PD、CQ、队列基地址、深度、producer/consumer 索引、PSN 状态、重试状态以及 owner function。
- [x] 4.2 实现 QP 生命周期命令：创建、修改、查询、销毁以及错误迁移。
- [x] 4.3 实现 IBTA 兼容的 QP 状态迁移校验，覆盖 RESET、INIT、RTR、RTS、SQD、SQE 和 ERR 状态。
- [x] 4.4 实现 SQ 引擎，负责取出 WQE、校验 QP 状态、解码工作请求操作码，并分发到 DMA 或 transport 逻辑。
- [x] 4.5 实现 RQ 引擎，消费 Recv WQE 以接收入站 Send payload，并将写入操作分发到 DMA。
- [x] 4.6 实现 QP 销毁和错误清理，包含 pending work 静默等待和 flushed completion。
- [x] 4.7 添加 QP 测试，覆盖生命周期、合法/非法状态迁移、SQ 处理、RQ 处理、错误迁移以及 QPN 别名防护。

## 5. CQ 管理器与完成引擎

- [x] 5.1 实现 CQ context 表，包含 buffer 地址、深度、producer index、consumer index、owner function、MSI-X 向量、中断调节计数、中断调节定时器以及 arm 状态。
- [x] 5.2 实现完成引擎，接收工作完成事件并格式化为 64 字节 CQE。
- [x] 5.3 实现 CQE 写入路径，计算主机 CQ buffer 地址并发出 DMA/PCIe 内存写。
- [x] 5.4 实现 CQ producer/consumer 回绕逻辑以及溢出检测。
- [x] 5.5 实现 CQ 通知逻辑，支持轮询模式、solicited 事件、中断调节计数和调节定时器。
- [x] 5.6 添加 CQ 测试，覆盖 CQE 格式化、producer/consumer 更新、溢出、CQ arm 竞态、调节计数以及 MSI-X 请求生成。

## 6. MR 管理器与内存保护

- [x] 6.1 实现 MR 表，包含 valid 位、lkey、rkey、虚拟基地址、物理基地址、长度、页大小、访问权限标志、PD、owner function 以及 refcount。
- [x] 6.2 实现 MR 注册命令处理，支持来自 pinned scatter-gather page list 的注册。
- [x] 6.3 实现 MR 注销，包含 pending-deregister 状态以及 in-flight DMA refcount 排空等待。
- [x] 6.4 实现本地 lkey 和远端 rkey 的方向检查。
- [x] 6.5 实现访问权限检查，覆盖本地读/写、远端读/写、远端原子操作以及 memory window bind。
- [x] 6.6 实现保护域（PD）检查，覆盖本地和远端操作。
- [x] 6.7 实现 memory window 的 bind、unbind、权限子集校验以及 QP 错误时的 invalidation。
- [x] 6.8 添加 MR 测试，覆盖注册、注销、地址翻译、越界拒绝、PD 不匹配、key 方向、权限拒绝以及 memory window bind。

## 7. Scatter-Gather DMA 引擎

- [x] 7.1 实现 DMA descriptor 格式和调度器，支持 Send、Recv、RDMA Write、RDMA Read 以及 CQE 写入。
- [x] 7.2 实现 WQE 和 SGE fetch 支持，包括 inline 和 extended SGE list（最多 256 条）。
- [x] 7.3 实现 SGE 遍历，包含总长度累计以及零重叠校验。
- [x] 7.4 实现对每个 DMA segment 的 MR 查找和权限集成。
- [x] 7.5 实现主机内存读路径，用于 Send 和 RDMA Write 的 payload 生成。
- [x] 7.6 实现主机内存写路径，用于 Recv 和 RDMA Read 响应 payload 投递。
- [x] 7.7 实现 PMTU 和 4KB 物理页边界切分。
- [x] 7.8 实现跨 active QP 的 DMA 仲裁，并支持可配置公平性策略。
- [x] 7.9 实现 DMA 错误向 completion status 的传播。
- [x] 7.10 添加 DMA 测试，覆盖单 SGE、多 SGE、256 SGE、非对齐 segment、4KB 边界切分、仲裁公平性以及错误注入。

## 8. 数据包解析器与数据包构造器

- [x] 8.1 实现入站数据包解析器，解析以太网、可选 VLAN、IPv4、UDP、BTH、RETH、AETH、DETH、ImmDt 以及不变 CRC 字段。
- [x] 8.2 实现入站校验：EtherType、IP 版本、IHL、协议、UDP 端口、BTH 传输版本、操作码、校验和以及数据包长度。
- [x] 8.3 实现解析器到接收 DMA 和传输逻辑的载荷提取接口。
- [x] 8.4 实现数据包构造器，支持以太网、IPv4、UDP、BTH、RETH、AETH、DETH、ImmDt、ACK、NAK、CNP 以及载荷帧。
- [x] 8.5 实现 ICRC 计算，或使用明确隔离的占位实现并附带标记兼容性限制的测试。
- [x] 8.6 添加数据包测试，覆盖所有支持的操作码、无效数据包丢弃、头部字段提取、头部生成、载荷对齐以及 ICRC 行为。

## 9. RoCEv2 传输引擎

- [x] 9.1 实现 RC 发送侧 PSN 分配、未完成数据包追踪、ACK 处理、重试定时器以及重试耗尽处理。
- [x] 9.2 实现 RC 接收侧 PSN 校验、重复/重放丢弃、gap NAK 生成、ACK 合并以及 RNR NAK 生成。
- [x] 9.3 实现 RC QP 的 RDMA Read 请求与响应排序。
- [x] 9.4 实现 RDMA Write 和 Send 的 immediate data 处理。
- [x] 9.5 实现 UD 发送路径，包含 AH 查找、DETH 生成、Q_Key 处理，并且不引入连接状态。
- [x] 9.6 实现 UD 接收路径，包含 DETH 解析、Q_Key 校验、源 QPN 上报以及失败计数器。
- [x] 9.7 实现 address handle 表，保存目的 MAC、IP、UDP 端口、GID 派生字段以及 service level 元数据。
- [x] 9.8 添加传输层测试，覆盖 RC Send、RDMA Write、RDMA Read、UD Send、PSN 错误、重试、RNR、immediate data 以及 Q_Key 拒绝。

## 10. PFC、ECN、DCQCN 与调度

- [x] 10.1 实现入站数据包的 ECN 检测，并将拥塞标记传递给 transport 和 congestion 逻辑。
- [x] 10.2 实现 CNP 数据包生成和 CNP 接收分类。
- [x] 10.3 实现 DCQCN 状态机，支持可配置 alpha、速率降低、速率恢复、目标速率和最小速率。
- [x] 10.4 实现 per-QP token bucket 或等价的发送 pacing。
- [x] 10.5 实现配置优先级的 PFC pause 处理和发送调度器背压。
- [x] 10.6 添加拥塞测试，覆盖 ECN-to-CNP、CNP 速率更新、速率恢复、pacing、PFC pause/resume 以及 malformed CNP 处理。

## 11. 顶层 RTL 集成

- [x] 11.1 实现 `smartnic_top`，实例化所有主要 RTL block，并通过稳定的内部接口连接。
- [x] 11.2 将 PCIe BAR/CSR 控制路径连接到 QP、CQ、MR、AH、MSI-X、SR-IOV 和拥塞控制寄存器。
- [x] 11.3 将 Doorbell 路径连接到 QP SQ/RQ 和 CQ arm 逻辑。
- [x] 11.4 连接 QP、DMA、packet、transport、completion 和 CQ 管理器，形成 RC Send/Recv 最小环路。
- [x] 11.5 连接 RDMA Write 和 RDMA Read 数据路径。
- [x] 11.6 连接 UD 发送和接收数据路径。
- [x] 11.7 添加顶层测试，覆盖 reset、CSR command、Doorbell-to-CQE 最小环路、RC Send、RDMA Write、RDMA Read、UD Send 以及 MSI-X completion interrupt。

## 12. Linux 内核驱动

- [x] 12.1 实现 PCIe 驱动 probe/remove，包含 BAR mapping、DMA mask 设置、reset、feature discovery 和 teardown。
- [x] 12.2 实现 CSR mailbox helper，包含 timeout、错误码映射和 locking。
- [x] 12.3 实现字符设备 open、release、ioctl 分发、mmap 和 poll 操作。
- [x] 12.4 实现用于 SmartNIC 驱动控制的用户态库和 CLI 工具。
- [x] 12.5 实现驱动中断支持，包含 MSI-X setup、ISR、事件处理和 teardown。
- [x] 12.6 实现驱动 DMA buffer 管理，用于 queue、descriptor 和用户可见 ring。
- [x] 12.7 实现驱动测试，覆盖 probe/remove、mailbox、char device、ioctl、mmap、poll、MSI-X 和 DMA buffer 生命周期。
- [x] 12.8 编写驱动文档、示例用法和故障排查说明。
- [x] 12.9 实现端到端驱动集成测试和 packaging 检查。
- [x] 12.10 实现驱动 self-test、错误路径测试和集成测试，覆盖 PCIe probe/remove、CSR mailbox、字符设备 ioctl/mmap/poll、DMA mapping 和中断处理。
- [x] 12.11 编写 Linux SmartNIC 驱动文档、UAPI 说明、使用示例和调试指南。
- [x] 12.12 完成 Linux SmartNIC 驱动集成收尾，包含构建、CI、清理和发布就绪检查。

## 13. 用户态 Verbs 库

- [x] 13.1 实现设备发现和 context open/close API。
- [x] 13.2 实现 query_device、query_port、query_gid 和 query_pkey API。
- [x] 13.3 实现 PD alloc/dealloc API。
- [x] 13.4 实现 CQ create/destroy/resize、poll_cq 和 req_notify_cq API。
- [x] 13.5 实现 QP create/modify/query/destroy API。
- [x] 13.6 实现 MR register/deregister API。
- [x] 13.7 实现用于 UD 的 AH create/destroy API。
- [x] 13.8 实现 WQE builder，支持 Send、Send with Immediate、RDMA Write、RDMA Write with Immediate、RDMA Read 以及已支持的 UD 操作。
- [x] 13.9 实现 post_send 和 post_recv 批量提交，并加入 Doorbell memory barrier。
- [x] 13.10 实现 CQE parser，返回 Verbs-compatible work completion。
- [x] 13.11 实现 async event retrieval 和 acknowledgement API。
- [x] 13.12 添加 pkg-config、provider metadata、examples 和用户态单元测试。

## 14. Cocotb/Verilator 验证

- [x] 14.1 实现 PCIe BFM，覆盖 config、memory read/write、completion、MSI-X 和 function identity。
- [x] 14.2 实现 Ethernet/RoCEv2 BFM，用于 packet 构造、解析、错误注入以及 CNP/PFC 激励。
- [x] 14.3 实现 host memory model，支持 DMA read/write 可见性和数据完整性检查。
- [x] 14.4 实现 scoreboard，用于 WR-to-CQE 匹配、payload 比较、PSN 跟踪、重试行为和错误状态检查。
- [x] 14.5 实现 functional coverage，覆盖 opcode、QP state、CQ status、MR permission、message size、SGE count、QP type 和 congestion event。
- [x] 14.6 实现模块级 Cocotb 测试，覆盖 PCIe、Doorbell、QP、CQ、MR、DMA、packet、transport、congestion 和顶层 reset。
- [x] 14.7 实现集成测试，覆盖 Doorbell-to-CQE、RC Send、RDMA Write、RDMA Read、UD Send、MSI-X 和 SR-IOV 隔离。
- [x] 14.8 实现协议一致性测试，覆盖 RoCEv2 header field、ACK/NAK、RNR、immediate data、invalid packet 和 ICRC 行为。
- [x] 14.9 实现 regression script，用于运行 lint、单元测试、集成测试、兼容性仿真和覆盖率报告生成。

## 15. 兼容性与性能验证

- [x] 15.1 添加最小 verbs 示例，打开设备、创建 PD/CQ/QP/MR、post Send/Recv，并轮询 completion。
- [x] 15.2 添加 perftest 兼容性目标，用于支持的 RC Send、RDMA Write 和 RDMA Read 测试。
- [x] 15.3 添加 UCX 兼容性 smoke test，用于支持的 RC 操作。
- [x] 15.4 添加 libfabric 兼容性 smoke test，用于支持的 verbs-backed 操作。
- [x] 15.5 添加仿真性能计数器，覆盖 Doorbell-to-CQE latency、Doorbell-to-wire latency、DMA bandwidth、packet rate 和 completion rate。
- [x] 15.6 添加 FPGA 原型 checklist，覆盖 board selection、PCIe IP wrapper、MAC IP wrapper、clocks、resets、constraints、loopback 和 host driver loading。

## 16. 文档与验收

- [x] 16.1 编写硬件模块架构和顶层数据路径文档。
- [x] 16.2 编写 Linux driver ioctl ABI、mmap offset、资源生命周期和错误码文档。
- [x] 16.3 编写用户态 Verbs API 兼容性范围和已知限制文档。
- [x] 16.4 编写验证策略、测试矩阵、覆盖率目标和回归运行方式文档。
- [x] 16.5 验证 `openspec validate add-rdma-smartnic-design-capability --strict` 通过。
- [x] 16.6 验证所有生成的 OpenSpec artifact 已准备好用于 `/opsx:apply`。
