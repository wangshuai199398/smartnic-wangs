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

## 9.2 RC Receive-Side Engine

`rtl/transport/rc_recv_engine.sv` 位于 8.x payload extractor 和后续 RQ/DMA/remote operation 处理之间：

```text
roce_payload_extractor
  -> packet_meta_t + packet_payload_stream_t
  -> rc_recv_engine
  -> accepted payload to RQ/DMA/remote op path
```

只有通过 receive-side PSN 和 RQ 可用性检查的 packet 才会从 `accept_valid` 输出。duplicate、gap、RNR 或 unsupported opcode 都会走 drop/debug 路径，避免错误 packet 在主机内存上产生 DMA 副作用。

### 接口

| 接口 | 方向 | 作用 |
| --- | --- | --- |
| `cfg_valid/cfg_ready` | input | 配置一个最小 RC receive context，包括 QPN、owner function、PD、expected PSN、ACK 合并阈值和 timeout。 |
| `rx_meta_valid/rx_meta_ready/rx_meta` | input | 接收 packet parser/payload extractor 输出的入站 metadata。 |
| `rx_payload_valid/rx_payload_ready/rx_payload` | input | 接收与 metadata 对应的 payload beat。 |
| `rq_buffer_available` | input | 表示 Send/Send with Imm 是否有可用 RQ buffer；没有则生成 RNR NAK。 |
| `accept_valid/accept_ready` | output | PSN/RQ 检查通过后放行 packet metadata 和 payload。 |
| `ack_event_valid/ack_event_ready` | output | 输出 ACK、sequence NAK 或 RNR NAK 事件。 |
| `drop_valid/drop_ready` | output | 输出 duplicate/replay、gap、RNR、unsupported opcode 等 drop/debug 事件。 |

### PSN Validation

当前最小版本用 `expected_psn_q` 表示下一个期望接收的 PSN：

| 条件 | 行为 |
| --- | --- |
| `packet.psn == expected_psn` | packet in-order，允许进入 `accept_valid`，并在接受后 `expected_psn += 1`。 |
| `packet.psn < expected_psn` | duplicate/replay，drop，不放行 payload，重新 ACK `last_acked_psn`。 |
| `packet.psn > expected_psn` | gap，drop，不放行 payload，生成 sequence NAK，指向当前 `expected_psn`。 |

TODO：PSN 比较目前是普通数值比较，尚未实现 24-bit wraparound aware compare。

### RNR NAK

Send 和 Send with Immediate 需要远端 RQ buffer。如果 `rq_buffer_available=0`，模块生成 RNR NAK，并 drop 当前 packet。RDMA Write 和 RDMA Read Request 不消耗 RQ buffer，因此不会因为 RQ 为空触发 RNR。

### ACK Coalescing

模块保存 `pending_ack_count_q` 和 `ack_timer_q`：

- `cfg_ack_coalesce_count <= 1` 时，每个成功接收的 packet 都会尽快 ACK。
- `pending_ack_count >= cfg_ack_coalesce_count` 时，输出 ACK。
- `cfg_ack_timeout != 0` 且 timer 到期时，输出 ACK。

当前 ACK event 使用 `transport_rx_ack_event_t`，保留 `desc_id`、`qpn`、`cqn`、`owner_function`、`pd_id`、`opcode`、`status/error_code`，并提供最小 AETH placeholder 给后续 packet builder。

### 当前 Stub/TODO

- TODO：当前只保存一个最小 receive context，后续需要接 QP context table 的 per-QP `rq_psn`。
- TODO：AETH syndrome/MSN 只是 placeholder，后续按 IBTA/RoCEv2 完整编码。
- TODO：ACK coalescing 是基础 count/timer 模型，未实现真实 ACK scheduler 或 multi-QP arbitration。
- TODO：RNR retry 计数、RNR timer、receiver not ready 状态机留给后续 transport/QP 集成。
- TODO：RDMA Read request/response sequencing 和 remote memory access side effect 留给 9.3。

