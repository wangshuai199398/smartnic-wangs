# MR 单元测试说明

6.8 阶段把 MR manager 的测试面收束成一组可学习、可逐步运行的 Cocotb 入口。当前测试只验证 MR 管理和保护检查路径的最小行为，不实现完整 DMA Engine、IOMMU、真实 page walk 或 RoCEv2 transport。

## 测试文件

| 测试文件 | 覆盖重点 |
| --- | --- |
| `sim/cocotb/test_mr_table.py` | MR entry 写入与 lookup、lkey/rkey 命中、lookup miss、key alias、VA->PA 转换、bounds/length 错误、cross-function 拒绝、refcount inc/dec 和上下溢 |
| `sim/cocotb/test_mr_registration.py` | REGISTER_MR 请求校验、SG entry fetch mock、MR entry 构造、lkey/rkey alias、SG length、table full、成功响应 lkey/rkey/mr_index |
| `sim/cocotb/test_mr_deregistration.py` | DEREGISTER_MR lookup、permission/PD 检查、pending_deregister、refcount drain、clear entry、timeout 和 repeated pending 错误 |
| `sim/cocotb/test_mr_key_checker.py` | local path 使用 lkey、remote path 使用 rkey、方向错误、lookup miss、pending、cross-function、zero length 和 bounds 错误 |
| `sim/cocotb/test_mr_access_checker.py` | local/remote/MW access_flags 权限矩阵、permission rejection、pending/invalidating、owner mismatch、zero length、bounds 和 address overflow |
| `sim/cocotb/test_mr_pd_checker.py` | local/remote operation 的 QP PD 与 MR PD 匹配、PD mismatch、owner mismatch、pending、invalid entry、invalid operation 和 physical_addr 透传 |
| `sim/cocotb/test_memory_window.py` | MW bind、range/length/permission subset/rkey alias 检查、parent pending、parent is MW、unbind、refcount drain、QP error invalidation |
| `sim/cocotb/test_mr_integration.py` | 最小端到端保护路径：REGISTER_MR、lookup、permission、PD、VA->PA、refcount、DEREGISTER_MR；以及 parent MR、MW rkey、remote access、unbind 后拒绝访问 |

## 运行方式

从仓库根目录运行全部 MR 测试入口：

```sh
make mr-test
```

或者单独运行某个 MR 测试：

```sh
make -C sim/cocotb test-mr-table
make -C sim/cocotb test-mr-registration
make -C sim/cocotb test-mr-deregistration
make -C sim/cocotb test-mr-key-checker
make -C sim/cocotb test-mr-access-checker
make -C sim/cocotb test-mr-pd-checker
make -C sim/cocotb test-memory-window
make -C sim/cocotb test-mr-integration
```

如果本机没有安装 Cocotb 或 Verilator，`make mr-test` 会打印跳过提示。单独测试目标需要完整仿真工具链。

## 对应 spec 要求

这些测试主要覆盖 `MR Lifecycle and Memory Protection`：

- `MR registration creates keys`：由 registration 和 integration 测试覆盖；
- `Local access uses lkey`：由 table、key checker、access checker、PD checker 和 integration 测试覆盖；
- `Remote access uses rkey`：由 key checker、access checker、PD checker、Memory Window 和 integration 测试覆盖；
- `MR deregistration waits for active DMA`：由 deregistration 和 integration 测试覆盖；
- Memory Window 的权限子集和失效语义：由 Memory Window 和 integration 测试覆盖。

它们也支撑 `Scatter-Gather DMA Engine` 中的 “DMA uses MR translation” 场景，因为后续 DMA 每个 segment 都要复用这里验证过的 key direction、permission、PD 和 VA->PA 保护顺序。
