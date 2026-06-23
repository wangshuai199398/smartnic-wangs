# Cocotb 模块级单元测试

本目录存放 RDMA SmartNIC 的 Cocotb 模块级测试。当前阶段覆盖 PCIe endpoint/control-plane、Doorbell path、QP manager、CQ manager、MR manager、DMA dispatcher、packet processing 和 transport RC send-side 的最小行为，不模拟完整 PCIe 链路、TLP credit、DMA completion、完整 RoCEv2 transport 或主机内存模型。

## 测试文件

| 文件 | 覆盖模块 | 最小覆盖点 |
| --- | --- | --- |
| `test_pcie_cfg_space.py` | `rtl/pcie/pcie_cfg_space.sv` | vendor/device 读取、command/status 读写、capability 链表基础检查 |
| `test_pcie_bar_decoder.py` | `rtl/pcie/pcie_bar_decoder.sv` | BAR0 Doorbell、BAR2 CSR、BAR4 MSI-X 路由，以及非法 BAR/offset 错误 |
| `test_csr_mailbox.py` | `rtl/reg/pcie_csr_mailbox.sv` | NOP GO/DONE 生命周期、非法 command_id error_code、timeout 计数寄存器可见性 |
| `test_msix.py` | `rtl/pcie/pcie_msix.sv` | masked interrupt pending、unmask 后 message 输出、PBA bit 清除 |
| `test_sriov_function_manager.py` | `rtl/pcie/pcie_function_manager.sv` | PF 允许、enabled VF 窗口内允许、disabled VF 拒绝、VF 资源越界拒绝 |
| `test_doorbell_decoder.py` | `rtl/doorbell/doorbell_decoder.sv` | SQ/RQ/CQ arm offset 解码、非法 offset、未对齐 offset |
| `test_doorbell_access_check.py` | `rtl/doorbell/doorbell_access_check.sv` | PF/VF Doorbell 访问允许、disabled VF、cross-VF、QPN/CQN 越界拒绝 |
| `test_sq_doorbell.py` | `rtl/doorbell/sq_doorbell_handler.sv` | SQ Doorbell payload 解析、producer index 更新、PI 回绕、非法 QPN、权限拒绝 |
| `test_rq_doorbell.py` | `rtl/doorbell/rq_doorbell_handler.sv` | RQ Doorbell payload 解析、producer index 更新、PI 回绕、非法 QPN、权限拒绝 |
| `test_cq_arm_doorbell.py` | `rtl/doorbell/cq_arm_doorbell_handler.sv` | CQ Arm payload 解析、consumer index 更新、solicited-only、非法 CQN、权限拒绝 |
| `test_qp_context_table.py` | `rtl/qp/qp_context_table.sv` | QPN lookup/miss、QPN alias、owner function、SQ/RQ producer index 更新 |
| `test_qp_lifecycle.py` | `rtl/qp/qp_lifecycle_manager.sv` | CREATE/QUERY/MODIFY/DESTROY/QP_TO_ERROR、cleanup 请求、cross-function 拒绝 |
| `test_qp_state_validator.py` | `rtl/qp/qp_state_validator.sv` | 合法/非法 QP state transition、required attribute mask |
| `test_sq_engine.py` | `rtl/qp/sq_engine.sv` | SQ WQE fetch、NOP、dispatch、非法 state/opcode、consumer index wraparound |
| `test_rq_engine.py` | `rtl/qp/rq_engine.sv` | Recv WQE fetch、RNR、local length error、DMA write request、receive completion request |
| `test_qp_cleanup.py` | `rtl/qp/qp_cleanup_manager.sv` | Doorbell blocking、in-flight drain、SQ/RQ flushed completion、timeout、权限拒绝 |
| `test_qp_integration.py` | `rtl/qp/qp_lifecycle_manager.sv` | CREATE -> RTS -> mock SQ NOP -> DESTROY cleanup 的最小控制路径 |
| `test_cq_context_table.py` | `rtl/cq/cq_context_table.sv` | CQN lookup/miss、CQN alias、CQ arm update、completion producer update、owner function、overflow set/clear |
| `test_completion_engine.py` | `rtl/cq/completion_engine.sv` | SQ/RQ/cleanup/error event 到 64-byte CQE 格式化、CQ lookup miss、owner mismatch、backpressure |
| `test_cqe_write_path.py` | `rtl/cq/cqe_write_path.sv` | CQE 地址计算、64-byte DMA write 请求、PI update、lookup/permission error、DMA backpressure、基础 PI wrap |
| `test_cq_index_manager.py` | `rtl/cq/cq_index_manager.sv` | PI/CI wraparound、CQ arm CI 更新、depth/index 越界、empty/full、overflow set/clear |
| `test_cq_notification.py` | `rtl/cq/cq_notification.sv` | polling mode、armed、solicited-only、moderation count/timer、error immediate notify、MSI-X backpressure |
| `test_cq_integration.py` | `sim/cocotb/cq_integration_tb.sv` | mock completion -> 64-byte CQE -> CQE write address -> PI update -> notification/MSI-X request |
| `test_mr_table.py` | `rtl/mr/mr_table.sv` | MR entry 写入、lkey/rkey lookup、VA->PA 转换、bounds check、owner function、refcount 上下溢 |
| `test_mr_registration.py` | `rtl/mr/mr_registration_manager.sv` | REGISTER_MR 请求校验、SG entry fetch mock、MR entry 构造、table alias/full、成功响应 |
| `test_mr_deregistration.py` | `rtl/mr/mr_deregistration_manager.sv` | DEREGISTER_MR lookup、pending_deregister、refcount drain、clear entry、权限/PD/timeout 错误 |
| `test_mr_key_checker.py` | `rtl/mr/mr_key_checker.sv` | 本地 lkey、远端 rkey、方向错误、pending、权限、zero length、bounds 错误 |
| `test_mr_access_checker.py` | `rtl/mr/mr_access_checker.sv` | local/remote/MW access_flags 权限、pending、owner、zero length、bounds、overflow 错误 |
| `test_mr_pd_checker.py` | `rtl/mr/mr_pd_checker.sv` | QP PD 与 MR PD 匹配、PD mismatch、owner、pending、invalid entry、invalid operation、PA 透传 |
| `test_memory_window.py` | `rtl/mr/mr_memory_window_manager.sv` | MW bind/unbind、权限子集、rkey alias、refcount drain、QP error invalidation |
| `test_mr_integration.py` | `sim/cocotb/mr_integration_tb.sv` | REGISTER_MR -> lookup -> permission -> PD -> VA->PA -> refcount -> DEREGISTER_MR，以及 parent MR -> MW bind -> remote access -> unbind |
| `test_dma_descriptor_dispatcher.py` | `rtl/dma/dma_descriptor_dispatcher.sv` | SQ/RQ/CQE/fetch descriptor 分发、unsupported opcode、zero length、backpressure、fixed priority |
| `test_dma_wqe_sge_fetcher.py` | `rtl/dma/dma_wqe_sge_fetcher.sv` | SQ/RQ WQE fetch 地址计算、WQE decode、inline SGE、extended SGE fetch、256 SGE 边界、backpressure |
| `test_dma_sge_traversal.py` | `rtl/dma/dma_sge_traversal.sv` | SGE total-length accounting、byte_offset、256 SGE、zero-length 拒绝、overlap 检查、index 顺序、backpressure |
| `test_dma_mr_integration.py` | `rtl/dma/dma_mr_integration.sv` | 每个 DMA segment 的 lkey/rkey 方向、access_flags、PD、bounds、MW 状态、refcount increment 和 protected segment backpressure |
| `test_dma_segment_splitter.py` | `rtl/dma/dma_segment_splitter.sv` | PMTU split、4KB PA boundary split、max segment 限制、byte_offset/sub_index/last 标志、backpressure |
| `test_dma_arbiter.py` | `rtl/dma/dma_arbiter.sv` | fixed priority、round-robin、weighted round-robin、starvation guard、grant backpressure、source ready |
| `test_dma_host_read_path.py` | `rtl/dma/dma_host_read_path.sv` | Send/RDMA Write protected segment 到 PCIe read request、read response 到 payload stream、tag/length/error 检查、payload backpressure、refcount release |
| `test_dma_host_write_path.py` | `rtl/dma/dma_host_write_path.sv` | Recv/RDMA Read response protected segment 和 payload stream 到 PCIe write request、write completion 到 done、tag/error 检查、write backpressure、refcount release |
| `test_dma_error_propagation.py` | `rtl/dma/dma_error_propagation.sv` | DMA error source 到 completion status 映射、fatal QP error request、completion backpressure、多 source 优先级 |
| `test_roce_packet_parser.py` | `rtl/packet/roce_packet_parser.sv` | Ethernet/单层 VLAN/IPv4/UDP/BTH/RETH 字段提取、metadata 透传、NEED_MORE_DATA 状态 |
| `test_roce_ingress_validator.py` | `rtl/packet/roce_ingress_validator.sv` | EtherType、IP version/IHL/protocol、UDP port、BTH version、opcode、checksum、packet length 校验和 drop/accept ready/valid |
| `test_roce_payload_extractor.py` | `rtl/packet/roce_payload_extractor.sv` | validated metadata + frame beat 到 transport metadata 和 receive-DMA payload stream 的转换、零 payload、multi-beat stub error、backpressure |
| `test_roce_packet_builder.py` | `rtl/packet/roce_packet_builder.sv` | Ethernet/IPv4/UDP/BTH frame 构造、RETH、AETH/ACK、DETH、ImmDt、CNP、payload、unsupported opcode、multi-beat stub、backpressure |
| `test_roce_icrc_placeholder.py` | `rtl/packet/roce_icrc_placeholder.sv` | ICRC placeholder 透传、RX unchecked 标记、compatibility_limited 标志、backpressure |
| `test_roce_packet_stage8.py` | 第 8 阶段 packet mock integration | 全部支持 opcode、invalid packet drop、header extraction/generation、payload alignment、ICRC placeholder known limitation |
| `test_rc_send_engine.py` | `rtl/transport/rc_send_engine.sv` | RC send-side PSN allocation、outstanding tracking、ACK clear、retry timer、retry exhausted QP error request |
| `test_rc_recv_engine.py` | `rtl/transport/rc_recv_engine.sv` | RC receive-side PSN validation、duplicate/replay drop、gap NAK、ACK coalescing、RNR NAK |
| `test_rc_rdma_read_engine.py` | `rtl/transport/rc_rdma_read_engine.sv` | RC RDMA Read request generation、responder MR/DMA read path、Read Response sequencing、local write、completion/error mapping |
| `test_rc_immediate_engine.py` | `rtl/transport/rc_immediate_engine.sv` | SEND_WITH_IMM、RDMA_WRITE_WITH_IMM、0x11223344 byte order、RNR、remote write denial、normal SEND/WRITE no immediate CQE |

