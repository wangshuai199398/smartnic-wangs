# SmartNIC 用户态 Provider

13.1 在 `lib/libsmartnic` 中添加了首个面向 provider 的用户态层，覆盖设备发现和上下文生命周期。13.2 在此基础上加入 `query_device`、`query_port`、`query_gid` 和 `query_pkey` 查询 API。

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

## 13.2 后仍未实现的内容

- PD 分配；
- CQ 创建或轮询；
- QP 创建或提交；
- MR 注册；
- AH 管理；
- 快速路径 Doorbell 写入；
- libibverbs provider 注册。

这些有意留给后续 13.x 任务。
