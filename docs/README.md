# `docs/` 目录 —— 按学习顺序编排

建议按编号顺序阅读，每个文档对应 `tasks.md` 中的构建阶段。

## 📖 阅读顺序

| 编号 | 文件 | 对应 tasks.md | 内容 |
|------|------|--------------|------|
| 01 | 01-rdma-concepts.md | （预备知识） | RDMA 核心概念：QP、CQ、MR、PD、Doorbell、WQE、CQE、DMA、RoCEv2 |
| 02 | 02-shared-formats.md | 1.5 | 硬件和软件共享的数据格式（packed struct、enum）详解 |
| 03 | 03-pcie-endpoint.md | 2.1 | PCIe endpoint wrapper 接口定义 |
| 04 | 04-pcie-bar-decoder.md | 2.3 | BAR 解码器：BAR0/BAR2/BAR4 路由 |
| 05 | 05-pcie-configuration-space.md | 2.2 | PCIe Type 0 配置空间和 Capability 链表 |
| 06 | 06-csr-mailbox.md | 2.4 | CSR mailbox 命令协议 |
| 07 | 07-msix-interrupts.md | 2.5 | MSI-X 中断表、PBA 和中断调节 |
| 08 | 08-sriov-function-management.md | 2.6 | SR-IOV PF/VF 身份和资源隔离 |
| 09 | 09-pcie-unit-tests.md | 2.7 | PCIe 子系统单元测试说明 |
| 10 | 10-doorbell-path.md | 3 | Doorbell 解码和队列提交路径 |
| 11 | 11-doorbell-unit-tests.md | 3.6 | Doorbell 单元测试说明 |
| 12 | 12-qp-management.md | 4 | QP 生命周期、SQ/RQ 引擎、状态迁移、清理 |
| 13 | 13-qp-unit-tests.md | 4.7 | QP 单元测试说明 |
| 14 | 14-cq-management.md | 5 | CQ 管理、CQE 格式化、通知和中断 |
| 15 | 15-mr-management.md | 6 | MR 注册/注销、key 检查、权限检查、PD 检查、Memory Window |
| 16 | 16-mr-unit-tests.md | 6.8 | MR 单元测试说明 |
| 17 | 17-dma-engine.md | 7 | DMA 引擎：调度、WQE/SGE fetch、SGE 遍历、MR 集成、host read 路径 |
| 18 | 18-data-path.md | 综合 | 端到端数据通路走读（RDMA Write 全程） |
| 19 | 19-build-and-test.md | 1.6 | 构建目标、仿真运行、回归测试 |

## 🗺️ 架构总览

另见 [architecture.html](architecture.html) —— 一份图文并茂的完整架构讲解，包含每个模块的类/函数/FSM 详解和设计原理。
