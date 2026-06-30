# 用户态 Verbs 兼容性范围

本文是 16.3 的 userspace Verbs API 兼容性说明，描述当前 SmartNIC 用户态 provider/library 已实现的对象、操作、属性、完成语义、错误路径和已知限制。本文只记录当前行为和兼容目标，不新增 Verbs/provider 功能，不覆盖 Linux driver ABI（见 `docs/26-linux-driver-abi.md`），也不覆盖验证策略（16.4）。

权威源码与相关文档：

- `lib/libsmartnic/smartnic_provider.h`：用户态 provider public API、对象、opcode、status、attribute 和限制常量。
- `lib/libsmartnic/smartnic_provider.c`：provider discovery、context、PD/CQ/QP/MR/AH、WQE builder、post_send/post_recv、CQE parser 和 async event 实现。
- `lib/libsmartnic/smartnic-provider.json`：provider metadata。
- `lib/libsmartnic/libsmartnic-provider.pc.in`：pkg-config 模板。
- `docs/userspace-provider.md`：13.x provider API 细节。
- `docs/26-linux-driver-abi.md`：内核 driver ioctl/mmap/queue ABI。
- `examples/smartnic_minimal_verbs_example.c`：最小 RC Send/Recv bring-up 示例。
- `tests/run_perftest_compat.sh`、`tests/run_ucx_compat.sh`、`tests/run_libfabric_compat.sh`：外部兼容性 smoke runner。

## 兼容目标

当前用户态层是项目自有的 `smartnic_provider_*` API，使用 libibverbs 风格的对象模型、work request、work completion 和错误语义。它的目标是让后续 rdma-core provider glue、perftest、UCX 和 libfabric 兼容层可以复用同一套对象生命周期和 fast-path WQE/CQE 格式。

当前状态：

| 项目 | 状态 | 说明 |
| --- | --- | --- |
| API surface | 部分支持 | 提供 `smartnic_provider_*` C API；不是完整 rdma-core plugin ABI。 |
| Transport | 部分支持 | `SMARTNIC_PROVIDER_TRANSPORT_RC` 和 `SMARTNIC_PROVIDER_TRANSPORT_UD` 出现在 capability 中；RC Send/RDMA Write/RDMA Read 和 UD Send WQE builder 已建模。 |
| 执行环境 | 原型/仿真/FPGA bring-up | 可在无硬件环境做静态测试；真实 datapath 依赖 Linux driver、RTL 和设备。 |
| Kernel dependency | 必需 | 通过 `/dev/smartnicX`、`SMARTNIC_IOCTL_MBOX_EXEC`、queue mmap/doorbell 约定与 driver 交互。 |
| ABI version | `SMARTNIC_PROVIDER_ABI_VERSION = 1` | provider 和应用必须按 header 编译，不应复制结构体布局。 |
| Provider discovery | 部分支持 | 默认扫描 `/dev/smartnic*`；可用 `SMARTNIC_PROVIDER_ENV_DEV_DIR` / `SMARTNIC_PROVIDER_DEV_DIR` 覆盖测试目录。 |
| rdma-core plugin loader | 未实现 | `smartnic-provider.json` 和 pkg-config 已存在，但尚未接入完整 libibverbs provider 注册。 |

## 支持的 Verbs 对象

