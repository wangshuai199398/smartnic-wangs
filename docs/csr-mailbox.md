# CSR Mailbox

本文档说明 `rtl/reg/pcie_csr_mailbox.sv` 的最小 CSR mailbox 协议。当前阶段对应 tasks.md 的 2.4，只实现寄存器协议和命令生命周期，不创建真实 QP/CQ/MR，也不访问资源表。

## 系统位置

Mailbox 位于 BAR2 CSR space 后面：

```text
Host driver ioctl
    |
BAR2 CSR write/read
    |
pcie_bar_decoder
    |
pcie_csr_mailbox
    |
future QP/CQ/MR managers
```

BAR decoder 负责把 BAR2 请求转给 CSR path。Mailbox 负责把软件写入的 command_id、参数和 owner_function 组织成一个可被硬件管理模块消费的命令。

## 寄存器布局

Mailbox 使用 BAR2 的 `0x0100-0x01ff` 区间。

| Offset | 名称 | 方向 | 说明 |
| --- | --- | --- | --- |
| `0x0100` | `command_id` | RW | 命令编号，使用 `csr_cmd_e` |
| `0x0104` | `owner_function` | RW | 命令所属 PF/VF function |
| `0x0108` | `control` | RW/RO | bit0=`go`，bit1=`done`，bit2=`busy`，bit3=`error` |
| `0x010c` | `status` | RO | `IDLE/BUSY/SUCCESS/FAILED` |
| `0x0110` | `error_code` | RO | 具体错误码 |
| `0x0114` | `timeout_counter` | RO | BUSY 状态计数 |
| `0x0120` | `arg0` | RW | 参数 0 |
| `0x0124` | `arg1` | RW | 参数 1 |
| `0x0128` | `arg2` | RW | 参数 2 |
| `0x012c` | `arg3` | RW | 参数 3 |

当前支持 32-bit dword 访问和 byte enable。

## 命令生命周期

Mailbox 状态机包括：

```text
IDLE -> GO -> BUSY -> DONE
              |
              v
             ERROR
```

1. 软件在 `IDLE` 写入 `command_id`、`arg0..arg3` 和可选的 `owner_function`。
2. 软件写 `control.go=1` 提交命令。
3. 硬件进入 `GO`，检查 command_id 是否受支持。
4. 合法命令进入 `BUSY`，同时输出一拍 `mailbox_cmd_valid`。
5. 当前阶段不访问真实资源表，所以合法命令在最小 BUSY 周期后进入 `DONE`。
6. 非法命令或超时进入 `ERROR`。

`DONE` 和 `ERROR` 会保持，直到软件写新的 `command_id` 或重新提交命令。

## 当前支持的命令

当前阶段只接受以下命令 ID：

- `CSR_CMD_NOP`
- `CSR_CMD_CREATE_QP`
- `CSR_CMD_DESTROY_QP`
- `CSR_CMD_CREATE_CQ`
- `CSR_CMD_DESTROY_CQ`
- `CSR_CMD_REG_MR`
- `CSR_CMD_DEREG_MR`

这些命令只完成 mailbox 协议，不创建、销毁或修改真实资源。

## 错误处理

Mailbox 当前定义以下错误码：

| Error Code | 含义 |
| --- | --- |
| `CSR_MB_ERR_NONE` | 无错误 |
| `CSR_MB_ERR_INVALID_CMD` | command_id 当前不支持 |
| `CSR_MB_ERR_TIMEOUT` | BUSY 超过 timeout limit |
| `CSR_MB_ERR_BUSY` | mailbox 忙时收到新的 go |
| `CSR_MB_ERR_BAD_OFFSET` | 访问了不支持的 mailbox offset |

非法 command_id 会进入 `ERROR`，并设置 `status=FAILED`、`error_code=CSR_MB_ERR_INVALID_CMD`。

## 对后续实现的作用

### Linux driver ioctl

后续 driver ioctl 可以把 `CREATE_QP`、`CREATE_CQ`、`REG_MR` 等控制操作翻译成 mailbox 写寄存器流程：写参数、写 go、轮询 done、读取 status/error_code。

### QP/CQ/MR 资源管理

当前模块已经输出 `mailbox_cmd_valid`、`mailbox_cmd_id`、`arg0..arg3` 和 `mailbox_owner_function`。后续 QP/CQ/MR manager 可以接收这些字段，真正分配或销毁资源表项。

### SR-IOV Function Ownership

`owner_function` 会随着命令一起输出。后续 SR-IOV guard 和资源管理器可以用它记录资源归属，并拒绝 VF 访问不属于自己的 QP/CQ/MR。
