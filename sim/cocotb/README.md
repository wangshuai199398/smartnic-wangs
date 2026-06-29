# Cocotb 模块级单元测试

本目录存放 RDMA SmartNIC 的 Cocotb 模块级测试。当前阶段覆盖 PCIe endpoint/control-plane、Doorbell path、QP manager、CQ manager、MR manager、DMA dispatcher、packet processing 和 transport RC send-side 的最小行为。14.x 已开始补充可复用 BFM、host memory model、scoreboard 和 functional coverage collector，但仍不模拟完整 PCIe 链路、TLP credit 或完整 RoCEv2 transport。

## 测试文件

| 文件 | 覆盖模块 | 最小覆盖点 |
| --- | --- | --- |
| `bfm/pcie_bfm.py` | Host-side PCIe BFM | function identity、config read/write、BAR probe/program、MMIO read/write、completion matching、MSI-X table/interrupt observation |
| `bfm/roce_ethernet_bfm.py` | Ethernet/RoCEv2 BFM | Ethernet/VLAN/FCS、IPv4/UDP checksum、BTH/RETH/AETH/DETH/ImmDt、CNP、PFC pause/resume、packet queues、explicit error injection |
| `bfm/host_memory_model.py` | Host memory / DMA model | byte-addressable backing store、aligned DMA allocation、DMA read/write visibility、byte enable、transaction history、integrity helpers、PCIe TLP service hook |
| `bfm/rdma_scoreboard.py` | RDMA scoreboard | expected WR tracking、WR-to-CQE matching、payload comparison、PSN tracking、retry checks、error completion validation、end-of-test outstanding checks |
| `bfm/rdma_coverage.py` | RDMA functional coverage | opcode、QP state、CQ status、MR permission、message size、SGE count、QP type、congestion event bins；reset/enable/summary/optional bins |
| `test_pcie_bfm.py` | PCIe BFM unit tests | identity/config、command enable、BAR discovery、MMIO TLP emission、completion timeout/malformed 检查、MSI-X masked/unmasked、reset 清 outstanding |
| `test_roce_ethernet_bfm.py` | Ethernet/RoCEv2 BFM unit tests | frame/header round-trip、checksum/length、RC Send、RDMA Write、ACK/UD extension headers、invalid opcode/checksum、CNP、PFC、queue ordering |
| `test_host_memory_model.py` | Host memory model unit tests | aligned allocation、initialization、PCIe DMA read/write service、partial byte enable writes、out-of-range errors、history order、reset policy、deterministic patterns |
| `test_rdma_scoreboard.py` | RDMA scoreboard unit tests | SEND/RECV CQE matching、payload compare、RDMA Write/Read data checks、missing/unexpected/out-of-order CQE、PSN gap/duplicate、retry exhaustion、expected error status |
| `test_rdma_coverage.py` | RDMA functional coverage unit tests | opcode、QP state、CQ status、MR permission、message size、SGE count、QP type、congestion bins、reset/disable、missing required/optional summary |
| `test_module_level_stage14.py` | 14.6 module-level smoke suite | PCIe config/MMIO/TLP、Doorbell decode、QP state、CQE/overflow、MR permission/bounds、DMA read/write、packet parse/build、transport PSN/retry、congestion bins、top reset recovery |
| `test_rdma_integration_stage14.py` | 14.7 RDMA/RoCE integration suite | Doorbell-to-CQE、RC Send packet/DMA/ACK/CQE、RDMA Write remote memory update、RDMA Read request/response/writeback、UD Send DETH/AH、MSI-X delivery/masking、SR-IOV isolation |
| `test_roce_protocol_compliance_stage14.py` | 14.8 RoCEv2/RDMA protocol compliance suite | Ethernet/IP/UDP/BTH/RETH/AETH/DETH/ImmDt fields、ACK/NAK、RNR retry exhaustion、immediate CQE、invalid packets、bad rkey/address、ICRC accept/reject |
| `../../tests/run_rdma_regression.sh` | 14.9 regression runner | lint/unit/module/integration/protocol/compatibility/coverage 分组、smoke/full 模式、日志目录、summary table、coverage support report |
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
| `test_roce_packet_parser.py` | `rtl/packet/roce_packet_parser.sv` | Ethernet/单层 VLAN/IPv4/IPv6 ECN/UDP/BTH/RETH 字段提取、metadata 透传、NEED_MORE_DATA 状态 |
| `test_roce_ingress_validator.py` | `rtl/packet/roce_ingress_validator.sv` | EtherType、IP version/IHL/protocol、UDP port、BTH version、opcode、checksum、packet length 校验和 drop/accept ready/valid |
| `test_roce_payload_extractor.py` | `rtl/packet/roce_payload_extractor.sv` | validated metadata + frame beat 到 transport metadata 和 receive-DMA payload stream 的转换、零 payload、multi-beat stub error、backpressure |
| `test_roce_packet_builder.py` | `rtl/packet/roce_packet_builder.sv` | Ethernet/IPv4/UDP/BTH frame 构造、RETH、AETH/ACK、DETH、ImmDt、CNP、payload、unsupported opcode、multi-beat stub、backpressure |
| `test_roce_icrc_placeholder.py` | `rtl/packet/roce_icrc_placeholder.sv` | ICRC placeholder 透传、RX unchecked 标记、compatibility_limited 标志、backpressure |
| `test_roce_packet_stage8.py` | 第 8 阶段 packet mock integration | 全部支持 opcode、invalid packet drop、header extraction/generation、payload alignment、ICRC placeholder known limitation |
| `test_transport_stage9.py` | 第 9 阶段 transport mock regression | RC Send、RDMA Write、RDMA Read、PSN errors、retry exhaustion、RNR、immediate data、UD Send、Q_Key rejection |
| `test_ah_table.py` | `rtl/transport/ah_table.sv` | AH create/update/lookup/delete、owner/PD permission、GID-derived metadata、service_level、alias/invalid entry |
| `test_rc_send_engine.py` | `rtl/transport/rc_send_engine.sv` | RC send-side PSN allocation、outstanding tracking、ACK clear、retry timer、retry exhausted QP error request |
| `test_rc_recv_engine.py` | `rtl/transport/rc_recv_engine.sv` | RC receive-side PSN validation、duplicate/replay drop、gap NAK、ACK coalescing、RNR NAK |
| `test_rc_rdma_read_engine.py` | `rtl/transport/rc_rdma_read_engine.sv` | RC RDMA Read request generation、responder MR/DMA read path、Read Response sequencing、local write、completion/error mapping |
| `test_rc_immediate_engine.py` | `rtl/transport/rc_immediate_engine.sv` | SEND_WITH_IMM、RDMA_WRITE_WITH_IMM、0x11223344 byte order、RNR、remote write denial、normal SEND/WRITE no immediate CQE |
| `test_ud_tx_engine.py` | `rtl/transport/ud_tx_engine.sv` | UD SEND、AH lookup、DETH Q_Key/source QPN、无 RC connection state、invalid AH、missing Q_Key、拒绝 UD RDMA ops |
| `test_ud_rx_engine.py` | `rtl/transport/ud_rx_engine.sv` | UD receive DETH parsing、Q_Key validation、source QPN completion seed、missing RQ WQE、malformed/invalid DETH counters |
| `test_congestion_stage10.py` | 第 10 阶段 congestion mock checks | IPv4/IPv6 ECN、CE hook、CNP、DCQCN rate update、token bucket pacing、PFC pause/resume |
| `test_congestion_integration.py` | 第 10.6 阶段 congestion integration mock suite | ECN->CNP、CNP->DCQCN、recovery、pacing throttle、PFC pause/resume、malformed CNP drop、no-deadlock |
| `test_ecn_ingress_marker.py` | `rtl/congestion/ecn_ingress_marker.sv` | CE mark hook、ECN/CE/malformed counter、非 CE 包透传 |
| `test_cnp_packet_generator.py` | `rtl/congestion/cnp_packet_generator.sv` | CE/queue/port trigger 到 CNP build request、congestion type、per-QP rate limit |
| `test_cnp_receive_classifier.py` | `rtl/congestion/cnp_receive_classifier.sv` | CNP opcode/UDP port 分类、QP lookup hit/miss、DCQCN event、invalid counter |
| `test_dcqcn_state_machine.py` | `rtl/congestion/dcqcn_state_machine.sv` | per-QP rate config、CNP 后 current_rate 减半、min_rate clamp、alpha EWMA、recovery additive increase |
| `test_tx_pacer_token_bucket.py` | `rtl/congestion/tx_pacer_token_bucket.sv` | per-QP bucket config、DCQCN rate update、token refill/clamp、allow/throttle/bypass/invalid decision |
| `test_pfc_pause_scheduler.py` | `rtl/congestion/pfc_pause_scheduler.sv` | per-priority PAUSE/RESUME、timer expiry、TX scheduler backpressure、token bucket freeze gate |
| `test_smartnic_top_structure.py` | `rtl/top/smartnic_top.sv` | 主要子系统实例、reset 同步、debug observability、顶层边界注释 |
| `test_csr_fabric_structure.py` | `rtl/reg/csr_decode.sv` / `rtl/reg/csr_fabric.sv` / `rtl/top/smartnic_top.sv` | BAR2 CSR 子窗口、单 slave 选择、byte enable 写模型、top-level CSR fabric 连接 |
| `test_doorbell_ctrl_structure.py` | `rtl/doorbell/doorbell_ctrl.sv` / `rtl/top/smartnic_top.sv` | BAR0 Doorbell 到 SQ/RQ PI 更新、CQ arm 和 scheduler wakeup hint 的 top-level 连接 |
| `test_rc_pipeline_structure.py` | `rtl/top/rc_pipeline_top.sv` / `rtl/top/smartnic_top.sv` | 最小 RC Send/Recv pipeline、packet builder mux、completion engine 连接、CQE write hook |
| `test_rdma_write_read_engine_structure.py` | `rtl/transport/rdma_write_read_engine.sv` / `rtl/top/smartnic_top.sv` | 11.5 RDMA Write/Read one-sided pipeline、RETH packet build、single outstanding RDMA Read、completion mux |
| `test_ud_datapath_top_structure.py` | `rtl/transport/ud_datapath_top.sv` / `rtl/top/smartnic_top.sv` | 11.6 UD TX/RX top integration、AH lookup、DETH/Q_Key、QP lookup、DMA hooks、completion mux、drop counters |
| `test_top_level_paths.py` | `rtl/top/smartnic_top.sv` and top-level datapath modules | 11.7 reset、CSR、Doorbell-to-CQE、RC Send、RDMA Write/Read、UD Send/RX、MSI-X completion interrupt contract |

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
make congestion-test
make top-test
make module-test
make integration-test
make protocol-test
tests/run_rdma_regression.sh --mode smoke
```

或直接进入本目录运行：

```sh
make -C sim/cocotb pcie-control-plane-tests
make -C sim/cocotb test-host-memory-model
make -C sim/cocotb test-rdma-scoreboard
make -C sim/cocotb test-rdma-coverage
make -C sim/cocotb test-roce-ethernet-bfm
make -C sim/cocotb test-module-level-stage14
make -C sim/cocotb module-level-tests
make -C sim/cocotb test-rdma-integration-stage14
make -C sim/cocotb rdma-integration-tests
make -C sim/cocotb test-roce-protocol-compliance-stage14
make -C sim/cocotb protocol-compliance-tests
../../tests/run_rdma_regression.sh --mode smoke
make -C sim/cocotb doorbell-tests
make -C sim/cocotb qp-tests
make -C sim/cocotb cq-tests
make -C sim/cocotb mr-tests
make -C sim/cocotb dma-tests
make -C sim/cocotb packet-tests
make -C sim/cocotb transport-tests
make -C sim/cocotb congestion-tests
make -C sim/cocotb top-tests
```

如果本机没有安装 `cocotb` 或 `verilator`，目标会打印提示并跳过。安装工具后，可以单独运行某个模块测试：

```sh
make -C sim/cocotb test-pcie-cfg
make -C sim/cocotb test-pcie-bfm
make -C sim/cocotb test-host-memory-model
make -C sim/cocotb test-rdma-scoreboard
make -C sim/cocotb test-rdma-coverage
make -C sim/cocotb test-roce-ethernet-bfm
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
make -C sim/cocotb test-congestion-stage10
make -C sim/cocotb test-congestion-integration
make -C sim/cocotb test-ecn-ingress-marker
make -C sim/cocotb test-cnp-packet-generator
make -C sim/cocotb test-cnp-receive-classifier
make -C sim/cocotb test-dcqcn-state-machine
make -C sim/cocotb test-tx-pacer-token-bucket
make -C sim/cocotb test-pfc-pause-scheduler
make -C sim/cocotb test-smartnic-top-structure
make -C sim/cocotb test-module-level-stage14
make -C sim/cocotb test-rdma-integration-stage14
make -C sim/cocotb test-roce-protocol-compliance-stage14
```

## PCIe BFM

14.1 新增 `sim/cocotb/bfm/pcie_bfm.py`，用于后续 Doorbell、DMA、CQ、MSI-X 和 SR-IOV 验证复用。BFM 以 host 侧 API 为中心：

- `cfg_read()` / `cfg_write()`：标准配置空间访问，含 byte enable、command bit、identity 和 MSI-X capability header；
- `probe_bar_size()` / `program_bar()`：BAR size probe 和 base programming；
- `mem_write()` / `mem_read()`：向已编程 BAR 发起 MMIO transaction，并通过 BAR memory 或 callback 表示 DUT-visible transaction；
- `push_completion()` / `wait_for_completion()`：按 tag 匹配 read completion，并检查 requester ID、byte count 和 payload length；
- `program_msix_vector()` / `observe_msix_write()` / `wait_msix()`：建模 MSI-X table、mask/PBA pending 和 DUT 发出的 MSI-X memory write；
- `PcieFunctionIdentity`：保存 BDF、vendor/device/subsystem/class/revision 和 PF/VF identity hook。

BFM 当前不实现完整 PCIe credit、ordering rule、posted/non-posted request scheduling、TLP ECRC 或 vendor-specific hard-IP sideband。它通过 `bar.sink` 和 `on_tlp` callback 暴露 transaction，后续 cocotb DUT driver 可以把这些 callback 接到 AXI-stream TLP 或 wrapper 信号。

## Ethernet/RoCEv2 BFM

14.2 新增 `sim/cocotb/bfm/roce_ethernet_bfm.py`，用于后续 packet、transport、congestion 和协议一致性测试复用。BFM 以 packet object 和 raw frame API 为中心：

- `EthernetFrame`：构造/解析 Ethernet frame，支持可选 VLAN tag 和可选 FCS 检查；
- `Ipv4UdpPacket`：构造/解析 IPv4/UDP，生成 IPv4 header checksum、UDP length/checksum，并支持 DSCP/ECN 字段；
- `RocePacket`：构造/解析 RoCEv2 BTH，并支持 RETH、AETH、DETH、Immediate Data 和 CNP payload 的 normalized fields；
- `EthernetRoceBfm.build_roce_frame()` / `parse_frame()`：把 normalized RoCE packet 转成 Ethernet/IPv4/UDP/RoCEv2 frame，或把 DUT-emitted raw frame 解析回对象；
- `send_raw_frame()` / `send_roce_packet()` / `observe_tx_frame()` / `recv_roce_packet()`：提供 RX 注入和 TX 观察队列，后续可以绑定到 AXI-stream MAC ready/valid；
- explicit `errors={...}`：支持 bad FCS、bad IPv4 checksum、bad UDP length/checksum、bad ICRC、invalid opcode、invalid destination QP、PSN delta、truncated frame 和 extra padding；
- `build_cnp()`：生成 RoCEv2 Congestion Notification Packet；
- `build_pfc_frame()` / `parse_pfc_frame()`：生成和解析 802.1Qbb PFC pause/resume stimulus。

当前 RoCE ICRC 仍使用 deterministic CRC32 placeholder，只用于显式好/坏 ICRC 测试分流；真实 invariant CRC 行为仍由后续协议一致性测试和 RTL ICRC 实现补齐。本 BFM 不包含 scoreboard、coverage、host memory DMA model 或 Ethernet MAC timing policy。

## Host Memory Model

14.3 新增 `sim/cocotb/bfm/host_memory_model.py`，用于后续 DMA、CQ、MR、packet 和集成测试复用。它提供 DMA-visible host memory，而不包含 RDMA scoreboard policy：

- `HostMemoryModel(base_addr, size)`：创建 byte-addressable backing store；
- `allocate(size, alignment, init, pattern)` / `free()`：确定性分配和复用 DMA buffer，返回包含 `handle`、`dma_addr`、`size`、`alignment` 的 `DmaBuffer`；
- `read()` / `write()`：测试侧直接读写 host memory；
- `dma_read()` / `dma_write()`：DUT DMA 侧可见读写，并记录 transaction history；
- `service_pcie_tlp()`：接收 14.1 PCIe BFM 的 Memory Read/Write TLP，Memory Read 返回 `PcieCompletion`，Memory Write 更新 backing store；
- `compare()` / `compare_masked()` / `digest()`：数据完整性检查和可读 mismatch 诊断；
- `pattern_bytes()`：支持 zero、constant、incrementing、walking-bit 和 deterministic random patterns；
- `history`、`assert_dma_read()`、`assert_dma_write()`：用于测试断言 DMA 访问顺序和可见性。

默认使用 strict allocation policy：DMA 访问必须落在已分配 buffer 内。需要测试非法/未知地址访问时，应显式断言 `HostMemoryError`，或在构造模型时关闭 `strict_allocations`。

## RDMA Scoreboard

14.4 新增 `sim/cocotb/bfm/rdma_scoreboard.py`，用于后续模块级、集成和协议一致性测试复用。它只负责期望和观测事件的匹配，不采集功能覆盖率：

- `ExpectedWorkRequest`：登记预期 WR，包含 `wr_id`、opcode、QPN、QP type、SGE、byte length、completion status、immediate data、vendor error 和 signaled/unsignaled 行为；
- `ObservedCqe`：归一化 DUT/CQ model 输出的 completion，用于 `observe_cqe()` 匹配；
- `SgeRef` + `HostMemoryModel`：支持 SEND/RECV gather/scatter payload 比较、RDMA Write destination memory 比较、RDMA Read response payload 比较；
- `PacketObservation` / `RocePacket`：支持 per-QP PSN progression、gap、duplicate 和 retry packet 检查；
- `expect_retry()` / `observe_retry_packet()`：建模 RC retry attempt 和 retry exhaustion；
- `expect_dma_read()` / `expect_dma_write()`：借助 host memory model transaction history 检查 DMA 访问是否发生；
- `finish()`：在测试结束时检查 outstanding WR、CQE 和 DMA expectation。

默认 strict mode 会在第一次 mismatch 处抛出 `ScoreboardError`，错误信息包含 QPN、WR ID、opcode、PSN 或 byte offset。permissive mode 可用于后续半集成阶段收集 unexpected 事件而不中断当前测试。

## RDMA Functional Coverage

14.5 新增 `sim/cocotb/bfm/rdma_coverage.py`，用于模块 monitor、BFM、scoreboard 和 mock model 共享功能覆盖率采样。它不定义具体测试场景，只收集 feature bins：

- opcode：SEND、RECV、RDMA_WRITE、RDMA_READ、UD_SEND、ACK、NAK，以及 SEND/RDMA_WRITE/UD immediate variants；
- QP state：RESET、INIT、RTR、RTS、SQD、SQE、ERROR；
- CQ status：SUCCESS 和当前 scoreboard 中归一化的 error statuses；
- MR permission：local read/write、remote read/write/atomic、MW bind、invalid/denied；
- message size：zero、small、MTU、multi-packet、max；
- SGE count：zero、one、multiple、max、invalid；
- QP type：RC、UD；
- congestion：ECN、CNP、rate reduction、recovery。

主要采样入口：

- `sample_wr(ExpectedWorkRequest)`：从 WR/WQE 提交路径采 opcode、QP type、message size、SGE count；
- `sample_cqe(ObservedCqe)`：从 CQE monitor 采 completion opcode/status/size；
- `sample_packet(RocePacket)`：从 RoCEv2 packet monitor 采 opcode/immediate/size；
- `sample_qp_state_transition()`：从 QP lifecycle monitor 采状态；
- `sample_mr_access_flags()` / `sample_mr_permission()`：从 MR checker monitor 采权限和 denied；
- `sample_congestion_event()`：从 ECN/CNP/DCQCN monitor 采拥塞事件；
- `summary()` / `report()`：返回 hit/missing required/missing optional 信息。

不支持或暂未实现的 DUT feature 可以通过 `optional_bins={CoverageCategory.OPCODE: ["UD_SEND_IMM"]}` 等方式标记为 optional，避免 early-stage DUT 因缺少预留 feature 阻塞覆盖率收敛。

## Stage 14.6 Module-Level Tests

14.6 新增 `sim/cocotb/test_module_level_stage14.py`，作为快速、确定性的模块级 smoke suite。它复用 14.1-14.5 的 PCIe BFM、Ethernet/RoCEv2 BFM、host memory model、scoreboard 和 functional coverage collector，覆盖：

- PCIe config/MMIO/TLP handling；
- Doorbell valid/invalid decode、ordering 和 queue update metadata；
- QP state transition 和 invalid transition；
- CQE status、empty/overflow reserved-slot 行为；
- MR registration-style bounds、permission 和 invalid key 语义；
- DMA read/write visibility、byte enable、alignment 和 error handling；
- Packet build/parse、header fields、payload length 和 malformed input；
- Transport SEND/RDMA PSN、retry 和 ACK/NAK 基础行为；
- Congestion ECN/CNP/rate-control coverage events；
- top-level reset during idle/active 的模型状态清理和恢复。

运行：

```sh
make -C sim/cocotb test-module-level-stage14
make -C sim/cocotb module-level-tests
make module-test
```

`module-level-tests` 先运行 14.6 smoke，再调用现有 PCIe、Doorbell、QP、CQ、MR、DMA、Packet、Transport、Congestion 和 Top targets。若环境缺少 `cocotb` 或 `verilator`，RTL 仿真 targets 会按现有约定打印 skip；纯 Python BFM/scoreboard/coverage/module smoke 仍会运行。

## Stage 14.7 Integration Tests

14.7 新增 `sim/cocotb/test_rdma_integration_stage14.py`，用于把 14.1-14.6 的 reusable verification pieces 串成跨模块集成语义测试：

- Doorbell-to-CQE：host doorbell 更新 SQ producer，mock DMA read 后生成 CQE，并用 scoreboard 匹配 WR-to-CQE；
- RC Send：配置 RC QP，读取 host payload，构造/观察 RoCE SEND packet，检查 PSN、payload、ACK placeholder 和 CQE；
- RDMA Write：检查 remote rkey/permission，构造 RDMA Write packet，更新 remote host memory，验证 destination payload 和 CQE；
- RDMA Read：发送 Read Request，读取 remote memory，接收 Read Response payload 并写回 local buffer，最终生成 CQE；
- UD Send：使用 AH metadata 构造 DETH，检查 Q_Key、source QPN、destination QPN、payload 和 send completion；
- MSI-X：通过 PCIe BFM 验证 unmasked vector delivery、masked pending 和 unmask delivery；
- SR-IOV：验证 owner_function 对 Doorbell 和 MR 访问的隔离，cross-VF 访问被拒绝；
- Negative checks：invalid QP state、invalid MR permission、invalid lkey/rkey、bounds 和 missing CQE path。

运行：

```sh
make -C sim/cocotb test-rdma-integration-stage14
make -C sim/cocotb rdma-integration-tests
make integration-test
```

这些测试复用 BFM、host memory model、scoreboard 和 coverage，不做 14.8 的 RoCEv2 header/ACK/NAK/RNR/ICRC exhaustive compliance，也不提供 14.9 的全量 regression orchestration。

## Stage 14.8 Protocol Compliance Tests

14.8 新增 `sim/cocotb/test_roce_protocol_compliance_stage14.py`，聚焦 RoCEv2/RDMA protocol-visible behavior：

- Header fields：Ethernet、VLAN、IPv4 DSCP/ECN、UDP port/length、BTH opcode/QPN/PSN/P_Key、RETH remote VA/rkey/length、payload length；
- ACK/NAK：valid ACK 更新 expected PSN，sequence NAK 进入 retry expectation，unexpected NAK 不腐蚀 scoreboard 状态；
- RNR：RNR NAK 触发 RNR retry，超过配置 retry limit 后产生 `RNR_RETRY_EXCEEDED` error CQE；
- Immediate data：`SEND_WITH_IMM` 和 `RDMA_WRITE_WITH_IMM` 使用 32-bit network byte order，并在 receive CQE 中携带 imm_data；
- Invalid packets：bad opcode、bad QPN、bad PSN、malformed/truncated header、invalid UDP length、invalid rkey/address；
- ICRC：valid placeholder ICRC accepted，bad placeholder ICRC rejected，且不会产生 false success completion。

运行：

```sh
make -C sim/cocotb test-roce-protocol-compliance-stage14
make -C sim/cocotb protocol-compliance-tests
make protocol-test
```

当前 ICRC 行为仍与 8.5 一致：测试验证 BFM/placeholder ICRC 的 accept/reject contract，不声明已实现真实 RoCEv2 invariant CRC。

## Stage 14.9 Regression Runner

14.9 新增 `tests/run_rdma_regression.sh`，用于复用已有目标运行可组合回归。它支持以下 group：

- `lint`：`make lint` 和 `git diff --check`；
- `unit`：PCIe BFM、host memory、scoreboard、coverage、Ethernet/RoCEv2 BFM unit tests；
- `module`：14.6 `module-level-tests`；
- `integration`：14.7 `rdma-integration-tests`；
- `protocol`：14.8 `protocol-compliance-tests`；
- `compatibility`：已有 driver/userspace smoke/static tests（存在则运行，缺失则 skip）；
- `coverage`：运行现有 functional coverage unit test，并生成 `coverage.txt`，明确标注尚未配置 simulator/Python coverage merge；
- `smoke`：展开为 `lint unit integration protocol coverage`；
- `full`：展开为 `lint unit module integration protocol compatibility coverage`。

示例：

```sh
tests/run_rdma_regression.sh --mode smoke
tests/run_rdma_regression.sh --mode full
tests/run_rdma_regression.sh --sim verilator module integration protocol
RDMA_REGRESSION_OUT=/tmp/rdma-regression tests/run_rdma_regression.sh smoke
make regression
make coverage
```

每个阶段会写入 `build/rdma-regression/<timestamp>/logs/*.log`，最终 `summary.txt` 汇总 PASS/FAIL/SKIP。任何 FAIL 都会让脚本返回非零退出码。当前脚本只编排现有测试和报告，不新增 14.5 coverage bins、14.6 module tests、14.7 integration tests 或 14.8 protocol tests。

## 当前限制

- 测试只驱动模块级 ready/valid 和寄存器接口。
- PCIe BFM 检查 host-side TLP metadata、tag/completion matching 和 MSI-X write observation，但不检查完整 PCIe credit、ordering、ECRC 或厂商 hard-IP sideband。
- Ethernet/RoCEv2 BFM 检查 packet byte layout、checksum、extension headers、CNP/PFC stimulus 和显式错误注入，但不建模真实 MAC timing、scoreboard、coverage、host memory DMA model 或真实 RoCE invariant CRC。
- Host memory model 检查 DMA-visible byte storage、byte enable、transaction history 和 data integrity，不建模 IOMMU、PCIe ordering/credit、RDMA WR-to-CQE scoreboard 或 functional coverage。
- RDMA scoreboard 检查 WR-to-CQE、payload、PSN、retry 和 error status 语义，不采集 coverage，不规定具体 test-case policy，也不替代协议 compliance suite。
- RDMA functional coverage 只统计 feature bin hit，不改变 BFM/scoreboard 行为。14.6 模块级 smoke 会采样 coverage，但不实现 14.7 集成测试、14.8 协议一致性或 14.9 回归脚本。
- Stage 14.6 module-level smoke 使用 BFM/model/mock contract 进行快速断言，不实例化所有 RTL 模块，也不替代已有细粒度 Cocotb targets。
- Stage 14.7 integration suite 使用 BFM/model/mock contract 串接 host-visible action、packet、DMA/memory、CQE、MSI-X 和 SR-IOV isolation 语义；它不实例化完整 `smartnic_top` RTL，不证明真实 PCIe credit、MAC timing、RoCEv2 wire compliance 或 ICRC 互操作。
- Stage 14.8 protocol compliance suite 检查 protocol-visible fields 和错误语义，但仍运行在 BFM/model 层；ACK/NAK/RNR retry 和 ICRC 使用当前可见接口/placeholder 语义，不替代后续真实 wire interoperability validation。
- Stage 14.9 regression runner 只编排已有 targets 和生成日志/summary；compatibility 和 coverage merge 能力以当前仓库可用工具为准，不伪造不存在的 simulator coverage 或 Python coverage merge。
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
- Packet parser 测试只验证 8.1/10.1 的首个 512-bit beat 字段提取和 ECN metadata 输出，不实现完整 IPv6 RoCEv2 layout、8.2 ingress validation、8.3 payload extraction、8.4 packet builder 或 8.5 ICRC 校验。
- Ingress validator 测试只验证 8.2 的 metadata 合法性裁决和 drop/accept ready/valid，不实现真实 checksum 计算器、payload extraction、packet builder 或 transport/QP 状态机。
- Payload extractor 测试只验证 8.3 的接口转换，不实现完整多 beat payload reassembly、真实 receive DMA 写入、第 9 阶段 transport 状态机或 packet builder。
- Packet builder 测试只验证 8.4 的单 beat header/payload frame 构造，不实现真实 ICRC、IPv4/UDP checksum、PMTU 多 beat packetization 或第 9 阶段 transport 语义。
- ICRC placeholder 测试只验证 8.5 的隔离占位行为，不实现真实 RoCEv2 invariant CRC，因此不能代表真实网络互操作兼容性。
- Stage 8 packet mock integration 测试只串联第 8 阶段的抽象语义，不实例化完整 RTL pipeline，不实现第 9 阶段 RC/UD transport，也不证明真实 RoCEv2 互操作。
- ECN/CNP/DCQCN/pacing/PFC congestion 测试只验证 10.1/10.2/10.3/10.4/10.5/10.6 的 CE mark propagation、CNP build request、CNP receive classification、per-QP rate update、token bucket allow/throttle 判定、PFC priority gate、malformed CNP drop 和轻量 counter，不发送真实 MAC/PFC control frame、不实现完整 TX scheduler，也不映射 CSR counter。
- smartnic_top / CSR fabric / Doorbell control / RC pipeline 结构测试只检查 11.1/11.2/11.3/11.4 的层次实例、边界命名、BAR2 CSR decode/fabric、BAR0 Doorbell 到 QP/CQ manager 的控制连接、最小 RC Send/Recv hook、packet builder mux 和 completion event 连接；真实 PCIe/DMA/MR/transport/CQ notification 端到端行为测试留给 11.7。
- RC send engine 测试只验证 9.1 的 send-side PSN、outstanding、ACK、retry 和 retry exhausted QP error 请求，不实现 9.2 receive-side PSN validation、NAK/RNR、9.3 RDMA Read sequencing 或完整 RC retry 语义。
- RC receive engine 测试只验证 9.2 的 receive-side PSN 顺序检查、duplicate/replay drop、gap NAK、ACK 合并和 RNR NAK，不实现 9.3 RDMA Read sequencing、完整 AETH syndrome/MSN 编码、RNR retry timer 或真实 RQ/DMA side effect。
- RC RDMA Read engine 测试只验证 9.3 的 requester/responder/response receive 最小序列，不实现多 outstanding table、真实 MR/DMA pipeline、PMTU 多响应分段、完整 retry/NAK replay 或 RoCEv2 wire-format 互操作。
- RC immediate engine 测试只验证 9.4 的 RC SEND_WITH_IMM/RDMA_WRITE_WITH_IMM immediate-data receive completion 语义，不实现 UD immediate、完整 multi-beat packet builder 或 CSR failure counters。
