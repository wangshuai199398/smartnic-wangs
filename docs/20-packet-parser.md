# RoCEv2 Packet Processing

本阶段覆盖第 8 阶段的包处理子模块。RX 方向已经包含 parser、validator 和 payload extractor；8.4 新增 TX 方向的 packet builder。

```text
MAC RX frame
  -> roce_packet_parser
  -> packet metadata
  -> roce_ingress_validator
  -> roce_payload_extractor
  -> transport metadata + receive DMA payload stream
```

TX 方向：

```text
transport/DMA TX request
  -> roce_packet_builder
  -> Ethernet/IPv4/UDP/RoCEv2 frame
  -> 后续 MAC TX
```

## 解析范围

`rtl/packet/roce_packet_parser.sv` 解析首个 512-bit frame beat 中的这些字段：

| 层级 | 字段 |
| --- | --- |
| Ethernet | EtherType |
| VLAN | 单层 VLAN TCI 和内层 EtherType |
| IPv4 | source IPv4、destination IPv4 |
| UDP | source port、destination port |
| BTH | opcode、P_Key、destination QPN、PSN |
| RETH | remote virtual address、rkey、DMA length |
| AETH | 原始 AETH 字段 |
| DETH | Q_Key、source QPN |
| ImmDt | immediate data |
| ICRC | invariant CRC 原始字段 |

解析结果通过 `packet_meta_t` 输出，并保留 `desc_id`、`qpn`、`cqn`、`owner_function`、`pd_id`、`opcode`、`status/error_code`，方便后续模块把包和 QP/CQ/MR/DMA/完成路径关联起来。

## Ready/Valid 语义

输入接口使用：

```text
frame_valid / frame_ready / frame_data / frame_len / frame_last
```

输出接口使用：

```text
meta_valid / meta_ready / packet_meta_t
```

当 `meta_valid=1` 且 `meta_ready=0` 时，解析器保持当前 metadata，不接收下一帧。这保证后续 validation 或 transport path 反压时不会丢包元数据。

## 8.2 入站校验

`rtl/packet/roce_ingress_validator.sv` 消费 `packet_meta_t`，只在 metadata 通过基础协议检查后输出到后续路径。失败的包通过 drop/debug 接口输出，不会进入 payload extraction、transport RX、RQ/DMA 或 CQE 路径。

校验项如下：

| 校验项 | 当前规则 | 错误码 |
| --- | --- | --- |
| Parser status | 必须为 `PKT_PARSE_STATUS_OK` | `PKT_VALIDATION_ERR_PARSE` |
| EtherType | VLAN 内层或普通 EtherType 必须为 IPv4 `0x0800` | `PKT_VALIDATION_ERR_ETHERTYPE` |
| IP version | 必须为 IPv4 `4` | `PKT_VALIDATION_ERR_IP_VERSION` |
| IHL | 当前只支持 `5`，即无 IPv4 options 的 20B header | `PKT_VALIDATION_ERR_IHL` |
| Protocol | 必须为 UDP `17` | `PKT_VALIDATION_ERR_PROTOCOL` |
| UDP port | UDP destination port 必须为 RoCEv2 `4791` | `PKT_VALIDATION_ERR_UDP_PORT` |
| BTH transport version | 必须为 `0` | `PKT_VALIDATION_ERR_BTH_VERSION` |
| Opcode | 必须属于当前枚举支持的 Send/RDMA Read/Write/ACK/CNP/UD Send 子集 | `PKT_VALIDATION_ERR_OPCODE` |
| Checksum | `checksum_valid=1` 且 `checksum_ok=1` | `PKT_VALIDATION_ERR_CHECKSUM` |
| Packet length | frame/IP/UDP/payload/ICRC 长度必须自洽 | `PKT_VALIDATION_ERR_LENGTH` |

validator 保留 `desc_id`、`qpn`、`cqn`、`owner_function`、`pd_id`、`opcode` 和错误状态，便于后续 drop counter、debug 或 completion/error path 关联。

## 为什么 parser 和 validator 分开

8.1 parser 的目标是“字段能被稳定提取”；8.2 validator 的目标是“判断这包能不能继续进入 RDMA receive/transport 路径”。分开后，后续可以单独替换 checksum checker、payload extractor 或 transport engine，而不需要重写 parser。

parser 当前只设置结构性状态：

- `PKT_PARSE_STATUS_OK`：首 beat 足够输出 metadata。
- `PKT_PARSE_STATUS_NEED_MORE_DATA`：`frame_last=0`，表示后续 payload 或扩展字段还在下一 beat。
- `PKT_PARSE_STATUS_SHORT_FRAME`：帧长度短于最小 RoCEv2 header 加 ICRC。

validator 则把非 OK parser status 统一转换为 `PKT_VALIDATION_ERR_PARSE`。

## 8.3 Payload Extraction Interface

`rtl/packet/roce_payload_extractor.sv` 接收两类同步输入：

```text
validated metadata: meta_valid / meta_ready / packet_meta_t
frame beat:         frame_valid / frame_ready / frame_data / frame_len / frame_last
```

它输出两路接口：

| 输出 | 作用 |
| --- | --- |
| `transport_meta_valid / transport_meta_ready / transport_meta` | 把已通过 8.2 校验的 `packet_meta_t` 传给后续 transport RX。 |
| `rx_payload_valid / rx_payload_ready / packet_payload_stream_t` | 把 payload 对齐成 receive DMA/RQ path 可消费的 payload stream。 |

`packet_payload_stream_t` 保留这些跨模块调试和 completion 关联字段：

