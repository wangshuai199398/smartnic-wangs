# QP Context Table

本文说明 QP 管理相关模块。4.1 阶段加入 QP context table，建立 QP 管理的“账本”：保存 QP 的静态属性和少量运行时索引，支持按 QPN 查找，并接收 Doorbell path 传来的 SQ/RQ producer index 更新。4.2 阶段加入 QP lifecycle manager，提供 create、modify、query、destroy 和 error transition 命令框架。

## 模块位置

`rtl/qp/qp_context_table.sv` 位于 Doorbell path 和后续 SQ/RQ engine 之间。

```text
SQ/RQ Doorbell handler
        |
        v
qp_context_table
        |
        +--> 后续 SQ engine 读取 SQ base/depth/PI/CI
        +--> 后续 RQ engine 读取 RQ base/depth/PI/CI
        +--> 后续 RoCEv2 transport 读取 QP type/state/PSN/retry
```

它不直接处理 WQE，也不执行 RDMA Send/Recv/Read/Write。这样做是为了把“资源状态保存”和“真正的数据通路执行”拆开，便于逐步验证。

## QP Context 字段

公共结构体 `qp_context_t` 定义在 `rtl/common/smartnic_pkg.sv`。

| 字段 | 作用 |
| --- | --- |
| `valid` | 表项是否已经分配。 |
| `owner_func` | 拥有该 QP 的 PF/VF function，用于 SR-IOV 隔离。 |
| `qpn` | 完整 QPN tag，查找时必须匹配该字段。 |
| `qp_type` | QP 类型，例如 RC、UD。 |
| `state` | QP 状态，例如 RESET、INIT、RTR、RTS、ERR。 |
| `pd_id` | QP 所属 Protection Domain，后续 MR 权限检查会使用。 |
| `send_cqn` / `recv_cqn` | Send/Recv completion 写入的 CQ。 |
| `sq_base` / `rq_base` | SQ/RQ WQE buffer 的主机地址。 |
| `sq_depth` / `rq_depth` | SQ/RQ 队列深度。 |
| `sq_producer` / `sq_consumer` | SQ 软件 producer 和硬件 consumer。 |
| `rq_producer` / `rq_consumer` | RQ 软件 producer 和硬件 consumer。 |
| `remote_qpn` | RC 连接对端 QPN。 |
| `sq_psn` / `rq_psn` / `last_acked_psn` | RC 发送、接收和 ACK 跟踪使用的 PSN 状态。 |
| `retry_count` / `rnr_retry_count` | RC retry 和 RNR retry 状态字段。 |
| `pkey` / `qkey` / `ah_id` | RoCEv2/UD 相关元数据。 |
| `error_state` / `error_code` | 后续 QP error transition 和 flush completion 使用。 |

## QPN Tag Matching

QP 表不是简单使用 `qpn` 低位直接寻址，而是遍历有效表项并比较完整 `qpn` 字段：

```text
lookup_valid + lookup_qpn
        |
        v
for each valid table entry:
    if entry.qpn == lookup_qpn:
        hit
```

这样设计的原因是避免低位索引别名。例如两个不同 QPN 如果低位相同，不能因为映射到同一个 slot 就被误认为同一个 QP。当前实现使用线性搜索，优点是语义清楚；后续可以替换成 CAM、hash table 或 banked SRAM，但外部接口可以保持稳定。

## 读写接口

最小写接口接收完整 `qp_context_t`：

- 如果 QPN 已存在，覆盖原表项。
- 如果 QPN 不存在，写入第一个空闲表项。
- 如果使用 `context_write_use_index`，则写入显式 slot，主要用于控制面和测试 alias 行为。
- 如果同一个 QPN 已在其他有效 slot 中存在，返回 `QP_TABLE_STATUS_ALIAS`。
- 如果非 PF bypass 路径访问已有表项，`context_write_function_id` 必须匹配 `owner_func`。

最小读接口按 QPN 查找，并进行 owner 检查：

- 命中且 owner 匹配，返回 `QP_TABLE_STATUS_OK` 和完整 context。
- 未命中，返回 `QP_TABLE_STATUS_MISS`。
- 命中但 function 不匹配，返回 `QP_TABLE_STATUS_PERMISSION`。

