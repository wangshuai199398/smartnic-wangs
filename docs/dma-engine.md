# DMA Engine

7.1 阶段实现 `rtl/dma/dma_descriptor_dispatcher.sv`，目标是先定义统一的 DMA descriptor，并把来自 SQ、RQ、CQE write path 和 fetch path 的请求分发到后续子路径。当前阶段不实现真实 PCIe DMA read/write、不遍历 SGE、不做 MR permission check、不做 PMTU/4KB split，也不做公平仲裁。

## DMA Descriptor

统一 descriptor 类型是 `dma_desc_t`，定义在 `rtl/common/smartnic_pkg.sv`。关键字段包括：

| 字段 | 作用 |
| --- | --- |
| `desc_valid` / `desc_id` | 标记 descriptor 有效，并在错误/completion 路径中回传 ID |
| `dma_opcode` | 描述 Send、Recv、RDMA Write、RDMA Read response、CQE write、WQE fetch、SGE fetch 等操作 |
| `qpn` / `cqn` | 关联的 QP 或 CQ 编号 |
| `owner_function` / `pd_id` | SR-IOV function 和 Protection Domain 元数据，供后续隔离与 MR 检查使用 |
| `wr_id` | 原始 WR ID，后续 completion path 使用 |
| `local_key` / `remote_key` | 本地 lkey 和远端 rkey |
| `local_va` / `remote_va` / `physical_addr` | 本地/远端虚拟地址和已经翻译的物理地址；7.4 前 `physical_addr` 可为空 |
| `length` / `byte_len_remaining` | 当前请求长度和整个 WR 剩余长度 |
| `sge_count` / `sge_index` | SGE traversal 预留字段 |
| `inline_data_present` / `inline_data_len` | inline payload 预留字段 |
| `direction` | 目标路径：host read、host write、CQE write、WQE fetch 或 SGE fetch |
| `solicited` / `has_imm` / `imm_data` | completion 和 immediate data 元数据 |
| `completion_required` | 该 DMA 完成后是否需要生成 completion |
| `error_code` / `user_context` | 错误和上游不透明上下文 |

## 输入来源

dispatcher 使用 ready/valid 输入接收五类来源：

| 输入 | 来源 | 用途 |
| --- | --- | --- |
| `sq_dma_req_*` | SQ engine | Send、RDMA Write、RDMA Read request/response 相关 DMA 请求 |
| `rq_dma_req_*` | RQ engine | Recv buffer host write |
| `cqe_dma_req_*` | CQE write path | 64-byte CQE host memory write |
| `wqe_fetch_req_*` | 后续 WQE fetch path | SQ/RQ WQE fetch |
| `sge_fetch_req_*` | 后续 SGE fetch path | 扩展 SGE list fetch |

## 分发规则

| `dma_opcode` | 分发目标 |
| --- | --- |
| `DMA_OP_SEND` | `host_read_desc_*`，读取本地 Send payload |
| `DMA_OP_RDMA_WRITE` | `host_read_desc_*`，读取本地 RDMA Write payload |
| `DMA_OP_RECV` | `host_write_desc_*`，写入本地 Recv buffer |
| `DMA_OP_RDMA_READ_REQ` | 当前只保留 descriptor 语义，后续接 transport read-request path |
| `DMA_OP_RDMA_READ_RESP` | `host_write_desc_*`，把 read response payload 写入本地内存 |
| `DMA_OP_CQE_WRITE` | `cqe_write_desc_*`，写 64-byte CQE |
| `DMA_OP_WQE_FETCH` | `fetch_desc_*`，读取 WQE |
| `DMA_OP_SGE_FETCH` | `fetch_desc_*`，读取扩展 SGE list |
| unsupported opcode | `dma_error_*` |

## 仲裁和 Backpressure

多个输入同时有效时，7.1 采用固定优先级：

```text
CQE write > RQ write > SQ request > WQE fetch > SGE fetch
```

这样设计的原因是当前阶段更适合学习和验证：固定优先级容易观察，也容易写单元测试。后续 7.8 会把这里替换或扩展为可配置公平仲裁，避免低优先级 QP 长时间得不到服务。

如果目标输出 `ready=0`，dispatcher 会保持当前 descriptor，并持续拉高对应输出 `valid`，直到下游 ready。输入侧 ready 只在 descriptor 被接收时拉高，避免请求丢失。

## 当前边界

7.1 只完成 descriptor 和 dispatcher 框架：

- 7.2 会实现 WQE/SGE fetch；
- 7.3 会实现 SGE traversal 和长度统计；
- 7.4 会把 MR key direction、access permission、PD check 和 VA->PA translation 接入每个 DMA segment；
- 7.5 和 7.6 会实现真实 host memory read/write；
- 7.7 会实现 PMTU 和 4KB page boundary split；
- 7.8 会实现公平仲裁；
- 7.9 会把 DMA 错误传播到 completion status。

## WQE 和 SGE Fetch

7.2 阶段新增 `rtl/dma/dma_wqe_sge_fetcher.sv`。它负责把 SQ/RQ engine 给出的 queue base、queue index 和 stride 转成 host read 请求：

```text
wqe_addr = wqe_fetch_base_addr + wqe_fetch_index * wqe_fetch_stride
```

fetcher 会检查 stride 不能为 0，并检查地址加法 overflow。它通过 `host_read_req_*` 发出读请求，通过 `host_read_resp_*` 接收返回数据。本阶段这个接口只是 RTL 边界，不实现真实 PCIe read。

### WQE Decode

WQE response 会解码出：

- `opcode`
- `wr_id`
- `inline_present`
- `inline_len`
- `sge_count`
- inline SGE entries
- `extended_sge_list_addr`

`inline data` 和 `inline SGE` 是两个不同概念：

- **inline data**：payload 数据直接放在 WQE 中，适合很小的 Send；
- **inline SGE**：SGE descriptor 直接放在 WQE 中，描述 host buffer 的地址、长度和 lkey。

当前原型格式最多直接输出 2 个 inline SGE。若 `sge_count` 超过 inline SGE 数量，或者 WQE 使用 extended SGE list，则后续通过 `extended_sge_list_addr` 发起 SGE fetch。

### Extended SGE List

SGE fetch 使用：

```text
sge_addr = sge_fetch_list_base_addr + sge_index * sizeof(sge_t)
```

每个 `sge_t` 至少包含：

- `addr`
- `length`
- `lkey`
- `flags`

fetcher 逐项输出 `sge_entry_*`，最后输出 `sge_list_done`。`sge_fetch_count` 支持 1 到 256；0 会报错，超过 256 会报 unsupported/too many SGE。

7.2 仍然不做 SGE traversal 的总长度统计、不做 overlap 检查，也不做 MR lookup。它只把 WQE 里的 inline/extended SGE 列表交给后续 7.3。
