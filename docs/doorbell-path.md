# Doorbell Path

本文说明当前阶段新增的 `doorbell_decoder`。它只负责把 BAR0 Doorbell aperture 的 offset 解码成三类 Doorbell 事件，不更新 QP/CQ 状态，也不解析完整 payload。

## 系统位置

```text
Host MMIO write
  -> PCIe endpoint
  -> pcie_bar_decoder
  -> doorbell_decoder
  -> 后续 QP SQ / QP RQ / CQ arm 逻辑
```

`pcie_bar_decoder` 已经负责识别 BAR0 并把请求转发到 Doorbell path。`doorbell_decoder` 接收 `doorbell_req_offset`、`doorbell_req_wdata`、`doorbell_req_func_id`，然后根据地址生成一个规范化 Doorbell 事件。

## BAR0 地址布局

当前阶段采用 4 KiB Doorbell page：

```text
BAR0 + page_id * 0x1000
  + 0x000  QP SQ Doorbell
  + 0x008  QP RQ Doorbell
  + 0x010  CQ Arm Doorbell
```

其中：

- `page_id = BAR0 offset >> 12`
- SQ/RQ Doorbell 中，`page_id` 暂时解释为 `qpn`
- CQ Arm Doorbell 中，`page_id` 暂时解释为 `cqn`
- `raw_payload` 原样透传给后续模块
- `queue_index` 只取 payload 低 `QUEUE_IDX_W` 位，作为后续 producer/consumer index 解析的输入

## 输出事件

`doorbell_decoder` 输出：

| 字段 | 作用 |
| --- | --- |
| `doorbell_valid` | 解码成功，有一个 Doorbell 事件 |
| `doorbell_type` | `DB_TYPE_SQ`、`DB_TYPE_RQ` 或 `DB_TYPE_CQ_ARM` |
| `qpn` | SQ/RQ Doorbell 的目标 QP |
| `cqn` | CQ arm Doorbell 的目标 CQ |
| `queue_index` | payload 低位中的队列索引，占位透传 |
| `raw_payload` | 原始 BAR0 写数据 |
| `owner_function` | 发起 Doorbell 的 PF/VF function |

## PF/VF 访问隔离

3.2 新增 `doorbell_access_check`，位于 `doorbell_decoder` 之后：

```text
pcie_bar_decoder
  -> doorbell_decoder
  -> doorbell_access_check
  -> sq_doorbell_handler / 后续 RQ/CQ arm 处理
```

`doorbell_access_check` 不重新解析地址，也不解析 payload。它只检查解码后的 Doorbell 事件是否允许继续向后传递。

检查输入来自两侧：

- `doorbell_decoder`：`doorbell_type`、`qpn`、`cqn`、`owner_function`。
- `pcie_function_manager`：`function_id`、`is_pf`、`vf_id`、`function_enabled`、`resource_window`。

检查规则：

| 场景 | 结果 |
| --- | --- |
| PF 访问其资源窗口内的 QP/CQ Doorbell | 允许 |
| enabled VF 访问自己资源窗口内的 QP/CQ Doorbell | 允许 |
| disabled VF 访问 Doorbell | 拒绝，返回 `SRIOV_ACCESS_DISABLED` |
| VF 访问其他 VF 的 Doorbell | 拒绝，返回 `SRIOV_ACCESS_DENIED` 或 `SRIOV_ACCESS_OUT_OF_RANGE` |
| QPN/CQN 超出当前 function 的资源窗口 | 拒绝，返回 `SRIOV_ACCESS_OUT_OF_RANGE` |

这样可以防止一个 VF 通过伪造 BAR0 offset 去 ring 另一个 VF 的 QP/CQ Doorbell。

## 错误处理

当前阶段返回以下错误状态：

- offset 超出 BAR0 aperture：`PCIE_BAR_RSP_BAD_OFFSET`
- offset 非 dword 对齐：`PCIE_BAR_RSP_MISALIGNED`
- 非写访问或 byte enable 为空：`PCIE_BAR_RSP_UNSUPPORTED`
- page 内 offset 不是 `0x000`、`0x008`、`0x010`：`PCIE_BAR_RSP_BAD_OFFSET`

## 为什么这样设计

Doorbell 是 fast path。用户态写 WQE/RQE 后，不通过 mailbox，而是直接 MMIO 写 BAR0。把地址解码单独放在 `doorbell_decoder` 中，有两个好处：

