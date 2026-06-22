# DMA Engine Unit Tests

本文档描述 DMA Engine（第 7 阶段）所有测试的覆盖范围、测试分类和 mock/stub 情况。

运行方法：

```bash
# 运行全部 DMA 单元测试（需要 Verilator + cocotb）
cd sim/cocotb && make dma-tests

# 运行 DMA 集成测试（纯 Python, 无需 Verilator）
cd sim/cocotb && make test-dma-integration
# 或
python3 sim/cocotb/test_dma_integration.py

# 单独运行某个测试
cd sim/cocotb && make test-dma-descriptor-dispatcher
```

---

## 1. DMA Descriptor Dispatcher

**文件**: `sim/cocotb/test_dma_descriptor_dispatcher.py`  
**分类**: Unit Test  
**RTL 模块**: `rtl/dma/dma_descriptor_dispatcher.sv`

| 测试 | 覆盖内容 |
|------|----------|
| `test_sq_send_routes_to_host_read` | SQ Send opcode 路由到 host_read 路径 |
| `test_sq_rdma_write_routes_to_host_read` | RDMA Write opcode 路由到 host_read 路径 |
| `test_rq_recv_routes_to_host_write` | RQ Recv opcode 路由到 host_write 路径 |
| `test_rdma_read_response_routes_to_host_write` | RDMA Read Response 路由到 host_write |
| `test_cqe_write_routes_to_cqe_write_path` | CQE Write opcode 路由到 cqe_write 路径 |
| `test_wqe_fetch_routes_to_fetch_path` | WQE Fetch opcode 路由到 fetch 路径 |
| `test_sge_fetch_routes_to_fetch_path` | SGE Fetch opcode 路由到 fetch 路径 |
| `test_unsupported_opcode_rejected` | 不支持的 opcode → UNSUPPORTED 错误 |
| `test_zero_length_non_nop_rejected` | 非 NOP 零长度 → LENGTH 错误 |
| `test_nop_zero_length_accepted` | NOP 零长度不产生错误或输出 |
| `test_owner_function_out_of_range_rejected` | owner_function 越界 → FUNCTION 错误 |
| `test_direction_mismatch_rejected` | opcode-direction 不匹配 → DIRECTION 错误 |
| `test_simultaneous_inputs_cqe_highest_priority` | CQE > RQ > SQ > WQE > SGE 固定优先级 |
| `test_rq_priority_over_sq` | RQ 优先于 SQ |
| `test_sq_priority_over_wqe_fetch` | SQ 优先于 WQE fetch |
| `test_wqe_fetch_priority_over_sge_fetch` | WQE fetch 优先于 SGE fetch |
| `test_host_read_backpressure_holds_descriptor` | host_read backpressure 时 descriptor 保持 |
| `test_host_write_backpressure_holds_descriptor` | host_write backpressure 时 descriptor 保持 |
| `test_fetch_backpressure_holds_descriptor` | fetch backpressure 时 descriptor 保持 |
| `test_rdma_read_req_opcode_no_routed_output` | RDMA Read Request 不路由到任何输出 |

**Mock/Stub**: 无 — 直接驱动 RTL 输入/输出信号, 不需要 PCIe BFM。

---

## 2. WQE/SGE Fetcher

**文件**: `sim/cocotb/test_dma_wqe_sge_fetcher.py`  
**分类**: Unit Test  
**RTL 模块**: `rtl/dma/dma_wqe_sge_fetcher.sv`

| 测试 | 覆盖内容 |
|------|----------|
| `sq_wqe_fetch_address_is_calculated` | SQ WQE 地址 = base + index × stride |
| `rq_wqe_fetch_address_is_calculated` | RQ WQE 地址计算 |
| `wqe_stride_zero_and_host_read_error_are_reported` | stride=0 → STRIDE_ZERO; host read error → HOST_READ |
| `inline_sge_and_extended_sge_address_are_decoded` | inline SGE 派生, extended SGE list 地址解码 |
| `extended_sge_fetch_single_and_multiple_entries` | 单个 SGE 和多个 SGE 逐项 emit + list_done |
| `sge_count_limits_and_fetch_error_are_reported` | count=0 → COUNT_ZERO; count>256 → TOO_MANY; read error → HOST_READ |
| `sge_count_256_is_accepted_and_response_backpressure_holds` | 256 SGE 成功, backpressure 保持 SGE entry 不丢 |

