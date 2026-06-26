# `lib/` 目录

这个目录用于存放用户态 RDMA Verbs 兼容库。

用户态库位于应用程序和 Linux 驱动之间，后续会逐步实现：

- 设备发现和打开
- 查询设备和端口能力
- PD、CQ、QP、MR、AH 生命周期 API
- `post_send` 和 `post_recv`
- Completion Queue 轮询
- CQ 通知和异步事件
- mmap Doorbell 写入辅助函数
- 与 libibverbs 风格接口的兼容层

当前 13.1 已实现 provider-facing 的设备发现与 context open/close：

- `lib/libsmartnic/smartnic_provider.h`
- `lib/libsmartnic/smartnic_provider.c`

这些 API 只负责发现 `/dev/smartnic*`、打开驱动 fd、缓存基础 ABI/能力信息、初始化锁和后续对象计数，并在 close 时释放 context。PD/CQ/QP/MR/AH 和 fast path verbs 仍留给后续 13.x 任务。
