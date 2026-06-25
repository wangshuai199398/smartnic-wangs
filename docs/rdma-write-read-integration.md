# RDMA Write / Read Top-Level Integration

本文记录 11.5 阶段新增的 RDMA Write / RDMA Read 顶层连接。目标不是实现完整 RoCEv2 one-sided 协议，而是把已有 QP、DMA、packet、transport 和 completion 边界串成一条可验证的数据通路。

## 模块位置

新增模块：

```text
rtl/transport/rdma_write_read_engine.sv
```

它位于 transport 层和 top-level integration 层之间，接收来自 SQ/test hook 的 one-sided work request，并输出：

- `packet_build_req_t` 给 `roce_packet_builder`
- 简化 DMA read/write hook 给后续 DMA/MR path
- `completion_event_t` 给 `completion_engine`

## RDMA Write 路径

当前最小路径如下：

```text
rdma_wr_test_valid
  -> rdma_write_read_engine
  -> lkey/rkey/length 基础检查
  -> dma_read_valid
  -> packet_build_req_t(opcode=ROCE_OPCODE_RDMA_WRITE_ONLY, RETH remote_va/rkey/len)
  -> roce_packet_builder
  -> completion_event_t(opcode=RDMA_OP_RDMA_WRITE)
  -> completion_engine
```

这里的 DMA read 代表从本地 MR 读取 RDMA Write payload。11.5 只保留地址、lkey、长度和 desc_id metadata；真实 `dma_mr_integration`、`dma_host_read_path` 和 PCIe DMA 读完成将在后续 top-level 闭环中接入。

## RDMA Read 路径

当前最小路径如下：

```text
rdma_wr_test_valid(opcode=RDMA_OP_RDMA_READ)
  -> rdma_write_read_engine
  -> lkey/rkey/length 基础检查
  -> packet_build_req_t(opcode=ROCE_OPCODE_RDMA_READ_REQ, RETH remote_va/rkey/len)
  -> outstanding_read_valid
  -> rdma_read_resp_test_valid
  -> PSN/length/error 检查
  -> dma_write_valid
  -> completion_event_t(opcode=RDMA_OP_RDMA_READ)
  -> completion_engine
```

11.5 只支持每个 engine 一个 outstanding RDMA Read。`rdma_read_resp_test_*` 是测试注入入口，代表后续 RX parser + RC Read response sequencing 交付的 payload。真实多包 response、ACK/NAK、retry、PMTU segmentation 和 response reassembly 继续由 transport/DMA 后续集成补齐。

## Packet Builder 复用

`smartnic_top.sv` 的 packet builder 输入现在按固定优先级复用：

```text
CNP build request
  > RC Send/Recv build request
  > RDMA Write/Read build request
```

这样不会改变已有 CNP 和 11.4 RC Send/Recv 行为。RDMA Write 使用 `ROCE_OPCODE_RDMA_WRITE_ONLY`，RDMA Read request 使用 `ROCE_OPCODE_RDMA_READ_REQ`，并通过 `packet_build_req_t.remote_va`、`rkey`、`dma_length` 传递 RETH 字段。

## Completion 复用

`completion_engine` 的 event 输入从单一 RC pipeline 改为：

```text
RC completion
  > RDMA Write/Read completion
```

RDMA Write 在最小模型中以 packet builder 接受作为发送完成边界生成 SQ completion。RDMA Read 在 response PSN/length 检查通过并完成本地 DMA write hook 后生成 SQ completion。错误路径会输出 `CMPL_LOC_LEN_ERR`、`CMPL_LOC_PROT_ERR`、`CMPL_BAD_RESP_ERR` 或 `CMPL_DMA_ERR`。

## 当前 Stub / TODO

- TODO：接入真实 `qp_context_table`，按 QP type/state、remote_qpn、PSN 和 retry 参数驱动 one-sided operation。
- TODO：接入 `dma_mr_integration`，把当前 lkey/rkey 非零检查替换为 lkey/rkey 方向、access flags、PD 和 bounds 检查。
- TODO：接入 `dma_host_read_path` / `dma_host_write_path`，用真实 PCIe DMA read/write completion 驱动 packet 和 CQE。
- TODO：接入 RX parser / `rc_rdma_read_engine` response path，替换 `rdma_read_resp_test_*` 注入入口。
- TODO：支持多 outstanding RDMA Read、PMTU 多 response、ACK/NAK、retry 和 RNR。

## 验证

新增结构测试：

```text
sim/cocotb/test_rdma_write_read_engine_structure.py
```

该测试检查：

- `rdma_write_read_engine.sv` 存在；
- RDMA Write/Read opcode、RETH 字段、DMA hook 和 completion hook 存在；
- RDMA Read single outstanding 与 PSN mismatch 错误路径存在；
- `smartnic_top.sv` 已实例化该模块；
- packet builder mux 和 completion mux 已纳入 RDMA Write/Read path；
- `tasks.md` 已将 11.5 标记完成。