| Verbs 概念 | 当前 API / 结构 | 状态 | 兼容性说明 |
| --- | --- | --- | --- |
| Device discovery | `smartnic_provider_discover()`、`smartnic_provider_device` | 支持 | 扫描 device node，并通过 mailbox `SMARTNIC_CMD_QUERY_DEVICE` 验证兼容性。 |
| Context open/close | `smartnic_provider_open()`、`smartnic_provider_open_path()`、`smartnic_provider_close()` | 支持 | close 时如果仍有 PD/CQ/QP/MR/AH 子对象，返回 `EBUSY`。 |
| query_device | `smartnic_provider_query_device()` | 支持 | 返回 ABI、driver version、feature/cap/status 和默认能力上限。 |
| query_port | `smartnic_provider_query_port()` | 支持 | 当前仅支持 `port_num = 1`，Ethernet/RoCE，MTU 4096。 |
| query_gid | `smartnic_provider_query_gid()` | 支持 | 当前 `gid_index = 0` 返回默认全零 GID；其他 index 返回 `EINVAL`。 |
| query_pkey | `smartnic_provider_query_pkey()` | 支持 | 当前 `pkey_index = 0` 返回 `0xffff` full-membership P_Key。 |
| Protection Domain | `smartnic_provider_alloc_pd()`、`smartnic_provider_dealloc_pd()`、`smartnic_provider_pd` | 支持 | PD 由 mailbox command 创建，provider 维护 child/refcount。 |
| Completion Queue | `smartnic_provider_create_cq()`、`destroy_cq()`、`resize_cq()`、`poll_cq()`、`req_notify_cq()` | 支持 | ring-backed CQE parser 和 mailbox fallback 均使用 `smartnic_provider_parse_cqe()`。 |
| Queue Pair | `smartnic_provider_create_qp()`、`modify_qp()`、`query_qp()`、`destroy_qp()` | 支持 | 支持 RC/UD QP 类型和基本状态迁移校验。 |
| Memory Region | `smartnic_provider_reg_mr()`、`smartnic_provider_dereg_mr()`、`smartnic_provider_mr` | 部分支持 | 当前通过 mailbox 传递压缩参数，单 MR 长度暂限 4GB 以内。 |
| Address Handle | `smartnic_provider_create_ah()`、`smartnic_provider_destroy_ah()` | 部分支持 | 仅支持 RoCE/Ethernet global addressing；LID-only 和 multicast 未实现。 |
| Send Queue / Receive Queue | `smartnic_provider_post_send()`、`smartnic_provider_post_recv()` | 部分支持 | 使用 provider shadow SQ/RQ ring 和 doorbell record；真实 mmap MMIO doorbell 仍是 TODO。 |
| CQ completion channel | `smartnic_provider_req_notify_cq()` | 部分支持 | 支持 arm command；没有标准 completion channel fd。 |
| Async event | `smartnic_provider_get_async_event()`、`smartnic_provider_ack_async_event()` | 部分支持 | provider 内部 FIFO 和 ack token 已实现；没有独立 async fd。 |
| SRQ / XRC / shared receive | 无 | 不支持 | 调用方应视为 `EOPNOTSUPP`/unsupported capability。 |
| Multicast attach/detach | 无 | 不支持 | UD multicast 不在当前范围内。 |

## 支持的操作

| Work Request opcode | QP type | Immediate | Remote addr/rkey | 状态 | 约束 |
| --- | --- | --- | --- | --- | --- |
| `SMARTNIC_PROVIDER_WR_SEND` | RC | 否 | 否 | 支持 | QP 必须 RTS；SGE 必须引用同 PD 下已注册 MR。 |
| `SMARTNIC_PROVIDER_WR_SEND_WITH_IMM` | RC | 是，32 bit | 否 | 支持 | immediate data 使用 `htonl()` 编码为 network byte order。 |
| `SMARTNIC_PROVIDER_WR_RDMA_WRITE` | RC | 否 | 是 | 支持 | `rkey != 0`；本地 SGE lkey 必须有效。 |
| `SMARTNIC_PROVIDER_WR_RDMA_WRITE_WITH_IMM` | RC | 是，32 bit | 是 | 支持 | 写操作 WQE 同时携带 remote address/rkey 和 immediate data。 |
| `SMARTNIC_PROVIDER_WR_RDMA_READ` | RC | 否 | 是 | 支持 | 本地目标 MR 必须有 `SMARTNIC_PROVIDER_ACCESS_LOCAL_WRITE`。 |
| `SMARTNIC_PROVIDER_WR_UD_SEND` | UD | 否 | AH/Q_Key | 部分支持 | 必须提供有效 AH、remote QPN 和 remote QKey。 |
| `SMARTNIC_PROVIDER_WR_UD_SEND_WITH_IMM` | UD | 是，32 bit | AH/Q_Key | 部分支持 | WQE builder 支持；完整外部 UD interoperability 仍处于 bring-up。 |
| Atomic compare-and-swap | RC | 否 | 是 | 不支持 | `SMARTNIC_PROVIDER_WC_COMP_SWAP` 仅用于 completion enum 兼容，不代表 post_send 支持 atomic WR。 |
| Atomic fetch-and-add | RC | 否 | 是 | 不支持 | `SMARTNIC_PROVIDER_WC_FETCH_ADD` 仅用于 completion enum 兼容。 |
| Local invalidate / remote invalidate | - | - | - | 不支持 | 当前没有 WR opcode；CQE parser 可表达 invalidate-rkey flag。 |
| Bind MW / TSO / raw packet | - | - | - | 不支持 | 不在当前 provider API 范围内。 |

