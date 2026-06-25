# Top-Level Doorbell Control

本文记录 11.3 阶段新增的顶层 Doorbell 控制路径。目标是把 BAR0 Doorbell 写入连接到 QP SQ/RQ producer index 更新和 CQ arm 更新，而不启动完整 RDMA 数据通路。

## 数据流

```text
BAR0 Doorbell MMIO
  -> doorbell_ctrl
      -> sq_doorbell_handler -> qp_context_table.sq_pi_update
      -> rq_doorbell_handler -> qp_context_table.rq_pi_update
      -> cq_arm_doorbell_handler -> cq_context_table.cq_arm
      -> scheduler wakeup hints
```

`doorbell_ctrl.sv` 复用第 3 阶段已有的三个 handler：

- `sq_doorbell_handler`
- `rq_doorbell_handler`
- `cq_arm_doorbell_handler`

这避免在 top-level 重新实现 payload 解析规则。

## 输入接口

`smartnic_top.sv` 新增 BAR0 Doorbell 入口：

```text
bar0_db_valid
bar0_db_ready
bar0_db_qp_num
bar0_db_type
bar0_db_value
bar0_db_owner_function
```

SQ/RQ Doorbell 使用 `bar0_db_qp_num` 表示 QPN。CQ arm Doorbell 复用同一字段表示 CQN。后续接入完整 `pcie_bar_decoder` / `doorbell_decoder` 时，可以由 BAR0 offset 自动生成这些字段。

## SQ Doorbell

SQ Doorbell 被解析为新的 SQ producer index：

```text
db_type = DB_TYPE_SQ
db_value -> sq_doorbell_payload_t
```

处理结果连接到：

- `qp_context_table.sq_pi_update_valid`
- `sq_pi_update_qpn`
- `sq_pi_update_new_pi`

当 SQ PI 更新被 QP table 接收且没有 payload/access 错误时，`doorbell_ctrl` 产生 `sq_scheduler_valid` wakeup hint。11.3 只生成这个 hint，不实例化完整 SQ scheduler；后续 11.4 会用它启动 SQ engine/WQE fetch。

## RQ Doorbell

RQ Doorbell 被解析为新的 RQ producer index：

```text
db_type = DB_TYPE_RQ
db_value -> rq_doorbell_payload_t
```

处理结果连接到：

- `qp_context_table.rq_pi_update_valid`
- `rq_pi_update_qpn`
- `rq_pi_update_new_pi`

成功更新后，`doorbell_ctrl` 产生 `rq_post_valid` hint，表示软件已经补充了 receive buffers。11.3 不执行 inbound receive path，只保留后续 RQ/transport RX 可用的连接点。

## CQ Arm Doorbell

CQ arm Doorbell 被解析为 consumer index 和 solicited-only 标志：

```text
db_type = DB_TYPE_CQ_ARM
db_value -> cq_arm_doorbell_payload_t
```

处理结果连接到：

- `cq_context_table.cq_arm_valid`
- `cq_arm_cqn`
- `cq_arm_consumer_index`
- `cq_arm_armed`
- `cq_arm_solicited_only`

CQ table 会保存 arm 状态。真正的 CQE 写入、中断调节和 MSI-X 请求仍由第 5 阶段模块负责，top-level 完整闭环留给后续任务。

## Ordering 和 Reset

- Doorbell 控制器使用一项 pending register，接收后即可释放上游，避免把 MMIO 写入长时间阻塞在数据通路上。
- `csr_order_ready` 预留用于确保 CSR 配置对 datapath 可见后再触发 Doorbell。当前 `smartnic_top` 绑为 `1'b1`，因为 11.2 的 CSR fabric 和 11.3 的 Doorbell path 尚未共享真实配置寄存器。
- 复位后 pending Doorbell、scheduler hint、RQ post hint 和错误状态全部清零。

## TODO

- 11.4：把 `sq_scheduler_valid` 连接到 SQ engine / WQE fetch 路径。
- 11.4：把 `rq_post_valid` 与 RQ/transport RX 的 no-receive-buffer 处理结合。
- 11.3 后续增强：由 `pcie_bar_decoder` 和 `doorbell_decoder` 从真实 BAR0 offset 自动生成 `bar0_db_*`。
- 后续 SR-IOV 集成：用 `pcie_function_manager` 的真实资源窗口替换 top 内默认全开放窗口。