- `pcie_bar_decoder` 只需要关心 BAR 路由，不需要理解 RDMA 队列语义。
- 后续 3.3、3.4、3.5 可以分别接收已分类的 SQ、RQ、CQ arm 事件，专注解析 payload 和更新对应上下文。

后续衔接：

- 3.3 会解析 `DB_TYPE_SQ` payload，并更新 QP SQ producer index。
- 3.4 会解析 `DB_TYPE_RQ` payload，并更新 QP RQ producer index。
- 3.5 会解析 `DB_TYPE_CQ_ARM` payload，并更新 CQ arm/consumer/solicited-only 状态。

从 3.2 开始，后续 3.3、3.4、3.5 应只消费 `access_allowed=1` 的 Doorbell 事件。被拒绝的 Doorbell 不应产生 QP/CQ 状态副作用。

## SQ Doorbell payload

3.3 新增 `sq_doorbell_handler`，只处理 `DB_TYPE_SQ`。它接收 `doorbell_decoder` 的 `raw_payload` 和 `queue_index`，同时接收 `doorbell_access_check` 的权限结果，再生成给后续 QP manager 使用的 SQ producer index 更新事件。

当前 SQ Doorbell payload 是 32 bit：

| bit 范围 | 字段 | 作用 |
| --- | --- | --- |
| `[15:0]` | `new_sq_producer_index` | 软件写入的新 SQ producer index |
| `[23:16]` | `doorbell_sequence` | 软件递增序号，当前用于调试/测试，后续可做乱序检测 |
| `[31:24]` | `flags` | SQ Doorbell flags，当前允许 `SQ_DB_FLAG_SIGNAL` 和 `SQ_DB_FLAG_FENCE` |

`doorbell_decoder` 已经把 payload 低 `QUEUE_IDX_W` 位透传为 `queue_index`。`sq_doorbell_handler` 会检查 `queue_index` 是否等于 payload 中的 `new_sq_producer_index`，这能尽早发现集成阶段的连线或 payload 格式错误。

## SQ producer index 更新流程

```text
用户态写 SQ WQE
  -> MMIO 写 BAR0 SQ Doorbell
  -> doorbell_decoder 解码 QPN 和 raw_payload
  -> doorbell_access_check 检查 PF/VF ownership
  -> sq_doorbell_handler 解析 new_sq_producer_index
  -> 输出 qp_update_* 事件给后续 QP manager
```

`sq_doorbell_handler` 输出的核心字段：

| 字段 | 作用 |
| --- | --- |
| `qp_update_valid` | 有一个 SQ PI 更新事件 |
| `qp_update_qpn` | 需要更新的 QP |
| `qp_update_function_id` | 该 QP 所属 PF/VF function |
| `qp_update_new_sq_pi` | 新的 SQ producer index |
| `qp_update_wraparound` | 新 PI 小于旧 PI，说明 16 bit PI 已回绕 |
| `qp_update_error` | 该事件不能用于真实更新 |
| `qp_update_error_code` | 错误原因，例如权限失败、非法 QPN、payload 错误 |

producer index 回绕不是错误。队列索引是有限位宽计数器，软件持续投递 WQE 时，新 PI 可能从 `0xffff` 回到 `0x0000`。因此当前模块只把回绕作为 `qp_update_wraparound` 元数据报告给后续 QP manager，由后续队列深度和 consumer index 逻辑判断是否有溢出或未消费 WQE。

当前阶段会拒绝以下 SQ Doorbell：

| 场景 | 错误码 |
| --- | --- |
| `doorbell_type` 不是 `DB_TYPE_SQ` | `DB_ERR_NOT_SQ` |
| 3.2 权限检查失败 | `DB_ERR_ACCESS_DENIED` |
| QP context 无效 | `DB_ERR_INVALID_QPN` |
| flags 含未知 bit，或 payload PI 与 `queue_index` 不一致 | `DB_ERR_BAD_PAYLOAD` |

这个设计把 Doorbell fast path 拆成三步：地址分类、权限隔离、payload 语义解析。后续 3.4 可以用同样模式实现 RQ producer index，3.5 可以用同样模式实现 CQ arm，而 4.4 的 QP scheduler/WQE fetch 会消费 `qp_update_*`，知道某个 QP 的 SQ 中出现了新的 WQE。