通用 posting 规则：

- `smartnic_provider_build_send_wqe()` 和 `smartnic_provider_post_send()` 要求 QP 处于 `SMARTNIC_PROVIDER_QPS_RTS`。
- `smartnic_provider_post_recv()` 接受 `INIT`、`RTR`、`RTS` 状态。
- Send flags 限于 `SMARTNIC_PROVIDER_SEND_SIGNALED`、`SMARTNIC_PROVIDER_SEND_SOLICITED`、`SMARTNIC_PROVIDER_SEND_FENCE`、`SMARTNIC_PROVIDER_SEND_INLINE`。
- Inline data 只有在设置 `SMARTNIC_PROVIDER_SEND_INLINE` 且 `inline_len <= SMARTNIC_PROVIDER_WQE_INLINE_BYTES` 时可用。
- SGE 数量同时受 QP capability 和 `SMARTNIC_PROVIDER_MAX_WQE_SGE` 限制。
- 空 WR 链是 no-op success；批量提交在第一个失败 WR 停止，并通过 `bad_wr` 返回失败位置。

## QP 状态与连接行为

支持的 QP type：

| QP type | 常量 | 状态 |
| --- | --- | --- |
| RC | `SMARTNIC_PROVIDER_QPT_RC` | 支持 |
| UD | `SMARTNIC_PROVIDER_QPT_UD` | 部分支持 |
| UC/XRC/raw packet | 无 | 不支持 |

支持的基础状态迁移：

| 迁移 | 必需 attr mask | 说明 |
| --- | --- | --- |
| `SMARTNIC_PROVIDER_QPS_RESET` -> `SMARTNIC_PROVIDER_QPS_INIT` | `SMARTNIC_PROVIDER_QP_REQUIRED_INIT` | 需要 state、port、P_Key index。 |
| `SMARTNIC_PROVIDER_QPS_INIT` -> `SMARTNIC_PROVIDER_QPS_RTR` | `SMARTNIC_PROVIDER_QP_REQUIRED_RTR` | 需要 state、path MTU、dest QPN、RQ PSN。 |
| `SMARTNIC_PROVIDER_QPS_RTR` -> `SMARTNIC_PROVIDER_QPS_RTS` | `SMARTNIC_PROVIDER_QP_REQUIRED_RTS` | 需要 state、SQ PSN、retry/RNR retry、timeout。 |
| RTS -> SQD | `SMARTNIC_PROVIDER_QP_ATTR_STATE` | 基础 drain 状态缓存。 |
| any -> ERR | `SMARTNIC_PROVIDER_QP_ATTR_STATE` | fatal/error cleanup 入口。 |
| same-state modify | `SMARTNIC_PROVIDER_QP_ATTR_STATE` | 允许保持状态并更新缓存属性。 |

连接假设：

- RC QP 需要应用或测试在 `RTR/RTS` 前设置 `dest_qpn`、`rq_psn`、`sq_psn`、path MTU、retry 和 timeout 参数。
- 当前 provider 不包含 connection manager；`examples/smartnic_minimal_verbs_example.c` 使用 loopback-style QPN 连接做 bring-up。
- `port_num` 当前只支持 1；`gid_index` 和 `pkey_index` 当前只支持 0。
- LID 在 RoCE/Ethernet 环境中不具备实际意义，query_port 返回 LID 0。
- 非法状态迁移或缺少必要属性返回 `EINVAL`；不支持 QP type 返回 `EOPNOTSUPP`。

