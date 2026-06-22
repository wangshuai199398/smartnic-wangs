# RoCEv2 Transport Engine

本文档从第 9 阶段开始记录 RoCEv2 transport 层。9.1 只实现 RC send-side 的最小可验证骨架：PSN 分配、outstanding packet 记录、ACK 处理、retry timer 和 retry exhausted 后的 QP error 请求。

## 9.1 RC Send-Side Engine

`rtl/transport/rc_send_engine.sv` 位于 packet builder 和 SQ/DMA dispatch 之间：

```text
SQ engine / DMA payload dispatch
  -> transport_tx_req_t
  -> rc_send_engine
  -> transport_rc_packet_t
  -> roce_packet_builder
  -> MAC TX
```

ACK 路径来自后续 receive-side transport 或 packet parser：

```text
RX ACK metadata
  -> transport_ack_event_t
  -> rc_send_engine
  -> outstanding entry clear
```

## 输入输出接口

| 接口 | 方向 | 作用 |
| --- | --- | --- |
| `cfg_valid/cfg_ready` | input | 配置一个最小 RC send context，包括 QPN、owner function、PD、初始 PSN、retry limit 和 retry timeout。 |
| `tx_req_valid/tx_req_ready/tx_req` | input | 接收 SQ/DMA 发来的 transport TX 请求。 |
| `packet_valid/packet_ready/packet` | output | 输出首次发送的 RC packet request，交给 packet builder。 |
| `ack_valid/ack_ready/ack_event` | input | 接收 ACK 事件，按 ACK PSN 清理 outstanding packet。 |
| `timer_tick` | input | 推动 retry timer 递增。 |
| `retry_valid/retry_ready/retry_packet` | output | retry timeout 后重新发出已记录 packet。 |
| `qp_error_req_valid/qp_error_req_ready` | output | retry 耗尽后请求 QP cleanup/error transition。 |

所有请求都保留 `desc_id`、`qpn`、`cqn`、`owner_function`、`pd_id`、`opcode`、`status/error_code`，这样后续 completion、debug 和 QP cleanup 能继续追踪同一个 work request。

## PSN 分配

模块用 `next_psn_q` 保存 send-side 下一个 PSN。每接受一个 `tx_req`：

1. 使用当前 `next_psn_q` 填入 `transport_rc_packet_t.psn`。
2. 将 packet 记录到 outstanding window。
3. `next_psn_q += 1`。
4. 输出 `packet_valid` 给 packet builder。

当前实现按 packet 粒度分配一个 PSN。RDMA Read 分段、PMTU 多包 payload 和 PSN wraparound 的完整规则留给后续 transport 任务。

## Outstanding Tracking

9.1 使用小型固定深度 outstanding window：

```text
valid
packet metadata
timer
retries_left
```

当 window 满时，`tx_req_ready=0`，并通过 `debug_status=RC_SEND_STATUS_WINDOW_FULL` 暴露状态。后续可以将这个窗口扩展为 per-QP scoreboard 或与 QP context table 中的 retry state 融合。

## ACK Processing

`transport_ack_event_t` 包含：

- `qpn`
- `owner_function`
- `ack_psn`
- `retry_hint`

当前 ACK 行为是 cumulative ACK 的最小版本：同一 QPN 和 owner function 下，`packet.psn <= ack_psn` 的 outstanding entry 会被清除。若 ACK 没有命中任何 entry，模块输出 `RC_SEND_STATUS_ACK_MISS` 方便调试。

## Retry Timer

每个 outstanding entry 有独立 timer。`timer_tick=1` 时，所有 valid entry 的 timer 加一；当某个 entry 的 timer 达到 `retry_timeout_q`：

1. 如果 `retries_left != 0`，输出 `retry_packet`。
2. `retry_packet.is_retry=1`。
3. `retries_left` 减一。
4. entry timer 清零。

如果 `retries_left == 0`，模块输出 `qp_error_req_valid`，并携带 QPN、owner function、desc_id 和 `RC_SEND_STATUS_RETRY_EXHAUSTED`。

## 设计原因

RC 的可靠性需要三个最核心的 send-side 状态：PSN、outstanding window 和 retry state。把这三件事先独立成 `rc_send_engine`，可以让前面的 SQ/DMA/packet builder 不必知道 ACK 或重传细节，也让后续 9.2 的 receive-side ACK/NAK 逻辑能通过一个明确的事件接口接入。

## 当前 Stub/TODO

- TODO：当前只保存一个最小 RC send context，后续需要接 QP context table 的 per-QP PSN/retry state。
- TODO：PSN 比较暂未实现 24-bit wraparound aware compare。
- TODO：ACK 仅支持 cumulative ACK 清理，不支持 NAK syndrome、RNR NAK 或 selective retry。
- TODO：retry timer 使用外部 `timer_tick`，未接真实时间基准和 per-QP programmable timeout CSR。
- TODO：RDMA Read request/response sequencing、atomic、multi-packet payload 和 PMTU 分段留给后续 9.x/transport 任务。
- TODO：retry exhausted 只发出 QP error 请求，不直接修改 QP context；实际 cleanup 由 4.6 的 QP cleanup manager 负责。

