# CSR Control Fabric

本文记录 11.2 阶段新增的 BAR2 CSR 控制通路。目标是把 PCIe BAR/MMIO 访问稳定地路由到内部寄存器块，为后续驱动 ioctl、mailbox 命令和资源管理打基础。

## 数据流

```text
PCIe BAR2 MMIO
  -> csr_fabric
  -> csr_decode
  -> QP / CQ / MR / AH / MSI-X / SR-IOV / congestion CSR block
  -> one-cycle read response
```

`csr_decode.sv` 只做地址解码，`csr_fabric.sv` 负责 ready/valid 握手、单目标选择、读响应打一拍和错误状态返回。

## BAR2 子窗口

| Offset range | Target |
| --- | --- |
| `0x1000-0x1fff` | QP manager registers |
| `0x2000-0x2fff` | CQ manager registers |
| `0x3000-0x3fff` | MR/MW manager registers |
| `0x4000-0x4fff` | Address Handle table registers |
| `0x5000-0x5fff` | MSI-X control registers |
| `0x6000-0x6fff` | SR-IOV PF/VF registers |
| `0x7000-0x7fff` | Congestion control / DCQCN / PFC registers |

Mailbox 仍保留在 `0x0100-0x01ff`，由已有 `pcie_csr_mailbox.sv` 建模。11.2 没有改变 mailbox 命令协议。

## 标准寄存器块接口

每个目标块暴露同一组 CSR 信号：

```text
csr_wr_en
csr_rd_en
csr_addr
csr_wdata
csr_be
csr_func_id
csr_rdata
```

`csr_addr` 是目标窗口内的相对 offset，不是 BAR2 全局 offset。`csr_be` 原样转发，用于 32-bit CSR 的 byte-enable 写。

## 访问语义

- 只支持 32-bit 对齐访问。
- 未对齐访问返回 `PCIE_BAR_RSP_MISALIGNED`。
- 未命中任何子窗口返回 `PCIE_BAR_RSP_BAD_OFFSET`。
- 合法访问返回 `PCIE_BAR_RSP_OK`。
- 同一笔请求只会选择一个 slave。
- 读响应在请求接收后一拍返回。
- 复位后 top 内部最小 CSR register bank 读值为 0。

## Top-Level 连接

`smartnic_top.sv` 新增 `bar2_csr_*` 端口，代表从 PCIe BAR 解码器进入 BAR2 CSR fabric 的 MMIO 请求。当前阶段 top 内部使用最小寄存器桩连接到：

- `qp_csr_*`
- `cq_csr_*`
- `mr_csr_*`
- `ah_csr_*`
- `msix_csr_*`
- `sriov_csr_*`
- `congestion_csr_*`

这些寄存器桩只是为了验证 CSR fabric、byte enable 和 reset 行为。真正的 QP/CQ/MR/AH/MSI-X/SR-IOV/DCQCN 资源命令仍由后续任务接入现有 manager。

## TODO

- 将 `pcie_bar_decoder.sv` 的 BAR2 `csr_req_*` 直接接入 `smartnic_top` 的 `bar2_csr_*` 边界。
- 用真实 manager CSR 寄存器替换 top 内的最小 register bank。
- 将 SR-IOV function ownership 检查插入 CSR fabric 或目标寄存器块。
- 将 mailbox command path 和 CSR register fabric 的软件 ABI 文档合并到 12.x driver 文档。