## Memory Registration 兼容性

支持的 access flags：

| Flag | 状态 | 说明 |
| --- | --- | --- |
| `SMARTNIC_PROVIDER_ACCESS_LOCAL_WRITE` | 支持 | Recv 和 RDMA Read response 写入本地 buffer 需要该权限。 |
| `SMARTNIC_PROVIDER_ACCESS_REMOTE_WRITE` | 支持 | 允许远端 RDMA Write；当前要求同时设置 LOCAL_WRITE。 |
| `SMARTNIC_PROVIDER_ACCESS_REMOTE_READ` | 支持 | 允许远端 RDMA Read。 |
| `SMARTNIC_PROVIDER_ACCESS_REMOTE_ATOMIC` | 预留/不支持 | Header 中有 bit，但当前验证要求 atomic 依赖 REMOTE_WRITE 并返回 `EOPNOTSUPP`。 |
| `SMARTNIC_PROVIDER_ACCESS_RELAXED_ORDER` | 预留 | 作为 capability bit 保留；真实 ordering 仍由驱动/硬件接入。 |
| 未知 bit | 不支持 | 返回 `EOPNOTSUPP`。 |

MR 行为：

- `smartnic_provider_reg_mr()` 要求 PD 有效、地址非空、长度非零、access flags 合法。
- 当前 mailbox 参数区限制导致单个 MR 长度暂不超过 4GB。
- provider 保存 `lkey` 和 `rkey`，WQE builder 通过 context MR 链表按 lkey 查找并做地址范围检查。
- RDMA Read 的本地 SGE 必须引用有 `LOCAL_WRITE` 的 MR；Recv SGE 同样需要 `LOCAL_WRITE`。
- deregistration 会拒绝 active operations 或额外 refcount 的 MR；伪造或重复 dereg 返回 `EINVAL`。
- 任意 userspace memory pinning、IOMMU page-list 和 revocation callback 由 Linux driver/RTL 后续集成承担，当前文档不把它们声明为标准兼容能力。

## Completion 行为

CQE 格式由 `struct smartnic_provider_cqe` 表示，大小为 `SMARTNIC_PROVIDER_CQE_BYTES`（64 bytes）。`smartnic_provider_parse_cqe()` 将 provider CQE 转换为 `struct smartnic_provider_wc`：

| Work completion 字段 | 来源/语义 |
| --- | --- |
| `wr_id` | CQE 中保存的 WR ID。 |
| `status` | provider status，经 `smartnic_provider_map_wc_status()` 映射到支持枚举。 |
| `opcode` | provider opcode，经安全映射后返回。 |
| `byte_len` | CQE byte length。 |
| `qp_num` | CQE QP number。 |
| `wc_flags` | immediate / invalidate flag。 |
| `imm_data` | `SMARTNIC_PROVIDER_WC_FLAG_IMM` 设置时，从 network byte order 转回 host order。 |
| `invalidate_rkey` | `SMARTNIC_PROVIDER_WC_FLAG_INV` 设置时填充。 |
| `vendor_err` | 非 success completion 的 provider/hardware detail。 |

支持的 completion status：

| Status | 兼容语义 |
| --- | --- |
| `SMARTNIC_PROVIDER_WC_SUCCESS` | 成功完成。 |
| `SMARTNIC_PROVIDER_WC_LOC_LEN_ERR` | 本地长度错误。 |
| `SMARTNIC_PROVIDER_WC_LOC_PROT_ERR` | 本地保护错误。 |
| `SMARTNIC_PROVIDER_WC_LOC_ACCESS_ERR` | 本地访问/PCIe/DMA 错误。 |
| `SMARTNIC_PROVIDER_WC_WR_FLUSH_ERR` | WR 被 flush。 |
| `SMARTNIC_PROVIDER_WC_REM_ACCESS_ERR` | 远端访问错误。 |
| `SMARTNIC_PROVIDER_WC_REM_OP_ERR` | 远端操作错误。 |
| `SMARTNIC_PROVIDER_WC_CQ_OVERFLOW_ERR` | CQ overflow。 |
| `SMARTNIC_PROVIDER_WC_GENERAL_ERR` | 未知或 generic error。 |

