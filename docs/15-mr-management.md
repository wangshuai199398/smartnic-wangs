# MR Management

本文说明 Memory Region 管理相关模块。6.1 阶段加入 `rtl/mr/mr_table.sv`，它是 MR/MW manager 的基础“账本”：保存 lkey、rkey、虚拟地址范围、物理/DMA 地址、长度、页大小、访问标志、PD、owner function、refcount 和 pending deregister 状态。

当前阶段只实现 MR table 的最小行为，不处理 MR 注册命令、不解析 scatter-gather page list、不实现完整访问权限、PD 规则或 Memory Window bind。

## MR Entry 字段

`mr_entry_t` 保存在 `rtl/common/smartnic_pkg.sv` 中，主要字段如下：

- `valid`：该表项是否有效；
- `mr_id`：驱动可见的 MR handle；
- `lkey`：本地 DMA 使用的 key；
- `rkey`：远端 RDMA 访问使用的 key；
- `virtual_base_addr`：MR 覆盖的起始虚拟地址；
- `physical_base_addr`：对应的起始物理/DMA 地址；
- `length`：MR 覆盖的字节数；
- `page_size`：页大小编码，通常表示 log2(page bytes)；
- `access_flags`：本地读写、远端读写、atomic、MW bind 等权限位；
- `pd_id`：所属 Protection Domain；
- `owner_function`：所属 PF/VF function；
- `refcount`：正在引用该 MR 的 in-flight DMA/transport 操作数量；
- `pending_deregister`：已经开始注销，不允许新的 lookup/check；
- `memory_window`：预留 Memory Window 表项标志；
- `parent_mr_key`：Memory Window 绑定的父 MR key；
- `error_state` / `error_code`：错误状态和调试用错误码。

## lkey/rkey Lookup

`mr_table` 提供 key lookup 接口：

```text
lookup_valid
lookup_key
lookup_is_remote
lookup_owner_function
lookup_pd_id
lookup_hit
lookup_entry
lookup_error_code
```

本地操作使用 `lkey` 匹配，远端操作使用 `rkey` 匹配。只有 `valid = 1` 的表项可以命中。`pending_deregister = 1` 的表项默认拒绝新的 lookup，返回 `MR_TABLE_STATUS_PENDING`。

当前阶段只保存并透传 `pd_id`，完整 PD 匹配规则留给 6.6。

## VA 到 PA 转换

地址检查接口基于 key 找到 MR 后执行范围检查：

```text
check_va >= virtual_base_addr
check_va + check_len <= virtual_base_addr + length
```

如果合法，则输出：

```text
check_pa = physical_base_addr + (check_va - virtual_base_addr)
```

错误处理包括：

- `check_len = 0` 返回 `MR_TABLE_STATUS_LENGTH`；
- `check_va < virtual_base_addr` 返回 `MR_TABLE_STATUS_BOUNDS`；
- `check_va + check_len` 超过 MR 末尾返回 `MR_TABLE_STATUS_BOUNDS`；
- 地址加法溢出也返回 `MR_TABLE_STATUS_BOUNDS`。

## Key Alias 防护

写入 MR entry 时，硬件检查所有有效表项：

- 不允许两个有效表项使用同一个 `lkey`；
- 不允许两个有效表项使用同一个 `rkey`；
- 发现重复 key 时返回 `MR_TABLE_STATUS_ALIAS`。

这样可以避免 DMA 或远端访问通过 key 查找时命中多个 MR，保证后续权限检查和地址转换有唯一来源。

## Owner Function 隔离

lookup、check、read、write 和 refcount update 都检查 `owner_function`。非 owner function 访问返回 `MR_TABLE_STATUS_PERMISSION`。

`admin_bypass` 作为 PF/管理路径预留信号保留在接口里，但当前阶段不实现复杂 PF 策略。

## Refcount 与 Pending Deregister

`refcount` 表示正在使用该 MR 的 in-flight 操作数量。6.1 只提供基础 `ref_inc_valid` 和 `ref_dec_valid`：

- inc 成功后 `refcount + 1`；
- dec 成功后 `refcount - 1`；
- inc 到全 1 后继续 inc 返回 `MR_TABLE_STATUS_REF_OVER`；
- refcount 为 0 时 dec 返回 `MR_TABLE_STATUS_REF_UNDER`；
- `refcount_zero` 指示更新后是否为 0。

