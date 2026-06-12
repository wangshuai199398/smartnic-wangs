# CQ 管理

本文说明 Completion Queue 管理相关模块。5.1 阶段加入 `rtl/cq/cq_context_table.sv`，它是 CQ manager 的“账本”：保存 CQ buffer 地址、深度、producer/consumer index、owner function、MSI-X vector、中断调节字段、arm 状态和错误状态。5.2 阶段加入 `rtl/cq/completion_engine.sv`，它把 SQ/RQ/cleanup/error 路径的 completion event 统一格式化成 64-byte CQE。5.3 阶段加入 `rtl/cq/cqe_write_path.sv`，它根据 CQ context 计算 host CQ buffer 地址并发出 64-byte DMA/PCIe memory write 请求。

当前阶段只管理 CQ context、格式化 CQE、定义 CQE memory write 请求接口，并实现基础 producer/consumer wraparound 与 overflow 检测；真实 DMA Engine 和 MSI-X 通知分别留给后续 DMA 和 5.5。

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
        v
cqe_write_path --lookup CQN--> cq_context_table
        |
        +--> 64-byte DMA/PCIe memory write request
        +--> CQ producer index update request
        +--> cq_index_manager 判断 full/empty/overflow
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

## CQE Write Path

`cqe_write_path` 接收 `completion_engine` 的输出：

```text
cqe_write_valid
cqe_write_cqn
cqe_write_owner_function
cqe_write_data[511:0]
cqe_write_solicited
cqe_write_status
cqe_write_error
```

模块先根据 `cqe_write_cqn` 查询 CQ context，并检查：

- CQN 必须命中；
- CQ context 必须 `valid = 1`；
- `cqe_write_owner_function` 必须等于 CQ context 的 `owner_function`；
- `cq_depth` 不能为 0；
- 当前阶段如果 CQ context 已经标记 `overflow`，先返回预留错误，不继续写入。

地址计算公式固定为：

```text
cqe_addr = cq_buffer_base_addr + producer_index * 64
```

因为 CQE 固定 64 字节，所以写入地址必须 64-byte aligned。如果 base 地址或 producer index 组合得到的地址未对齐，模块返回 `CQE_WR_ERR_ADDR_ALIGN`。实际项目里驱动创建 CQ 时也应该保证 CQ buffer base 按 CQE size 对齐。

### DMA/PCIe Write 请求

地址计算成功后，write path 输出一个 memory write 请求：

```text
dma_write_valid
dma_write_addr
dma_write_data[511:0]
dma_write_len = 64
dma_write_byte_enable = all ones
dma_write_owner_function
dma_write_tag = producer_index
dma_write_error
```

这里的 `dma_write_*` 只是后续 DMA/PCIe write engine 的接口，不是真实 PCIe TLP。`dma_write_ready = 0` 时，模块会保持 `dma_write_valid`、地址和数据不变，直到下游接收，避免 completion event 丢失。

### Producer Index Update

write request 被下游接收后，模块输出 producer index 更新请求：

```text
cq_pi_update_valid
cq_pi_update_cqn
cq_pi_update_new_producer_index
cq_pi_update_owner_function
cqe_written_solicited
cqe_written_status
```

本阶段只实现基础 wrap：

```text
if producer_index == cq_depth - 1:
    new_producer_index = 0
else:
    new_producer_index = producer_index + 1
```

完整的 owner bit 翻转和复杂 race 处理留给后续更完整的 CQ manager；5.4 已经加入 reserved-slot full/empty 和基础 overflow 检测。

### CQE Write Path 错误

当前最小错误包括：

| 错误 | 含义 |
| --- | --- |
| `CQE_WR_ERR_CQ_MISS` | CQN lookup miss 或 CQ context invalid。 |
| `CQE_WR_ERR_PERMISSION` | completion function 与 CQ owner 不匹配。 |
| `CQE_WR_ERR_CQ_ALIAS` | CQ table 发现 CQN alias。 |
| `CQE_WR_ERR_DEPTH_ZERO` | CQ depth 为 0，无法计算 ring slot。 |
| `CQE_WR_ERR_ADDR_ALIGN` | 计算出的 CQE 地址不是 64-byte aligned。 |
| `CQE_WR_ERR_OVERFLOW` | CQ context 已标记 overflow，完整恢复策略留给 5.4。 |

