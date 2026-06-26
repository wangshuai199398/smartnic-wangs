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

当前已经实现第一步 PCIe probe/remove 骨架，代码位于 `drivers/linux/`：

- `smartnic_pci.c`：PCI ID table、probe/remove、BAR 映射、DMA mask、reset 和 feature discovery；
- `smartnic_pci.h`：驱动私有状态；
- `smartnic_mbox.c` / `smartnic_mbox.h`：CSR mailbox 同步命令 helper、timeout 和错误码映射；
- `smartnic_regs.h`：PCI ID、BAR 和早期 CSR offset 宏。

后续阶段会继续补充 CSR mailbox、字符设备、mmap、资源管理、MSI-X 和 SR-IOV。
