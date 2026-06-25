# Congestion Control

本文件记录第 10 阶段拥塞控制路径。当前实现覆盖 10.1 ingress ECN detection、CE mark propagation，10.2 CNP packet generation / receive classification，以及 10.3 per-QP DCQCN state machine。不实现 10.4 transmit pacing，也不处理 PFC pause。

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
- DCQCN 只输出 per-QP `current_rate` update；真正 transmit pacing 由 10.4 负责。
- 不实现 transmit pacing；10.4 负责。
- 不实现 PFC pause/resume；10.5 负责。
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
