# RDMA SmartNIC 学习项目

这个仓库会根据 OpenSpec 变更 `add-rdma-smartnic-design-capability`
一步一步搭建一款 RDMA SmartNIC 的教学型项目。

当前阶段只创建项目骨架和说明文档。还没有实现 RTL 逻辑、Linux 驱动、
用户态库或仿真测试。

## 第一阶段目录

- `rtl/`：硬件 RTL 设计目录。
- `driver/`：Linux 驱动设计目录。
- `lib/`：用户态库设计目录。
- `sim/`：仿真和验证目录。
- `docs/`：文档目录。
- `openspec/`：OpenSpec 需求、设计和任务规划目录。

## 学习路线

推荐按下面顺序逐步实现：

1. 理解项目骨架和每个目录的职责。
2. 定义硬件和软件共享的数据格式。
3. 搭建最小 Doorbell 到 CQE 闭环。
4. 增加 DMA 内存搬运。
5. 增加 RC Send/Recv。
6. 增加 RDMA Write 和 RDMA Read。
7. 增加 UD。
8. 增加 Linux 驱动和用户态 Verbs 栈。
9. 增加兼容性测试和性能验证。

## 当前状态

本阶段只完成项目骨架。复杂逻辑会在后续阶段逐步加入。
