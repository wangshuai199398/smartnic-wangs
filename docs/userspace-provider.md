# SmartNIC 用户态 Provider

13.1 在 `lib/libsmartnic` 中添加了首个面向 provider 的用户态层，覆盖设备发现和上下文生命周期。13.2 在此基础上加入 `query_device`、`query_port`、`query_gid` 和 `query_pkey` 查询 API。13.3 添加了保护域（PD）的分配和释放 API。13.4 添加了 Completion Queue 的创建、销毁、resize、poll 和 notify API。13.5 添加了 Queue Pair 的创建、修改、查询和销毁 API。13.6 添加了 Memory Region 注册和注销 API。13.7 添加了 UD Address Handle 创建和销毁 API。13.8 添加了 Send/RDMA/UD WQE 构建 helper。13.9 添加了 post_send/post_recv 批量提交和 Doorbell memory barrier helper。13.10 添加了 CQE parser。13.11 添加了 async event retrieval 和 acknowledgement API。

## 已实现的 API

```c
int smartnic_provider_discover(struct smartnic_provider_device **devices,
                               size_t *count);
void smartnic_provider_free_devices(struct smartnic_provider_device *devices);
int smartnic_provider_open(const struct smartnic_provider_device *device,
                           struct smartnic_provider_context **ctx);
int smartnic_provider_open_path(const char *node_path,
                                struct smartnic_provider_context **ctx);
int smartnic_provider_close(struct smartnic_provider_context *ctx);
int smartnic_provider_query_device(struct smartnic_provider_context *ctx,
                                   struct smartnic_provider_device_attr *attr);
int smartnic_provider_query_port(struct smartnic_provider_context *ctx,
                                 uint8_t port_num,
                                 struct smartnic_provider_port_attr *attr);
int smartnic_provider_query_gid(struct smartnic_provider_context *ctx,
                                uint8_t port_num, uint32_t index,
                                struct smartnic_provider_gid *gid);
int smartnic_provider_query_pkey(struct smartnic_provider_context *ctx,
                                 uint8_t port_num, uint32_t index,
                                 uint16_t *pkey);
int smartnic_provider_alloc_pd(struct smartnic_provider_context *ctx,
                               struct smartnic_provider_pd **pd);
int smartnic_provider_dealloc_pd(struct smartnic_provider_pd *pd);
int smartnic_provider_create_cq(struct smartnic_provider_context *ctx, int cqe,
                                struct smartnic_provider_cq **cq);
int smartnic_provider_destroy_cq(struct smartnic_provider_cq *cq);
int smartnic_provider_resize_cq(struct smartnic_provider_cq *cq, int cqe);
int smartnic_provider_poll_cq(struct smartnic_provider_cq *cq, int num_entries,
                              struct smartnic_provider_wc *wc);
int smartnic_provider_req_notify_cq(struct smartnic_provider_cq *cq,
                                    int solicited_only);
int smartnic_provider_queue_async_event(struct smartnic_provider_context *ctx,
                                        const struct smartnic_provider_async_event *event);
int smartnic_provider_get_async_event(struct smartnic_provider_context *ctx,
                                      struct smartnic_provider_async_event *event);
int smartnic_provider_ack_async_event(struct smartnic_provider_async_event *event);
int smartnic_provider_create_qp(struct smartnic_provider_pd *pd,
                                const struct smartnic_provider_qp_init_attr *init_attr,
                                struct smartnic_provider_qp **qp);
int smartnic_provider_modify_qp(struct smartnic_provider_qp *qp,
                                const struct smartnic_provider_qp_attr *attr,
                                uint32_t attr_mask);
int smartnic_provider_query_qp(struct smartnic_provider_qp *qp,
                               struct smartnic_provider_qp_attr *attr,
                               struct smartnic_provider_qp_init_attr *init_attr);
int smartnic_provider_destroy_qp(struct smartnic_provider_qp *qp);
int smartnic_provider_reg_mr(struct smartnic_provider_pd *pd, void *addr,
                             uint64_t length, uint32_t access_flags,
                             struct smartnic_provider_mr **mr);
int smartnic_provider_dereg_mr(struct smartnic_provider_mr *mr);
int smartnic_provider_create_ah(struct smartnic_provider_pd *pd,
                                const struct smartnic_provider_ah_attr *attr,
                                struct smartnic_provider_ah **ah);
int smartnic_provider_destroy_ah(struct smartnic_provider_ah *ah);
int smartnic_provider_build_send_wqe(struct smartnic_provider_qp *qp,
                                     const struct smartnic_provider_send_wr *wr,
                                     struct smartnic_provider_wqe *wqe_out);
int smartnic_provider_post_send(struct smartnic_provider_qp *qp,
                                const struct smartnic_provider_send_wr *wr_list,
                                const struct smartnic_provider_send_wr **bad_wr);
int smartnic_provider_post_recv(struct smartnic_provider_qp *qp,
                                const struct smartnic_provider_recv_wr *wr_list,
                                const struct smartnic_provider_recv_wr **bad_wr);
```

