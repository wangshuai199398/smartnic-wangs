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

## SGE Traversal

7.3 阶段新增 `rtl/dma/dma_sge_traversal.sv`。它位于 WQE/SGE fetcher 之后、MR checker 之前，作用是把上游输出的 SGE stream 规范化成 `dma_segment_t`：

```text
dma_wqe_sge_fetcher -> dma_sge_traversal -> MR lookup/access/PD check -> DMA split/read/write
```

当前阶段只处理 SGE 元数据，不搬运 payload，也不访问 MR table。

### 输入 Stream

输入侧每个 SGE 至少携带：

- `desc_id`：关联原始 DMA descriptor；
- `qpn`、`owner_function`、`pd_id`：后续隔离和 MR 检查需要的上下文；
- `operation`：后续 MR access checker 使用的操作类型；
- `index`：SGE 在 WR 中的序号；
- `addr`、`length`、`lkey`、`flags`：SGE 本身的地址、长度、key 和 flags；
- `last`：标记该 SGE 是否是当前 WR 的最后一个 SGE；
- `expected_total_len`：WQE 或上游 descriptor 期望搬运的总字节数。

输出侧每个合法 SGE 会变成一个 normalized DMA segment，额外带上 `byte_offset` 和 `is_last`。

### Total-Length Accounting

Traversal 对每个 SGE 的 `length` 做累计：

```text
total_len += sge.length
```

当 `last=1` 到来时，`total_len` 必须等于 `expected_total_len`：

- 小于 `expected_total_len`：返回 `LENGTH_UNDERRUN`；
- 大于 `expected_total_len`：返回 `LENGTH_OVERRUN`；
- 累计发生 32-bit 溢出：返回 `TOTAL_OVERFLOW`。

当前实现选择拒绝 zero-length SGE，而不是跳过。原因是后续 MR lookup、PMTU split 和 DMA issue 都可以假设每个 segment 都代表真实字节范围，验证更直接。

### Byte Offset

`byte_offset` 表示当前 segment 在整个 WR payload 中的起始偏移：

```text
第 0 个 SGE: byte_offset = 0
第 N 个 SGE: byte_offset = 前面所有 SGE length 之和
```

后续 7.7 的 PMTU/4KB split 会使用这个偏移把多个物理 segment 重新映射回同一个 WR payload。

### Zero-Overlap Validation

Traversal 记录最多 256 个已经接受的 SGE 范围：

```text
[seen_base[i], seen_end[i])
```

新 SGE 范围为 `[addr, addr + length)`。两个范围不重叠的条件是：

```text
A_end <= B_base 或 B_end <= A_base
```

因此相邻范围合法，例如 `[0x1000, 0x2000)` 和 `[0x2000, 0x3000)` 不算重叠。只要新范围与任意已接受范围交叠，模块返回 `SGE_OVERLAP_ERROR`。

地址计算 `addr + length` 也会检查 overflow，避免 wrap 后绕过范围比较。

### SGE 数量和顺序

`MAX_SGE=256`，合法 index 范围是 `0..255`。Traversal 要求 index 从 0 开始单调递增：

- index 重复或跳号：返回 `INDEX_ORDER`；
- index 大于 255：返回 `INDEX_RANGE`；
- 已开始接收 SGE list 但长期没有 `last`：返回 `MISSING_LAST`。

这个顺序要求让 7.3 的硬件和测试都更容易观察。后续如果要支持乱序 SGE fetch，可以在 fetcher 或 traversal 前增加 reorder buffer。

### Inline Data 边界

inline data 是 payload 直接放在 WQE 中，不引用 host SGE，也不需要 lkey/rkey、MR lookup 或 overlap 检查。因此 inline data 不走普通 SGE traversal 路径。当前模块提供简单的 inline 长度校验语义：`inline_data_len` 必须等于 `expected_total_len`，payload 数据搬运留给后续 transport/DMA 数据路径。