`pending_deregister` 表示驱动已经发起注销。处于 pending 状态时，不允许新的 lookup/check，但允许后续 6.3 通过 refcount drain 等待旧操作完成后释放表项。

## MR Registration

6.2 阶段加入 `rtl/mr/mr_registration_manager.sv`，用于处理 REGISTER_MR 控制命令。它不直接 pin 用户页；pin page 仍然是 Linux driver 的职责。

推荐软件到硬件流程如下：

```text
userspace reg_mr()
  -> Linux driver pin_user_pages()
  -> driver 构造 pinned SG list
  -> CSR mailbox REGISTER_MR
  -> mr_registration_manager fetch 第一个 SG entry
  -> 构造 mr_entry_t
  -> 写入 mr_table
  -> 返回 lkey/rkey/mr_index/status
```

REGISTER_MR 请求包含：

```text
owner_function
pd_id
virtual_base_addr
length
page_size
access_flags
sg_list_base_addr
sg_entry_count
lkey
rkey
cmd_sequence
```

当前阶段只支持单段/线性 SG list，因此 `sg_entry_count` 必须为 1。多段 page walk、IOMMU/IOTLB 以及真实 DMA fetch 留给后续 DMA/MR translation 阶段。

## Pinned SG Entry

`sg_entry_t` 描述驱动已经 pin 好并 DMA-map 好的一段物理地址：

- `physical_base_addr`：该段起始物理/DMA 地址；
- `length`：该段覆盖字节数；
- `page_count`：页数量；
- `page_size`：页大小 log2(bytes)；
- `flags`：pinned、只读等标志预留；
- `reserved`：保留字段。

`mr_registration_manager` 发出：

```text
sg_fetch_valid
sg_fetch_addr = sg_list_base_addr
sg_fetch_len  = SG_ENTRY_BYTES
sg_fetch_owner_function
```

本阶段不实现真实 DMA read。测试或后续 fetch path 用 `sg_fetch_resp_valid` 和 `sg_fetch_resp_data` 返回第一个 SG entry。

## Registration 校验

请求校验包括：

- `length != 0`；
- `page_size` 当前支持 4 KiB、2 MiB 和 1 GiB 编码；
- `virtual_base_addr` 必须按 `page_size` 对齐；
- `sg_entry_count != 0`；
- `sg_entry_count` 不能超过当前支持的单段范围；
- `access_flags` 不能包含未知 bit；
- `lkey` 和 `rkey` 不能为 0；
- `owner_function` 必须已启用。

SG entry 校验包括：

- `physical_base_addr` 按 `page_size` 对齐；
- `sg_entry.length >= reg_req_length`；
- `sg_entry.page_size == reg_req_page_size`；
- `physical_base_addr + length` 不发生地址溢出。

## 写入 MR Table

校验通过后，registration manager 构造：

```text
valid              = 1
lkey/rkey          = 请求中的 key
virtual_base_addr  = 请求 VA
physical_base_addr = SG entry PA
length             = 请求 length
page_size          = 请求 page_size
access_flags       = 请求 access_flags
pd_id              = 请求 PD
owner_function     = 请求 function
refcount           = 0
pending_deregister = 0
memory_window      = 0
error_state        = 0
```

然后通过 `mr_table` 的 `entry_write_*` 接口写入显式 slot。registration manager 使用最小 allocation bitmap 选择 slot；`mr_table` 仍负责最终的 lkey/rkey alias 防护。如果 table 返回 alias 或其他写错误，REGISTER_MR 返回失败。

当前 CSR mailbox 已支持 `CSR_CMD_REG_MR` 命令枚举和 command pulse。完整 mailbox 参数解码到 registration manager、以及 done/status 回写，将在后续顶层 control path 集成时连接。

## MR Deregistration

6.3 阶段加入 `rtl/mr/mr_deregistration_manager.sv`，用于处理 DEREGISTER_MR 控制命令。注销不能直接把 `valid` 清零，因为 DMA engine、transport RX/TX 或后续 MR permission path 可能已经完成 lookup，并正在使用该 MR 的地址转换结果。如果此时马上复用同一个 lkey/rkey 或 table entry，就可能让旧 DMA 和新 MR 混在一起。

因此注销流程分成两步：

```text
DEREGISTER_MR
  -> lookup MR by lkey/rkey
  -> 检查 owner_function 和 PD
  -> 设置 pending_deregister = 1
  -> 等待 refcount drain 到 0
  -> 清除 valid/refcount/access_flags/pending_deregister
  -> 返回 done/status/error
```