## Doorbell PI 更新

3.3 和 3.4 阶段的 SQ/RQ Doorbell handler 不直接改表，而是输出 producer index 更新事件：

```text
SQ Doorbell -> sq_pi_update_qpn + sq_pi_update_new_pi
RQ Doorbell -> rq_pi_update_qpn + rq_pi_update_new_pi
```

`qp_context_table` 接收这些事件后：

- 按 QPN 查找 QP context。
- 检查更新来源 function 是否等于 `owner_func`。
- 只更新 `sq_producer` 或 `rq_producer`。
- 不读取 WQE，不推进 consumer index，不执行 RDMA 操作。

这种拆分让 Doorbell path 只负责“软件告诉硬件队列有新内容”，而 SQ/RQ engine 后续再负责“什么时候消费 WQE、怎么校验状态、如何派发 DMA/transport”。

## Owner Function 隔离

每个 QP context 都记录 `owner_func`。非 PF bypass 的 lookup、read、write 和 Doorbell PI update 都必须匹配该 owner。

这可以防止一个 VF 通过伪造 QPN 或 Doorbell payload 修改另一个 VF 的 QP producer index。真正的 Doorbell aperture 范围检查已经在 `doorbell_access_check` 和 `pcie_function_manager` 中完成；QP 表这里再做一次基于资源所有者的最终检查。

## QPN Alias Prevention

同一个 QPN 只能对应一个有效 QP context。写入时如果发现目标 QPN 已经存在于其他 slot，会返回 `QP_TABLE_STATUS_ALIAS`，并且不修改表内容。

这个检查对后续 SQ/RQ engine 很重要：如果一个 QPN 能命中多个 context，硬件就无法确定应该消费哪一个 SQ/RQ，也会破坏 completion、PSN 和 retry 状态。

## 本阶段不做的事情

- 不实现 `CREATE_QP`、`MODIFY_QP`、`QUERY_QP`、`DESTROY_QP` mailbox 命令。
- 不校验 RESET/INIT/RTR/RTS/ERR 等 IBTA 状态迁移。
- 不实现真实 host DMA 读取 SQ/RQ WQE 数据；当前只定义 fetch request/response 边界。
- 不调度 DMA 或 RoCEv2 transport。
- 不生成 CQE，也不触发 MSI-X。

这些逻辑会在 4.2 到 4.7 继续分阶段加入。

## QP Lifecycle Manager

`rtl/qp/qp_lifecycle_manager.sv` 是 CSR mailbox 或 admin command path 和 QP context table 之间的控制器。

```text
CSR mailbox / admin command
        |
        v
qp_lifecycle_manager
        |
        v
qp_context_table
```

它把软件控制面的 QP 命令转换成 QP 表的 read/write 操作。本阶段仍然不读取 WQE，不启动 SQ/RQ engine，也不做完整 IBTA 状态迁移校验。

## 命令状态机

Lifecycle manager 使用以下最小状态：

| 状态 | 作用 |
| --- | --- |
| `IDLE` | 等待新的 QP 命令。 |
| `LOOKUP` | 按 QPN 读取 QP context table。 |
| `EXECUTE` | 根据命令和 lookup 结果决定下一步。 |
| `UPDATE` | 将 create/modify/destroy/error 的结果写回 QP 表。 |
| `DONE` | 命令成功，等待上游接收响应。 |
| `ERROR` | 命令失败，返回错误码。 |

这种设计把“检查目标是否存在”和“真正修改表项”分开，后续 4.3 加入状态迁移校验时，只需要在 `EXECUTE` 阶段插入规则判断。

## CREATE_QP

CREATE_QP 的流程：

1. 使用 admin bypass 对目标 QPN 做 lookup，用来检查是否已有表项。
2. 如果 QPN 已存在，返回 `QP_LC_ERR_DUPLICATE_QPN`。
3. 检查 `owner_function` 是否在当前建模的 PF/VF 范围内。
4. 检查初始状态是否为 `RESET` 或 `INIT`。
5. 构造新的 `qp_context_t`，强制设置：
   - `valid = 1`
   - `owner_func = cmd_owner_function`
   - `qpn = cmd_qpn`
   - SQ/RQ producer 和 consumer index 清零
   - `error_state = 0`
   - `error_code = 0`
