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

当前阶段只创建目录，不实现用户态库代码。