**Mock/Stub**: 以 `host_read_resp_*` 信号模拟 host memory read response, 不连接真实 PCIe BFM。

---

## 3. SGE Traversal

**文件**: `sim/cocotb/test_dma_sge_traversal.py`  
**分类**: Unit Test  
**RTL 模块**: `rtl/dma/dma_sge_traversal.sv`

| 测试 | 覆盖内容 |
|------|----------|
| `test_single_sge_total_len_match` | 单个 SGE, 长度匹配 expected_total_len |
| `test_multi_sge_total_len_match` | 多个 SGE, byte_offset 累加正确 |
| `test_256_sges_success` | **256 SGE** 依次成功, byte_offset 对齐 |
| `test_zero_length_sge_rejected` | SGE length=0 → ZERO_LENGTH 错误 |
| `test_total_length_underrun` | last SGE 时累计长度 < expected → LENGTH_UNDERRUN |
| `test_total_length_overrun` | 累计长度 > expected → LENGTH_OVERRUN |
| `test_adjacent_ranges_do_not_overlap` | 相邻范围 (end == start) 不触发 overlap |
| `test_overlapping_ranges_rejected` | 范围重叠 → OVERLAP 错误 |
| `test_address_plus_length_overflow_rejected` | addr + length 溢出 → ADDR_OVERFLOW |
| `test_sge_index_must_be_monotonic` | index 非单调递增 → INDEX_ORDER 错误 |
| `test_sge_index_over_255_rejected` | index > 255 → INDEX_RANGE 错误 |
| `test_segment_backpressure_holds_current_sge` | dma_segment_ready=0 时 segment 保持不丢 |
| `test_byte_offset_outputs_accumulated_length` | byte_offset 随 SGE 累加正确输出 |
| `test_total_length_overflow_rejected` | 总长度超 32-bit → TOTAL_OVERFLOW |

**Mock/Stub**: 无 — 直接驱动 SGE stream 输入, 不依赖真实 SGE fetch。

---

## 4. MR Integration

**文件**: `sim/cocotb/test_dma_mr_integration.py`  
**分类**: Unit Test  
**RTL 模块**: `rtl/dma/dma_mr_integration.sv` (依赖 mr_key_checker, mr_access_checker, mr_pd_checker)

| 测试 | 覆盖内容 |
|------|----------|
| `test_local_send_segment_uses_lkey_local_read` | 本地 Send 使用 lkey + LOCAL_READ 权限 |
| `test_rdma_write_payload_read_uses_lkey_local_read` | RDMA Write 本地读用 lkey |
| `test_recv_segment_uses_lkey_local_write` | Recv 写入用 lkey + LOCAL_WRITE 权限 |
| `test_remote_rdma_write_uses_rkey_remote_write` | 远端 RDMA Write 使用 rkey + REMOTE_WRITE |
| `test_remote_rdma_read_uses_rkey_remote_read` | 远端 RDMA Read 使用 rkey + REMOTE_READ |
| `test_local_path_using_rkey_rejected` | 本地路径用 rkey → **KEY_DIRECTION 拒绝** |
| `test_remote_path_using_lkey_rejected` | 远端路径用 lkey → **KEY_DIRECTION 拒绝** |
| `test_access_flags_insufficient_rejected` | 访问权限不足 → **ACCESS_DENIED 拒绝** |
| `test_pd_mismatch_rejected` | MR PD ≠ QP PD → **PD_MISMATCH 拒绝** |
| `test_va_bounds_error_rejected` | VA 越界 → BOUNDS 拒绝 |
| `test_pending_deregister_rejected` | MR 正在注销 → PENDING 拒绝 |
| `test_memory_window_remote_access_success` | Memory Window 远端访问成功 |
| `test_memory_window_invalidating_rejected` | MW invalidating → MW_INVALIDATING 拒绝 |
| `test_refcount_overflow_rejected` | refcount 溢出 → REFCOUNT_OVERFLOW 拒绝 |
| `test_protected_segment_backpressure_holds_segment` | protected_segment backpressure 保持 |
| `test_lookup_miss_rejected` | key lookup miss → **LOOKUP_MISS 拒绝** |
| `test_owner_function_mismatch_rejected` | owner_function 不匹配 → PERMISSION 拒绝 |
| `test_zero_segment_length_rejected` | segment length=0 → ZERO_LENGTH 错误 |

**Mock/Stub**: 以 `mr_check_*` 和 `mr_ref_update_*` 信号 mock MR table 的 key/access/PD/refcount 响应, 不连接真实 MR table。

