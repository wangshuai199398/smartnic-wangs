# RDMA SmartNIC 共享数据格式

本文解释 `rtl/common/smartnic_pkg.sv` 中定义的共享常量、枚举和 packed
数据结构。它们是后续 RTL、驱动、用户态库和仿真测试之间的共同语言。

当前阶段只定义格式，不实现 DMA Engine、QP 状态机或 RoCEv2 发包逻辑。

## 为什么先定义共享格式

RDMA SmartNIC 横跨多层：

```text
user app -> libsmartnic -> kernel driver -> RTL hardware -> network
```

这些层必须对关键对象有一致理解。例如：

- 软件写入的 WQE，硬件必须能读懂。
- 硬件写出的 CQE，用户态库必须能解析。
- QP/CQ/MR/AH 上下文，控制面和数据面必须使用同一套字段。
- Doorbell 写入格式，用户态和 RTL 必须一致。
- CSR command 编号，驱动和 RTL mailbox 必须一致。

所以 1.5 阶段先定义格式，再进入真正逻辑实现。

## 基础参数

`smartnic_pkg.sv` 中定义了基础宽度和规模参数：

- `ADDR_W`：地址宽度，当前为 64 bit。
- `DMA_LEN_W`：DMA 长度字段宽度，当前为 32 bit。
- `QP_ID_W`：QP 编号宽度，当前为 24 bit，对应 RoCEv2 QPN。
- `CQ_ID_W`：CQ 编号宽度。
- `MR_ID_W`：MR handle 或表项编号宽度。
- `PD_ID_W`：Protection Domain 编号宽度。
- `AH_ID_W`：Address Handle 编号宽度。
- `KEY_W`：lkey/rkey 宽度，当前为 32 bit。
- `PSN_W`：RoCEv2 Packet Sequence Number 宽度，当前为 24 bit。
- `QUEUE_IDX_W`：队列 producer/consumer index 宽度。
- `WQE_BYTES`：硬件 WQE 大小，当前为 64 字节。
- `CQE_BYTES`：硬件 CQE 大小，当前为 64 字节。
- `MAX_SGE`：一个 Work Request 最多引用的 SGE 数。
- `PMTU_BYTES`：默认 PMTU 分段大小，当前为 4096 字节。

这些参数让后续模块可以统一使用同一套位宽，避免每个模块自己发明格式。

## 枚举类型

### RDMA opcode

`rdma_opcode_e` 描述 WQE 要执行什么操作。

常见值包括：

- `RDMA_OP_SEND`
- `RDMA_OP_SEND_WITH_IMM`
- `RDMA_OP_RDMA_WRITE`
- `RDMA_OP_RDMA_WRITE_WITH_IMM`
- `RDMA_OP_RDMA_READ`
- `RDMA_OP_BIND_MW`
- `RDMA_OP_SEND_WITH_INV`

在数据通路中：

```text
QP 读取 WQE -> 查看 opcode -> 决定走 Send、Write、Read 或其他路径
```

### QP type

`qp_type_e` 描述 QP 类型。

- `QP_TYPE_RC`：Reliable Connection。
- `QP_TYPE_UD`：Unreliable Datagram。
- `QP_TYPE_UC`：预留。

RC 和 UD 的传输语义不同，所以 QP context 里必须记录 QP 类型。

### QP state

`qp_state_e` 描述 QP 当前状态。

常见状态：

- `RESET`
- `INIT`
- `RTR`
- `RTS`
- `SQD`
- `SQE`
- `ERR`

数据面通常只允许 `RTS` 状态的 QP 发送数据。

### Completion status

`cmpl_status_e` 描述 CQE 中的完成状态。

例如：

- `CMPL_SUCCESS`：成功。
- `CMPL_LOC_PROT_ERR`：本地保护错误。
- `CMPL_REM_ACCESS_ERR`：远端访问错误。
- `CMPL_RETRY_EXC_ERR`：重试次数耗尽。
- `CMPL_DMA_ERR`：DMA 错误。

当 DMA、QP 或 RoCEv2 处理失败时，最终会通过 CQE status 告诉应用。

### CSR command

`csr_cmd_e` 描述驱动通过 CSR mailbox 下发的控制命令。

例如：

- `CSR_CMD_CREATE_QP`
- `CSR_CMD_MODIFY_QP`
- `CSR_CMD_CREATE_CQ`
- `CSR_CMD_REG_MR`
- `CSR_CMD_CREATE_AH`
- `CSR_CMD_CONFIG_MSIX`
- `CSR_CMD_CONFIG_VF`

这些命令属于控制面，不是 fast path 数据面。

### Doorbell type

`doorbell_type_e` 描述 Doorbell 类型。

- `DB_TYPE_SQ`：通知 Send Queue 有新 WQE。
- `DB_TYPE_RQ`：通知 Receive Queue 有新 WQE。
- `DB_TYPE_CQ_ARM`：通知硬件 arm CQ。

## packed struct

### `wqe_t`

WQE 是 Work Queue Entry，也就是软件交给硬件的任务单。

主要字段：

- `opcode`：操作类型，例如 RDMA Write。
- `flags`：是否 signaled、是否 solicited 等标志。
- `sge_count`：SGE 数量。
- `wr_id`：应用传入的工作请求 ID，完成时会返回。
- `local_va`：本地虚拟地址。
- `lkey`：本地 MR key。
- `length`：传输长度。
- `remote_va`：远端虚拟地址。
- `rkey`：远端 MR key。
- `imm_data`：immediate data。
- `inv_rkey`：需要失效的 key。