## 9.3 RDMA Read Request / Response Sequencing

`rtl/transport/rc_rdma_read_engine.sv` 实现 RDMA Read 的三个最小半边：

```text
Requester SQ RDMA_READ descriptor
  -> rc_rdma_read_engine
  -> RDMA Read Request packet_build_req_t
  -> packet builder / MAC TX

Responder inbound Read Request
  -> MR remote read check
  -> DMA host read
  -> RDMA Read Response packet_build_req_t
  -> packet builder / MAC TX

Requester inbound Read Response
  -> outstanding read context match
  -> response PSN / length check
  -> local buffer write request
  -> completion_event_t
```

### Requester Side

Requester 输入使用 `rc_rdma_read_req_t`，保留：

- `desc_id`
- `qpn`
- `cqn`
- `owner_function`
- `pd_id`
- `wr_id`
- `remote_qpn`
- `request_psn`
- `expected_resp_psn`
- `local_va/local_lkey`
- `remote_va/remote_rkey`
- `length`
- `retry/rnr_retry` 预留字段

当前最小实现只支持一个 outstanding Read context。接收合法请求后会：

1. 检查 `qp_type == QP_TYPE_RC`。
2. 检查 requester QP state 为 `RTS`。
3. 构造 `ROCE_OPCODE_RDMA_READ_REQ` 的 `packet_build_req_t`。
4. 保存 outstanding context，用于后续 response 匹配、local write 和 completion。

### Responder Side

Responder 侧接收入站 `ROCE_OPCODE_RDMA_READ_REQ` metadata，使用外部 QP context snapshot 检查：

- responder context valid；
- QP type 为 RC；
- QP state 为 RTR 或 RTS。

通过后，模块发起 MR check：

```text
rkey + remote_va + length + owner_function + pd_id
```

MR check 通过后发起 DMA host read；DMA 返回 payload 后构造 `ROCE_OPCODE_RDMA_READ_RESP`。当前只输出单个 response packet，并保留 `read_response_first/middle/last/only` 标志，后续可扩展成 PMTU 分段 response。

### Response Receive Side

Requester 收到 Read Response 后，使用 outstanding context 检查：

| 检查项 | 当前行为 |
| --- | --- |
| outstanding valid | 不存在则生成 `CMPL_BAD_RESP_ERR`。 |
| response PSN | 必须等于 `next_resp_psn`。 |
| response length | 不能为 0，不能超过剩余请求长度。 |
| local write | 输出 `rc_rdma_read_local_write_t`，由后续 DMA host write path 消费。 |
| completion | 所有 response 字节到达后输出 `completion_event_t`。 |

多 response packet 通过 `next_resp_psn += 1` 和 `received_len += valid_bytes` 追踪。当前还没有完整 retry/NAK 重传，PSN mismatch 会直接生成 completion error。

### 错误映射

| 错误 | 当前输出 |
| --- | --- |
| QP type/state invalid | `CMPL_LOC_QP_OP_ERR` |
| MR permission denied | `CMPL_REM_ACCESS_ERR` |
| PD mismatch | `CMPL_LOC_PROT_ERR` |
| response PSN mismatch | `CMPL_BAD_RESP_ERR` |
| response length mismatch | `CMPL_LOC_LEN_ERR` |
| DMA read error | `CMPL_DMA_ERR` |
| local write/DMA write error | 预留 `RC_READ_STATUS_DMA_WRITE_ERR`，后续接 host write completion。 |
| outstanding full | `CMPL_LOC_QP_OP_ERR` |

### 当前 Stub/TODO

- TODO：当前只支持一个 outstanding Read context；后续需要 per-QP outstanding table。
- TODO：response first/middle/last/only 标志目前固定为 single response，占位给 PMTU 分段 response。
- TODO：responder read response PSN 只是 `request.psn + 1` 的占位策略，后续应来自 QP send PSN allocator。
- TODO：local write 只输出请求结构，不等待真实 host write completion。
- TODO：MR check/DMA read 通过外部 ready/valid stub 接口接入，未实例化完整 MR/DMA pipeline。
- TODO：retry exhausted、NAK replay、RNR retry 和 remote error packet 留给后续 transport 任务。