---

## 5. Segment Splitter

**文件**: `sim/cocotb/test_dma_segment_splitter.py`  
**分类**: Unit Test  
**RTL 模块**: `rtl/dma/dma_segment_splitter.sv`

| 测试 | 覆盖内容 |
|------|----------|
| `test_segment_smaller_than_pmtu_and_not_crossing_page_is_not_split` | 小型 segment 不做拆分 |
| `test_segment_larger_than_pmtu_is_split_by_pmtu` | PMTU=1024, 2500B → 3 splits (1024+1024+452) |
| `test_pa_near_4kb_boundary_splits_by_page_remaining` | PA=0x0F00, 512B → 2 splits (256+256) |
| `test_pmtu_and_4kb_boundary_take_minimum` | PMTU=512, PA=0x0E00, 1200B → 3 splits (512+512+176) |
| `test_max_dma_segment_bytes_limit_applies` | max=300, 700B → 3 splits (300+300+100) |
| `test_4kb_aligned_pa_has_4096_page_remaining` | PA 4KB 对齐, 4096B → 1 split |
| `test_wqe_last_only_on_final_split_when_input_is_last` | WQE last 标志仅在最后一个 split 输出 |
| `test_wqe_last_not_set_when_input_is_not_last` | is_last=0 时所有 split 的 wqe_last=0 |
| `test_zero_length_rejected` | length=0 → ZERO_LENGTH |
| `test_illegal_pmtu_rejected` | PMTU=1536 (非法) → PMTU_CONFIG |
| `test_split_ready_backpressure_holds_current_split` | split_segment_ready=0 时 split 保持 |

**Mock/Stub**: 无 — 直接配置 pmtu/enable 信号, 不依赖真实 PCIe TLP。

---

## 6. Host Read Path

**文件**: `sim/cocotb/test_dma_host_read_path.py`  
**分类**: Unit Test  
**RTL 模块**: `rtl/dma/dma_host_read_path.sv`

| 测试 | 覆盖内容 |
|------|----------|
| `test_send_protected_segment_issues_pcie_read` | protected segment → PCIe read request |
| `test_rdma_write_payload_read_issues_pcie_read` | RDMA Write payload read 发出 PCIe read |
| `test_read_response_becomes_payload_stream` | read response → payload stream 转换 |
| `test_byte_offset_and_segment_index_are_preserved` | byte_offset / segment_index 透传 |
| `test_last_segment_sets_payload_wqe_last` | is_last=1 → payload_wqe_last=1 |
| `test_zero_length_rejected_and_ref_dec_issued` | length=0 → 错误 + ref_dec |
| `test_unsupported_operation_rejected` | 非 host-read operation → UNSUPPORTED_OP |
| `test_pcie_read_response_error_enters_error_path` | response error → **RESP_ERROR** |
| `test_response_tag_mismatch_rejected` | tag mismatch → **TAG_MISMATCH** |
| `test_payload_ready_backpressure_does_not_drop_data` | payload backpressure 数据不丢 |
| `test_read_completion_releases_mr_refcount` | 完成释放 MR refcount |
| `test_segment_larger_than_max_read_is_split` | 64B segment → 2 chunks (32B+32B) |

**Mock/Stub**: 以 `pcie_read_resp_*` 信号 mock PCIe/DMA read completion, 不连接真实 PCIe Root Complex。

---

## 7. Host Write Path

**文件**: `sim/cocotb/test_dma_host_write_path.py`  
**分类**: Unit Test  
**RTL 模块**: `rtl/dma/dma_host_write_path.sv`

| 测试 | 覆盖内容 |
|------|----------|
| `test_recv_segment_and_payload_issue_pcie_write` | Recv segment + payload → PCIe write |
| `test_rdma_read_response_segment_issues_pcie_write` | RDMA Read Resp → PCIe write |
| `test_byte_offset_and_segment_index_are_preserved` | byte_offset/segment_index 透传 |
| `test_write_completion_generates_write_done` | PCIe write completion → write_done |
| `test_zero_segment_length_rejected` | segment length=0 → ZERO_SEGMENT_LEN |
| `test_zero_payload_length_rejected` | payload length=0 → ZERO_PAYLOAD_LEN |
| `test_payload_desc_id_mismatch_rejected` | desc_id mismatch → PAYLOAD_MISMATCH |
| `test_payload_exceeding_segment_length_rejected` | payload > segment → **BOUNDS 错误** |
| `test_write_address_overflow_rejected` | write addr overflow → ADDR_OVERFLOW |
| `test_pcie_write_completion_error_enters_error_path` | completion error → **CPL_ERROR** |
| `test_completion_tag_mismatch_rejected` | tag mismatch → **TAG_MISMATCH** |
| `test_write_req_backpressure_does_not_drop_payload` | write req backpressure 数据不丢 |
| `test_write_completion_releases_mr_refcount` | 完成释放 MR refcount |

