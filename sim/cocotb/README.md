# Cocotb PCIe 控制面单元测试

本目录存放 RDMA SmartNIC 的 Cocotb 模块级测试。当前阶段只覆盖 PCIe endpoint/control-plane 的最小行为，不模拟完整 PCIe 链路、TLP credit、DMA completion 或主机内存模型。

## 测试文件

| 文件 | 覆盖模块 | 最小覆盖点 |
| --- | --- | --- |
| `test_pcie_cfg_space.py` | `rtl/pcie/pcie_cfg_space.sv` | vendor/device 读取、command/status 读写、capability 链表基础检查 |
| `test_pcie_bar_decoder.py` | `rtl/pcie/pcie_bar_decoder.sv` | BAR0 Doorbell、BAR2 CSR、BAR4 MSI-X 路由，以及非法 BAR/offset 错误 |
| `test_csr_mailbox.py` | `rtl/reg/pcie_csr_mailbox.sv` | NOP GO/DONE 生命周期、非法 command_id error_code、timeout 计数寄存器可见性 |
| `test_msix.py` | `rtl/pcie/pcie_msix.sv` | masked interrupt pending、unmask 后 message 输出、PBA bit 清除 |
| `test_sriov_function_manager.py` | `rtl/pcie/pcie_function_manager.sv` | PF 允许、enabled VF 窗口内允许、disabled VF 拒绝、VF 资源越界拒绝 |

## 运行方式

从仓库根目录运行：

```sh
make pcie-test
```

或直接进入本目录运行：

```sh
make -C sim/cocotb pcie-control-plane-tests
```

如果本机没有安装 `cocotb` 或 `verilator`，目标会打印提示并跳过。安装工具后，可以单独运行某个模块测试：

```sh
make -C sim/cocotb test-pcie-cfg
make -C sim/cocotb test-pcie-bar
make -C sim/cocotb test-csr-mailbox
make -C sim/cocotb test-msix
make -C sim/cocotb test-sriov
```

## 当前限制

- 测试只驱动模块级 ready/valid 和寄存器接口。
- 不检查完整 PCIe TLP 编码、completion ordering 或 MSI-X TLP 发送。
- mailbox 的 timeout 注入能力后续会随 CSR command 执行器增强；当前测试只确认 timeout 计数和错误码定义可见。
