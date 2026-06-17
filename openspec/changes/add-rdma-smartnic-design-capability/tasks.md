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
- [x] 7.6 Implement host memory write path for Recv and RDMA Read response payload delivery.
- [ ] 7.7 Implement PMTU and 4KB physical page boundary segmentation.
- [ ] 7.8 Implement DMA arbitration across active QPs with configurable fairness policy.
- [ ] 7.9 Implement DMA error propagation into completion status.
- [ ] 7.10 Add DMA tests for single SGE, multi-SGE, 256 SGE, unaligned segments, 4KB boundary split, arbitration fairness, and error injection.

## 8. Packet Parser and Packet Builder

- [ ] 8.1 Implement ingress packet parser for Ethernet, optional VLAN, IPv4, UDP, BTH, RETH, AETH, DETH, ImmDt, and invariant CRC fields.
- [ ] 8.2 Implement ingress validation for EtherType, IP version, IHL, protocol, UDP port, BTH transport version, opcode, checksum, and packet length.
- [ ] 8.3 Implement payload extraction interface from parser to receive DMA and transport logic.
- [ ] 8.4 Implement packet builder for Ethernet, IPv4, UDP, BTH, RETH, AETH, DETH, ImmDt, ACK, NAK, CNP, and payload frames.
- [ ] 8.5 Implement ICRC calculation or a clearly isolated placeholder with tests marking compatibility limitations.
- [ ] 8.6 Add packet tests for every supported opcode, invalid packet drop, header field extraction, header generation, payload alignment, and ICRC behavior.

## 9. RoCEv2 Transport Engine

- [ ] 9.1 Implement RC send-side PSN allocation, outstanding packet tracking, ACK processing, retry timer, and retry exhaustion handling.
- [ ] 9.2 Implement RC receive-side PSN validation, duplicate/replay drop, gap NAK generation, ACK coalescing, and RNR NAK generation.
- [ ] 9.3 Implement RDMA Read request and response sequencing for RC QPs.
- [ ] 9.4 Implement RDMA Write and Send immediate-data handling.
- [ ] 9.5 Implement UD transmit path with AH lookup, DETH generation, Q_Key handling, and no connection state.
- [ ] 9.6 Implement UD receive path with DETH parsing, Q_Key validation, source QPN reporting, and failure counters.
- [ ] 9.7 Implement address handle table for destination MAC, IP, UDP port, GID-derived fields, and service level metadata.
- [ ] 9.8 Add transport tests for RC Send, RDMA Write, RDMA Read, UD Send, PSN errors, retries, RNR, immediate data, and Q_Key rejection.

## 10. PFC ECN DCQCN and Scheduling

- [ ] 10.1 Implement ECN detection from ingress packets and pass congestion marks to transport and congestion logic.
- [ ] 10.2 Implement CNP packet generation and CNP receive classification.
- [ ] 10.3 Implement DCQCN state machine with configurable alpha, rate decrease, rate recovery, target rate, and minimum rate.
- [ ] 10.4 Implement per-QP token bucket or equivalent transmit pacing.
- [ ] 10.5 Implement PFC pause handling for configured priority and transmit scheduler backpressure.
- [ ] 10.6 Add congestion tests for ECN-to-CNP, CNP rate update, rate recovery, pacing, PFC pause/resume, and malformed CNP handling.

## 11. Top-Level RTL Integration

- [ ] 11.1 Implement `smartnic_top` with all major RTL blocks instantiated and connected through stable internal interfaces.
- [ ] 11.2 Connect PCIe BAR/CSR control path to QP, CQ, MR, AH, MSI-X, SR-IOV, and congestion-control registers.
- [ ] 11.3 Connect Doorbell path to QP SQ/RQ and CQ arm logic.
- [ ] 11.4 Connect QP, DMA, packet, transport, completion, and CQ managers for RC Send/Recv minimal loop.
- [ ] 11.5 Connect RDMA Write and RDMA Read datapaths.
- [ ] 11.6 Connect UD transmit and receive datapaths.
- [ ] 11.7 Add top-level tests for reset, CSR command, Doorbell-to-CQE minimal loop, RC Send, RDMA Write, RDMA Read, UD Send, and MSI-X completion interrupt.

## 12. Linux Kernel Driver