Polling 语义：

- `smartnic_provider_poll_cq()` 在 CQ 为空时返回 0。
- `num_entries` 是本次最多返回 completion 数。
- 只有当前 consumer slot 有 `SMARTNIC_PROVIDER_CQE_VALID_BIT` 时才消费 CQE。
- 消费一个 CQE 后推进 consumer index，并在 ring-backed 路径清除 valid bit。
- consumer index 到尾部后回绕。
- 如果没有 mmap-backed CQ ring，provider 使用 `SMARTNIC_CMD_POLL_CQ` mailbox fallback。
- 当前没有标准 completion channel fd；`smartnic_provider_req_notify_cq()` 只负责 arm CQ。

排序与限制：

- provider 保留 per-QP SQ/RQ WR ID metadata，用于后续 completion matching。
- 当前 shadow ring 假设单进程 provider 控制；跨进程共享 CQ/QP 的 verbs 语义未实现。
- CQ overflow 由 CQE/status 或硬件事件报告；provider 不尝试恢复被覆盖的 CQE。

## 能力与限制矩阵

| 能力/概念 | 状态 | 当前限制 |
| --- | --- | --- |
| Device/context | 支持 | 依赖 `/dev/smartnicX` 和 mailbox query。 |
| PD | 支持 | 通过 mailbox 分配；子对象未释放时不能 dealloc。 |
| CQ | 支持 | 64-byte CQE；ring path 和 mailbox fallback；completion channel fd 未实现。 |
| QP RC | 支持 | 基础状态机和 posting；完整 CM、retry policy 由 RTL/driver 承担。 |
| QP UD | 部分支持 | AH 和 UD Send WQE 支持；UD external interop 仍是 bring-up。 |
| MR | 部分支持 | 单 MR 长度暂限 4GB；完整 page-list pinning/IOMMU 仍依赖 driver。 |
| AH | 部分支持 | 仅 RoCE global addressing；无 multicast。 |
| post_send/post_recv | 支持 | 使用 shadow SQ/RQ ring；真实 MMIO doorbell 接入仍是 TODO。 |
| CQE parser | 支持 | Verbs-like WC 字段已填充；未知 opcode/status 安全降级。 |
| Async event | 部分支持 | provider FIFO 和 ack 已有；没有 async fd。 |
| Inline data | 部分支持 | 最大 `SMARTNIC_PROVIDER_WQE_INLINE_BYTES`，仅 WQE builder 范围。 |
| Scatter/Gather | 部分支持 | WQE builder 最大 `SMARTNIC_PROVIDER_MAX_WQE_SGE`；query_device 报告 max_sge 256。 |
| Atomics | 不支持 | access flag 和 WC enum 预留，WR opcode 未实现。 |
| SRQ/XRC/UC | 不支持 | 无对象和 opcode。 |
| Multicast | 不支持 | AH 不支持 multicast attach/detach。 |

## 已知上限