请求接口包含：

```text
dereg_req_owner_function
dereg_req_key
dereg_req_is_remote_key
dereg_req_pd_id
dereg_req_force
dereg_req_cmd_sequence
```

响应接口返回：

```text
dereg_resp_status
dereg_resp_error_code
dereg_resp_key
dereg_resp_cmd_sequence
```

`dereg_req_is_remote_key = 0` 时按 `lkey` 查找，`dereg_req_is_remote_key = 1` 时按 `rkey` 查找。当前阶段保留 `force` 给未来 PF/admin force deregister 使用，但不实现复杂策略。

## Pending Deregister 与 Refcount Drain

`pending_deregister` 是“停止接新活”的标志：

- 新的 MR lookup/check 默认拒绝 pending 表项；
- 已经拿到引用的 in-flight DMA/transport 操作可以继续完成；
- refcount 未清零前，MR entry 保持 `valid = 1`，避免旧操作找不到上下文；
- refcount 清零后，deregistration manager 才清除 `valid` 并释放 entry。

这对应 spec 中 “MR deregistration waits for active DMA” 的要求：注销先阻止新访问，再等待旧访问完成。这样不会丢掉正在进行的 DMA，也不会让被注销的 key 被新请求继续使用。

当前状态机为：

```text
IDLE
LOOKUP_MR
CHECK_PERMISSION
MARK_PENDING_DEREGISTER
WAIT_REFCOUNT_ZERO
CLEAR_MR_ENTRY
RESPOND
ERROR
```

错误处理包括：

- key 为 0 或 MR lookup miss；
- owner_function 不匹配；
- PD mismatch；
- MR 已经处于 pending_deregister；
- refcount drain timeout；
- MR table read/write 返回错误。

当前阶段不取消真实 DMA，不实现 Memory Window 级联失效，也不实现 PF/admin force deregister。后续 6.4/6.5 会在 key direction 和 permission check 中复用 pending/refcount 语义，确保注销中的 MR 不再被新的本地或远端访问命中。

## lkey / rkey 方向检查

6.4 阶段加入 `rtl/mr/mr_key_checker.sv`，它是 DMA/transport 访问 MR table 前的统一方向检查入口。它解决一个很容易混淆的问题：`lkey` 和 `rkey` 都是 key，但使用场景完全不同，不能互相兜底。

方向规则如下：

- 本地 SQ WQE fetch、Send payload read、RDMA Write 本地 payload read 使用 `lkey`；
- 本地 Recv buffer write、RDMA Read response 写入本地 host buffer 也使用 `lkey`；
- 远端 RDMA Read 读取本端内存使用 `rkey`；
- 远端 RDMA Write 写入本端内存使用 `rkey`；
- 远端 Atomic 使用 `rkey`；
- Memory Window bind 当前先按本地路径预留，完整规则留给 6.7；
- 本地路径如果传入 `rkey`，返回 `MR_KEY_CHECK_ERR_LOCAL_KEY_REQUIRED`；
- 远端路径如果传入 `lkey`，返回 `MR_KEY_CHECK_ERR_REMOTE_KEY_REQUIRED`；
- 方向错误时不会再去 `mr_table` 尝试另一个 key。

`mr_key_checker` 请求接口：

```text
key_check_valid
key_check_key
key_check_is_remote
key_check_operation
key_check_owner_function
key_check_pd_id
key_check_va
key_check_len
```

方向正确后，它调用 `mr_table` 的地址检查接口：

```text
mr_check_key       = key_check_key
mr_check_is_remote = key_check_is_remote
mr_check_va        = key_check_va
mr_check_len       = key_check_len
```

因此 `mr_table` 仍然负责精确的 lkey/rkey lookup、`pending_deregister` 拒绝、owner function 检查和 VA bounds 检查。`mr_key_checker` 负责把 table status 映射成更贴近上游 DMA/transport 的 key check 错误码。

当前阶段不检查 `access_flags`。例如本地 read/write 是否被 MR 权限允许、远端 write/read/atomic 是否被授权，会在 6.5 中继续接在方向检查之后。完整 Protection Domain 规则会在 6.6 加入，Memory Window bind/unbind 会在 6.7 加入。

## Access Permission Check

