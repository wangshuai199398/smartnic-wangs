# PCIe BAR Decoder

本文档说明 `rtl/pcie/pcie_bar_decoder.sv` 的最小 BAR 解码框架。当前阶段对应 tasks.md 的 2.3，只做地址窗口识别和请求转发，不实现 Doorbell payload 解析、CSR mailbox 或 MSI-X table/PBA 内容。

## 系统位置

BAR decoder 位于 PCIe endpoint wrapper 的 inbound memory request 之后：

```text
Host Memory Read/Write TLP
        |
pcie_endpoint_wrapper
        |
pcie_bar_decoder
   +----+-----+------+
   |          |      |
 BAR0       BAR2   BAR4
 Doorbell   CSR    MSI-X
```

它的作用是把 Host 对不同 BAR 的访问分到不同内部模块。这样后续 Doorbell、CSR、MSI-X 可以各自实现自己的寄存器或 fast path 行为。

## BAR 地址布局

当前公共常量定义在 `rtl/common/smartnic_pkg.sv`。

| BAR | 窗口大小 | 目标模块 | 用途 |
| --- | --- | --- | --- |
| BAR0 | 256 MB | Doorbell path | QP SQ Doorbell、QP RQ Doorbell、CQ arm Doorbell |
| BAR2 | 64 KB | CSR/register block | 控制寄存器、mailbox、统计和配置 |
| BAR4 | 16 KB | MSI-X block | MSI-X table 和 pending-bit array |

## BAR0 Doorbell Aperture

BAR0 当前整段窗口都转发给 Doorbell path：

```text
BAR0 + function_base(func)
  + qpn * 0x1000
      + 0x000 SQ Doorbell
      + 0x008 RQ Doorbell
      + 0x010 CQ Arm Doorbell
```

2.3 阶段不解析 `SQ/RQ/CQ` 的具体 doorbell payload，只把 offset、write data、byte enable 和 function ID 转发出去。真正解析属于 3.x Doorbell path。

## BAR2 CSR Space

BAR2 当前整段 64 KB 窗口都转发给 CSR path。设计文档中建议的 CSR 分组如下：

| Offset Range | 用途 |
| --- | --- |
| `0x0000-0x00ff` | device control/status |
| `0x0100-0x01ff` | mailbox command |
| `0x0200-0x02ff` | interrupt control |
| `0x0300-0x03ff` | queue defaults |
| `0x0400-0x04ff` | SR-IOV control |
| `0x0500-0x05ff` | congestion control |
| `0x0600-0x06ff` | statistics |
| `0x0700-0x07ff` | debug and trace |

2.3 阶段不实现这些 CSR 寄存器，只把请求交给后续 2.4 的 CSR mailbox/register block。

## BAR4 MSI-X Table/PBA

BAR4 当前划分为两个占位窗口：

| Offset Range | 用途 |
| --- | --- |
| `0x0000-0x07ff` | MSI-X table |
| `0x0800-0x0fff` | MSI-X pending-bit array |

decoder 会输出 `msix_req_is_pba`，让后续 MSI-X block 区分访问 table 还是 PBA。2.3 阶段不会实现 vector mask、message address/data 存储或 MSI-X transaction 生成。

## 错误处理

当前 decoder 对以下情况返回错误状态：

- 非 BAR0/BAR2/BAR4：`PCIE_BAR_RSP_UNSUPPORTED`；
- offset 超出目标 BAR 窗口：`PCIE_BAR_RSP_BAD_OFFSET`；
- offset 非 dword 对齐：`PCIE_BAR_RSP_MISALIGNED`。

合法访问会转发到目标模块，并返回 `PCIE_BAR_RSP_OK`。读响应数据当前固定为 0，后续 CSR/MSI-X/Doorbell 模块接入后可以扩展为真实读返回路径。

## 后续连接关系

### 连接 2.4 CSR Mailbox

BAR2 输出的 `csr_req_*` 会接到 CSR/register block。2.4 会在这个入口后面实现 mailbox command、GO/DONE、status/error 和参数窗口。

### 连接 2.5 MSI-X Table

BAR4 输出的 `msix_req_*` 会接到 MSI-X block。2.5 会实现 MSI-X table、PBA、vector mask 和中断 transaction 生成。

### 连接 3.x Doorbell Path

BAR0 输出的 `doorbell_req_*` 会接到 Doorbell decoder。3.x 会把 offset 映射为 QP SQ、QP RQ 或 CQ arm 操作，并解析 producer/consumer index 等 payload。
