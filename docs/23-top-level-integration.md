# Top-Level Integration

本文记录 11.1 阶段新增的 `smartnic_top` 顶层集成骨架。当前目标是建立清晰层次和稳定内部边界，不改变已有 PCIe、QP、CQ、MR、DMA、packet、transport、completion 或 congestion 子模块的功能。

## 顶层接口

`rtl/top/smartnic_top.sv` 暴露四类外部接口：

| 接口 | 作用 |
| --- | --- |
| `clk` / `rst_n` | 全局时钟和低有效复位 |
| `pcie_rx_*` / `pcie_tx_*` | 简化 PCIe TLP 流边界，11.2 后继续连接 BAR/CSR/DMA |
| `eth_rx_*` / `eth_tx_*` | 简化 512-bit RoCEv2 frame RX/TX 边界 |
| `pfc_event_*` | PFC PAUSE/RESUME 注入入口，后续可由 MAC control frame parser 驱动 |

顶层还暴露：

- `debug_qp_status`
- `debug_cq_status`
- `debug_transport_status`
- `debug_congestion_status`

这些 debug 信号只用于 11.1 的可观察性。后续 CSR/debugfs counter 映射属于 11.2 和 12.x。

## Reset

`smartnic_top` 使用两级同步寄存器生成 `core_rst_n`：

```text
rst_n -> rst_sync_1 -> rst_sync_2 -> core_rst_n
```

所有已实例化子模块使用同一个 `clk` 和 `core_rst_n`。后续若接入 PCIe/MAC 多时钟域，需要在对应 wrapper 中引入 CDC 和 per-block reset。

## 已实例化子系统

| 子系统 | 顶层实例 | 当前连接 |
| --- | --- | --- |
| PCIe subsystem | `u_pcie_endpoint` | 接入外部 PCIe RX/TX 边界，内部 BAR/CSR/DMA 仍 tie-off |
| Packet parser | `u_packet_parser` | 接收 `eth_rx_*`，输出 `packet_meta_t` |
| ECN marker | `u_ecn_marker` | 接收 parser metadata，输出 CE mark hook |
| CNP classifier | `u_cnp_classifier` | 接收 marked metadata，向 DCQCN 输出 `cnp_event_t` |
| CNP generator | `u_cnp_generator` | CE mark 触发 CNP `packet_build_req_t` |
| Packet builder | `u_packet_builder` | 当前构造 CNP frame 到 `eth_tx_*` |
| DCQCN | `u_dcqcn` | 接收 CNP event，输出 rate update |
| PFC scheduler gate | `u_pfc_scheduler` | 接收 PFC PAUSE/RESUME，控制 pacer 前置 backpressure |
| TX pacer | `u_tx_pacer` | 接收 DCQCN rate update 和 PFC gate 后的 pacing request |
| QP table | `u_qp_table` | 已实例化，CSR/Doorbell/transport lookup 留给 11.2-11.4 |
| CQ table | `u_cq_table` | 与 completion engine lookup 口已连接 |
| Completion engine | `u_completion_engine` | CQ lookup 已接入，completion event 源暂 tie-off |
| DMA dispatcher | `u_dma_dispatcher` | 已实例化，transport/DMA path 留给 11.4-11.6 |
| MR table | `u_mr_table` | 已实例化，DMA/MR lookup path 留给 11.5 |
| RC transport | `u_rc_send_engine` | 已实例化，SQ/packet/ACK 连接留给 11.4-11.5 |
| UD transport | `u_ud_tx_engine` | 已实例化，AH/packet path 留给 11.6 |

## 当前真实连接

11.1 阶段只建立少量安全连接：

```text
eth_rx -> packet_parser -> ecn_ingress_marker -> cnp_receive_classifier -> dcqcn
                                 |
                                 v
                           cnp_packet_generator -> packet_builder -> eth_tx

pfc_event -> pfc_pause_scheduler -> tx_pacer_token_bucket
dcqcn.rate_update ----------------^

completion_engine -> cq_context_table lookup
```

其余复杂路径使用 tie-off 或 ready 常量隔离，避免引入未验证的行为变化。

## 11.2 CSR Control Fabric

11.2 新增 BAR2 CSR 控制通路：

```text
bar2_csr_* -> csr_fabric -> csr_decode -> QP/CQ/MR/AH/MSI-X/SR-IOV/congestion CSR block
```

`smartnic_top` 现在暴露 `bar2_csr_req_*` 和 `bar2_csr_rsp_*` 端口，用于表示 PCIe BAR2 MMIO read/write 请求。`csr_fabric` 根据 BAR2 offset 选择一个内部寄存器块，并返回一拍读响应。

当前接入的目标块是最小 CSR register bank：

- QP manager CSR
- CQ manager CSR
- MR/MW manager CSR
- AH table CSR
- MSI-X control CSR
- SR-IOV control CSR
- Congestion/DCQCN/PFC CSR

这些 register bank 只验证 CSR 互联、32-bit 对齐访问、byte enable 写和 reset-to-zero 行为，不实现真实资源生命周期。真实 QP/CQ/MR/AH/MSI-X/SR-IOV/DCQCN 控制命令会在后续 top-level 和 driver 阶段继续接入。

## 11.3 Doorbell Control Path

11.3 新增 BAR0 Doorbell 控制通路：

```text
bar0_db_* -> doorbell_ctrl
          -> qp_context_table.sq_pi_update
          -> qp_context_table.rq_pi_update
          -> cq_context_table.cq_arm
```

`doorbell_ctrl` 复用已有 SQ/RQ/CQ arm Doorbell handler，不重新实现 payload 解析。SQ Doorbell 成功更新 QP SQ producer index 后产生 `sq_scheduler_valid`；RQ Doorbell 成功更新 RQ producer index 后产生 `rq_post_valid`。这两个信号是 11.4 连接 SQ/RQ engine 的 wakeup hint，当前阶段只保留接口。

CQ arm Doorbell 直接连接到 `cq_context_table`，用于更新 `consumer_index`、`armed` 和 `solicited_only`。

## 11.4 Minimal RC Send/Recv Loop

11.4 新增 `rc_pipeline_top`，用于把最小 RC Send/Recv 控制流接到 packet builder 和 completion engine：

```text
RC Send hook / SQ wakeup
  -> rc_pipeline_top
  -> DMA read hook
  -> packet builder
  -> eth_tx
  -> completion_engine
  -> CQE write hook

RC Recv hook
  -> rc_pipeline_top
  -> DMA write hook
  -> completion_engine
  -> CQE write hook
```

当前只支持单 active QP、单 packet per WR 和 RC Send 最小路径，不实现 retry/RNR/congestion/multi-QP arbitration。`rc_send_test_*` 和 `rc_recv_test_*` 是 11.4 的测试入口；真实 SQ WQE fetch、MR translation、host memory read/write、parser-driven RX 和 CQ notification 完整闭环留给 11.5-11.7。

## 后续任务边界

- 11.5：连接 RDMA Write / RDMA Read 数据路径。
- 11.6：连接 UD transmit / receive 数据路径。
- 11.7：增加 reset、CSR、Doorbell-to-CQE、RC/UD、MSI-X top-level tests。

## 验证

11.1 增加 `sim/cocotb/test_smartnic_top_structure.py`，用于检查：

- `smartnic_top.sv` 存在；
- 主要子系统实例都存在；
- reset 同步和 debug observability 存在；
- 关键层次边界有明确注释。

该测试是结构检查，不替代后续 11.7 的真实 top-level 行为测试。