6. 写入 QP context table。

这样设计的原因是 QPN 的唯一性必须由硬件表最终确认，不能只相信软件 allocator。即使后续 driver 已经分配了 QPN，硬件仍要防止重复写入破坏已有 QP。

## MODIFY_QP

MODIFY_QP 的流程：

1. 按 QPN lookup 目标 QP。
2. 如果 QP 不存在，返回 `QP_LC_ERR_NOT_FOUND`。
3. 如果发起 function 不是 `owner_func` 且没有 admin bypass，返回 `QP_LC_ERR_PERMISSION`。
4. 根据 `cmd_modify_mask` 选择性更新字段。
5. 写回 QP context table。

当前支持的 mask 包括 state、type、PD、CQ、队列地址、队列深度、队列索引、PSN、retry、remote QPN、P_Key/Q_Key、AH 和 error 字段。

本阶段只做基础字段替换，不判断 RESET 到 RTS 这类状态迁移是否合法。完整状态规则留给 4.3。

## QUERY_QP

QUERY_QP 的流程：

1. 按 QPN lookup 目标 QP。
2. 通过 owner function 权限检查。
3. 直接返回完整 `qp_context_t`。
4. 不修改表项。

QUERY_QP 是后续 driver `QUERY_QP ioctl` 和调试工具读取硬件状态的基础。

## DESTROY_QP

DESTROY_QP 的流程：

1. 按 QPN lookup 目标 QP。
2. 通过 owner function 权限检查。
3. 写回一个清零 context，使 `valid = 0`。

这会释放硬件表项，但本阶段不处理 pending work quiesce，也不生成 flushed completion。这些行为留给 4.6，因为它们需要 SQ/RQ engine、completion engine 和 CQ manager 一起配合。

## QP_TO_ERROR

QP_TO_ERROR 的流程：

1. 按 QPN lookup 目标 QP。
2. 通过 owner function 权限检查。
3. 将 `state` 设置为 `QP_STATE_ERR`。
4. 设置 `error_state = 1`。
5. 写入命令携带的 `error_code`。
6. 写回 QP context table。

这一步只记录错误状态，不 flush WQE，不生成 CQE。后续 4.6 会在这个状态基础上加入 pending work 清理和 flushed completion。

## QP State Validator

`rtl/qp/qp_state_validator.sv` 是 4.3 阶段加入的状态迁移校验器。它是一个纯组合模块，输入当前 state、目标 state、QP type 和本次 `MODIFY_QP` 的 `modify_mask`，输出：

- `validate_allowed`：迁移是否允许；
- `validate_error_code`：失败原因；
- `required_attr_mask`：该迁移需要哪些属性；
- `missing_attr_mask`：本次命令缺少哪些属性。

Lifecycle manager 只在 `MODIFY_QP` 且 `QP_MOD_MASK_STATE` 置位时调用 validator。`QUERY_QP`、`DESTROY_QP` 和 `QP_TO_ERROR` 的基础行为不受它影响。

## 合法状态迁移表

当前阶段支持以下基础迁移：

| 当前状态 | 目标状态 | 说明 |
| --- | --- | --- |
| `RESET` | `INIT` | 初始化本地 QP 属性。 |
| `INIT` | `RTR` | Ready to Receive，准备接收入站包。 |
| `RTR` | `RTS` | Ready to Send，准备发送。 |
| `RTS` | `SQD` | Send Queue Draining。 |
| `SQD` | `RTS` | drain 后恢复发送。 |
| `RTS` | `SQE` | Send Queue Error。 |
| `SQE` | `RTS` | 从发送队列错误恢复，当前阶段只保留框架。 |
| 任意状态 | `ERR` | 进入错误状态。 |
| `ERR` | `RESET` | 错误恢复后回到 RESET。 |
| 任意状态 | 相同状态 | 保持当前状态，允许。 |

明显非法的例子：

- `RESET -> RTS`：没有经过 INIT/RTR，不能直接发送；
- `INIT -> RTS`：还没有进入 RTR；
- `RTR -> RESET`：当前阶段不允许直接回 RESET；
- `ERR -> RTS`：错误状态只能先回 RESET；
- `SQD -> RTR`：drain 状态不能倒退到 RTR；
- `SQE -> RTR`：发送队列错误不能倒退到 RTR。

