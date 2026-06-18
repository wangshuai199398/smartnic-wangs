# Cocotb 模块级单元测试

本目录存放 RDMA SmartNIC 的 Cocotb 模块级测试。当前阶段覆盖 PCIe endpoint/control-plane、Doorbell path、QP manager、CQ manager、MR manager 和 DMA dispatcher 的最小行为，不模拟完整 PCIe 链路、TLP credit、DMA completion、RoCEv2 transport 或主机内存模型。

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
| `test_dma_host_read_path.py` | `rtl/dma/dma_host_read_path.sv` | Send/RDMA Write protected segment 到 PCIe read request、read response 到 payload stream、tag/length/error 检查、payload backpressure、refcount release |
| `test_dma_host_write_path.py` | `rtl/dma/dma_host_write_path.sv` | Recv/RDMA Read response protected segment 和 payload stream 到 PCIe write request、write completion 到 done、tag/error 检查、write backpressure、refcount release |

## 运行方式

从仓库根目录运行：

```sh
make pcie-test
make doorbell-test
make qp-test
make cq-test
make mr-test
make dma-test
```

或直接进入本目录运行：

```sh
make -C sim/cocotb pcie-control-plane-tests
make -C sim/cocotb doorbell-tests
make -C sim/cocotb qp-tests
make -C sim/cocotb cq-tests
make -C sim/cocotb mr-tests
make -C sim/cocotb dma-tests
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
make -C sim/cocotb test-dma-host-write-path
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
- DMA host write path 测试只验证 protected segment 和 payload stream 到 PCIe write request 的转换、write completion、错误输出和 refcount release，不实现真实 PCIe memory write、跨 segment 拼接、PMTU/4KB split 或 completion error propagation。