**Mock/Stub**: 以 `pcie_write_cpl_*` 信号 mock PCIe/DMA write completion, 不连接真实 PCIe Root Complex。

---

## 8. DMA Arbiter

**文件**: `sim/cocotb/test_dma_arbiter.py`  
**分类**: Unit Test  
**RTL 模块**: `rtl/dma/dma_arbiter.sv`

| 测试 | 覆盖内容 |
|------|----------|
| `test_single_source_valid_grants_immediately` | 单个 source 立即 grant |
| `test_fixed_priority_prefers_cqe_write` | 固定优先级: CQE > RQ > SQ |
| `test_round_robin_rotates_between_sources` | **Round-robin 轮转** → SQ → RQ |
| `test_round_robin_skips_invalid_source` | RR 跳过 invalid source |
| `test_weight_zero_source_is_disabled_for_wrr` | WRR: weight=0 → source disabled |
| `test_weighted_round_robin_basic_weight_behavior` | WRR: weight=2 vs weight=1 → 2:1 比例 |
| `test_grant_ready_backpressure_holds_grant` | grant backpressure 保持 |
| `test_unselected_source_ready_is_zero` | 未选中 source 的 ready=0 |
| `test_last_grant_source_updates_after_accept` | debug_last_grant_source 更新 |
| `test_starvation_counter_increases_for_waiting_source` | **starvation detection** counter 递增 |
| `test_starvation_guard_promotes_waiting_source` | STRICT_GUARD 提升 starvation source |

**Mock/Stub**: 无 — 直接驱动 vectorized 请求信号, 不连接真实 QP/transport 数据通路。

---

## 9. DMA Error Propagation

**文件**: `sim/cocotb/test_dma_error_propagation.py`  
**分类**: Unit Test  
**RTL 模块**: `rtl/dma/dma_error_propagation.sv`

| 测试 | 覆盖内容 |
|------|----------|
| `test_mr_lookup_miss_maps_to_local_protection` | LOOKUP_MISS → **CMPL_LOC_PROT_ERR** |
| `test_access_denied_maps_to_local_protection` | ACCESS_DENIED → CMPL_LOC_PROT_ERR |
| `test_remote_access_denied_maps_to_remote_access` | 远端 ACCESS_DENIED → **CMPL_REM_ACCESS_ERR** |
| `test_bounds_error_maps_to_local_length` | BOUNDS → CMPL_LOC_LEN_ERR |
| `test_sge_length_overrun_maps_to_local_length` | SGE_LENGTH → CMPL_LOC_LEN_ERR |
| `test_wqe_fetch_error_maps_to_work_request_error` | WQE_FETCH → CMPL_LOC_QP_OP_ERR |
| `test_unsupported_opcode_maps_to_work_request_error` | UNSUPPORTED_OPCODE → CMPL_LOC_QP_OP_ERR |
| `test_pcie_read_error_maps_to_dma_access_error` | PCIE_READ → **CMPL_DMA_ERR** |
| `test_pcie_write_error_maps_to_dma_access_error` | PCIE_WRITE → CMPL_DMA_ERR |
| `test_cq_overflow_maps_to_cq_overflow_error` | CQ_OVERFLOW → CMPL_CQ_OVERFLOW_ERR |
| `test_fatal_error_generates_qp_error_request` | **fatal error → QP error request** |
| `test_non_fatal_error_only_generates_completion` | 非 fatal → 仅 completion |
| `test_completion_ready_backpressure_holds_error_event` | completion backpressure 保持 |
| `test_multiple_sources_choose_fatal_first` | 多个 error → **fatal 优先** |
| `test_multiple_nonfatal_sources_choose_mr_protection_first` | 非 fatal 时 MR 保护错误优先 |

**Mock/Stub**: 以 vectorized error 信号注入错误, mock 上游子模块的错误输出接口。

---

## 10. DMA Integration Test