## 设备发现

发现流程默认扫描 `/dev` 目录下的 `smartnic*` 节点。测试或打包可通过以下环境变量覆盖扫描目录：

```bash
SMARTNIC_PROVIDER_DEV_DIR=/path/to/devdir
```

仅返回兼容的字符设备。provider 打开每个候选设备并发送 `SMARTNIC_IOCTL_MBOX_EXEC`（操作码 `SMARTNIC_CMD_QUERY_DEVICE`），缓存版本、特性、能力和状态元数据。如果没有设备存在，发现流程返回成功，且 `count == 0`。

## 上下文生命周期

打开上下文：

1. 以 `O_RDWR | O_CLOEXEC` 打开设备节点；
2. 分配 `struct smartnic_provider_context`；
3. 初始化 provider 锁；
4. 查询并缓存基本驱动元数据；
5. 初始化子对象计数器，供后续 PD/CQ/QP/MR/AH API 使用。

关闭上下文时，若仍有未释放的子对象，返回 `EBUSY` 拒绝关闭。由于 13.1 尚未实现这些对象，计数器目前只是占位，留给后续 13.x 任务。

## 查询 API

`smartnic_provider_query_device()` 会通过 mailbox query 刷新 context 缓存的 `driver_version`、`features`、`caps` 和 `status`，然后填充 provider device attributes。

当前 13.2 的能力上限采用原型默认值：

| 字段 | 当前值 |
| --- | --- |
| `max_qp` | 4096 |
| `max_cq` | 4096 |
| `max_mr` | 8192 |
| `max_pd` | 1024 |
| `max_sge` | 256 |
| `max_wr` | 4096 |
| `supported_transport` | RC + UD |
| `link_layer` | Ethernet/RoCE |
| `atomic_cap` | none |
| `page_size_cap` | 4096 |

`smartnic_provider_query_port()` 当前支持单端口 `port_num = 1`，返回 active Ethernet/RoCE 风格端口：MTU 4096、LID 为 0、GID table 长度 1、P_Key table 长度 1。无效端口返回 `EINVAL`。

`smartnic_provider_query_gid()` 当前在 index 0 返回全零默认 GID。该占位让后续 AH/QP 代码可以按 RoCE GID 派生字段接入真实表。无效 GID index 返回 `EINVAL`。

`smartnic_provider_query_pkey()` 当前在 index 0 返回默认 full-membership P_Key `0xffff`。硬件没有真实 P_Key 表时也能给依赖 P_Key 查询的软件一个清晰默认值。无效 P_Key index 返回 `EINVAL`。

所有查询 API 都会检查：

- context 不能为 `NULL`；
- context fd 不能已关闭；
- ABI version 必须匹配 `SMARTNIC_PROVIDER_ABI_VERSION`；
- 输出指针不能为 `NULL`；
- 端口号和表 index 必须在范围内。