## Required Attributes

状态迁移不仅要符合状态图，还要带齐必要属性。本阶段用 `modify_mask` 表示这次命令提供了哪些字段。

| 迁移 | 必需属性 |
| --- | --- |
| `RESET -> INIT` | `PD`、`CQs`、`queue base address`、`queue depth` |
| `INIT -> RTR` for RC | `remote_qpn`、`rq_psn/expected_psn`、`address handle` |
| `INIT -> RTR` for UD | `address handle` |
| `RTR -> RTS` for RC | `sq_psn`、`retry/rnr_retry` |
| `RTR -> RTS` for UD/UC | `sq_psn` |

如果必需属性没有出现在 `modify_mask` 中，validator 会返回 `QP_STATE_VAL_ERR_MISSING_ATTR`，并在 `missing_attr_mask` 中标出缺失项。Lifecycle manager 会把这个错误映射为 `QP_LC_ERR_MISSING_ATTR`。

当前实现只检查“本次命令是否携带了这些属性”，不检查字段值是否真实有效。例如它不会验证 CQ 是否存在、AH 是否可用、PSN 是否在合法范围内。这些检查会在 CQ/MR/AH 管理和 transport 阶段继续补充。

## SQ Engine

`rtl/qp/sq_engine.sv` 是 4.4 阶段加入的 Send Queue 执行骨架。它接在 SQ Doorbell handler 或后续 scheduler 后面，负责把“某个 QP 的 SQ 有新 WQE”转换成 WQE fetch、opcode decode 和 dispatch 请求。

```text
SQ Doorbell / scheduler
        |
        v
sq_engine
        |
        +--> QP context read
        +--> WQE fetch request
        +--> DMA dispatch request
        +--> transport dispatch request
        +--> completion/error request
        +--> SQ consumer index update
```

当前阶段它只定义接口和最小状态机，不实现真实 host DMA read，不生成 RoCEv2 packet，也不写真实 CQE。

## SQ Engine 状态机

| 状态 | 作用 |
| --- | --- |
| `IDLE` | 等待 Doorbell/scheduler 输入的 QPN 和 function。 |
| `LOOKUP_QP` | 通过 QP context read 接口读取目标 QP。 |
| `CHECK_STATE` | 检查 QP state 是否允许处理 SQ，并检查 SQ 是否非空。 |
| `FETCH_WQE` | 根据 `sq_base + sq_consumer * WQE_BYTES` 发出 WQE fetch request。 |
| `DECODE_WQE` | 解码 `wqe.opcode`。 |
| `DISPATCH` | 根据 opcode 分发到 DMA、transport、local invalidate 或 NOP path。 |
| `UPDATE_CI` | dispatch 成功后推进 SQ consumer index。 |
| `ERROR` | 输出 completion/error request。 |

## QP State 检查

SQ engine 只允许 `QP_STATE_RTS` 处理 SQ WQE。

- `RTS`：允许 fetch 和 dispatch；
- `SQD`：后续会进入 drain 逻辑，当前阶段只保留 TODO 并按不可处理返回错误；
- `RESET`、`INIT`、`RTR`、`SQE`、`ERR`：不允许消费 SQ WQE，输出错误 completion request。

这样设计的原因是 SQ engine 是真正开始消费 WQE 的地方。即使 lifecycle manager 已经约束了状态迁移，执行侧仍然要在消费队列前做最后一道状态检查。

## WQE Fetch

当 `sq_consumer != sq_producer` 时，SQ 非空。SQ engine 使用 QP context 中的字段生成 fetch request：

```text
wqe_fetch_addr = sq_base + sq_consumer * WQE_BYTES
wqe_fetch_qpn = qpn
wqe_fetch_owner_function = owner_func
wqe_fetch_sq_ci = sq_consumer
wqe_fetch_size = WQE_BYTES
```

本阶段 fetch response 直接使用 `smartnic_pkg.sv` 中的 `wqe_t`。真实 DMA 读取、PCIe Memory Read 和 host memory model 会在后续 DMA/verification 阶段补上。

