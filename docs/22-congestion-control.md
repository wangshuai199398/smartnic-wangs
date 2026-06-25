# Congestion Control

本文件记录第 10 阶段拥塞控制路径。当前实现覆盖 10.1 ingress ECN detection、CE mark propagation，10.2 CNP packet generation / receive classification，10.3 per-QP DCQCN state machine，10.4 per-QP token bucket transmit pacing，以及 10.5 PFC pause handling / scheduler backpressure。

## 10.1 ECN Ingress Detection

接收方向的数据流如下：

```text
MAC RX frame
  -> roce_packet_parser
  -> packet_meta_t(ecn, ecn_valid, ecn_ce)
  -> roce_ingress_validator / roce_payload_extractor
  -> transport receive path
  -> ecn_ingress_marker
  -> congestion mark hook for future CNP generation
```

`rtl/packet/roce_packet_parser.sv` 从 IP header 中提取 ECN：

| Packet 类型 | ECN 来源 | 当前行为 |
| --- | --- | --- |
| IPv4 | DS field 低 2 bit | 写入 `packet_meta_t.ecn`，CE(11) 时置 `ecn_ce` |
| IPv6 | traffic class 低 2 bit | 写入 ECN metadata；完整 IPv6 RoCEv2 layout 仍为 TODO |
| 非 IP | 无 | `ecn_valid=0`，不改变原有 drop/validate 行为 |

IPv6 当前只完成 traffic class/ECN detection。因为项目的 8.x parser/validator 主路径仍以 IPv4 RoCEv2 为最小实现，IPv6 包不会被当作完整 RoCEv2 包放行。

## Congestion Hook

`rtl/congestion/ecn_ingress_marker.sv` 接收 `packet_meta_t`，并原样透传 metadata。若 `ecn_valid=1 && ecn_ce=1`，模块额外输出：

- `congestion_mark_valid`
- `congestion_mark_desc_id`
- `congestion_mark_qpn`
- `congestion_mark_cqn`
- `congestion_mark_owner_function`
- `congestion_mark_pd_id`
- `congestion_mark_opcode`
- `congestion_mark_ecn`

这些字段保留了后续生成 CNP 或更新 per-QP congestion state 所需的上下文。10.1 不直接修改 QP context，也不发送 CNP packet。

## Counters

10.1 提供轻量计数器：

| Counter | 含义 |
| --- | --- |
| `ecn_packet_count` | ingress metadata 中 ECN 字段有效的包数量 |
| `ce_packet_count` | ECN 字段为 CE(11) 的包数量 |
| `malformed_ecn_count` | 带 ECN metadata 但 parser status 非 OK 的包数量 |

这些 counter 目前作为 RTL 输出暴露。后续 10.x 或 11.x 可以把它们映射到 CSR/telemetry。

## 边界

- CNP 生成只输出到 packet builder 请求，不直接驱动 MAC TX top。
- DCQCN 只输出 per-QP `current_rate` update；10.4 token bucket 使用该 rate 做发送准入判定。
- PFC pause/resume 只在 10.5 的 TX scheduler gate 中建模，不实现真实 MAC control frame RX/TX。
- 不改变普通非 ECN 包的 parser、validator、payload extraction 或 transport 行为。

## 10.2 CNP Packet Generation

`rtl/congestion/cnp_packet_generator.sv` 把拥塞触发事件转换为 `packet_build_req_t`：

```text
ecn_ingress_marker.congestion_mark_*
queue_congestion_*
port_congestion_*
  -> cnp_packet_generator
  -> packet_build_req_t(opcode=ROCE_OPCODE_CNP)
  -> roce_packet_builder
```

触发来源：

| 来源 | congestion_type | 当前输入 |
| --- | --- | --- |
| ECN CE mark | `CNP_CONGESTION_ECN` | `ce_mark_valid` |
| Queue threshold | `CNP_CONGESTION_QUEUE` | `queue_congestion_valid` |
| Port threshold | `CNP_CONGESTION_PORT` | `port_congestion_valid` |

生成的 CNP build request 保留：

