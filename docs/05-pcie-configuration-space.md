# PCIe 配置空间

本文档说明 `rtl/pcie/pcie_cfg_space.sv` 的最小配置空间布局。当前阶段对应 tasks.md 的 2.2，只实现 Type 0 header 和 capability 链表框架，不实现 BAR decoder、CSR mailbox、MSI-X table、SR-IOV VF 资源分配或 AER/ATS 真实协议行为。

## 模块位置

`pcie_cfg_space` 接在 `pcie_endpoint_wrapper` 的 configuration interface 后面：

```text
PCIe hard IP
    |
pcie_endpoint_wrapper
    |
configuration interface
    |
pcie_cfg_space
```

它的职责是让 Host 在枚举设备时能读到基本身份、BAR 寄存器和 capability 结构。后续 driver probe 会依赖这些字段判断设备类型、BAR 布局和支持的中断/虚拟化能力。

## Type 0 Header 布局

当前实现覆盖以下常用 dword：

| Byte Offset | 字段 | 当前作用 |
| --- | --- | --- |
| `0x000` | `vendor_id` / `device_id` | 标识 RDMA SmartNIC 原型设备 |
| `0x004` | `command` / `status` | 支持最小可读写 command，status 标记 capability list present |
| `0x008` | `revision_id` / `class_code` | class code 使用网络控制器类型 |
| `0x00c` | header/cache/latency | Type 0 header 占位 |
| `0x010` | `bar0` | Doorbell aperture 的 BAR 占位 |
| `0x014` | `bar1` | BAR0 64-bit 高位占位 |
| `0x018` | `bar2` | CSR/MMIO BAR 占位 |
| `0x020` | `bar4` | MSI-X table/PBA BAR 占位 |
| `0x02c` | subsystem IDs | 子系统标识 |
| `0x034` | capability pointer | 指向 PCIe capability |
| `0x03c` | interrupt line/pin | 传统中断字段占位 |

BAR 当前只是配置寄存器。真正的 BAR 地址匹配、offset 解析和 BAR0/BAR2/BAR4 分发属于 2.3。

## Capability 链表

当前实现了普通 capability 链表框架：

```text
0x034 capability pointer
  -> 0x040 PCIe capability
  -> 0x060 MSI-X capability
  -> end
```

### PCIe Capability

PCIe capability 目前提供 capability header、device control 和 link control 的占位寄存器。后续可以在这里扩展 PCIe device capability、link capability、device status 和 link status。

### MSI-X Capability

MSI-X capability 目前提供：

- message control；
- table BIR/offset，占位指向 BAR4；
- PBA BIR/offset，占位指向 BAR4。

当前不会访问 MSI-X table，也不会根据 mask 位生成中断。真实 MSI-X table、PBA、vector mask 和 MSI-X transaction 生成属于 2.5。

## Extended Capability 链表

AER、ATS 和 SR-IOV 属于 PCIe extended capability。当前实现使用独立的 extended capability 链表：

```text
0x100 AER extended capability
  -> 0x140 ATS extended capability
  -> 0x180 SR-IOV extended capability
  -> end
```

AER 只提供 error status/mask 的占位读值。ATS 只提供 control 占位寄存器。SR-IOV 提供 control 和 number of VFs 占位字段。真实错误上报、地址转换请求、缓存一致性策略、VF 创建和 VF 资源隔离后续再实现。

## 最小读写行为

配置空间接口使用 32-bit dword 地址和 byte enable：

- 读请求返回对应 dword；
- 写请求只更新当前阶段允许写的寄存器；
- 只读或未实现寄存器忽略写入；
- 所有已识别访问当前返回 `PCIE_CFG_RSP_OK`。

允许写的寄存器包括 command/status、BAR0/BAR1/BAR2/BAR3/BAR4/BAR5、PCIe control 占位、MSI-X message control、SR-IOV control、VF 数量占位和 ATS control。

这种设计的目的不是完整模拟 PCIe 设备，而是先让 Host 枚举路径和后续驱动 probe 有稳定字段可读。

## 对后续任务的支撑

### 支撑 2.3 BAR decoder

2.3 会读取或使用 `cfg_bar0`、`cfg_bar2`、`cfg_bar4` 这些输出，把 Host 的 Memory Read/Write TLP 路由到 Doorbell、CSR 或 MSI-X 区域。2.2 先定义 BAR 寄存器和软件可见布局。

### 支撑 2.5 MSI-X

2.5 会基于 MSI-X capability 中的 table/PBA 指针和 message control，补充 MSI-X table、pending-bit array、vector mask 和 message TLP 生成。2.2 先让 Host 能发现“设备声明支持 MSI-X”。

### 支撑 2.6 SR-IOV

2.6 会基于 SR-IOV capability 的 enable/control 信息和 function identity，实现 PF/VF 访问隔离和 VF 资源检查。2.2 先提供 SR-IOV capability 的枚举入口。