- `desc_id`
- `qpn`
- `cqn`
- `owner_function`
- `pd_id`
- `opcode`
- `status/error_code`
- `payload_len`
- `valid_bytes`
- `byte_offset`
- `first/last`
- `imm_data`
- `remote_va/rkey/dma_length`
- `dest_qpn/psn`

当前最小版本只支持 payload 完整落在首个 512-bit beat 内的包。若 payload 跨 beat 或 `frame_last=0`，模块通过 `extract_error_valid` 输出错误：

| 错误 | 含义 |
| --- | --- |
| `PKT_PAYLOAD_ERR_META_STATUS` | 输入 metadata 不是 parser OK 状态。 |
| `PKT_PAYLOAD_ERR_LENGTH` | frame length、payload offset、payload length 或 ICRC 范围不自洽。 |
| `PKT_PAYLOAD_ERR_MULTI_BEAT_STUB` | payload 超出首个 512-bit beat，当前阶段不重组多 beat。 |
| `PKT_PAYLOAD_ERR_FRAME_NOT_LAST` | 当前 frame 还有后续 beat，最小实现先拒绝。 |

为什么这样切分：8.3 的目标是把 parser/validator 结果连接到 receive DMA 和 transport 逻辑，而不是实现完整 RoCEv2 transport 状态机。真正的多 beat payload reassembly、PMTU payload 分段、RQ/DMA 写入和 RC/UD 语义会在后续任务中继续接上。

## 8.4 Packet Builder

`rtl/packet/roce_packet_builder.sv` 接收 `packet_build_req_t`，输出单个 512-bit frame beat：

```text
build_req_valid / build_req_ready / packet_build_req_t
  -> frame_valid / frame_ready / frame_data / frame_len / frame_last
```

支持的构造内容：

| 层级 | 当前行为 |
| --- | --- |
| Ethernet | 写入 dst/src MAC，支持无 VLAN 或单层 VLAN。 |
| IPv4 | 写入 version/IHL、total length、UDP protocol、src/dst IPv4。 |
| UDP | 写入 source port 和 RoCEv2 destination port。 |
| BTH | 写入 opcode、P_Key、destination QPN、PSN。 |
| RETH | 用于 RDMA Write 和 RDMA Read Request，写入 remote VA、rkey、DMA length。 |
| AETH | 用于 ACK 和 Read Response 的最小 AETH 字段。 |
| DETH | 用于 UD Send，写入 Q_Key 和 source QPN。 |
| ImmDt | 用于 Send with Immediate。 |
| CNP | 生成 CNP opcode 的最小 header frame。 |
| Payload | 支持 payload 完整落在单个 512-bit beat 内。 |

当前 builder 会保留：

- `desc_id`
- `qpn`
- `cqn`
- `owner_function`
- `pd_id`
- `opcode`
- `status/error_code`

如果请求无法在单 beat 内输出，会返回 `PKT_BUILD_ERR_MULTI_BEAT_STUB`。不支持 opcode 返回 `PKT_BUILD_ERR_UNSUPPORTED`。

## 8.5 ICRC Placeholder

`rtl/packet/roce_icrc_placeholder.sv` 是一个刻意隔离的 ICRC placeholder。它不计算真实 RoCEv2 invariant CRC，只透传已有 ICRC 字段，并输出 `compatibility_limited=1`。

接口：

```text
req_valid / req_ready
  -> req_desc_id / qpn / cqn / owner_function / pd_id / opcode
  -> req_frame_data / req_frame_len / req_existing_icrc / req_is_tx

result_valid / result_ready
  -> packet_icrc_result_t
```

当前状态语义：

| 状态 | 含义 |
| --- | --- |
| `PKT_ICRC_STATUS_PLACEHOLDER` | TX 方向透传 placeholder ICRC，未做真实 CRC。 |
| `PKT_ICRC_STATUS_UNCHECKED` | RX 方向只提取 ICRC 字段，未做真实校验。 |
| `PKT_ICRC_STATUS_MISMATCH` | 为后续真实 checker 预留，当前不会由 placeholder 产生。 |

`roce_packet_builder.sv` 可以接收 `packet_icrc_result_t`。若未接入外部 ICRC result，则仍回退使用 `packet_build_req_t.icrc_placeholder`。这样后续把 placeholder 替换成真实 ICRC 计算器时，不需要重写 packet builder 的 header 生成接口。

### 兼容性限制

当前 8.5 满足任务中“clearly isolated placeholder with tests marking compatibility limitations”的路径，而不是完整 ICRC calculation。限制如下：

- 不能用于真实 RoCEv2 网络互操作验证。
- 不能检测入站 ICRC mismatch。
- 不能证明 packet builder 输出满足 IBTA/RoCEv2 ICRC 要求。
- 8.6 之后的完整协议测试应把该限制标为 known limitation，直到真实 ICRC 计算器替换 placeholder。

## 当前 Stub / TODO

- 当前 payload extractor 只支持首个 512-bit beat 内的 payload；完整多 beat payload reassembly 仍是 TODO。
- 当前 packet builder 只支持单个 512-bit beat 输出；多 beat packet segmentation 仍是 TODO。
- VLAN 情况下 RETH length 可能落在下一 beat，当前只提取 remote VA 和 rkey。
- checksum 当前通过 `checksum_valid/checksum_ok` stub 接口接入；真实 IPv4/UDP checksum 计算器后续独立实现。
- ICRC 当前使用隔离 placeholder，不计算真实 invariant CRC。
- 不实例化真实 MAC，也不连接第 9 阶段 transport engine；测试使用 Cocotb 直接驱动 frame 和 metadata 接口。