| 限制 | 当前值 | 来源 | 说明 |
| --- | --- | --- | --- |
| ABI version | 1 | `SMARTNIC_PROVIDER_ABI_VERSION` | provider/header ABI。 |
| max devices | 32 | `SMARTNIC_PROVIDER_MAX_DEVICES` | discovery 返回数组上限。 |
| ports | 1 | `SMARTNIC_PROVIDER_MAX_PORTS` | 当前单端口 RoCE。 |
| GID table | 1 | `SMARTNIC_PROVIDER_GID_TABLE_LEN` | 只支持 index 0。 |
| P_Key table | 1 | `SMARTNIC_PROVIDER_PKEY_TABLE_LEN` | 只支持 index 0。 |
| max_qp | 4096 | provider default | query_device 默认值。 |
| max_cq | 4096 | provider default | query_device 默认值。 |
| max_mr | 8192 | provider default | query_device 默认值。 |
| max_pd | 1024 | provider default | query_device 默认值。 |
| max_wr | 4096 | provider default | SQ/RQ/CQ depth 校验默认上限。 |
| query max_sge | 256 | provider default | device capability。 |
| WQE builder SGE | 4 | `SMARTNIC_PROVIDER_MAX_WQE_SGE` | 当前 WQE ABI 固定数组上限。 |
| inline data | 32 bytes | `SMARTNIC_PROVIDER_WQE_INLINE_BYTES` | 需要 `SMARTNIC_PROVIDER_SEND_INLINE`。 |
| WQE alignment | 64 bytes | `SMARTNIC_PROVIDER_WQE_ALIGNMENT` | ABI 对齐目标。 |
| MTU | 4096 bytes | `SMARTNIC_PROVIDER_MTU_4096` | port max/active MTU。 |
| MR length | <= 4GB | mailbox argument limit | 当前 `SMARTNIC_CMD_REG_MR` 只传 length low32。 |
| outstanding RDMA Read | 最小模型 | RTL/provider 文档 | 当前以单 outstanding bring-up 为主要验证目标。 |

注意：上表中的“未知”不会写成 unlimited。没有被 header、driver 或 RTL 文档明确声明的能力，都应按 unsupported 或 planned 处理。

## 不支持特性和预期失败

| 请求/属性 | 预期失败 | 说明 |
| --- | --- | --- |
| 非 RC/UD QP type | `EOPNOTSUPP` | `smartnic_provider_validate_qp_type()` 拒绝。 |
| RESET 直接到 RTS | `EINVAL` | 非法 QP state transition。 |
| 缺少 INIT/RTR/RTS 必需 attr | `EINVAL` | attr mask 不满足 required set。 |
| 未知 send flag | `EOPNOTSUPP` | 仅支持四个 provider send flag。 |
| UD Send 无 AH | `EINVAL` | UD WR 必须带有效 AH。 |
| UD remote QPN/QKey 为 0 | `EINVAL` | 无效目的信息。 |
| AH LID-only addressing | `EOPNOTSUPP` | 当前仅支持 RoCE global addressing。 |
| remote write MR 不带 local write | `EINVAL` | provider access policy。 |
| atomic access / atomic WR | `EOPNOTSUPP` | atomic 数据路径未实现。 |
| SGE lkey 不存在或地址越界 | `EINVAL` / `EACCES` | builder 会查 MR 链表和权限。 |
| SQ/RQ 空间不足 | `ENOSPC` | reserved-one-entry ring 策略。 |
| context close 时仍有子对象 | `EBUSY` | 防止 use-after-free。 |
| CQ poll 空队列 | 返回 0 | 不是错误。 |
| async event 队列空 | `EAGAIN` | 当前 get_async_event 非阻塞。 |

## 外部兼容性范围

这些目标已有 runner 或文档入口，但本任务不新增测试功能：

| 工具/栈 | 当前入口 | 范围 |
| --- | --- | --- |
| 最小 Verbs 示例 | `examples/smartnic_minimal_verbs_example.c` | open/query、PD/CQ/QP/MR、post Recv、post Send、poll CQ。 |
| perftest | `tests/run_perftest_compat.sh`，`docs/testing.md` | RC Send、RDMA Write、RDMA Read smoke；硬件/环境缺失时 skip。 |
| UCX | `tests/run_ucx_compat.sh`，`docs/testing.md` | verbs-backed RC smoke；不是 16.3 新增内容。 |
| libfabric | `tests/run_libfabric_compat.sh`，`docs/testing.md` | verbs-backed send/recv、write、read smoke；不是 16.3 新增内容。 |
| pkg-config / metadata | `lib/libsmartnic/libsmartnic-provider.pc.in`、`lib/libsmartnic/smartnic-provider.json` | packaging/discovery 元数据，不等于完整 rdma-core plugin。 |