## Opcode Decode 和 Dispatch

当前 SQ engine 支持或预留以下 opcode：

| Opcode | 行为 |
| --- | --- |
| `RDMA_OP_RDMA_WRITE` | 输出 DMA/transport dispatch 请求，后续由 DMA 和 RoCEv2 transport 完成数据搬运和发包。 |
| `RDMA_OP_RDMA_READ` | 输出 DMA/transport dispatch 请求，后续由 transport 发起 read request 并由 DMA 写回响应数据。 |
| `RDMA_OP_SEND` | 输出 transport dispatch 请求。 |
| `RDMA_OP_SEND_WITH_IMM` | 输出 transport dispatch 请求，并保留 immediate data 字段。 |
| `RDMA_OP_LOCAL_INV` | 输出 local invalidate 预留请求，本阶段不真正修改 MR 表。 |
| `RDMA_OP_NOP` | 不分发到 DMA/transport，只推进 SQ consumer index，并可生成成功 completion。 |
| 其他 opcode | 返回 `SQ_ENG_ERR_UNSUPPORTED_OPCODE`。 |

## Producer/Consumer Index

SQ engine 使用 `sq_consumer` 和 `sq_producer` 判断是否有 WQE：

- 两者相等表示 SQ 空，不发起 WQE fetch；
- 成功 dispatch 后输出 `sq_ci_update_new_ci`；
- 当 `sq_consumer == sq_depth - 1` 时，新 consumer index 回绕到 0；
- 当前阶段只检查 `sq_depth != 0`，更完整的 ring occupancy/overflow 检查会在后续 scheduler 和 queue manager 中继续完善。

## 错误输出

SQ engine 通过 `completion_req_valid` 和 `completion_error_code` 报告最小错误：

- `SQ_ENG_ERR_LOOKUP_MISS`：QPN lookup/read 未命中；
- `SQ_ENG_ERR_PERMISSION`：owner_function 不匹配；
- `SQ_ENG_ERR_BAD_STATE`：QP state 不允许消费 SQ；
- `SQ_ENG_ERR_UNSUPPORTED_OPCODE`：WQE opcode 不支持；
- `SQ_ENG_ERR_FETCH`：WQE fetch response 报错；
- `SQ_ENG_ERR_QUEUE_INDEX`：SQ depth/index 不合法。

真实 CQE 格式化和 CQE DMA 写回会在 CQ/completion 阶段实现；当前这里只输出 completion/error 请求接口。

## RQ Engine

`rtl/qp/rq_engine.sv` 是 4.5 阶段加入的 Receive Queue 执行骨架。它接在后续 inbound transport RX 后面，用来处理远端 Send/Send with immediate 到达本地 QP 时的接收路径。

```text
inbound transport RX
        |
        v
rq_engine
        |
        +--> QP context read
        +--> Recv WQE fetch request
        +--> DMA write dispatch request
        +--> RQ consumer index update
        +--> receive completion request
        +--> RNR/no receive buffer indication
```

当前阶段只定义接口和最小状态机，不实现真实 payload buffer、PCIe DMA write、MR/lkey 校验或 CQE 写回。

## RQ Engine 状态机

| 状态 | 作用 |
| --- | --- |
| `IDLE` | 等待 transport RX 输入入站 Send metadata。 |
| `LOOKUP_QP` | 按 `inbound_qpn` 和 `inbound_function_id` 读取 QP context。 |
| `CHECK_STATE` | 检查 QP state 是否允许接收入站 Send。 |
| `CHECK_RQ_AVAILABLE` | 检查 `rq_consumer != rq_producer`，确认有 posted Recv WQE。 |
| `FETCH_RECV_WQE` | 根据 `rq_base + rq_consumer * WQE_BYTES` 发起 Recv WQE fetch。 |
| `DECODE_RECV_WQE` | 读取 Recv buffer 地址、长度、lkey、flags 和 wr_id。 |
| `DISPATCH_DMA_WRITE` | 请求后续 DMA engine 把入站 payload 写入 Recv buffer。 |
| `UPDATE_CI` | DMA write 成功后推进 RQ consumer index。 |
| `COMPLETE` | 生成 receive completion request。 |
| `ERROR` | 输出 RNR 或错误 completion request。 |

