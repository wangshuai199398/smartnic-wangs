# UD Datapath Top-Level Integration

本文记录 11.6 阶段新增的 UD transmit / receive 顶层连接。目标是把 9.x 已完成的 `ud_tx_engine`、`ud_rx_engine` 和 `ah_table` 接入 `smartnic_top` 的 packet、DMA、QP lookup 和 completion 边界。

## 新增模块

```text
rtl/transport/ud_datapath_top.sv
```

该 wrapper 内部实例化：

- `ah_table`：保存 destination MAC/IP/UDP port、P_Key、Q_Key、GID-derived metadata 和 service level。
- `ud_tx_engine`：执行 AH lookup、生成 BTH/DETH metadata、产生本地 send completion。
- `ud_rx_engine`：解析 UD metadata、校验 Q_Key、读取目标 QP context、消费 RQ stub、产生 receive completion。

## UD Transmit Path

当前最小 TX 路径如下：

```text
ud_tx_test_valid
  -> ud_datapath_top
  -> tx_dma_read_valid
  -> ud_tx_engine
  -> ah_table lookup
  -> packet_build_req_t(opcode=ROCE_OPCODE_UD_SEND_ONLY, DETH qkey/source_qpn)
  -> roce_packet_builder
  -> completion_event_t(opcode=RDMA_OP_SEND)
  -> completion_engine
```

UD 不维护 RC connection state，不等待 ACK，不做 retry/RNR。packet builder 负责把 `packet_build_req_t.qkey` 和 `src_qpn` 放入 DETH。

## UD Receive Path

当前最小 RX 路径如下：

```text
eth_rx
  -> roce_packet_parser
  -> ecn_ingress_marker
  -> marked_meta(opcode=ROCE_OPCODE_UD_SEND_ONLY)
  -> ud_datapath_top
  -> ud_rx_engine
  -> qp_context_table context_read
  -> Q_Key validation
  -> rx_dma_write_valid
  -> RQ consume hook
  -> completion_event_t(source_qpn in vendor_error)
  -> completion_engine
```

`ud_rx_engine` 已经把 DETH source QPN 保存在 `ud_rx_completion_t.source_qpn`，并把该值放入 completion event 的 `vendor_error` 字段，作为后续 Verbs `wc.src_qp` / CQE parser 的最小传递路径。

## Packet / Completion Mux

`smartnic_top` 的 packet builder 输入现在按固定优先级复用：

```text
CNP > RC Send/Recv > RDMA Write/Read > UD Send
```

completion engine 输入现在按固定优先级复用：

```text
RC completion > RDMA completion > UD completion
```

11.6 这样设计，是为了不改变已经完成的 RC、RDMA one-sided 和 CNP 行为，同时把 UD 作为第四条可验证路径接入顶层。

## Error Counters

`ud_datapath_top` 暴露：

- `ud_rx_counters.invalid_deth`
- `ud_rx_counters.qkey_mismatch`
- `ud_rx_counters.missing_rq_wqe`
- `ud_rx_counters.malformed`
- `ah_lookup_fail_count`

其中 invalid destination QPN 目前归入 `UD_RX_STATUS_QP_ERROR` / malformed-style drop 路径。后续若需要独立 Verbs/debugfs counter，可以在 `ud_rx_counters_t` 中拆出 `invalid_dest_qpn`。

## 当前 Stub / TODO

- TODO：TX payload 当前由 `ud_tx_test_payload` 直接提供；真实路径应由 SQ WQE + SGE/MR + DMA read response 填充。
- TODO：RX RQ WQE 当前由 `ud_rx_rq_*` hook 提供；真实路径应接 `rq_engine` / QP RQ context。
- TODO：RX payload 当前由 parser metadata 和 `eth_rx_data` 单 beat 构造；真实 payload extractor 多 beat 接入留给 11.7/14.x。
- TODO：CQE 中 source QPN 目前通过 `vendor_error` 传递，后续可扩展正式 CQE field 或 CQE parser 映射。
- TODO：不支持 multicast、GRH generation、UD receive multicast group、真实 TX scheduler pacing。

## 验证

新增结构测试：

```text
sim/cocotb/test_ud_datapath_top_structure.py
```

该测试检查：

- `ud_datapath_top` 存在并实例化 AH table、UD TX、UD RX；
- TX path 包含 DMA read、AH lookup、packet builder 和 completion；
- RX path 包含 parser metadata、QP lookup、RQ hook、DMA write、completion 和 drop counters；
- `smartnic_top` 已把 UD packet / completion 纳入 mux；
- `tasks.md` 已将 11.6 标记完成。