## 9.4 SEND/RDMA_WRITE With Immediate

`rtl/transport/rc_immediate_engine.sv` 处理 RC immediate-data 语义：

```text
SQ dispatch SEND_WITH_IMM / RDMA_WRITE_WITH_IMM
  -> rc_immediate_engine
  -> packet_build_req_t(has_imm=1, imm_data)
  -> packet builder

RX SEND_WITH_IMM
  -> RQ availability check
  -> receive completion_event_t(has_imm=1)

RX RDMA_WRITE_WITH_IMM
  -> remote memory write validation/write
  -> RQ availability check
  -> receive completion_event_t(has_imm=1)
```

### Opcode Handling

已有 `wqe_t.imm_data` 是 32 bit。9.4 后：

| WQE opcode | Transport behavior |
| --- | --- |
| `RDMA_OP_SEND_WITH_IMM` | 生成 `ROCE_OPCODE_SEND_ONLY_IMM`，设置 `has_imm=1`。 |
| `RDMA_OP_RDMA_WRITE_WITH_IMM` | 生成 `ROCE_OPCODE_RDMA_WRITE_ONLY_IMM`，设置 `has_imm=1`。 |
| `RDMA_OP_SEND` | 普通 Send，不设置 immediate flag。 |
| `RDMA_OP_RDMA_WRITE` | 普通 RDMA Write，不生成 receive CQE。 |

`sq_engine` 已把 `RDMA_OP_RDMA_WRITE_WITH_IMM` 归入 DMA/write 类路径，普通 `RDMA_WRITE` 语义不变。

### Immediate Data Byte Order

Immediate data 固定 32 bit。packet builder 对 ImmDt 按 network byte order 拼接：

```text
imm_data[31:24], imm_data[23:16], imm_data[15:8], imm_data[7:0]
```

因此测试值 `0x11223344` 在 packet representation 和 receive CQE 中保持同一个语义值。

### Receive Completion

`completion_event_t` 和 64-byte CQE 已有：

- `has_imm`
- `imm_data`
- `CQE_FMT_FLAG_HAS_IMM`

9.4 只在 `SEND_WITH_IMM` 和 `RDMA_WRITE_WITH_IMM` receive completion 中置位 `has_imm`。普通 SEND 和普通 RDMA_WRITE 不置位。

`RDMA_WRITE_WITH_IMM` 的 receive completion 使用 `RDMA_OP_RDMA_WRITE_WITH_IMM` opcode；如果后续 Verbs provider 希望映射成普通 receive opcode + immediate flag，可以在用户态 CQE parser 层做兼容转换。

### Error Behavior

| 场景 | 行为 |
| --- | --- |
| `SEND_WITH_IMM` 无 RQ WQE | 走现有 RNR/error 路径，不生成 receive CQE。 |
| `RDMA_WRITE_WITH_IMM` 无 RQ WQE | 走 RNR/error 路径，不生成 receive CQE。 |
| `RDMA_WRITE_WITH_IMM` remote memory validation/write 失败 | 不生成 receive CQE。 |
| malformed/non-immediate opcode | 输出 debug status，不进入 receive CQE path。 |

### 当前 Stub/TODO

- TODO：`rc_immediate_engine` 的 remote write validation/write 通过 ready/valid stub 接口接入，后续连接 MR/DMA pipeline。
- TODO：`RDMA_WRITE_WITH_IMM` 的 RETH+ImmDt 在当前单 beat packet builder 下可能触发 multi-beat stub，完整 wire segmentation 留给 packet builder 后续增强。
- TODO：failure counters 目前只通过 `debug_status` 暴露，尚未接 CSR counter block。
- TODO：UD immediate 行为不在 9.4 范围内，留给 9.5/9.6。