## PD 生命周期

`smartnic_provider_alloc_pd()` 使用现有 `SMARTNIC_IOCTL_MBOX_EXEC` 路径向内核驱动发送 `SMARTNIC_CMD_ALLOC_PD`，驱动返回的 PD number/handle 保存在 `struct smartnic_provider_pd` 中。provider 侧 PD 对象包含：

- parent context 指针；
- kernel PD handle / PD number；
- `child_count` 和 `refcount`，供后续 CQ/QP/MR 绑定到 PD 时做生命周期保护；
- context 内部链表指针，用于 close 时检测仍未释放的 PD。

分配成功后，PD 会挂入 context 的 PD 链表，并增加 `pd_count`。如果 provider 无法分配用户态 PD 对象，会尝试用 `SMARTNIC_CMD_DEALLOC_PD` 回滚已经创建的 kernel PD。

`smartnic_provider_dealloc_pd()` 会先验证 PD magic、parent context 和链表归属，再检查 `child_count == 0` 且 `refcount <= 1`。如果仍有后续对象引用该 PD，返回 `EBUSY`，不会销毁 kernel PD。检查通过后，provider 发送 `SMARTNIC_CMD_DEALLOC_PD`，成功后从 context 链表摘除并释放用户态对象。

当前阶段只实现 PD 生命周期。真实 libibverbs provider glue、PD 关联的 CQ/QP/MR 子对象引用增加/减少，会在后续 13.x 任务补齐。

## CQ 生命周期和轮询

`smartnic_provider_create_cq()` 会校验 context、ABI 和 CQ depth，然后通过 `SMARTNIC_CMD_CREATE_CQ` 创建 kernel CQ。返回的 CQN/kernel handle 会保存到 `struct smartnic_provider_cq`。provider 侧 CQ 对象包含：

- parent context 指针；
- CQ lock；
- kernel CQ handle / CQN；
- CQ depth；
- producer/consumer index；
- ring 指针和 ring size 占位字段；
- `child_count` 和 `refcount`，供后续 QP 引用 CQ；
- notification armed / solicited-only 状态；
- context 内部链表指针。

当前实现保留 kernel/mailbox command path，同时定义了 provider 侧 64-byte `smartnic_provider_cqe` 格式。若 `cq->ring` 已经指向 mmap-backed CQ buffer，`poll_cq` 会优先从 ring 消费 CQE；若 ring 未映射，则回退到 `SMARTNIC_CMD_POLL_CQ` mailbox 路径。这样 CQE parser 和 consumer index 逻辑可以先稳定下来，真实驱动映射 CQ ring 后不需要重写 work completion 转换。

`smartnic_provider_destroy_cq()` 会检查 CQ 是否属于 parent context，并拒绝仍有 active QP/child 引用的 CQ。检查通过后发送 `SMARTNIC_CMD_DESTROY_CQ`，再从 context CQ 链表摘除并释放 provider 对象。

`smartnic_provider_resize_cq()` 通过 `SMARTNIC_CMD_RESIZE_CQ` 请求 kernel resize。只有 kernel 命令成功后才更新 provider 侧 `cqe` 和 index 元数据。如果驱动或硬件不支持 resize，ioctl/mailbox 应返回清晰错误，provider 不会修改本地状态。

`smartnic_provider_parse_cqe()` 是唯一的 CQE-to-work-completion 转换入口。它会先检查 CQE valid/owner bit，未 owned 的 CQE 不会被消费；有效 CQE 会被转换为 `struct smartnic_provider_wc`，填充 `wr_id`、`status`、`opcode`、`byte_len`、`qp_num`、`wc_flags`、`imm_data`、`invalidate_rkey` 和 `vendor_err`。未知 provider status 会映射到 `SMARTNIC_PROVIDER_WC_GENERAL_ERR`，未知 opcode 安全映射为 SEND，硬件的错误 detail 保存在 `vendor_err`。Immediate data 在 CQE 中按 network byte order 保存，parser 通过 `ntohl()` 转回 host order。