## 文档级示例流程

最小 context 和 query：

```c
struct smartnic_provider_context *ctx;
struct smartnic_provider_device_attr dev_attr;

smartnic_provider_open_path("/dev/smartnic0", &ctx);
smartnic_provider_query_device(ctx, &dev_attr);
```

最小 PD/MR/CQ/QP 初始化：

```c
struct smartnic_provider_pd *pd;
struct smartnic_provider_cq *cq;
struct smartnic_provider_qp *qp;
struct smartnic_provider_mr *mr;

smartnic_provider_alloc_pd(ctx, &pd);
smartnic_provider_create_cq(ctx, 64, &cq);
smartnic_provider_create_qp(pd, &init_attr, &qp);
smartnic_provider_reg_mr(pd, buffer, buffer_len,
                         SMARTNIC_PROVIDER_ACCESS_LOCAL_WRITE,
                         &mr);
```

最小 RC Send：

```c
struct smartnic_provider_recv_wr rwr = {
        .wr_id = 1,
        .sg_list = recv_sge,
        .num_sge = 1,
};
struct smartnic_provider_send_wr swr = {
        .wr_id = 2,
        .opcode = SMARTNIC_PROVIDER_WR_SEND,
        .send_flags = SMARTNIC_PROVIDER_SEND_SIGNALED,
        .sg_list = send_sge,
        .num_sge = 1,
};

smartnic_provider_post_recv(qp, &rwr, &bad_recv);
smartnic_provider_post_send(qp, &swr, &bad_send);
smartnic_provider_poll_cq(cq, 2, wc);
```

最小 RDMA Write：

```c
struct smartnic_provider_send_wr wr = {
        .opcode = SMARTNIC_PROVIDER_WR_RDMA_WRITE,
        .send_flags = SMARTNIC_PROVIDER_SEND_SIGNALED,
        .sg_list = local_sge,
        .num_sge = 1,
        .remote_addr = remote_addr,
        .rkey = remote_rkey,
};
```

最小 RDMA Read：

```c
struct smartnic_provider_send_wr wr = {
        .opcode = SMARTNIC_PROVIDER_WR_RDMA_READ,
        .send_flags = SMARTNIC_PROVIDER_SEND_SIGNALED,
        .sg_list = local_write_sge,
        .num_sge = 1,
        .remote_addr = remote_addr,
        .rkey = remote_rkey,
};
```

不支持 opcode 的处理：

```c
if (smartnic_provider_post_send(qp, &wr, &bad_wr) < 0) {
        if (bad_wr == &wr && errno == EOPNOTSUPP) {
                /* opcode、QP type 或 send flag 当前不被 provider 支持。 */
        }
}
```

## 已知限制 / TODO

- 尚未接入完整 rdma-core provider plugin loader；当前是 project provider API 和 metadata。
- 真实 mmap Doorbell MMIO 尚未接入，provider 记录 `last_sq_doorbell` / `last_rq_doorbell` 作为 fast-path bring-up 钩子。
- CQ completion channel fd 和 async fd 尚未实现。
- 完整 connection manager、path record、GID route resolution、P_Key enforcement 仍是上层或后续工作。
- UC、XRC、SRQ、multicast、raw packet、atomic WR、memory window bind/local invalidate/remote invalidate WR 均未作为 posting API 实现。
- 完整硬件 retry、RNR、ACK/NAK、multi-packet segmentation 和 ICRC/FCS 行为由 RTL/verification 阶段描述；provider 文档只声明用户态可见语义。
- 当前 provider MR registration 受 mailbox 参数区限制，单 MR 长度暂不超过 4GB。
- `SMARTNIC_PROVIDER_MAX_WQE_SGE` 当前为 4，而 query_device 默认 `max_sge` 为 256；这表示硬件/驱动长期目标和当前 provider WQE ABI 之间仍有 bring-up gap。
- 本文不新增 perftest、UCX 或 libfabric test，只引用已有 compatibility runner。