## 运行方式

从仓库根目录运行：

```sh
make pcie-test
make doorbell-test
make qp-test
make cq-test
make mr-test
make dma-test
make packet-test
make transport-test
```

或直接进入本目录运行：

```sh
make -C sim/cocotb pcie-control-plane-tests
make -C sim/cocotb doorbell-tests
make -C sim/cocotb qp-tests
make -C sim/cocotb cq-tests
make -C sim/cocotb mr-tests
make -C sim/cocotb dma-tests
make -C sim/cocotb packet-tests
make -C sim/cocotb transport-tests
```

如果本机没有安装 `cocotb` 或 `verilator`，目标会打印提示并跳过。安装工具后，可以单独运行某个模块测试：

```sh
make -C sim/cocotb test-pcie-cfg
make -C sim/cocotb test-pcie-bar
make -C sim/cocotb test-csr-mailbox
make -C sim/cocotb test-msix
make -C sim/cocotb test-sriov
make -C sim/cocotb test-doorbell-decoder
make -C sim/cocotb test-doorbell-access
make -C sim/cocotb test-sq-doorbell
make -C sim/cocotb test-rq-doorbell
make -C sim/cocotb test-cq-arm-doorbell
make -C sim/cocotb test-qp-context
make -C sim/cocotb test-qp-state-validator
make -C sim/cocotb test-qp-lifecycle
make -C sim/cocotb test-sq-engine
make -C sim/cocotb test-rq-engine
make -C sim/cocotb test-qp-cleanup
make -C sim/cocotb test-qp-integration
make -C sim/cocotb test-cq-context
make -C sim/cocotb test-completion-engine
make -C sim/cocotb test-cqe-write-path
make -C sim/cocotb test-cq-index-manager
make -C sim/cocotb test-cq-notification
make -C sim/cocotb test-cq-integration
make -C sim/cocotb test-mr-table
make -C sim/cocotb test-mr-registration
make -C sim/cocotb test-mr-deregistration
make -C sim/cocotb test-mr-key-checker
make -C sim/cocotb test-mr-access-checker
make -C sim/cocotb test-mr-pd-checker
make -C sim/cocotb test-memory-window
make -C sim/cocotb test-mr-integration
make -C sim/cocotb test-dma-descriptor-dispatcher
make -C sim/cocotb test-dma-wqe-sge-fetcher
make -C sim/cocotb test-dma-segment-splitter
make -C sim/cocotb test-dma-arbiter
make -C sim/cocotb test-dma-host-write-path
make -C sim/cocotb test-dma-error-propagation
make -C sim/cocotb test-roce-packet-parser
make -C sim/cocotb test-roce-ingress-validator
make -C sim/cocotb test-roce-payload-extractor
make -C sim/cocotb test-roce-packet-builder
make -C sim/cocotb test-roce-icrc-placeholder
make -C sim/cocotb test-roce-packet-stage8
make -C sim/cocotb test-rc-send-engine
make -C sim/cocotb test-rc-recv-engine
make -C sim/cocotb test-rc-rdma-read-engine
make -C sim/cocotb test-rc-immediate-engine
```