- `desc_id`
- `qpn`
- `cqn`
- `owner_function`
- `pd_id`
- `opcode=ROCE_OPCODE_CNP`
- `dest_qpn=trigger_qpn`
- `src_qpn=trigger_qpn`，作为最小 source QP/port 标识占位
- `imm_data[1:0]=congestion_type`，用于 10.2 原型阶段携带拥塞类型

为了避免 CNP storm，generator 维护一个按 QPN 低位索引的 cooldown table。若同一 QP 在 `cnp_rate_limit_cycles` 内再次触发，模块消费该 trigger、递增 `cnp_rate_limited`，但不输出新的 CNP。

Debug counters：

| Counter | 含义 |
| --- | --- |
| `cnp_generated_total` | 成功生成的 CNP build request 数 |
| `cnp_rate_limited` | 被 per-QP cooldown 抑制的 trigger 数 |

## 10.2 CNP Receive Classification

`rtl/congestion/cnp_receive_classifier.sv` 对 ingress metadata 做 CNP 旁路分类：

```text
packet_meta_t
  -> cnp_receive_classifier
  -> QP lookup hook
  -> cnp_event_t
  -> DCQCN state machine input queue (10.3)
```

识别条件：

- `opcode == ROCE_OPCODE_CNP`
- `udp_dst_port == ROCEV2_UDP_PORT`
- `packet_parse_status == PKT_PARSE_STATUS_OK`

校验规则：

| 情况 | 行为 |
| --- | --- |
| 非 CNP packet | 输出 `CNP_CLASS_STATUS_NOT_CNP` drop/debug，不计入 invalid CNP |
| CNP malformed | 输出 drop/debug，递增 invalid counter |
| QP lookup miss / inactive | 输出 drop/debug，递增 invalid counter |
| 有效 CNP | 输出 `cnp_event_t` 到 DCQCN input |

`cnp_event_t` 保留 QPN、owner function、PD、source QPN、congestion type 和 status。10.3 将消费该事件并更新 DCQCN alpha/rate；10.2 不实现速率变化。

Debug counters：

| Counter | 含义 |
| --- | --- |
| `cnp_received_total` | 有效 CNP 事件总数 |
| `cnp_invalid_total` | malformed 或 QP miss CNP 总数 |
| `cnp_received_count` | 当前 QPN 哈希槽的有效 CNP 计数 |
| `cnp_dropped_invalid_count` | 当前 QPN 哈希槽的无效 CNP 计数 |

## 10.2 Test Hooks

测试注入点：

- `ce_mark_valid`：模拟 CE-marked packet arrival。
- `queue_congestion_valid` / `port_congestion_valid`：模拟 queue/port threshold exceeded。
- `meta_valid + packet_meta_t(opcode=CNP)`：模拟 synthetic CNP packet injection。
- malformed CNP：通过错误 UDP port、parser status 或 QP miss 注入。

## 10.3 DCQCN State Machine

`rtl/congestion/dcqcn_state_machine.sv` 维护一个原型阶段的 per-QP congestion 表。表项按 QPN 低位索引，保存：

| 字段 | 含义 |
| --- | --- |
| `current_rate` | 当前发送速率，输出给 10.4 pacing/token bucket |
| `target_rate` | 恢复目标速率 |
| `min_rate` | CNP 降速后的最低速率 |
| `ai_rate` | additive increase 步长 |
| `alpha` | DCQCN alpha，使用定点抽象值 |
| `state` | `NORMAL` / `CONGESTED` / `RECOVERY` |

控制面通过 `config_valid/config_ready` 写入初值。后续 11.x/12.x 可以把该接口连接到 BAR2 CSR 或 mailbox；当前 10.3 不定义 ABI。

### CNP Update

当 10.2 classifier 输出 `cnp_event_t`：

```text
cnp_event_t
  -> dcqcn_state_machine
  -> rate_update(current_rate, alpha, state)
  -> 10.4 pacing
```

更新规则：

```text
state        = CONGESTED
current_rate = max(current_rate / 2, min_rate)
alpha        = alpha - (alpha >> g) + (alpha_max >> g)
```

