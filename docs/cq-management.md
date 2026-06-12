# CQ 管理

本文说明 Completion Queue 管理相关模块。5.1 阶段加入 `rtl/cq/cq_context_table.sv`，它是 CQ manager 的“账本”：保存 CQ buffer 地址、深度、producer/consumer index、owner function、MSI-X vector、中断调节字段、arm 状态和错误状态。5.2 阶段加入 `rtl/cq/completion_engine.sv`，它把 SQ/RQ/cleanup/error 路径的 completion event 统一格式化成 64-byte CQE。

当前阶段只管理 CQ context 并格式化 CQE，不写 host CQ buffer，也不生成 MSI-X 请求。这些分别留给 5.3 和 5.5。

## 模块位置

```text
CQ Arm Doorbell
        |
        v
cq_context_table
        |
Completion event from SQ/RQ/cleanup/error
        |
        v
completion_engine --lookup CQN--> cq_context_table
        |
        +--> 64-byte CQE write request
        +--> 后续 CQE write path 使用 buffer base/depth/PI
        +--> 后续 notification logic 使用 armed/moderation/MSI-X vector
```

## CQ Context 字段

| 字段 | 作用 |
| --- | --- |
| `valid` | 该 CQ context 是否已分配。 |
| `cqn` | 完整 CQN tag，用于查找和防止 alias。 |
| `cq_buffer_base_addr` | host CQE ring buffer 起始地址。 |
| `cq_depth` | CQE ring 槽位数量。 |
| `producer_index` | 硬件下一次写入 CQE 的 index。 |
| `consumer_index` | 软件已经消费到的位置，通常通过 poll 或 CQ arm 更新。 |
| `owner_function` | 拥有该 CQ 的 PF/VF function。 |
| `msix_vector` | 该 CQ 默认关联的 MSI-X vector。 |
| `moderation_count` | 中断调节计数阈值。 |
| `moderation_timer` | 中断调节 timer 阈值。 |
| `moderation_counter` | 当前已累计的 completion 数。 |
| `moderation_timer_active` | moderation timer 是否正在运行。 |
| `armed` | CQ 是否已 arm，可触发通知。 |
| `solicited_only` | 只允许 solicited completion 触发通知。 |
| `overflow` | CQ overflow 标志。 |
| `error_state` / `error_code` | CQ 错误状态和错误码。 |

## CQN Tag Matching

CQ table 使用完整 CQN tag 做查找：

```text
lookup_valid + lookup_cqn -> lookup_hit + lookup_context
```

只有表项 `valid = 1` 且 `cqn` 完整匹配时才算命中。如果没有命中，返回 `CQ_TABLE_STATUS_MISS`。如果同一个 CQN 出现在多个 valid 表项，返回 `CQ_TABLE_STATUS_ALIAS`。这个 alias 检查很重要，因为 CQE 写回和 MSI-X 通知必须落到唯一 CQ；如果一个 CQN 对应多个 context，硬件无法知道该更新哪个 producer index。

## 最小读写接口

`context_write_*` 支持整项写入 CQ context。写入时会检查：

- 写入 payload 的 `cqn` 必须等于 `context_write_cqn`；
- 非 admin/bypass 写入时，`owner_function` 必须等于请求 function；
- 不允许把同一个 CQN 写到不同 valid slot 形成 alias；
- 创建新 CQ 时，如果没有空闲 slot，返回 `CQ_TABLE_STATUS_FULL`。

`context_read_*` 按 CQN 读取 context，并检查 owner function。PF/admin 管理路径可以通过 `context_read_admin_bypass` 预留绕过能力。

## CQ Arm 更新

3.5 阶段的 `cq_arm_doorbell_handler.sv` 会输出：

```text
cq_arm_valid
cq_arm_cqn
cq_arm_function_id
cq_arm_consumer_index
cq_arm_armed
cq_arm_solicited_only
```

CQ context table 接收该事件后：

- 更新 `consumer_index`；
- 设置 `armed`；
- 设置 `solicited_only`；
- 检查 CQN 是否存在；
- 检查请求 function 是否等于 `owner_function`；
- 上游 Doorbell handler 已报告错误时，返回 `CQ_TABLE_STATUS_INVALID`。

这一步只更新 CQ arm 状态，不判断是否马上触发 MSI-X。真正通知条件会在 5.5 根据 armed、solicited_only、moderation_count 和 moderation_timer 统一处理。

## Completion Producer 更新

completion path 通过预留接口更新 producer index：

```text
completion_update_valid
completion_update_cqn
completion_update_owner_function
completion_update_new_pi
```

当前阶段只把 `producer_index` 写入 CQ context。5.2 会先格式化 CQE，5.3 再根据 `cq_buffer_base_addr + producer_index * CQE_BYTES` 生成 host memory write。

## Completion Event 到 CQE

`completion_engine` 接收统一 completion event：

