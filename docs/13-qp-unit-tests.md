# QP 单元测试说明

本文说明 4.7 阶段加入和完善的 QP 测试集合。这些测试只验证 QP 管理、状态迁移、SQ/RQ 控制路径和 cleanup 控制框架，不实现完整 RoCEv2、完整 DMA Engine 或真实 CQE 写回。

## 测试文件

| 文件 | 覆盖模块 | 主要覆盖点 |
| --- | --- | --- |
| `sim/cocotb/test_qp_context_table.py` | `qp_context_table.sv` | context write/read/lookup、lookup miss、QPN alias rejection、owner function 匹配、cross-function 拒绝、SQ/RQ producer index 更新。 |
| `sim/cocotb/test_qp_lifecycle.py` | `qp_lifecycle_manager.sv` | CREATE_QP、duplicate QPN、QUERY_QP、MODIFY_QP、DESTROY_QP 发起 cleanup、QP_TO_ERROR 发起 error cleanup、cross-function modify/destroy 拒绝。 |
| `sim/cocotb/test_qp_state_validator.py` | `qp_state_validator.sv` | RESET/INIT/RTR/RTS/SQD/ERR 合法和非法迁移、any state -> ERR、ERR -> RESET、required attributes 和 missing_attr_mask。 |
| `sim/cocotb/test_sq_engine.py` | `sq_engine.sv` | RTS 且 SQ 非空时 WQE fetch、SQ 空队列不 fetch、非法 QP state 拒绝、NOP 更新 SQ consumer index、unsupported opcode、consumer wraparound、dispatch request 基础字段。 |
| `sim/cocotb/test_rq_engine.py` | `rq_engine.sv` | RTR/RTS 接收入站 Send、RQ empty/RNR、非法 QP state、Recv buffer local length error、RQ consumer index 更新、wraparound、receive completion request 字段。 |
| `sim/cocotb/test_qp_cleanup.py` | `qp_cleanup_manager.sv` | destroy block Doorbell、等待 in-flight drain、SQ/RQ pending slot flush、error transition 到 ERR、timeout、cross-function destroy 拒绝、already destroyed/ERR 状态。 |
| `sim/cocotb/test_qp_integration.py` | `qp_lifecycle_manager.sv` + mock fast path | CREATE_QP、RESET -> INIT -> RTR -> RTS、mock SQ Doorbell/NOP SQ engine 事件、DESTROY_QP cleanup 完成。 |

## 运行方式

从仓库根目录运行：

```sh
make qp-test
```

或进入 Cocotb 目录运行：

```sh
make -C sim/cocotb qp-tests
```

也可以单独运行某个 QP 测试：

```sh
make -C sim/cocotb test-qp-context
make -C sim/cocotb test-qp-state-validator
make -C sim/cocotb test-qp-lifecycle
make -C sim/cocotb test-sq-engine
make -C sim/cocotb test-rq-engine
make -C sim/cocotb test-qp-cleanup
make -C sim/cocotb test-qp-integration
```

如果本机没有安装 `cocotb` 或 `verilator`，`make qp-test` 会打印提示并跳过真实仿真。

## 对应 Requirement

这些测试主要覆盖 `spec.md` 中的以下要求：

- `QP Lifecycle Management`：QP create/modify/query/destroy、状态迁移、SQ processing、destroy flush work。
- `Doorbell Interface`：SQ/RQ producer index 更新和 per-function 隔离通过 QP table 与 Doorbell tests 联合覆盖。
- `RDMA Operations`：SQ/RQ 控制路径验证 Send/Recv 的 WQE fetch 和 completion request 边界。
- `CQ Lifecycle and Completion Queue`：当前只验证 completion request 和 flushed completion request 字段，不写真实 CQE。
- `PCIe Gen5 x16 Endpoint / SR-IOV function isolation`：owner function 和 cross-function 拒绝覆盖 QP 层资源隔离。
- `Cocotb Verilator Verification`：提供 QP 相关模块级测试和一个最小控制路径集成测试。

## 当前限制

- `test_qp_integration.py` 的 SQ Doorbell 和 SQ engine 部分使用 mock fast-path 事件记录；真实模块行为由 `test_sq_doorbell.py`、`test_qp_context_table.py` 和 `test_sq_engine.py` 分别覆盖。
- RQ/SQ 测试只定义 WQE fetch、dispatch 和 completion request 接口，不搬运真实 payload。
- cleanup 测试只生成 flushed completion request，不格式化 64-byte CQE，也不触发 MSI-X。