- [ ] 12.1 Implement PCIe driver probe/remove with BAR mapping, DMA mask setup, reset, feature discovery, and teardown.
- [ ] 12.2 Implement CSR mailbox helper with timeout, error-code mapping, and locking.
- [ ] 12.3 Implement character device open, release, ioctl dispatch, mmap, and poll operations.
- [ ] 12.4 Implement resource allocators for PD, CQ, QP, MR, AH, Doorbell pages, queue buffers, and mmap offsets.
- [ ] 12.5 Implement CQ create/destroy/query ioctls and CQ buffer mapping.
- [ ] 12.6 Implement QP create/modify/query/destroy ioctls and SQ/RQ buffer plus Doorbell mappings.
- [ ] 12.7 Implement MR register/deregister ioctls using page pinning and DMA mapping.
- [ ] 12.8 Implement AH create/destroy ioctls for UD addressing.
- [ ] 12.9 Implement MSI-X interrupt handlers for CQ events and async events.
- [ ] 12.10 Implement SR-IOV enable/disable, VF resource quotas, and per-function cleanup.
- [ ] 12.11 Implement hot-remove and process-release cleanup for all resources owned by a file descriptor.
- [ ] 12.12 Add driver build and static analysis targets.

## 13. Userspace Verbs Library

- [ ] 13.1 Implement device discovery and context open/close APIs.
- [ ] 13.2 Implement query_device, query_port, query_gid, and query_pkey APIs.
- [ ] 13.3 Implement PD alloc/dealloc APIs.
- [ ] 13.4 Implement CQ create/destroy/resize, poll_cq, and req_notify_cq APIs.
- [ ] 13.5 Implement QP create/modify/query/destroy APIs.
- [ ] 13.6 Implement MR register/deregister APIs.
- [ ] 13.7 Implement AH create/destroy APIs for UD.
- [ ] 13.8 Implement WQE builders for Send, Send with Immediate, RDMA Write, RDMA Write with Immediate, RDMA Read, and supported UD operations.
- [ ] 13.9 Implement post_send and post_recv batching with Doorbell memory barriers.
- [ ] 13.10 Implement CQE parser that returns Verbs-compatible work completions.
- [ ] 13.11 Implement async event retrieval and acknowledgement APIs.
- [ ] 13.12 Add pkg-config, provider metadata, examples, and userspace unit tests.

## 14. Cocotb Verilator Verification

- [ ] 14.1 Implement PCIe BFM for config, memory read/write, completions, MSI-X, and function identity.
- [ ] 14.2 Implement Ethernet/RoCEv2 BFM for packet construction, parsing, error injection, and CNP/PFC stimuli.
- [ ] 14.3 Implement host memory model with DMA read/write visibility and data integrity checks.
- [ ] 14.4 Implement scoreboard for WR-to-CQE matching, payload comparison, PSN tracking, retry behavior, and error statuses.
- [ ] 14.5 Implement functional coverage for opcodes, QP states, CQ statuses, MR permissions, message sizes, SGE counts, QP types, and congestion events.
- [ ] 14.6 Implement module-level Cocotb tests for PCIe, Doorbell, QP, CQ, MR, DMA, packet, transport, congestion, and top-level reset.
- [ ] 14.7 Implement integration tests for Doorbell-to-CQE, RC Send, RDMA Write, RDMA Read, UD Send, MSI-X, and SR-IOV isolation.
- [ ] 14.8 Implement protocol compliance tests for RoCEv2 header fields, ACK/NAK, RNR, immediate data, invalid packets, and ICRC behavior.
- [ ] 14.9 Implement regression script that runs lint, unit tests, integration tests, compatibility simulations, and coverage report generation.

## 15. Compatibility and Performance Validation

- [ ] 15.1 Add a minimal verbs example that opens the device, creates PD/CQ/QP/MR, posts Send/Recv, and polls completions.
- [ ] 15.2 Add perftest compatibility target for supported RC Send, RDMA Write, and RDMA Read tests.
- [ ] 15.3 Add UCX compatibility smoke tests for supported RC operations.
- [ ] 15.4 Add libfabric compatibility smoke tests for supported verbs-backed operations.
- [ ] 15.5 Add simulation performance counters for Doorbell-to-CQE latency, Doorbell-to-wire latency, DMA bandwidth, packet rate, and completion rate.
- [ ] 15.6 Add FPGA prototype checklist for board selection, PCIe IP wrapper, MAC IP wrapper, clocks, resets, constraints, loopback, and host driver loading.

## 16. Documentation and Acceptance

- [ ] 16.1 Document hardware module architecture and top-level data paths.
- [ ] 16.2 Document Linux driver ioctl ABI, mmap offsets, resource lifecycle, and error codes.
- [ ] 16.3 Document userspace Verbs API compatibility scope and known limitations.
- [ ] 16.4 Document verification strategy, test matrix, coverage goals, and how to run regression.
- [ ] 16.5 Verify `openspec validate add-rdma-smartnic-design-capability --strict` passes.
- [ ] 16.6 Verify all generated OpenSpec artifacts are ready for `/opsx:apply`.