```text
event_valid
event_type
qpn
cqn
owner_function
wr_id
opcode
status
byte_len
imm_data / has_imm
solicited
vendor_error
source_engine
```

它先按 `event.cqn` 查询 CQ context，并检查：

- CQ context 必须存在且 `valid = 1`；
- `owner_function` 必须等于 CQ context 的 owner；
- CQ table 不能返回 alias 或 permission error。

检查通过后，engine 输出 `cqe_write_valid` 和 512-bit `cqe_write_data`。这个输出只是给 5.3 的 CQE write path 使用；本阶段不计算 host CQ buffer 地址，也不推进 producer index。

## 64-byte CQE 字段

`cqe_t` 固定为 64 字节，也就是 512 bit。主要字段包括：

| 字段 | 作用 |
| --- | --- |
| `wr_id` | 软件投递 WQE 时给出的 work request ID。 |
| `qpn` | 产生 completion 的 QP。 |
| `opcode` | 完成的操作类型，例如 Send、RDMA Write、RDMA Read、Recv 语义。 |
| `status` | completion 状态，成功或具体错误。 |
| `byte_len` | 完成的数据字节数。 |
| `imm_data` / `has_imm` | immediate data 及有效位。 |
| `solicited` | 是否为 solicited event，用于后续通知逻辑。 |
| `vendor_error` | 上游模块传来的设备私有错误码。 |
| `owner_function` / `cqn` | CQE 的 function 和目标 CQ。 |
| `syndrome` | completion engine 归纳出的错误原因。 |
| `flags` | immediate、solicited、error、flush、recv/send 等标志。 |
| `timestamp` | 调试/性能分析预留时间戳。 |
| `valid` / `owner_bit` | CQE 有效位和 ring owner bit 预留。 |
| `reserved` | 保留位，保证总宽度为 64 字节。 |

## Event 类型映射

| Event 类型 | CQE 行为 |
| --- | --- |
| `CMPL_EVENT_SQ` | 保留 SQ opcode，例如 `SEND`、`RDMA_WRITE`、`RDMA_READ`、`LOCAL_INVALIDATE`、`NOP`，并设置 send-side flag。 |
| `CMPL_EVENT_RQ` | 生成 receive-side CQE；无 immediate 时使用 `SEND` 语义，有 immediate 时使用 `SEND_WITH_IMM` 语义，并设置 recv flag。 |
| `CMPL_EVENT_CLEANUP` | 强制生成 `CMPL_WR_FLUSH_ERR`，设置 flush 和 error flag。 |
| `CMPL_EVENT_ERROR` | 生成错误 CQE，使用上游 status；若上游 status 仍是 success，则转为 `CMPL_GENERAL_ERR`。 |

## 错误 CQE 语义

如果 CQ lookup miss、CQ context 无效或 owner_function 不匹配，completion engine 仍会输出一个错误 CQE write request，让后续错误统计或调试路径可以观察到事件没有静默丢失：

- lookup miss / invalid CQ：`CMPL_GENERAL_ERR` + `CQE_SYNDROME_CQ_LOOKUP`；
- owner mismatch：`CMPL_GENERAL_ERR` + `CQE_SYNDROME_PERMISSION`；
- cleanup flush：`CMPL_WR_FLUSH_ERR` + `CQE_SYNDROME_FLUSH`。

这样设计的原因是 completion path 是 RDMA 可观测性的核心。即使当前阶段还不写 host memory，也要先让每个完成事件都能被归一化成稳定格式，后续 5.3 才能专注于地址计算和 DMA/PCIe write。

## Overflow 标志

5.1 只保存 overflow 标志，不实现完整 overflow 检测。预留接口包括：

- `overflow_set_valid`：设置 `overflow = 1`；
- `overflow_clear_valid`：清除 `overflow = 0`。

真实 overflow 检测会在 5.4 基于 producer/consumer wraparound 和 CQ depth 实现。

## Owner Function 隔离

lookup、read、arm update、producer update 和 overflow set/clear 都检查请求 function 是否匹配 `owner_function`。非 owner function 访问返回 `CQ_TABLE_STATUS_PERMISSION`。这样可以防止一个 VF arm 或推进另一个 VF 的 CQ，也防止 cross-VF CQ overflow 状态被篡改。

## 后续连接

- 5.2 CQE formatting 会读取 CQ context 中的 CQN、owner 和 CQ 状态。
- 5.3 CQE write path 会使用 `cq_buffer_base_addr`、`cq_depth` 和 `producer_index` 计算 CQE 写回地址。
- 5.4 wraparound/overflow 会使用 `producer_index`、`consumer_index`、`cq_depth` 和 `overflow`。
- 5.5 notification logic 会使用 `armed`、`solicited_only`、`msix_vector`、`moderation_count`、`moderation_timer` 和 moderation 运行时字段。
