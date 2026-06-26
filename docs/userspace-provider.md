# SmartNIC 用户态 Provider

13.1 在 `lib/libsmartnic` 中添加了首个面向 provider 的用户态层，覆盖设备发现和上下文生命周期。13.2 在此基础上加入 `query_device`、`query_port`、`query_gid` 和 `query_pkey` 查询 API。13.3 添加了保护域（PD）的分配和释放 API。13.4 添加了 Completion Queue 的创建、销毁、resize、poll 和 notify API。

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

当前实现选择 kernel/mailbox command path 作为最小可验证路径，没有 mmap 真实 CQ ring。这样可以先稳定 CQ 对象生命周期和 completion 翻译接口，后续驱动暴露 CQ ring 后再把 `ring` 字段接到 mmap-backed CQ buffer。

`smartnic_provider_destroy_cq()` 会检查 CQ 是否属于 parent context，并拒绝仍有 active QP/child 引用的 CQ。检查通过后发送 `SMARTNIC_CMD_DESTROY_CQ`，再从 context CQ 链表摘除并释放 provider 对象。

`smartnic_provider_resize_cq()` 通过 `SMARTNIC_CMD_RESIZE_CQ` 请求 kernel resize。只有 kernel 命令成功后才更新 provider 侧 `cqe` 和 index 元数据。如果驱动或硬件不支持 resize，ioctl/mailbox 应返回清晰错误，provider 不会修改本地状态。

`smartnic_provider_poll_cq()` 当前通过 `SMARTNIC_CMD_POLL_CQ` 逐个拉取 completion。mailbox 返回的紧凑 CQE metadata 被翻译为 `struct smartnic_provider_wc`，包括 `wr_id`、`status`、`opcode`、`byte_len`、`qp_num`、`vendor_err`、`imm_data` 和 `wc_flags`。CQ 为空时返回 0；错误时返回负 errno；已经成功取到部分 completion 后遇到错误，则返回已取到的数量。

`smartnic_provider_req_notify_cq()` 通过 `SMARTNIC_CMD_ARM_CQ` arm CQ，支持 next-completion 和 solicited-only 两种模式。当前 poll/notify race 策略是先由调用方 poll drain，再 arm，再按需重新 poll；后续正式 verbs glue 会把该顺序封装为 libibverbs 兼容语义。

## 13.4 后仍未实现的内容

- QP 创建或提交；
- MR 注册；
- AH 管理；
- 快速路径 Doorbell 写入；
- libibverbs provider 注册。

这些有意留给后续 13.x 任务。
