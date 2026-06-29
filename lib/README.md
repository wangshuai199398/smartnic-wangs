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

当前 13.1～13.9 已实现 provider-facing 的基础层：

- `lib/libsmartnic/smartnic_provider.h`
- `lib/libsmartnic/smartnic_provider.c`

这些 API 负责发现 `/dev/smartnic*`、打开驱动 fd、缓存基础 ABI/能力信息、查询设备/端口/GID/P_Key，并通过 mailbox 命令分配/释放 PD、创建/销毁/resize/轮询/arm CQ、创建/修改/查询/销毁 QP、注册/注销 MR、创建/销毁 UD AH、构建 Send/RDMA/UD WQE，执行 post_send/post_recv shadow ring 提交和 Doorbell 记录，把 provider CQE 解析为 Verbs-compatible work completion，并维护 async event get/ack 队列。13.12 还提供 `libsmartnic-provider.pc` 生成、`smartnic-provider.json` metadata、provider examples 和 userspace packaging 静态测试。真实 mmap Doorbell 和 rdma-core provider plugin glue 仍留给后续任务。