6.5 阶段加入 `rtl/mr/mr_access_checker.sv`，它放在 key direction check 后面，负责解释 `mr_entry_t.access_flags`。这样数据通路可以分成三层逐步收紧：

```text
key direction check
  -> lkey/rkey lookup and bounds context
  -> access_flags permission check
  -> PD check
  -> DMA address translation / transport access
```

权限 bit 定义如下：

| Access Flag | 作用 |
| --- | --- |
| `MR_ACCESS_LOCAL_READ` | 允许本地 DMA 从 MR 读数据，例如 Send/RDMA Write payload read |
| `MR_ACCESS_LOCAL_WRITE` | 允许本地 DMA 写 MR，例如 Recv buffer write 或 RDMA Read response 写入 |
| `MR_ACCESS_REMOTE_READ` | 允许远端 RDMA Read 读取本端 MR |
| `MR_ACCESS_REMOTE_WRITE` | 允许远端 RDMA Write 写入本端 MR |
| `MR_ACCESS_REMOTE_ATOMIC` | 允许远端 Atomic 操作 |
| `MR_ACCESS_MW_BIND` | 允许基于该 MR 绑定 Memory Window |

operation 到权限 bit 的映射如下：

| Operation | Required Flag |
| --- | --- |
| `MR_OP_LOCAL_READ` / `MR_OP_LOCAL_DMA_READ` | `MR_ACCESS_LOCAL_READ` |
| `MR_OP_LOCAL_WRITE` / `MR_OP_LOCAL_DMA_WRITE` | `MR_ACCESS_LOCAL_WRITE` |
| `MR_OP_LOCAL_RECV_WRITE` | `MR_ACCESS_LOCAL_WRITE` |
| `MR_OP_REMOTE_READ` / `MR_OP_REMOTE_RDMA_READ` | `MR_ACCESS_REMOTE_READ` |
| `MR_OP_REMOTE_WRITE` / `MR_OP_REMOTE_RDMA_WRITE` | `MR_ACCESS_REMOTE_WRITE` |
| `MR_OP_REMOTE_ATOMIC` | `MR_ACCESS_REMOTE_ATOMIC` |
| `MR_OP_MW_BIND` | `MR_ACCESS_MW_BIND` |

`mr_access_checker` 还会重复检查一些基础条件：

- MR entry 必须 `valid = 1`；
- `pending_deregister = 1` 的 MR 不允许新访问；
- `owner_function` 必须匹配发起访问的 function；
- `access_check_len` 不能为 0；
- `VA + len` 不能溢出；
- 访问范围必须落在 `virtual_base_addr .. virtual_base_addr + length` 内；
- Memory Window entry 的权限不能超过预留的 parent permission mask，完整 MW bind 逻辑留给 6.7。

当前阶段仍不做完整 PD mismatch 规则。`access_check_pd_id` 已经在接口中保留，6.6 会把 PD 规则接在 access permission check 之后。

## Protection Domain Check

6.6 阶段加入 `rtl/mr/mr_pd_checker.sv`。Protection Domain，简称 PD，是 RDMA 资源隔离边界：同一个 PD 中创建的 QP、MR、CQ 等资源可以被同一组 verbs 对象组合使用；不同 PD 之间即使 key、地址和权限 bit 看起来正确，也不能互相访问。

推荐 MR 检查顺序现在变为：

```text
key direction check
  -> MR lookup / pending / bounds context
  -> access_flags permission check
  -> QP PD == MR PD check
  -> DMA dispatch or transport memory access
```

PD 检查规则：

- 本地操作：SQ/RQ engine 从 QP context 取出 `pd_id`，它必须等于 MR entry 的 `pd_id`；
- 远端操作：transport RX 先确定目标 QP，再使用目标 QP 的 `pd_id` 与被访问 MR 的 `pd_id` 比较；
- `QP PD != MR PD` 时返回 `MR_PD_CHECK_ERR_PD_MISMATCH`；
- `owner_function` 仍必须匹配 MR entry，避免 cross-VF 借用另一个 function 的 MR；
- 当前阶段要求调用方直接提供 `qp_pd_id`，按 `qpn` 反查 QP context 的接口在模块中预留，后续 top/control pipeline 集成时连接；
- Memory Window parent PD mismatch 只保留错误码和 parent PD 输入，完整 MW bind/unbind 留给 6.7。