`smartnic_provider_poll_cq()` 会遵守 `num_entries` 上限，CQ 为空或当前 consumer slot 没有 valid/owner bit 时返回已经取到的 completion 数量。消费一个 CQE 后才推进 consumer index，并在 ring-backed 路径中清除 valid bit；consumer index 到 `cqe - 1` 后回绕到 0。mailbox fallback 会把 4-word 紧凑 CQE 包装成同一个 `smartnic_provider_cqe` 后再调用 parser，因此两条路径返回一致的 Verbs-compatible work completion。若已经成功取到部分 completion 后遇到 mailbox 错误，则返回已取到数量；第一个 completion 就失败时返回负 errno。

`smartnic_provider_req_notify_cq()` 通过 `SMARTNIC_CMD_ARM_CQ` arm CQ，支持 next-completion 和 solicited-only 两种模式。当前 poll/notify race 策略是先由调用方 poll drain，再 arm，再按需重新 poll；后续正式 verbs glue 会把该顺序封装为 libibverbs 兼容语义。

## Async event

13.11 提供 provider 侧 async event 队列。事件格式为 `struct smartnic_provider_async_event`，包含 `event_type`、`element_type`、CQ/QP/port/device element、`vendor_err`、parent context 以及 provider 私有 token。支持的基础事件类型包括 CQ error、QP fatal/request error、port active/error 和 device fatal；SRQ 还未实现，因此没有 SRQ element。

`smartnic_provider_queue_async_event()` 是驱动事件、poll/IRQ 集成或后续 verbs glue 的 producer hook。它会复制事件并追加到 context 的 pending FIFO，保证多个事件按入队顺序被返回。

`smartnic_provider_get_async_event()` 是非阻塞 API：如果 pending 队列为空，返回 `-1` 并设置 `errno = EAGAIN`；如果有事件，则从 pending FIFO 取出一个节点，移动到 outstanding list，并返回 Verbs-compatible event copy。事件必须随后用 `smartnic_provider_ack_async_event()` 确认。

`smartnic_provider_ack_async_event()` 只接受从 `get_async_event` 返回的事件 token。确认成功后释放事件节点并清除调用方传入的 event 结构；重复 ack、伪造 token 或错误 context 会返回 `EINVAL`。context close 会清理 pending 和未 ack 的 outstanding 事件，避免未 ack event 泄漏。当前 provider 没有独立 async fd；可读性由 future driver/poll glue 把内核 event_pending 转换为 `queue_async_event()` 调用。

## QP 生命周期

`smartnic_provider_create_qp()` 需要一个有效 PD，以及 send CQ / recv CQ。创建前会校验：

- PD 和 CQ 必须属于同一个 provider context；
- QP type 当前支持 RC 和 UD，其他类型返回 `EOPNOTSUPP`；
- `max_send_wr`、`max_recv_wr`、`max_send_sge`、`max_recv_sge` 必须非 0 且不超过 provider 默认能力；
- context 中 QP 数量不能超过 `SMARTNIC_PROVIDER_DEFAULT_MAX_QP`。

创建成功后，provider 会保存 QPN/kernel handle、QP type、初始 RESET 状态、SQ/RQ capacity、SGE limit、SQ/RQ index 元数据，并增加 PD、send CQ、recv CQ 的 child/refcount。当前阶段不分配真实 SQ/RQ ring，也不 mmap Doorbell 页；这些留给 post_send/post_recv 和 fast path 任务。

`smartnic_provider_modify_qp()` 先做 provider 侧状态迁移校验，kernel 命令成功后才更新 cached state。当前支持的基础迁移包括：

| 迁移 | 必需属性 |
| --- | --- |
| RESET -> INIT | state、port、P_Key index |
| INIT -> RTR | state、path MTU、dest QPN、RQ PSN |
| RTR -> RTS | state、SQ PSN、retry/RNR retry、timeout |
| RTS -> SQD | state |
| any -> ERR | state |