**文件**: `sim/cocotb/test_dma_integration.py`  
**分类**: **Integration Test (mock/stub)**  
**RTL 模块**: 无 (纯 Python mock/stub)

| 测试 | 覆盖内容 |
|------|----------|
| `test_all_error_codes_map_to_known_completion_status` | 16 个 DMA error code → completion status 映射 |
| `test_single_sge_valid` | 单个 SGE 校验通过 |
| `test_multi_sge_valid` | 多个 SGE 校验通过 |
| `test_256_sge_valid` | **256 SGE 全通过** |
| `test_sge_overlap_rejected` | SGE overlap 被正确拒绝 |
| `test_sge_length_underrun` | length underrun 被检测 |
| `test_sge_length_overrun` | length overrun 被检测 |
| `test_mr_permission_denied` | MR 权限不足被拒绝 |
| `test_mr_pd_mismatch` | PD 不匹配被拒绝 |
| `test_mr_key_not_found` | key 未找到 → LOOKUP_MISS |
| `test_4kb_boundary_split` | 4KB 边界在 256B 处正确拆分 |
| `test_pmtu_split` | PMTU=1024, 2500B → 1024+1024+452 |
| `test_pmtu_and_4kb_combined` | PMTU + 4KB 组合限制取 min |
| `test_round_robin_fairness` | RR: 3 source × 6 grant → 每个 2 次 |
| `test_round_robin_one_source` | 单个 source 返回唯一可用 source |
| `test_dispatcher_routing` | 所有 opcode → route 映射正确 |
| `test_end_to_end_send_flow` | **完整 Send 流程**: dispatcher → SGE traversal → MR check → splitter |

---

## 测试分类总结

| 分类 | 文件 | 依赖硬件 | 说明 |
|------|------|----------|------|
| Unit Test | test_dma_descriptor_dispatcher.py | Verilator | 直接驱动 RTL 信号 |
| Unit Test | test_dma_wqe_sge_fetcher.py | Verilator | mock host read response |
| Unit Test | test_dma_sge_traversal.py | Verilator | 直接驱动 SGE stream |
| Unit Test | test_dma_mr_integration.py | Verilator | mock MR table 响应 |
| Unit Test | test_dma_segment_splitter.py | Verilator | 直接配置 PMTU/enable |
| Unit Test | test_dma_host_read_path.py | Verilator | mock PCIe read response |
| Unit Test | test_dma_host_write_path.py | Verilator | mock PCIe write completion |
| Unit Test | test_dma_arbiter.py | Verilator | 直接驱动 vectorized 请求 |
| Unit Test | test_dma_error_propagation.py | Verilator | inject vectorized error 信号 |
| Integration Test | test_dma_integration.py | **无** (Python mock) | 跨模块接口协议验证 |

## Mock / Stub 汇总

以下组件在所有 DMA 测试中均为 mock 或 stub, 未实现真实硬件:

| 组件 | 状态 | 说明 |
|------|------|------|
| PCIe Root Complex | **Stub** | 以 `pcie_read_resp_*` 和 `pcie_write_cpl_*` 信号 mock |
| IOMMU | **未实现** | DMA 地址转换使用 MR 表的 VA→PA, 不经过 IOMMU |
| RoCEv2 Transport | **未实现** | packet parser/builder/roce_engine 不在 DMA 测试范围 |
| PCIe BFM | **Stub** | 无完整 PCIe 协议建模 |
| Host Memory Model | **Stub** | 以 Python 值 mock MR 表内容 |
| 真实 DMA/PCIe TLP | **Stub** | ready/valid 握手代替真实 TLP 传输 |
| Completion Engine | **Stub** | 仅在 error propagation 测试中 mock completion event 接收端 |
| QP Manager | **Stub** | WQE opcode/sge_count/lkey 等字段由测试直接提供 |
| MR Table | **Mock** | 以 `mr_check_rsp_*` 和 `mr_ref_update_rsp_*` 信号 mock |

## 测试数量统计

| 模块 | 测试数量 |
|------|----------|
| DMA Descriptor Dispatcher | 20 |
| WQE/SGE Fetcher | 7 |
| SGE Traversal | 14 |
| MR Integration | 18 |
| Segment Splitter | 11 |
| Host Read Path | 12 |
| Host Write Path | 13 |
| DMA Arbiter | 11 |
| Error Propagation | 15 |
| Integration (mock) | 17 |
| **总计** | **138** |
