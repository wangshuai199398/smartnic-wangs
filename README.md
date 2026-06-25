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


## mattpocock/skills

此项目集成了 [mattpocock/skills](https://github.com/mattpocock/skills) 工程技能体系，
所有 skill 定义位于 `.agents/skills/` 目录下。通过 `/skill-name` 即可调用。

### 启动与路由

| Skill | 用途 |
|-------|------|
| `/setup-matt-pocock-skills` | **首次使用前运行一次**，配置 issue tracker、triage 标签词汇表和领域文档布局 |
| `/ask-matt` | 技能路由器——不确定用哪个 skill 时调用，自动推荐合适的 skill |

### 设计与架构

| Skill | 用途 |
|-------|------|
| `/codebase-design` | 深度模块设计——定义模块接口、寻找深化机会、决定 seam 位置、提升可测试性 |
| `/domain-modeling` | 构建和维护项目的领域模型与通用语言（ubiquitous language），记录架构决策 |
| `/improve-codebase-architecture` | 扫描代码库，找出可深化的架构点，生成可视化 HTML 报告，然后逐一攻破 |

### 计划评审与压力测试

| Skill | 用途 |
|-------|------|
| `/grilling` | 对计划或设计进行无情的面试式追问，在动手前压测方案的稳健性 |
| `/grill-me` | 同上，但不生成文档——纯粹的压力测试对话 |
| `/grill-with-docs` | 压测计划的同时生成 ADR（架构决策记录）和术语表 |

### 开发工作流

| Skill | 用途 |
|-------|------|
| `/tdd` | 测试驱动开发——先写测试再写代码，red-green-refactor 循环 |
| `/prototype` | 快速构建一次性原型来验证设计——可运行终端程序或 UI 变体切换 |
| `/diagnosing-bugs` | Bug 诊断循环——调试、性能回归排查 |

### 文档与交付

| Skill | 用途 |
|-------|------|
| `/to-prd` | 将当前对话内容合成为 PRD（产品需求文档），发布到 issue tracker |
| `/to-issues` | 将计划/规格/PRD 拆分为可独立领取的 issue，使用 tracer-bullet 纵向切片 |
| `/handoff` | 将当前对话压缩为交接文档，供下一个 agent 或会话继续工作 |
| `/triage` | 将 issue 和外部 PR 按分类→验证→评审→撰写 agent-ready brief 的状态机流转 |

### 学习与参考

| Skill | 用途 |
|-------|------|
| `/teach` | 在工作区内教你一个新技能或概念 |
| `/writing-great-skills` | Skill 编写参考——使 skill 行为可预测的词汇和原则 |

### 使用示例

```bash
# 首次使用
/setup-matt-pocock-skills

# 不确定用什么 skill
/ask-matt

# 压测设计方案
/grill-with-docs

# 将当前讨论转成 PRD
/to-prd
```