## RQ State 和空队列检查

RQ engine 允许 `QP_STATE_RTR` 和 `QP_STATE_RTS` 接收入站 Send。`QP_STATE_SQD` 当前也允许接收，并保留 TODO：后续会根据 drain 语义决定是否继续允许 receive path 工作。

`RESET`、`INIT`、`SQE` 和 `ERR` 状态下，RQ engine 返回 `RQ_ENG_ERR_BAD_STATE`。这样设计是因为入站包真正落到 Recv buffer 前仍要做执行侧检查，不能只依赖 control plane 的状态迁移约束。

当 `rq_consumer == rq_producer` 时，RQ 为空，说明软件没有 posted Recv WQE。RQ engine 不会发起 DMA write，而是输出 `rnr_error_valid`，为后续 RC RNR NAK/retry 逻辑提供入口。

## Recv WQE Fetch 和 DMA Write

Recv WQE 当前复用 `smartnic_pkg.sv` 中的 `wqe_t`，其中接收路径使用这些字段：

| 字段 | 接收路径含义 |
| --- | --- |
| `local_va` | Recv buffer 目标地址。 |
| `lkey` | Recv buffer 的本地访问 key，后续 MR 检查使用。 |
| `length` | Recv buffer 可接收的最大字节数。 |
| `wr_id` | 软件提交 Recv WR 时传入的 ID，会回到 completion。 |
| `flags` | 预留给 scatter-gather、inline 或其他接收语义。 |

如果 `inbound_payload_len > wqe.length`，RQ engine 返回 `RQ_ENG_ERR_LOCAL_LEN`，避免把远端 payload 写超过软件提供的 Recv buffer。

DMA write 请求通过 `rq_dma_write_req_t` 输出，包含 `dst_addr`、`length`、`lkey`、`owner_func`、`qpn` 和 `wr_id`。本阶段不检查 lkey 是否有效，只把字段传给后续 MR/lkey 校验和 DMA engine。

## Receive Completion Request

DMA write 成功后，RQ engine 输出 `rq_completion_req_t`：

- `cqn` 来自 QP context 的 `recv_cqn`；
- `wr_id` 来自 Recv WQE；
- `byte_count` 来自入站 payload 长度；
- `recv_with_imm` / `has_imm` 标识普通 RECV 或 RECV_WITH_IMM；
- `imm_data` 透传 inbound immediate data；
- `solicited` 透传入站 solicited event 标志。

真实 CQE 格式化、CQ ring 写回、CQ arm 判断和 MSI-X interrupt moderation 会在后续 CQ completion path 中实现。当前阶段先把 receive completion request 的边界定义清楚。

## QP Cleanup Manager

`rtl/qp/qp_cleanup_manager.sv` 是 4.6 阶段加入的 destroy/error cleanup 控制框架。它处理两类入口：

- `destroy_qp_req`：来自 `DESTROY_QP` lifecycle command；
- `error_qp_req`：来自 `QP_TO_ERROR` 或后续 SQ/RQ/transport/DMA 错误路径。

它的核心目标是让 QP 退出时不再接收新 work，同时把已经提交但还没执行的 SQ/RQ slot 转换成 flushed completion 请求。

```text
DESTROY_QP / QP_TO_ERROR
        |
        v
qp_lifecycle_manager
        |
        v
qp_cleanup_manager
        |
        +--> QP context read/write
        +--> Doorbell block request
        +--> in-flight count quiesce
        +--> SQ flushed completion request
        +--> RQ flushed completion/cleanup request
        +--> cleanup done/status
```

## Cleanup 状态机