明显非法迁移会返回 `EINVAL`。13.5 只实现用户态 provider 的基本状态门禁，完整 IBTA 属性语义、retry 和路径规则仍由硬件/驱动和后续任务细化。

`smartnic_provider_query_qp()` 返回 provider cached QP attrs 和 init attrs。`smartnic_provider_destroy_qp()` 会拒绝仍有 active operations 或额外引用的 QP，成功销毁 kernel QP 后释放 PD/CQ child 引用，并从 context QP 链表摘除。

## MR 生命周期

`smartnic_provider_reg_mr()` 需要一个有效 PD、非空用户虚拟地址、非零长度和受支持的 access flags。当前支持的 provider access flags 包括：

| flag | 用途 |
| --- | --- |
| `SMARTNIC_PROVIDER_ACCESS_LOCAL_WRITE` | 允许本地写入 buffer，例如 Recv 或 RDMA Read response |
| `SMARTNIC_PROVIDER_ACCESS_REMOTE_WRITE` | 允许远端 RDMA Write |
| `SMARTNIC_PROVIDER_ACCESS_REMOTE_READ` | 允许远端 RDMA Read |
| `SMARTNIC_PROVIDER_ACCESS_REMOTE_ATOMIC` | 预留远端 atomic 权限 |
| `SMARTNIC_PROVIDER_ACCESS_RELAXED_ORDER` | 预留 relaxed ordering |

为了避免授予不可执行的权限，当前规则会拒绝未知 bit；`REMOTE_WRITE` 必须同时带 `LOCAL_WRITE`；`REMOTE_ATOMIC` 当前返回不支持，直到硬件/驱动侧 atomic 能力真正接入。

注册成功后，provider 保存：

- parent context 和 PD；
- 用户虚拟地址和长度；
- access flags；
- kernel MR handle；
- lkey 和 rkey；
- page size / page shift；
- active operation/refcount；
- context MR 链表指针。

当前原型复用 `SMARTNIC_IOCTL_MBOX_EXEC`。由于 mailbox 参数区只有 4 个 dword，13.6 传给 kernel 的注册参数为 VA low、VA high、length low32 和 access flags，因此 provider 暂时拒绝超过 4GB 的单个 MR。后续如果驱动暴露 dedicated MR ioctl 或扩展 mailbox payload，可以自然放宽该限制并传递完整 pinned SG list 元数据。

`smartnic_provider_dereg_mr()` 会验证 MR magic、parent context 和链表归属，拒绝仍有 active operations 或额外 refcount 的 MR。注销成功后发送 `SMARTNIC_CMD_DEREG_MR`，释放 PD child/refcount，并从 context MR 链表摘除。重复注销或伪造 MR 会返回 `EINVAL`。

## AH 生命周期

`smartnic_provider_create_ah()` 用于 UD QP 后续发送时引用目的地址。当前仅支持 RoCE/Ethernet 风格的 global addressing，因此 `is_global` 必须为 1。创建前会校验：

- parent PD 有效且属于当前 context；
- `port_num` 在 provider 支持范围内；
- 端口 link layer 为 Ethernet/RoCE；
- `gid_index` 能通过 `query_gid` 兼容逻辑；
- `sl <= 15`；
- `flow_label <= 0xfffff`；
- `hop_limit != 0`；
- LID-only 或非 RoCE addressing 返回 `EOPNOTSUPP`。

AH 对象保存 parent context、PD、kernel AH handle、port、GID index、DGID、SL、traffic class、flow label、hop limit、static rate、path bits、Q_Key 和 destination QPN。这些字段为 13.8/13.9 的 UD Send WQE builder 和 post_send 复用。

`smartnic_provider_destroy_ah()` 会拒绝仍有 active UD operations 或额外 refcount 的 AH，成功后发送 `SMARTNIC_CMD_DESTROY_AH`，释放 PD child/refcount，并从 context AH 链表摘除。13.7 不实现 multicast、特殊地址模式，也不构造真实 UD WQE。