这里的 `g` 来自 `config_alpha_g_shift`。完整 DCQCN 参数化、精确定点格式和 rate unit 校准留给后续原型收敛。

### Recovery

`recovery_tick_valid` 表示一个 QP 在恢复周期内没有新的 CNP 或由恢复定时器驱动：

```text
current_rate = min(current_rate + ai_rate, target_rate)
state        = NORMAL if current_rate == target_rate else RECOVERY
```

该接口有意使用显式 `qpn` tick，便于单元测试和后续接入扫描器或定时器。

### Counters

| Counter | 含义 |
| --- | --- |
| `cnp_events` | 被 DCQCN 消费的 CNP 事件数 |
| `rate_decrease` | multiplicative decrease 次数 |
| `rate_increase` | additive increase 次数 |
| `state_transitions` | NORMAL/CONGESTED/RECOVERY 状态变化次数 |

## 10.4 Per-QP Token Bucket Pacing

`rtl/congestion/tx_pacer_token_bucket.sv` 把 10.3 输出的 DCQCN `current_rate` 转换成每个 QP 的发送准入规则：

```text
dcqcn_state_machine.rate_update
  -> tx_pacer_token_bucket(QP bucket rate)
TX packet metadata(packet_size, qpn, owner_function)
  -> token refill + token consume
  -> ALLOWED / THROTTLED / DISABLED / INVALID decision
  -> transport TX scheduler hook
```

每个 QP bucket 保存：

| 字段 | 含义 |
| --- | --- |
| `rate` | 来自 DCQCN 的 `current_rate`，当前按每个 time tick 增加的 token 数建模 |
| `bucket_size` | 最大 burst 容量 |
| `tokens` | 当前可用 token |
| `last_update_time` | 上次 refill 使用的时间戳 |
| `qpn` / `owner_function` | 防止不同 QP/VF 共享同一个 bucket entry |

Refill 规则：

```text
delta_time = time_now - last_update_time
tokens     = min(tokens + rate * delta_time, bucket_size)
```

发送规则：

| 情况 | 行为 |
| --- | --- |
| `tokens >= packet_size` | 输出 `PACER_STATUS_ALLOWED`，扣减 `packet_size` 个 token |
| `tokens < packet_size` | 输出 `PACER_STATUS_THROTTLED`，TX path 应暂停该 QP 发包 |
| `pacer_enable=0` | 输出 `PACER_STATUS_DISABLED`，旁路允许发送 |
| bucket 未配置、owner 不匹配、packet_size 为 0 | 输出 `PACER_STATUS_INVALID` |

10.4 只做准入判定，不直接操作 packet builder、MAC TX 或 QP scheduler。真实 TX scheduler 应把待发送 packet 的 `packet_size`、`qpn`、`owner_function` 送入 pacer；只有返回 `ALLOWED` 时继续发包。若返回 `THROTTLED`，scheduler 可以稍后重试同一个 QP。

Debug counters：

| Counter | 含义 |
| --- | --- |
| `tokens_refilled` | 成功 refill 到 bucket 中的 token 累计数 |
| `tx_throttled_events` | token 不足导致 TX 暂停的次数 |
| `tx_allowed_packets` | 被允许或 bypass 的 packet 数 |

当前限制：

- `rate` 单位是原型抽象 token/tick，尚未映射到真实 Gbps、端口时钟或 packet scheduler credit。
- bucket 表按 QPN 低位索引，未实现 collision walk；后续资源管理/CSR 阶段可以替换为更完整的 per-QP table。
- `THROTTLED` 只输出判定，不实现真实 TX 队列暂停/恢复，这部分属于后续 transmit scheduler/top 集成。

## 10.5 PFC Pause Handling and Scheduler Backpressure

`rtl/congestion/pfc_pause_scheduler.sv` 在 TX scheduler 和 10.4 token bucket 之间放置一个 per-priority gate：

```text
PFC PAUSE/RESUME event(priority, quanta)
  -> pfc_pause_scheduler.pause_state[priority]
TX scheduler request(qp_priority, pacer_tx_req_t)
  -> if pause_state[qp_priority] == PAUSED: backpressure, do not call token bucket
  -> else: forward request to tx_pacer_token_bucket
  -> pacer decision returns to TX scheduler
```