这样拆分后，5.3 只关心“把一个已格式化 CQE 放到 host CQ ring 的哪个地址，以及如何发出写请求”。它不判断 CQ 是否已满，也不决定是否通知软件；这让后续 5.4 和 5.5 的职责更单纯。

## Producer/Consumer Wraparound

5.4 阶段加入 `cq_index_manager`，专门管理 CQ ring index：

```text
current_producer_index
current_consumer_index
cq_depth
cqe_write_commit
cq_arm_consumer_update
overflow_clear_valid
    -> next_producer_index
    -> next_consumer_index
    -> cq_empty / cq_full / cq_has_space / cq_overflow
```

producer index 规则：

```text
if producer_index + 1 < cq_depth:
    next_producer_index = producer_index + 1
else:
    next_producer_index = 0
```

consumer index 来自 CQ Arm Doorbell。只要软件提交的 consumer index 小于 `cq_depth`，就允许更新；等于或超过 `cq_depth` 会返回 `CQ_INDEX_ERR_ARM_RANGE`。这一步保证软件不能把 CI 写到 ring 外面。

## Full / Empty 策略

当前采用 reserved-one-entry 方案：

```text
empty: producer_index == consumer_index
full:  next_producer_index == consumer_index
```

这个方案会牺牲一个 CQE slot，但实现简单，而且能避免 `producer == consumer` 同时表示 empty 和 full 的歧义。后续如果引入 phase/owner bit，可以把可用容量提高到完整 depth。

## Overflow 处理

当 `cq_full = 1` 时，如果仍然有新的 CQE write commit，`cq_index_manager` 输出：

```text
cq_overflow = 1
index_error_code = CQ_INDEX_ERR_OVERFLOW
```

`cqe_write_path` 在发起 DMA write 前调用该判断。只有 `cq_has_space = 1` 时才允许写 CQE；如果 CQ full，则不发 DMA write，并输出：

```text
cq_overflow_set_valid
cq_overflow_set_cqn
cq_overflow_set_owner_function
```

这个请求用于写回 CQ context 的 `overflow` 标志，防止硬件覆盖尚未被软件消费的 CQE。`overflow_clear_valid` 可以清除 overflow 标志，清除后如果 ring 也不再 full，`cq_has_space` 会恢复为 1。

## Overflow 标志

5.1 只保存 overflow 标志，不实现完整 overflow 检测。预留接口包括：

- `overflow_set_valid`：设置 `overflow = 1`；
- `overflow_clear_valid`：清除 `overflow = 0`。

真实 overflow 检测会在 5.4 基于 producer/consumer wraparound 和 CQ depth 实现。

## Owner Function 隔离

lookup、read、arm update、producer update 和 overflow set/clear 都检查请求 function 是否匹配 `owner_function`。非 owner function 访问返回 `CQ_TABLE_STATUS_PERMISSION`。这样可以防止一个 VF arm 或推进另一个 VF 的 CQ，也防止 cross-VF CQ overflow 状态被篡改。

## 后续连接

- 5.2 CQE formatting 会读取 CQ context 中的 CQN、owner 和 CQ 状态。
- 5.3 CQE write path 会使用 `cq_buffer_base_addr`、`cq_depth` 和 `producer_index` 计算 CQE 写回地址，并发出 64-byte DMA/PCIe memory write 请求。
- 5.4 wraparound/overflow 使用 `producer_index`、`consumer_index`、`cq_depth` 和 `overflow`，保护 CQE write path 不覆盖未消费 CQE。
- 5.5 notification logic 会使用 `armed`、`solicited_only`、`msix_vector`、`moderation_count`、`moderation_timer` 和 moderation 运行时字段。
