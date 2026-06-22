# 8.1 RoCEv2 入站包解析器

本阶段只实现 `roce_packet_parser.sv` 的最小可验证解析框架。它的位置在 MAC RX 之后、transport/RQ/DMA 之前：

```text
MAC RX frame
  -> roce_packet_parser
  -> packet metadata
  -> roce_ingress_validator
  -> 后续 8.3 payload extraction / transport RX / receive DMA
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

## 当前 Stub / TODO

- 多 beat payload 提取留给 8.3。
- VLAN 情况下 RETH length 可能落在下一 beat，当前只提取 remote VA 和 rkey。
- checksum 当前通过 `checksum_valid/checksum_ok` stub 接口接入；真实 IPv4/UDP/ICRC 计算器后续独立实现。
- ICRC 只作为原始字段输出，不计算；完整 ICRC 属于 8.5。
- 不实例化真实 MAC，也不连接 transport RX；测试使用 Cocotb 直接驱动 frame 接口。