这样设计的好处是每一道检查职责很窄：`mr_key_checker` 只回答“key 用法对不对”，`mr_access_checker` 只回答“这个 MR 允许这种操作吗”，`mr_pd_checker` 只回答“这个 QP 和这个 MR 是否属于同一个保护域”。后续 SQ engine、RQ engine 和 transport remote operation 只需要把 QP context 中的 `pd_id` 传入 MR pipeline，就能统一复用这套保护逻辑。

## Memory Window

6.7 阶段加入 `rtl/mr/mr_memory_window_manager.sv`。Memory Window，简称 MW，是从 parent MR 派生出来的、更窄的远端访问窗口。它复用 MR table entry 格式，但 `memory_window = 1`，并记录：

- `parent_mr_key`：绑定来源 parent MR 的 lkey；
- `bound_qpn`：绑定这个 MW 的 QPN；
- `rkey`：给远端使用的 MW rkey；
- `virtual_base_addr` / `length`：MW 暴露的 VA 范围；
- `physical_base_addr`：由 parent MR 的 PA 加 offset 得到；
- `access_flags`：MW 自己允许的远端访问权限；
- `invalidating`：unbind 或 QP error cleanup 正在使 MW 失效。

### Bind 流程

```text
MW_BIND request
  -> lookup parent MR by parent_lkey
  -> validate parent valid / owner / PD / not pending / not MW
  -> validate bind range inside parent MR
  -> validate MW permission subset
  -> check mw_rkey alias
  -> write MW entry into MR table
  -> response
```

当前阶段禁止 MW over MW。如果 `design.md` 后续明确支持，再把 `parent.memory_window` 的检查改成允许并递归校验 parent chain。

### Permission Subset

MW 不能扩大 parent MR 权限。也就是说：

- MW 请求 `REMOTE_READ` 时，parent MR 必须有 `MR_ACCESS_REMOTE_READ`；
- MW 请求 `REMOTE_WRITE` 时，parent MR 必须有 `MR_ACCESS_REMOTE_WRITE`；
- MW 请求 `REMOTE_ATOMIC` 时，parent MR 必须有 `MR_ACCESS_REMOTE_ATOMIC`；
- 当前阶段默认拒绝 MW 自己携带 `MR_ACCESS_MW_BIND`；
- 本地 read/write 权限暂不作为 MW 远端暴露权限使用。

这样远端拿到 MW rkey 后，只能访问 parent MR 中被显式缩小出来的一段地址和权限集合，不能靠 MW 获得 parent MR 没有授予的能力。

### Unbind 流程

```text
MW_UNBIND request
  -> lookup MW by mw_rkey
  -> require entry.valid && entry.memory_window
  -> check owner_function and PD
  -> set pending_deregister / invalidating
  -> wait refcount == 0
  -> clear MW entry.valid
  -> response
```

unbind 不清除 parent MR，也不改变 parent MR refcount。当前设计假设绑定期间不增加 parent MR refcount；后续如果加入 parent pin/drain 语义，可以在 bind/unbind 状态机中补 parent refcount 操作。

### QP Error Invalidation

当绑定 MW 的 QP 进入 ERR 或 cleanup，硬件需要使相关 MW 失效，避免出错 QP 的 rkey 继续可用。6.7 阶段提供最小框架：

```text
QP error invalidate
  -> scan MW entries by bound_qpn / owner_function / PD
  -> mark matching MW pending_deregister + invalidating
  -> wait refcount drain
  -> clear MW entry
```

当前 RTL 暴露 `mw_scan_*` 预留接口，由后续 top 或 MR table scanner 接入真实扫描。本阶段测试用 mock scan 响应验证控制状态机。

### 与访问路径的关系

`mr_key_checker` 按 rkey 查到 MW entry 时，不回退 parent MR；`mr_access_checker` 使用 MW entry 自己的 `access_flags`、range 和 `physical_base_addr`；`mr_pd_checker` 使用 MW entry 的 `pd_id`。如果 MW 正在 `pending_deregister` 或 `invalidating`，新访问会被拒绝。

## 后续连接

- 6.2 MR registration 会通过写接口创建 MR entry；
- 6.3 deregistration drain 会设置 `pending_deregister` 并等待 `refcount_zero`；
- 6.4 key direction checks 会细化 lkey/rkey 使用方向；
- 6.5 access permission checks 会解释 `access_flags`；
- 6.6 PD checks 会正式校验 `pd_id`；
- 6.7 Memory Window 会使用 `memory_window` 和 `parent_mr_key` 实现 bind/unbind。