## WQE 构建

13.8 定义了 provider-side WQE ABI：

- `smartnic_provider_wqe_ctrl`：opcode、flags、wr_id、QPN、SGE 数量、总长度、immediate data；
- `smartnic_provider_sge`：本地地址、长度、lkey；
- `smartnic_provider_wqe_rdma`：remote address 和 rkey；
- `smartnic_provider_wqe_ud`：AH handle、remote QPN、remote QKey、GID metadata；
- `smartnic_provider_wqe`：组合后的固定格式 WQE。

`smartnic_provider_build_send_wqe()` 当前支持：

- `SMARTNIC_PROVIDER_WR_SEND`
- `SMARTNIC_PROVIDER_WR_SEND_WITH_IMM`
- `SMARTNIC_PROVIDER_WR_RDMA_WRITE`
- `SMARTNIC_PROVIDER_WR_RDMA_WRITE_WITH_IMM`
- `SMARTNIC_PROVIDER_WR_RDMA_READ`
- `SMARTNIC_PROVIDER_WR_UD_SEND`
- `SMARTNIC_PROVIDER_WR_UD_SEND_WITH_IMM`

builder 会验证 QP 必须处于 RTS；RC op 只能用于 RC QP；UD op 只能用于 UD QP 且必须提供有效 AH。SGE 数量不能超过 QP 限制和 `SMARTNIC_PROVIDER_MAX_WQE_SGE`，每个 SGE 会在当前 context 的 MR 链表中按 lkey 查找，并检查地址范围。RDMA Read 的本地目标 SGE 必须带 `LOCAL_WRITE` MR 权限。

immediate data 通过 `htonl()` 编码为 network byte order，保证 Send with Immediate 和 RDMA Write with Immediate 在 wire/CQE 侧看到一致的 32-bit 值。inline data 仅在 `SMARTNIC_PROVIDER_SEND_INLINE` 被设置且长度不超过 `SMARTNIC_PROVIDER_WQE_INLINE_BYTES` 时接受。

13.8 只写入 QP 的 shadow SQ ring，保存 wr_id，并推进 provider-side producer index；不会批量 post，也不会写 Doorbell。若 SGE、lkey、AH、remote key、send flags 或 SQ 空间检查失败，builder 会返回错误且不会推进 producer index，这就是 13.9 post_send/doorbell 的 rollback 基础。

## post_send / post_recv

`smartnic_provider_post_send()` 接收 `smartnic_provider_send_wr` 链表，按顺序调用 13.8 的 WQE builder。每个成功 WR 都会写入 QP shadow SQ ring，保存 `wr_id`、opcode 和 signaled metadata，并推进 SQ producer index。遇到第一个失败 WR 时，`bad_wr` 指向该 WR；已经成功构建的 WR 保留，并在返回前写一次 SQ Doorbell。

`smartnic_provider_post_recv()` 接收 `smartnic_provider_recv_wr` 链表，校验 QP 状态、SGE 数量、lkey 和 MR 范围，并写入 RQ shadow ring。Recv SGE 必须引用带 `LOCAL_WRITE` 的 MR。成功批次只写一次 RQ Doorbell。

SQ/RQ ring 使用 reserved-one-entry 策略避免覆盖未完成 WQE：`next_producer == consumer` 表示队列满。producer index 只对成功 WR 前进；当前失败 WR 不会写入 ring。空 WR 链是 no-op success。

Doorbell helper 当前写入 provider-side `last_sq_doorbell` / `last_rq_doorbell` 记录，保留 QPN、queue type、producer index 和本批 count。真实 mmap/MMIO Doorbell 页会在后续 fast path 任务中接入。写 Doorbell 前调用 `__sync_synchronize()` 作为跨平台保守 write memory barrier，保证 WQE 和 metadata 对设备可见后再发布 producer index。x86 上这比普通 store-store ordering 更强；弱内存序架构需要保留该屏障或替换为平台专用 MMIO barrier。

