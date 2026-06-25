# RC Minimal Send/Recv Loop

本文记录 11.4 阶段新增的最小 RC Send/Recv loop。目标是把 QP、transport、packet、DMA、completion 和 CQ 管理器按固定顺序接起来，用于教学和后续 top-level 行为测试。

## Send Path

11.4 的 RC Send 顺序固定为：

```text
QP SQ / test hook
  -> rc_pipeline_top
  -> DMA read hook
  -> packet_build_req
  -> roce_packet_builder
  -> NIC TX
  -> completion_event
  -> completion_engine
  -> CQE write hook
  -> CQ commit/notify hook
```

当前只支持：

- 单 active QP
- 单 packet per WR
- opcode 固定为 RC Send
- QP state 假设已经是 RTS
- DMA read 使用 hook 表示，暂不做真实 MR translation 或 PCIe read
- 无 retry、RNR、拥塞控制、多 QP 仲裁

## Receive Path

11.4 的 RC Receive 顺序固定为：

```text
NIC RX / test hook
  -> rc_pipeline_top
  -> DMA write hook
  -> completion_event
  -> completion_engine
  -> CQE write hook
```

当前 receive path 使用 `rc_recv_test_*` 表示已经经过 packet parser 和 transport validation 的最小入站 Send payload。真实 parser -> RC receive engine -> RQ engine -> DMA write 细化留给后续集成测试和 11.7。

## Top-Level Test Hooks

`smartnic_top.sv` 新增两组测试 hook：

```text
rc_send_test_valid / ready
rc_send_test_qpn / cqn / owner_function / pd_id / wr_id / len / payload

rc_recv_test_valid / ready
rc_recv_test_qpn / cqn / owner_function / pd_id / wr_id / len / payload
```

这些 hook 让 11.4 可以在没有完整 driver、SQ WQE fetch、MR translation、host memory model 的情况下，验证 top-level 数据流方向和 metadata 保留。

## Packet Builder Mux

`smartnic_top` 现在将 CNP build request 和 RC Send build request 复用到同一个 `roce_packet_builder`：

```text
CNP build request ----+
                      +-> packet builder -> eth_tx
RC build request -----+
```

当前采用 CNP 优先。后续如果需要多个 TX source 的公平调度，应接入第 7.8 阶段 DMA/packet arbitration 或专门的 TX scheduler。

## Completion 和 CQ

`rc_pipeline_top` 生成 `completion_event_t`，并接入已有 `completion_engine`。completion engine 会按已有逻辑查询 CQ context 并格式化 64-byte CQE。11.4 只把 CQE write 输出作为 hook 暴露；真实 `cqe_write_path`、`cq_index_manager`、`cq_notification` 的完整 top-level 串联留给 11.7。

## TODO

- 将 `db_sq_scheduler_valid` 真正连接到 SQ engine，而不是通过测试 hook 形态进入 RC pipeline。
- 将 packet parser / RC receive engine 输出接到 receive path，而不是 `rc_recv_test_*`。
- 将 DMA hook 替换为 `dma_descriptor_dispatcher`、MR checker、host read/write path。
- 将 completion engine 的 CQE write 输出接入 `cqe_write_path` 和 `cq_notification`。
- 增加真实 CQ context 创建/写入流程，否则 completion lookup 会依赖测试或后续 CSR 初始化。
