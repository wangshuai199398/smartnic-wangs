# SmartNIC 用户态 Provider

13.1 在 `lib/libsmartnic` 中添加了首个面向 provider 的用户态层。目前有意限定于设备发现和上下文生命周期。

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

## 13.1 中未实现的内容

- PD 分配；
- CQ 创建或轮询；
- QP 创建或提交；
- MR 注册；
- AH 管理；
- 快速路径 Doorbell 写入；
- libibverbs provider 注册。

这些有意留给后续 13.x 任务。