## 当前限制

- 测试只驱动模块级 ready/valid 和寄存器接口。
- 不检查完整 PCIe TLP 编码、completion ordering 或 MSI-X TLP 发送。
- mailbox 的 timeout 注入能力后续会随 CSR command 执行器增强；当前测试只确认 timeout 计数和错误码定义可见。
- SQ Doorbell 测试只验证 payload 到 `qp_update_*` 事件的转换，不读取 SQ WQE，也不触发 QP scheduler。
- RQ Doorbell 测试只验证 payload 到 `qp_rq_update_*` 事件的转换，不读取 RQ WQE，也不触发 Receive Queue 处理。
- CQ Arm Doorbell 测试只验证 payload 到 `cq_arm_*` 事件的转换，不写 CQE，也不触发真实 MSI-X。
- CQ context table 测试只验证 CQ context 读写、arm 状态、producer index 和 overflow 标志，不格式化 CQE、不写 host CQ buffer，也不生成 MSI-X 请求。
- Completion engine 测试只验证 CQE 格式化和 lookup/权限错误处理，不计算 CQE 地址、不更新 producer index，也不触发 MSI-X。
- CQE write path 测试只验证地址计算、DMA write 请求和 producer update 请求，不实现真实 DMA Engine、不做完整 overflow 检测，也不触发 MSI-X。
- CQ index manager 测试只验证 reserved-slot index 规则和 overflow 标志，不实现 owner bit phase 方案。
- CQ notification 测试只验证 CQE commit 后的通知决策和 MSI-X request ready/valid，不发送真实 MSI-X PCIe memory write。
- CQ integration 测试使用 Python mock/stub 串起 CQ 子模块接口语义，不实例化完整 CQ manager top，也不执行真实 DMA/PCIe/RoCEv2。
- MR table 测试只验证 key 查找、地址范围转换和 refcount 计数，不实现 MR 注册命令、权限矩阵、PD 规则或 Memory Window bind。
- MR registration 测试只 mock 第一个 pinned SG entry 和 MR table 写响应，不实现真实 DMA fetch、多段 SG page walk、IOMMU 或 PD allocator。
- MR deregistration 测试只 mock MR table read/write 响应和 refcount drain，不取消真实 DMA，也不处理 Memory Window 级联失效或 PF force deregister 策略。
- MR key checker 测试只验证 lkey/rkey 使用方向和 MR table check 状态映射，不实现 access_flags 权限矩阵、完整 PD 规则或 Memory Window bind。
- MR access checker 测试只验证 `access_flags` 权限矩阵和基础 bounds/owner/pending 检查，不实现完整 PD mismatch、Memory Window bind/unbind 或 QP error invalidation。
- MR PD checker 测试只验证 QP PD 与 MR PD 的最后一道匹配检查，不实现按 QPN 查询 QP context、remote requester identity 或 PF admin override。
- Memory Window 测试只 mock MR table read/write 和 QP error scan 响应，不实现完整 IBTA Type 1/Type 2 MW、remote invalidate opcode 或真实 QP async event。
- MR integration 测试使用 Python mock/stub 串起 MR 子模块语义，不实例化完整 MR manager top，不实现真实 DMA Engine、IOMMU、page walk 或 RoCEv2 transport。
- DMA descriptor dispatcher 测试只验证 descriptor 分流和 backpressure，不执行真实 PCIe read/write、不遍历 SGE、不调用 MR checker，也不实现公平仲裁。
- DMA WQE/SGE fetcher 测试只验证 host read 请求/响应接口、WQE/SGE decode 和 ready/valid 行为，不实现真实 PCIe read、SGE total-length accounting、zero-overlap validation 或 MR permission check。
- DMA segment splitter 测试只验证 protected segment 的 PMTU/4KB/max 长度切分，不执行真实 host read/write，不释放 MR refcount，也不做 DMA arbitration 或 completion error propagation。
- DMA arbiter 测试只验证多 source request 到单个 grant 的调度策略和 starvation guard，不执行真实 host read/write/fetch，也不做 completion error propagation。
- DMA host write path 测试只验证 protected segment 和 payload stream 到 PCIe write request 的转换、write completion、错误输出和 refcount release，不实现真实 PCIe memory write、跨 segment 拼接、PMTU/4KB split 或 completion error propagation。
- DMA error propagation 测试只验证 DMA 子模块错误到 completion status / QP error request 的映射，不实现 retry engine、remote error packet、RoCEv2 NAK 或 async event queue。
- Packet parser 测试只验证 8.1 的首个 512-bit beat 字段提取和 metadata 输出，不实现 8.2 ingress validation、8.3 payload extraction、8.4 packet builder 或 8.5 ICRC 校验。
- Ingress validator 测试只验证 8.2 的 metadata 合法性裁决和 drop/accept ready/valid，不实现真实 checksum 计算器、payload extraction、packet builder 或 transport/QP 状态机。
- Payload extractor 测试只验证 8.3 的接口转换，不实现完整多 beat payload reassembly、真实 receive DMA 写入、第 9 阶段 transport 状态机或 packet builder。
- Packet builder 测试只验证 8.4 的单 beat header/payload frame 构造，不实现真实 ICRC、IPv4/UDP checksum、PMTU 多 beat packetization 或第 9 阶段 transport 语义。
- ICRC placeholder 测试只验证 8.5 的隔离占位行为，不实现真实 RoCEv2 invariant CRC，因此不能代表真实网络互操作兼容性。
- Stage 8 packet mock integration 测试只串联第 8 阶段的抽象语义，不实例化完整 RTL pipeline，不实现第 9 阶段 RC/UD transport，也不证明真实 RoCEv2 互操作。
- RC send engine 测试只验证 9.1 的 send-side PSN、outstanding、ACK、retry 和 retry exhausted QP error 请求，不实现 9.2 receive-side PSN validation、NAK/RNR、9.3 RDMA Read sequencing 或完整 RC retry 语义。
- RC receive engine 测试只验证 9.2 的 receive-side PSN 顺序检查、duplicate/replay drop、gap NAK、ACK 合并和 RNR NAK，不实现 9.3 RDMA Read sequencing、完整 AETH syndrome/MSN 编码、RNR retry timer 或真实 RQ/DMA side effect。
- RC RDMA Read engine 测试只验证 9.3 的 requester/responder/response receive 最小序列，不实现多 outstanding table、真实 MR/DMA pipeline、PMTU 多响应分段、完整 retry/NAK replay 或 RoCEv2 wire-format 互操作。
- RC immediate engine 测试只验证 9.4 的 RC SEND_WITH_IMM/RDMA_WRITE_WITH_IMM immediate-data receive completion 语义，不实现 UD immediate、完整 multi-beat packet builder 或 CSR failure counters。
