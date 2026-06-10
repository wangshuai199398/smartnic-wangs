# `rtl/` 目录

这个目录用于存放 RDMA SmartNIC 的硬件 RTL 设计。

后续这里会逐步加入 SystemVerilog 模块，例如：

- PCIe endpoint 和 BAR/CSR 访问逻辑
- Doorbell 捕获逻辑
- QP、CQ、MR 管理模块
- 分散-聚集 DMA 引擎
- RoCEv2 报文解析和构造模块
- RC/UD 传输逻辑
- MSI-X、SR-IOV、PFC/ECN/DCQCN 相关模块
- 顶层 `smartnic_top` 集成模块

当前阶段只创建目录，不实现任何 RTL 逻辑。
