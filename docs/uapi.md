# SmartNIC UAPI 参考

当前 UAPI 定义在 `include/uapi/linux/smartnic_ioctl.h` 中。用户态程序应包含该头文件，而非自行复制 ioctl 编号或结构体定义。

## 设备节点

驱动创建：

```text
/dev/smartnic0
/dev/smartnic1
...
```

以 `O_RDWR | O_CLOEXEC` 打开节点。

## Ioctl 命令

| 命令 | 方向 | 结构体 | 用途 |
| --- | --- | --- | --- |
| `SMARTNIC_IOCTL_MBOX_EXEC` | `_IOWR` | `struct smartnic_ioctl_mbox` | 执行一条小型 CSR mailbox 命令 |
| `SMARTNIC_IOCTL_QUEUE_CREATE` | `_IOWR` | `struct smartnic_ioctl_queue` | 分配一个 coherent DMA 队列/ring |
| `SMARTNIC_IOCTL_QUEUE_DESTROY` | `_IOW` | `struct smartnic_ioctl_queue_destroy` | 释放该 fd 拥有的队列/ring |
| `SMARTNIC_IOCTL_QUEUE_QUERY` | `_IOWR` | `struct smartnic_ioctl_queue` | 查询已拥有队列的安全元数据 |

未知 ioctl 命令返回 `-ENOTTY`。

## `struct smartnic_ioctl_mbox`

| 字段 | 方向 | 含义 |
| --- | --- | --- |
| `struct_size` | 输入 | 必须为 `sizeof(struct smartnic_ioctl_mbox)` |
| `opcode` | 输入 | CSR mailbox 操作码 |
| `flags` | 输入 | 保留，当前须为 0 |
| `in_len` | 输入 | 输入字节数，dword 对齐，最大 16 |
| `out_len` | 输入 | 输出字节数，dword 对齐，最大 16 |
| `data[4]` | 输入/输出 | 输入和输出 dword |
| `status` | 输出 | 驱动 errno 风格的命令状态 |
| `reserved` | 保留 | 不得使用 |

`tools/libsmartnic.h` 中使用的典型操作码：

| 操作码 | 名称 | 预期行为 |
| --- | --- | --- |
| `0x0000` | `SMARTNIC_CMD_NOP` | 硬件支持时为空操作 |
| `0x0001` | `SMARTNIC_CMD_QUERY_DEVICE` | 以四个 dword 返回 version/features/caps/status |
| `0x0002` | `SMARTNIC_CMD_RESET_DEVICE` | 硬件支持时请求设备复位 |

## `struct smartnic_ioctl_queue`

| 字段 | 方向 | 含义 |
| --- | --- | --- |
| `struct_size` | 输入 | 必须为 `sizeof(struct smartnic_ioctl_queue)` |
| `type` | 输入/输出 | 队列类型：SQ、RQ、CQ 或描述符 ring |
| `depth` | 输入/输出 | Ring 深度；创建时须为 2 的幂 |
| `desc_size` | 输入/输出 | 描述符大小；创建时须 8 字节对齐 |
| `flags` | 输入 | 保留，当前须为 0 |
| `queue_id` | 输出/输入 | 由 create 返回，供 query/destroy 使用 |
| `mmap_offset` | 输出 | 供 `mmap()` 使用的偏移量 cookie |
| `ring_size` | 输出 | Coherent ring 大小，单位字节 |
| `dma_addr` | 输出 | DMA 地址，供后续硬件编程使用 |
| `producer_index` | 输出 | 当前生产者索引 |
| `consumer_index` | 输出 | 当前消费者索引 |
| `reserved[4]` | 保留 | 不得使用 |

队列类型：

| 常量 | 值 | 含义 |
| --- | --- | --- |
| `SMARTNIC_QUEUE_TYPE_SQ` | 1 | Send Queue ring |
| `SMARTNIC_QUEUE_TYPE_RQ` | 2 | Receive Queue ring |
| `SMARTNIC_QUEUE_TYPE_CQ` | 3 | Completion Queue ring |
| `SMARTNIC_QUEUE_TYPE_DESC` | 4 | 描述符/控制 ring |

## mmap

存在两类映射：

1. Doorbell/MMIO BAR 映射，用于已授权的 BAR 偏移量。
2. 队列 ring 映射，使用 `SMARTNIC_IOCTL_QUEUE_CREATE` 返回的 `mmap_offset`。

队列 mmap 使用 `dma_mmap_coherent()`。无效偏移量、错误的所有者 fd 或错误的大小将返回 `-EINVAL` 或 `-EPERM`。

规则：

- 队列 mmap 的 `offset` 必须等于 `SMARTNIC_IOCTL_QUEUE_CREATE` 返回的 `mmap_offset`；
- mmap 必须通过创建该队列的同一个文件描述符发起；
- mmap 长度不能超过 `ring_size`；
- doorbell/MMIO mmap 只能映射驱动批准的 BAR 范围；
- 内核虚拟地址不会暴露给用户态。

## poll

`poll()` 报告：

常见组合为 `POLLIN | POLLRDNORM`、`POLLOUT | POLLWRNORM` 和
`POLLERR | POLLHUP`。

| 掩码 | 含义 |
| --- | --- |
| `POLLIN \| POLLRDNORM` | 事件/mailbox/CQ 通知就绪 |
| `POLLOUT \| POLLWRNORM` | 可以提交命令 |
| `POLLERR \| POLLHUP` | 设备正在移除、静默或不可用 |

## 常见 errno

| errno | 常见原因 |
| --- | --- |
| `-ENOTTY` | 未知 ioctl 命令或 ioctl magic 不匹配 |
| `-EINVAL` | 结构体大小错误、无效的 ring 参数、无效的 mmap 大小 |
| `-EFAULT` | 用户态指针无效 |
| `-ENODEV` | 设备已移除或 fd 没有设备上下文 |
| `-EAGAIN` | 设备复位处于活跃状态 |
| `-ETIMEDOUT` | Mailbox 命令超时 |
| `-EACCES` / `-EPERM` | 权限/状态错误或 mmap 所有权无效 |
| `-ENOSPC` | 设备报告无可用资源 |
| `-ENOMEM` | 主机分配失败 |
| `-EIO` | 硬件/内部错误 |

## 用户态兼容性期望

- 当前 UAPI 是 Linux-only，用户程序应包含 `<linux/smartnic_ioctl.h>`；
- 不要复制 ioctl 编号或结构体定义，避免 ABI 漂移；
- 所有结构体调用前必须设置 `struct_size`；
- 保留字段必须写 0；
- 当前驱动提供控制面和 DMA ring 原型能力，不提供完整 verbs 数据面 ABI；
- 32 位 compat ioctl 复用同一套结构体布局，结构体字段使用固定宽度类型。
