# MSI-X Interrupts

本文档说明 `rtl/pcie/pcie_msix.sv` 的 MSI-X table、PBA 和中断调节框架。当前阶段对应 tasks.md 的 2.5，只生成 `msix_msg_valid/address/data`，不发送真实 PCIe MSI-X TLP。

## 系统位置

```text
CQ/Admin/Error event
        |
pcie_msix
        |
msix_msg_valid / addr / data
        |
future PCIe message TLP builder
```

BAR4 访问由 `pcie_bar_decoder` 转发到 `pcie_msix`。软件通过 BAR4 配置 MSI-X table、读取/清除 PBA pending bit，并配置基础中断调节参数。

## MSI-X Table

每个 vector 有 16 字节 table entry：

| Entry Offset | 字段 | 说明 |
| --- | --- | --- |
| `+0x0` | `message_address_low` | MSI-X message address 低 32 位 |
| `+0x4` | `message_address_high` | MSI-X message address 高 32 位 |
| `+0x8` | `message_data` | MSI-X message data |
| `+0xc` | `vector_control` | bit0 是 mask bit |

复位后所有 vector 默认 mask，避免设备未初始化时发出中断。

## PBA

PBA 是 Pending Bit Array。内部事件到来时，模块设置对应 vector 的 pending bit：

- vector 0：CQ completion interrupt；
- vector 1：admin/mailbox interrupt；
- vector 2：error/asynchronous interrupt。

当前 PBA 支持 BAR4 读取。写 PBA 时按 bit 清除 pending，这便于后续测试和原型调试。

## 中断调节

当前实现三个基础字段：

| Offset | 字段 | 说明 |
| --- | --- | --- |
| `0x1000` | `moderation_enable` | 使能中断调节 |
| `0x1004` | `moderation_timer` | pending 后等待的 timer 阈值 |
| `0x1008` | `moderation_count` | 聚合事件数量阈值 |

当调节关闭时，只要 vector 未 mask 且 pending，就可以输出 MSI-X message。调节开启后，满足 count 或 timer 条件才会输出 message。

## 输出消息

当某个 vector pending 且未 mask，并且调节条件满足时，模块输出：

- `msix_msg_valid`
- `msix_msg_addr`
- `msix_msg_data`
- `msix_msg_vector`

下游 `msix_msg_ready` 接收后，模块清除该 vector 的 pending bit。真实 PCIe MSI-X message TLP 发送留给后续 PCIe outbound path。

## 后续支撑

### CQ Completion Interrupt

后续 CQ manager 在 CQ 被 arm 且 completion 满足通知条件时，可以拉高 `cq_interrupt_req`。本模块会设置 vector 0 pending，并在未 mask 时生成 MSI-X message。

### Admin Mailbox Interrupt

后续 CSR mailbox 或 admin event queue 可以拉高 `admin_interrupt_req`，用于通知驱动命令完成或异步管理事件。

### Error Interrupt

后续错误路径可以拉高 `error_interrupt_req`，用于报告 QP fatal、CQ overflow、设备错误或热移除等异步事件。