## Packaging, metadata 和 examples

13.12 添加了 provider packaging 文件：

- `lib/libsmartnic/libsmartnic-provider.pc.in`：pkg-config 模板；
- `lib/libsmartnic/smartnic-provider.json`：provider metadata，包含 provider name、ABI version、device vendor/device ID、RC/UD transport 和 Ethernet/RoCE link layer；
- `examples/smartnic_provider_query_example.c`：open `/dev/smartnicX` 并 query device；
- `examples/smartnic_provider_cq_poll_example.c`：创建 CQ 并调用 `smartnic_provider_poll_cq()`；
- `examples/smartnic_provider_async_event_example.c`：调用 async event get/ack 路径。
- `examples/smartnic_minimal_verbs_example.c`：最小 RC Send/Recv bring-up 示例，执行 open device、query、PD/CQ/QP/MR 创建、post_recv、post_send 和 poll completion。

生成 staged pkg-config 和 metadata：

```bash
make -C lib/libsmartnic packaging
```

安装到 staging 目录：

```bash
make -C lib/libsmartnic DESTDIR=/tmp/smartnic-stage PREFIX=/usr install
PKG_CONFIG_PATH=/tmp/smartnic-stage/usr/lib/pkgconfig pkg-config --cflags --libs libsmartnic-provider
```

默认安装布局：

| 文件 | 安装路径 |
| --- | --- |
| `smartnic_provider.h` | `${includedir}/smartnic/` |
| `libsmartnic_provider.a` | `${libdir}/`，若当前平台可构建 |
| `libsmartnic-provider.pc` | `${libdir}/pkgconfig/` |
| `smartnic-provider.json` | `${libdir}/smartnic/providers/` |

provider discovery 假设上层 RDMA glue 会读取 metadata 中的 `device_node_prefix = smartnic`，再使用 provider discovery API 扫描 `/dev/smartnic*`。当前尚未接入 rdma-core provider plugin loader；13.12 只固定 metadata 和 packaging 约定。

构建 examples：

```bash
make -C examples
```

当前 examples 是 Linux-only：如果环境缺少 Linux UAPI headers，Makefile 会清晰跳过。provider examples 依赖 `lib/libsmartnic/libsmartnic_provider.a` 和 `smartnic_provider.h`，不使用私有测试 helper。

运行最小 RC Send/Recv 示例：

```bash
SMARTNIC_PROVIDER_DEVICE=/dev/smartnic0 ./examples/smartnic_minimal_verbs_example
```

也可以直接把设备节点作为第一个参数传入：

```bash
./examples/smartnic_minimal_verbs_example /dev/smartnic0
```

示例会创建一个 loopback-style RC QP，将 `dest_qpn` 设置为本地 QPN，注册独立的 send/recv MR，先 post 一个 Recv WR，再 post 一个 signaled Send WR，最后轮询两个 completion。成功时输出类似：

```text
SUCCESS: minimal RC Send/Recv completed; recv buffer="smartnic minimal rc send"
```

如果没有 `/dev/smartnicX`、权限不足或当前环境没有 SmartNIC provider 设备，示例以退出码 77 报告 `SKIP`，便于 CI 和无硬件开发机区分“环境不可用”和“示例失败”。该示例不做连接管理，也不覆盖 perftest、UCX 或 libfabric；这些兼容性工作分别留给 15.2、15.3 和 15.4。

运行 userspace unit/static tests：

```bash
make -C lib/libsmartnic test
python3 docs/tests_driver_docs.py
```

`test_smartnic_provider_static.py` 覆盖 provider API surface、CQE parser、async event 和 post_send/post_recv；`test_smartnic_provider_packaging.py` 覆盖 pkg-config 模板、provider metadata、examples 和 install/staging 约定。

## 13.12 后仍未实现的内容

- 真实 mmap Doorbell MMIO；
- libibverbs provider 注册。

这些有意留给后续 13.x 任务。
