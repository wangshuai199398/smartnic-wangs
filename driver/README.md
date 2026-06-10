# `driver/` 目录

这个目录用于存放 RDMA SmartNIC 的 Linux 驱动设计。

驱动负责连接操作系统和硬件，后续会逐步实现：

- PCIe 设备 probe/remove
- BAR 映射和设备初始化
- CSR mailbox 控制命令
- 字符设备 ioctl 控制面
- mmap Doorbell 页面
- QP、CQ、MR、PD、AH 等资源管理
- MSI-X 中断处理
- SR-IOV PF/VF 管理
- 进程退出和设备热拔出的资源清理

当前阶段只创建目录，不实现驱动代码。