PFC priority 使用 802.1Qbb 的 8 个 traffic class，当前以 `tx_qp_priority` 输入表示 QP 到 priority 的映射。真实映射来源可以来自后续 CSR、QP context 或 service level/AH 配置；10.5 只实现调度点上的判断。

Per-priority 状态：

| 字段 | 含义 |
| --- | --- |
| `pause_state[priority]` | `ACTIVE` 或 `PAUSED` |
| `pause_timer[priority]` | pause quanta/timer，非 0 时每周期递减 |
| `pfc_pause_events` | 收到 PAUSE 事件次数 |
| `pfc_resume_events` | 收到显式 RESUME 或 timer 到期恢复次数 |
| `tx_stalled_due_to_pfc` | TX 请求因 priority paused 被反压的次数 |

行为规则：

| 事件/条件 | 行为 |
| --- | --- |
| PFC PAUSE | 将该 priority 置为 `PAUSED`，加载 pause timer |
| PFC RESUME | 将该 priority 置为 `ACTIVE`，清 timer |
| pause timer 到 0 | 自动恢复为 `ACTIVE`，计入 resume counter |
| TX 请求 priority 为 `PAUSED` | `tx_req_ready=0`，`pacer_req_valid=0`，上游 scheduler 被反压 |
| TX 请求 priority 为 `ACTIVE` | 请求透传到 10.4 token bucket |

10.5 选择的 token bucket backpressure 策略是 **freeze**：暂停期间不向 `tx_pacer_token_bucket` 发请求，因此 token 不被消费，也不基于暂停期间的 TX 请求触发 refill。恢复后由 scheduler 再次提交请求，token bucket 根据新的 `time_now` 继续正常 pacing。

当前限制：

- 不解析真实 MAC PFC control frame；`pfc_event_*` 是测试和未来 MAC control path 的注入接口。
- 不实现完整多队列 TX scheduler，只提供 priority gate 和 backpressure 信号。
- 不实现 PFC deadlock detection、watchdog 或 per-priority buffer accounting。

## 10.6 Congestion Control Test Suite

`sim/cocotb/test_congestion_integration.py` 是第 10 阶段的轻量集成测试套件。它使用 Python mock 模型串起 10.1 到 10.5 的语义，保证在没有 cocotb/Verilator 的环境中也能检查拥塞控制主链路。

覆盖场景：

| 场景 | 检查点 |
| --- | --- |
| ECN -> CNP | CE-marked metadata 生成 congestion hook，CNP build request 使用正确 QPN |
| CNP -> DCQCN | 合法 CNP event 触发 rate decrease，连续 CNP 时 current_rate clamp 到 min_rate |
| Recovery | 停止 CNP 后 additive increase 逐步恢复到 target_rate |
| Pacing | token bucket 根据 DCQCN rate 进行 allow/throttle 判定并更新 counter |
| PFC | PAUSE 反压 TX，RESUME 后恢复调度，验证没有永久 stall |
| Negative | malformed CNP 被 drop，DCQCN state/counter 不被污染 |
| Chain | ECN -> CNP -> DCQCN rate update -> pacing throttle 的最小端到端链路 |

该测试套件不替代 RTL module-level cocotb tests。工具链存在时，`make congestion-test` 还会运行：

- `test_ecn_ingress_marker.py`
- `test_cnp_packet_generator.py`
- `test_cnp_receive_classifier.py`
- `test_dcqcn_state_machine.py`
- `test_tx_pacer_token_bucket.py`
- `test_pfc_pause_scheduler.py`

当前限制：

- 集成测试使用 mock/stub，不实例化完整 MAC/PFC/RoCEv2 top。
- 不检查真实 PFC control frame 编解码，也不检查真实 TX scheduler 队列公平性。
- `no deadlock` 在 10.6 中定义为 PAUSE 后请求被 stall、RESUME 后同 priority 可再次 schedule；完整 watchdog/deadlock detection 属于后续 top-level/verification 阶段。