在 RDMA Write 中：

```text
libsmartnic 构造 wqe_t
  -> 写入 QP SQ
  -> Doorbell 通知硬件
  -> QP 读取 wqe_t
  -> DMA 读取 local_va/lkey 对应的数据
  -> RoCEv2 使用 remote_va/rkey 封包
```

### `cqe_t`

CQE 是 Completion Queue Entry，也就是硬件写回给软件的完成结果。

主要字段：

- `wr_id`：从 WQE 复制回来，帮助应用匹配请求。
- `qpn`：产生完成的本地 QP。
- `opcode`：对应的操作类型。
- `status`：完成状态。
- `byte_len`：完成字节数。
- `imm_data`：immediate data。
- `has_imm`：immediate data 是否有效。
- `solicited`：是否为 solicited completion。
- `vendor_error`：设备私有错误信息。
- `owner_function`：拥有该 CQE 的 PF/VF function。
- `cqn`：目标 Completion Queue。
- `syndrome`：硬件内部错误归因。
- `flags`：immediate、solicited、error、flush、recv/send 等标志。
- `timestamp`：设备时间戳。
- `valid / owner_bit`：CQE 有效位和 ring owner bit。
- `reserved`：保留位，保证总大小为 64 字节。

在数据通路中：

```text
DMA/QP/RoCEv2 处理完成
  -> completion engine 生成 cqe_t
  -> CQ manager 写入 CQ
  -> libsmartnic poll CQ
  -> user app 看到完成事件
```

### `qp_context_t`

QP context 保存一个 QP 的状态。

它包括：

- QP 是否有效
- owner PF/VF
- QPN
- QP type
- QP state
- PD
- send CQ 和 receive CQ
- SQ/RQ base address
- SQ/RQ depth
- SQ/RQ producer/consumer index
- remote QPN
- send/receive PSN
- retry 状态
- P_Key、Q_Key、AH

在数据通路中：

```text
Doorbell -> 找到 qp_context_t -> 判断 state/type/queue index -> 处理 WQE
```

### `cq_context_t`

CQ context 保存一个 CQ 的状态。

它包括：

- valid bit
- CQN
- CQ buffer 地址
- CQ depth
- producer/consumer index
- owner function
- MSI-X vector
- interrupt moderation 参数和运行时计数
- arm 状态
- overflow 状态
- error 状态和错误码

它用于决定 CQE 写到哪里，以及是否触发中断。

### `mr_entry_t`

MR entry 描述一段允许网卡访问的内存。

它包括：

- MR 是否有效
- owner PF/VF
- MR handle
- PD
- lkey/rkey
- virtual address base
- physical/DMA address base
- length
- page size
- access flags
- in-flight DMA refcount

DMA 或远端访问必须先经过 MR 检查：

```text
address + key + PD + permission
  -> mr_entry_t lookup/check
  -> pass: 返回物理地址
  -> fail: 产生错误 completion
```

### `ah_entry_t`

AH 是 Address Handle，主要用于 UD。

它包括：

- 目标 MAC
- 目标 IPv4
- UDP source/destination port
- P_Key
- Q_Key
- traffic class
- hop limit
- service level
- destination GID high/low
- source GID index
- flow label

UD 没有 RC 那种连接状态，所以发送时需要 AH 提供目的地址信息。

### `doorbell_t`

Doorbell 是用户态通知硬件的快速入口。

它包括：

- Doorbell 类型
- PF/VF function ID
- QPN
- CQN
- producer index
- consumer index
- solicited_only

它本身不携带完整 WQE，只告诉硬件队列有更新。

### `csr_cmd_hdr_t`

CSR command header 是驱动和硬件 mailbox 的命令头。

它包括：

- command ID
- function ID
- sequence number
- argument length
- status

它用于控制面命令，例如创建 QP、注册 MR、创建 CQ。

## 和 spec.md 的对应关系

这些共享格式直接支撑以下 Requirement：

- **RDMA Operations**：`wqe_t`、`rdma_opcode_e` 描述 Send/Write/Read/Recv 请求。
- **Scatter-Gather DMA Engine**：`wqe_t`、`mr_entry_t`、基础宽度参数支撑 DMA 地址和长度处理。
- **QP Lifecycle Management**：`qp_context_t`、`qp_state_e`、`qp_type_e` 描述 QP 状态和上下文。
- **CQ Lifecycle and Completion Queue**：`cq_context_t`、`cqe_t`、`cmpl_status_e` 描述 CQ 和完成结果。
- **MR Lifecycle and Memory Protection**：`mr_entry_t` 和 access flags 描述 MR 权限、key、PD 和地址范围。
- **Doorbell Interface**：`doorbell_t`、`doorbell_type_e` 描述 SQ/RQ/CQ arm Doorbell。
- **RoCEv2 Transport**：`rdma_opcode_e`、`qp_context_t`、`ah_entry_t` 提供 opcode、QPN、PSN、P_Key/Q_Key、AH 等字段基础。
- **Linux Kernel Driver Interface**：`csr_cmd_e`、`csr_cmd_hdr_t` 提供 CSR mailbox 命令编号和命令头。
- **Userspace Verbs API**：`wqe_t` 和 `cqe_t` 是用户态库与硬件队列之间的核心数据格式。
- **Cocotb Verilator Verification**：所有 packed struct 和 enum 都可被测试平台复用为参考格式。
