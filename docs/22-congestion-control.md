# Congestion Control

本文件记录第 10 阶段拥塞控制路径。10.1 只实现 ingress ECN detection 和 CE mark propagation，不生成 CNP，不实现 DCQCN rate update，也不处理 PFC pause。

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

- 不生成 CNP；10.2 负责 CNP packet generation 和 receive classification。
- 不实现 DCQCN alpha/rate state；10.3 负责。
- 不实现 transmit pacing；10.4 负责。
- 不实现 PFC pause/resume；10.5 负责。
- 不改变普通非 ECN 包的 parser、validator、payload extraction 或 transport 行为。
