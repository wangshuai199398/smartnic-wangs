# PCIe 控制面单元测试

本阶段新增 `sim/cocotb/` 下的 PCIe 控制面模块级测试。目标是给 2.x 阶段已经实现的 RTL 框架建立最小回归入口，而不是一次性构建完整 PCIe BFM。

## 覆盖关系

| 测试文件 | 对应 Requirement | 覆盖场景 |
| --- | --- | --- |
| `test_pcie_cfg_space.py` | PCIe Gen5 x16 Endpoint | Host enumerates PCIe endpoint |
| `test_pcie_bar_decoder.py` | PCIe Gen5 x16 Endpoint | BAR access is routed by function and offset |
| `test_csr_mailbox.py` | PCIe Gen5 x16 Endpoint / Linux Kernel Driver Interface | CSR mailbox GO/DONE、非法命令错误、timeout 字段可观测 |
| `test_msix.py` | PCIe Gen5 x16 Endpoint / CQ Lifecycle and Completion Queue | MSI-X mask、pending、unmask 后 message 输出 |
| `test_sriov_function_manager.py` | PCIe Gen5 x16 Endpoint / Doorbell Interface | SR-IOV function isolation、Doorbell per-function isolation |

## 为什么这样设计

PCIe 控制面是后续 RDMA 资源管理的入口。驱动创建 QP/CQ/MR、用户态 mmap Doorbell、CQ 中断通知和 VF 隔离，都会先经过 2.x 的这些基础模块。

因此测试顺序也按控制面链路展开：

1. 配置空间先保证设备能被枚举。
2. BAR decoder 保证 host MMIO 能路由到正确目标。
3. CSR mailbox 保证慢速控制命令有 GO/DONE/error 协议。
4. MSI-X 保证 completion 和 admin/error event 有中断承载。
5. SR-IOV function manager 保证 PF/VF 访问边界不会混在一起。

这种拆分让每个测试只验证一个模块的最小契约。后续 14.x 阶段再加入 PCIe BFM、host memory model、scoreboard 和端到端集成测试。

## 运行

```sh
make pcie-test
```

当前 Makefile 会检查 `cocotb-config` 和 `verilator`。工具未安装时会提示跳过；工具安装后会按模块顺序运行五组测试。
