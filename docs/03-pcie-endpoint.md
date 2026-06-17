# PCIe Endpoint Wrapper

本文档说明 `rtl/pcie/pcie_endpoint_wrapper.sv` 在 RDMA SmartNIC 系统中的位置。当前阶段对应 tasks.md 的 2.1，只定义接口，不实现真实 PCIe 功能逻辑。

## 系统位置

PCIe endpoint wrapper 位于 FPGA/ASIC PCIe hard IP 和 SmartNIC 内部 RTL 之间。

```text
Host CPU / Memory
       |
PCIe Gen5 x16 Link
       |
PCIe hard IP
       |
pcie_endpoint_wrapper
       |
+------+---------+------------+-------------+
| configuration | inbound TLP | outbound TLP|
| DMA req/cpl   | MSI-X req   | function ID |
+---------------+------------+-------------+
       |
SmartNIC 内部模块
```

它的作用不是完成所有 PCIe 协议，而是把厂商 PCIe IP 的接口隔离起来，向内部模块暴露稳定、可读、可逐步验证的接口边界。

## 为什么先做 wrapper

RDMA SmartNIC 后续会依赖 PCIe 完成很多事情：

- Host 通过配置空间发现设备；
- Host 通过 BAR 访问 Doorbell、CSR 和 MSI-X 区域；
- DMA engine 通过 PCIe 读写主机内存；
- completion 和异步事件通过 MSI-X 通知驱动；
- PF/VF function identity 用于 SR-IOV 资源隔离。

如果一开始就把配置空间、BAR decoder、DMA、MSI-X 和 SR-IOV 全写在一起，学习和调试都会很困难。因此 2.1 先只定义“边界”，后续每个功能都能按任务拆开实现。

## 接口分组

### PCIe configuration interface

配置接口把 PCIe 配置访问转交给后续的配置空间模块。它包含：

- 请求有效/就绪握手；
- 读写方向；
- function ID；
- requester ID；
- 配置空间地址；
- 写数据和 byte enable；
- 读响应数据和状态。

当前 wrapper 不生成 Type 0 header，也不实现 capability list。那些属于 2.2。

### inbound TLP interface

inbound TLP 指 Host 发往设备的 PCIe TLP，例如 BAR memory read/write。

当前接口只保留 TLP 流数据、有效掩码、last、sideband、TLP 类型占位、BAR 编号占位、function ID 和 requester ID。真实 TLP 解析和 BAR routing 不在 2.1 实现，后续会在 2.3 接入。

### outbound TLP interface

outbound TLP 指设备发往 Host 的 PCIe TLP，例如 completion、DMA write、MSI-X message。

当前接口只定义内部模块如何提交出站 TLP，以及 wrapper 如何把 TLP 送往 PCIe hard IP。真正的 TLP 组包策略后续再实现。

### DMA request/completion interface

DMA request/completion 接口连接 `dma_engine` 和 PCIe wrapper。

DMA request 用来描述主机内存读写请求，包括地址、长度、tag、function、traffic class 和 attributes。DMA completion 用来把 read completion 数据或 PCIe 错误返回给 DMA engine。

当前阶段只定义握手和字段，不发起真实 PCIe memory read/write。

### MSI-X request interface

MSI-X request 接口连接 completion/interrupt 相关模块和 PCIe wrapper。

它携带 vector、message address、message data 和 function ID。当前 wrapper 不实现 MSI-X table、PBA、mask 或 message TLP 生成，这些属于 2.5。

### function identity interface

function identity 接口向内部隔离逻辑提供 PF/VF 身份信息。

后续 SR-IOV guard 会使用这些字段判断某次 CSR、Doorbell 或 DMA 访问是否属于正确的 function。当前阶段只定义信号，不实现 VF 资源隔离策略。

## 与后续任务的关系

- 2.2 会在 configuration interface 后面实现 PCIe 配置空间和 capability 结构；
- 2.3 会使用 inbound TLP interface 中的 BAR/function 信息做 BAR0/BAR2/BAR4 路由；
- 2.4 会把 BAR2 CSR 访问接到 mailbox；
- 2.5 会把 MSI-X request 转成合法的 MSI-X transaction；
- 2.6 会基于 function identity 做 PF/VF 访问隔离。

所以 2.1 的价值是先把 PCIe 子系统的外形固定下来。后面实现每个功能时，只需要填充对应模块，不需要反复修改所有相邻模块的连接方式。
