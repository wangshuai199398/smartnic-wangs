# SR-IOV Function 管理

本文说明当前阶段新增的 `pcie_function_manager`。它的目标不是实现完整 SR-IOV，而是先建立一个最小的 PF/VF 身份和资源隔离框架，让后续 Doorbell、CSR mailbox、MSI-X、QP/CQ/MR 管理都能复用同一套访问检查。

## 模块位置

```text
PCIe inbound TLP
  -> requester_id / function_id
  -> pcie_function_manager
  -> BAR0 Doorbell / BAR2 CSR / BAR4 MSI-X / QP/CQ/MR manager
```

`pcie_function_manager` 位于 PCIe 控制平面和资源管理模块之间。上游提供 `requester_id` 或 `function_id`，模块返回：

- `sriov_function_identity_t`：访问来自 PF 还是 VF、是否 enabled、是否 trusted。
- `sriov_resource_window_t`：该 function 拥有的 QP、CQ、MR、Doorbell、MSI-X vector 范围。
- `sriov_access_status_e`：访问是否允许，以及失败原因。

## Function Identity

当前原型阶段使用简单规则：

- `function_id == 0` 表示 PF。
- `function_id >= 1` 表示 VF，`function_id 1` 对应 `VF0`。
- 当按 `requester_id` 查询时，暂时使用 `requester_id` 低位作为 `function_id`。
- 真实 PCIe/SR-IOV 集成时，这里会替换成 bus/device/function 到 PF/VF 的映射表。

这样设计的原因是：学习阶段先把“谁在访问”这个问题抽象出来，后续不用在 Doorbell、CSR、MSI-X、QP、CQ、MR 每个模块里重复写一套 PF/VF 判断。

## Resource Window

每个 function 都有一组资源窗口：

| 字段 | 作用 |
| --- | --- |
| `qp_base / qp_limit` | 限定该 function 可访问的 QP 编号范围 |
| `cq_base / cq_limit` | 限定该 function 可访问的 CQ 编号范围 |
| `mr_base / mr_limit` | 限定该 function 可访问的 MR handle 范围 |
| `doorbell_base / doorbell_limit` | 限定该 function 可写的 BAR0 Doorbell aperture |
| `msix_vector_base / msix_vector_limit` | 限定该 function 可使用的 MSI-X vector 范围 |

PF 默认拥有完整资源窗口。VF 使用固定大小的静态窗口，后续 12.10 的 Linux driver SR-IOV 管理和 4.x/5.x/6.x 的资源管理器可以把静态窗口替换成驱动配置的配额。

## 访问检查流程

一次访问检查大致分为四步：

1. 根据 `requester_id` 或 `function_id` 得到当前访问的 function。
2. 判断 function 是否存在。
3. 判断 function 是否 enabled。
4. 根据访问类型检查资源窗口或控制面权限。

当前支持的访问类型：

| 访问类型 | 检查内容 |
| --- | --- |
| `SRIOV_ACCESS_BAR0_DOORBELL` | BAR0 offset 必须落在该 function 的 Doorbell 窗口 |
| `SRIOV_ACCESS_BAR2_CSR` | PF 可访问全局 CSR；trusted VF 只允许写 mailbox 窗口 |
| `SRIOV_ACCESS_BAR4_MSIX` | MSI-X vector 必须落在该 function 的 vector 窗口 |
| `SRIOV_ACCESS_QP` | QP 编号必须落在该 function 的 QP 窗口 |
| `SRIOV_ACCESS_CQ` | CQ 编号必须落在该 function 的 CQ 窗口 |
| `SRIOV_ACCESS_MR` | MR handle 必须落在该 function 的 MR 窗口 |

失败时模块返回 `BAD_FUNCTION`、`DISABLED`、`OUT_OF_RANGE` 或 `PF_ONLY` 等状态。后续 BAR decoder、Doorbell decoder 或资源管理器可以把这些状态转换为 unsupported access、permission error、CQE error 或统计计数。

## Doorbell Ownership Check

3.2 新增的 `doorbell_access_check` 复用本模块的身份和资源窗口结果。推荐连接方式是：

```text
PCIe requester_id / function_id
  -> pcie_function_manager
  -> sriov_function_identity_t + sriov_resource_window_t
  -> doorbell_access_check
```

`doorbell_access_check` 专门检查 fast path Doorbell：

- SQ/RQ Doorbell 使用 QP 资源窗口：`qp_base <= qpn <= qp_limit`。
- CQ arm Doorbell 使用 CQ 资源窗口：`cq_base <= cqn <= cq_limit`。
- `owner_function` 必须等于 function manager 解析出的 `function_id`。
- `function_enabled` 必须为 1。

这个拆分很重要：`pcie_function_manager` 只回答“这个 requester 属于哪个 PF/VF、它拥有哪些资源窗口”；`doorbell_access_check` 则回答“这一次 Doorbell 是否落在这些窗口内”。这样后续 QP/CQ 管理器不用重复写 PF/VF 判断，只需要信任已经通过检查的 Doorbell 事件。

## 为什么这样设计

RDMA SmartNIC 里有两类隔离问题：

- 控制面隔离：VF 不能写 PF 全局寄存器，也不能管理其他 VF 的资源。
- 数据面隔离：VF 只能 ring 自己的 Doorbell，只能使用自己的 QP/CQ/MR/MSI-X vector。

把 identity 和 resource window 独立成 `pcie_function_manager` 后，后续模块只需要问一个问题：“这个访问允许吗？”这比在每个模块里硬编码 PF/VF 判断更容易测试，也更容易扩展到多租户 RDMA。

## 当前阶段没有实现的内容

本阶段没有实现以下功能：

- 真实 SR-IOV VF 创建和销毁。
- PCIe SR-IOV capability 的 VF BAR、VF stride、VF migration 等配置行为。
- 动态资源分配算法。
- QP/CQ/MR 表项的真实创建。
- Doorbell payload 解析。

这些内容会在后续 QP/CQ/MR、Doorbell、Linux driver SR-IOV 阶段继续实现。