| 状态 | 作用 |
| --- | --- |
| `IDLE` | 等待 destroy 或 error cleanup 请求。 |
| `LOCK_QP` | 读取 QP context；如果 QPN 不存在或 function 不匹配，返回错误。 |
| `BLOCK_DOORBELL` | 输出 `qp_block_doorbell_valid/qpn/function_id`，让 Doorbell path 或 QP table 拒绝新的 producer 更新。 |
| `QUIESCE_PENDING_WORK` | 等待 `sq_inflight_count`、`rq_inflight_count`、`dma_inflight_count`、`transport_inflight_count` 全部归零。 |
| `FLUSH_SQ` | 从 `sq_consumer` 追到 `sq_producer`，为每个未消费 SQ slot 生成 `CMPL_WR_FLUSH_ERR`。 |
| `FLUSH_RQ` | 从 `rq_consumer` 追到 `rq_producer`，为每个未消费 RQ slot 生成 receive flush/cleanup indication。 |
| `UPDATE_CONTEXT` | destroy 时清空 `valid`；error 时设置 `state = ERR`、`error_state` 和 `error_code`。 |
| `DONE` | 返回 cleanup 成功状态和更新后的 context。 |
| `ERROR` | 返回 lookup miss、permission、timeout、backpressure、already ERR/destroyed 等错误。 |

## Doorbell Blocking

cleanup 一开始要先挡住 Doorbell，而不是先 flush。原因是如果软件或 VF 在 cleanup 过程中继续写 SQ/RQ producer index，硬件就无法定义“哪些 WQE 应该被 flush，哪些是 cleanup 后新来的非法提交”。

本阶段 `qp_cleanup_manager` 只输出 block 请求：

```text
qp_block_doorbell_valid
qp_block_doorbell_qpn
qp_block_doorbell_function_id
```

真正让 Doorbell path 或 QP context table 拒绝新 SQ/RQ/CQ arm 更新，会在后续 top-level integration 中把这个信号接到 Doorbell/QP 表的权限检查路径。

## Pending Work Quiesce

cleanup manager 使用四个计数输入等待数据通路安静下来：

- `sq_inflight_count`
- `rq_inflight_count`
- `dma_inflight_count`
- `transport_inflight_count`

这些计数后续会来自 SQ/RQ engine、DMA engine 和 transport engine。当前阶段只定义接口和最小等待逻辑。如果超过 `cleanup_timeout_limit`，cleanup 返回 timeout。这样设计是为了避免 destroy 卡死，同时给后续 driver error recovery 一个明确的失败状态。

## Flushed Completion 语义

当 in-flight work 已经 drain 后，QP context 里仍可能有软件已经 posted、但硬件还没消费的 WQE：

```text
SQ pending: sq_consumer != sq_producer
RQ pending: rq_consumer != rq_producer
```

cleanup manager 不读取真实 WQE 内容，也不知道 WR ID；本阶段只基于 QPN、CQN 和 queue slot index 生成 `qp_flush_completion_req_t`：

- SQ flush 使用 `send_cqn`；
- RQ flush 使用 `recv_cqn`；
- status 固定为 `CMPL_WR_FLUSH_ERR`；
- `is_sq` / `is_rq` 标记来源队列；
- `queue_index` 标记被 flush 的 slot。

后续 CQ completion path 会把这个请求转换成真实 CQE，并在能拿到 WR ID/WQE metadata 后补齐 Verbs work completion 字段。

## Lifecycle 对接

4.6 后，`qp_lifecycle_manager.sv` 不再在 `DESTROY_QP` 时直接写 `valid = 0`，也不再在 `QP_TO_ERROR` 时只写 `ERR`。它改为输出 cleanup 请求，并等待 cleanup manager 返回：

- cleanup 成功：lifecycle 返回命令成功和 cleanup 后 context；
- cleanup 失败：lifecycle 把 lookup/permission/already destroyed 等错误映射回命令错误码。

这个拆分让 lifecycle manager 保持“控制命令状态机”的角色，而 cleanup manager 专注处理 pending work、flush 和 context 收尾。

## 权限检查

非 admin/bypass 命令只能管理自己的 QP。Lifecycle manager 调用 QP context table 的 read/write 接口，由 QP 表检查 `cmd_owner_function` 是否匹配 context 中的 `owner_func`。

CREATE_QP 额外会检查 `owner_function` 是否是合法 PF/VF 编号。这样可以避免软件把 QP 创建到不存在的 function 名下。

## 本阶段仍不做的事情

- 不检查 CQ/PD/MR/AH 是否真实存在。
- 不实现真实 DMA cancel。
- 不清除真实 transport retry/outstanding packet 状态。
- 不读取真实 SQ/RQ WQE 内容。
- 不写真实 CQE，只输出 flushed completion 请求。
- 不触发 MSI-X。
