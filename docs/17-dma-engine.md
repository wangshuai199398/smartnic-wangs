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

这样设计的原因是当前阶段更适合学习和验证：固定优先级容易观察，也容易写单元测试。7.8 在 dispatcher 后续增加了独立 `dma_arbiter`，用于可配置公平仲裁，避免低优先级 QP 长时间得不到服务。

如果目标输出 `ready=0`，dispatcher 会保持当前 descriptor，并持续拉高对应输出 `valid`，直到下游 ready。输入侧 ready 只在 descriptor 被接收时拉高，避免请求丢失。

## 当前边界

7.1 只完成 descriptor 和 dispatcher 框架：

- 7.2 会实现 WQE/SGE fetch；
- 7.3 会实现 SGE traversal 和长度统计；
- 7.4 会把 MR key direction、access permission、PD check 和 VA->PA translation 接入每个 DMA segment；
- 7.5 和 7.6 会实现真实 host memory read/write；
- 7.7 会实现 PMTU 和 4KB page boundary split；
- 7.8 已新增独立 DMA arbiter，用于 fixed priority、round-robin、weighted round-robin 和 starvation guard；
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

## MR Lookup 和 Permission Integration

7.4 阶段新增 `rtl/dma/dma_mr_integration.sv`。它接收 7.3 输出的 VA segment，并把每个 segment 送入 MR 保护检查管线：

```text
dma_segment
  -> mr_key_checker
  -> mr_access_checker
  -> mr_pd_checker
  -> VA to PA
  -> MR/MW refcount +1
  -> protected_segment
```

这样设计的核心目的，是让后续 host read/write DMA path 只看到已经验证过的物理地址和权限，不再重复处理 lkey/rkey、PD、bounds、Memory Window 状态等安全细节。

### Key Direction Check

`dma_mr_integration` 根据 `dma_segment_is_remote` 选择 key：

- `dma_segment_is_remote=0`：使用 `dma_segment_lkey`，进入本地 DMA path；
- `dma_segment_is_remote=1`：使用 `dma_segment_rkey`，进入远端 RDMA path；
- 不允许 lkey/rkey fallback。

典型 operation 映射如下：

| 场景 | MR operation | key |
| --- | --- | --- |
| Send payload host read | `MR_OP_LOCAL_DMA_READ` | lkey |
| RDMA Write payload host read | `MR_OP_LOCAL_DMA_READ` | lkey |
| Recv buffer host write | `MR_OP_LOCAL_RECV_WRITE` | lkey |
| RDMA Read response host write | `MR_OP_LOCAL_DMA_WRITE` | lkey |
| inbound RDMA Write | `MR_OP_REMOTE_RDMA_WRITE` | rkey |
| inbound RDMA Read | `MR_OP_REMOTE_RDMA_READ` | rkey |
| inbound Atomic | `MR_OP_REMOTE_ATOMIC` | rkey |
| Memory Window bind | `MR_OP_MW_BIND` | lkey/control key |

方向错误会直接进入 DMA/MR error path，并携带 `desc_id`、`qpn`、`segment_index` 和错误码。

### Access 和 PD Check

key lookup 成功后，segment 会继续通过：

- `mr_access_checker`：检查 `access_flags` 是否允许该 operation；
- `mr_pd_checker`：检查 QP PD 与 MR/MW PD 是否一致；
- bounds/VA->PA：复用 MR table / access checker 的范围检查结果。

如果 lookup 到 Memory Window entry，后续检查只使用 MW entry 自己的 range、`access_flags`、`pd_id` 和 `physical_base_addr`。它不会回退到 parent MR 权限，因为 MW 的意义就是缩小父 MR 的可访问窗口和权限。

### Protected Segment

通过全部检查后，模块输出 protected segment：

- 原始 `va`
- 转换后的 `pa`
- `len`
- 实际使用的 key
- `access_flags`
- `byte_offset`
- `is_last`
- `mr_refcount_token`

`mr_refcount_token` 保存 key、key 方向、owner function 和 MR/MW handle。后续真实 DMA 完成时，7.5/7.6 的完成路径可以用这个 token 对同一个 MR/MW 做 `ref_dec`。

### Refcount

每个 segment 通过 key/access/PD/bounds 检查后，都会发起 MR/MW `refcount +1`。这保证 MR deregistration 或 MW unbind 不会在 DMA 使用期间直接释放表项。

当前阶段只实现 refcount increment 和 token 输出；真实 DMA 完成后的 refcount decrement 留给后续 host read/write 完成路径。若 refcount 已满，模块返回 `REFCOUNT_OVERFLOW`，并阻止该 segment 进入 protected output。

### 当前边界

7.4 不实现：

- host memory read/write；
- PMTU / 4KB page boundary split；
- DMA arbitration；
- completion error propagation。

这些分别由 7.5、7.6、7.7、7.8 和 7.9 分阶段接上，其中 7.8 已提供独立仲裁框架。

## Host Memory Read Path

7.5 阶段新增 `rtl/dma/dma_host_read_path.sv`。它接收 7.4 输出的 `protected_segment`，为 Send 和 RDMA Write 的本地 payload 生成 host memory read 请求：

```text
protected_segment_pa -> PCIe/DMA read request -> read response -> transport payload stream
```

Send 和 RDMA Write 都需要读取本地 host buffer：

- Send：把本地 payload 读出后交给 transport，发送到对端 RQ；
- RDMA Write：把本地 payload 读出后交给 RoCEv2 packetizer，写入对端 remote VA/rkey 指定的内存。

Recv、RDMA Read response delivery 和 CQE write 不走这个模块，它们属于 host write path 或 CQE write path。

### Read Request

`dma_host_read_path` 只接受 `MR_OP_LOCAL_DMA_READ`，即已经过 MR 检查的本地读 segment。输入字段包括：

- `protected_segment_pa`
- `protected_segment_len`
- `protected_segment_byte_offset`
- `protected_segment_index`
- `protected_segment_is_last`
- `protected_segment_mr_refcount_token`

模块生成：

- `pcie_read_req_addr = protected_segment_pa + bytes_completed`
- `pcie_read_req_len = min(remaining_len, DMA_MAX_READ_BYTES)`
- `pcie_read_req_tag = {desc_id, segment_index, chunk_index}`

当前 `DMA_MAX_READ_BYTES` 等于内部 payload 数据总线的一拍字节数。若 segment 长度更大，7.5 会拆成多个固定大小 read chunk。这个拆分只解决“单次 read 不能太大”的问题，不处理 PMTU 和 4KB page boundary；后两者留给 7.7。

### Payload Stream

每个 read response 直接变成一拍 transport payload stream：

- `payload_data = pcie_read_resp_data`
- `payload_len = pcie_read_resp_len`
- `payload_byte_offset = protected_segment_byte_offset + bytes_completed`
- `payload_segment_index = protected_segment_index`
- `payload_segment_last = 当前 chunk 是否为该 segment 最后一拍`
- `payload_wqe_last = payload_segment_last && protected_segment_is_last`

如果 `payload_ready=0`，模块保持当前 payload，不丢 response。

### Refcount Release

7.4 对 MR/MW 做了 refcount +1。7.5 在以下情况下输出 `mr_ref_dec_valid`：

- segment 所有 read chunk 都成功转成 payload；
- read response 报错；
- response tag mismatch；
- response length mismatch；
- validation 阶段发现 unsupported operation 或 zero length。

这样做的原因是：只要 host read path 接收了 protected segment，就必须负责释放它携带的 MR/MW refcount token。真实 ref_dec 对接 `mr_table` 的响应和错误处理，后续可继续接入 7.9 的 completion error propagation。

### Error Path

当前错误路径输出 `host_read_error_*`，覆盖：

- unsupported operation；
- zero segment length；
- PA 为 0 或地址加法 overflow；
- read request backpressure timeout；
- PCIe read response error；
- response tag mismatch；
- response length mismatch；
- payload output 长时间 backpressure。

这些错误当前只停在 DMA host read path 输出边界，后续 7.9 会把它们映射为 work completion error status。

## Host Memory Write Path

7.6 阶段新增 `rtl/dma/dma_host_write_path.sv`。它是 7.5 host read path 的镜像路径：host read path 把本地 Send/RDMA Write payload 从主机内存读出来交给 transport；host write path 则把 RQ 或 transport 侧已经收到的 payload 写回主机内存。

当前只处理需要 host memory write 的两类路径：

- Recv buffer write：入站 Send payload 写入 RQ Recv WQE 指定的用户缓冲区；
- RDMA Read response delivery：远端返回的数据写入本地 RDMA Read WQE 指定的用户缓冲区。

CQE write 不走这个模块。CQE 固定 64 字节写入已经由 5.3 的 `cqe_write_path` 负责。

### Write Request

`dma_host_write_path` 接收 7.4 输出的 protected segment。这个 segment 已经完成 key direction、access_flags、PD、bounds 和 VA->PA 转换，因此写路径只需要把 payload offset 映射到物理地址：

```text
write_addr = protected_segment_pa + (payload_byte_offset - protected_segment_byte_offset)
```

模块生成：

- `pcie_write_req_addr`：本次 payload 写入的物理地址；
- `pcie_write_req_data`：来自 RQ/transport 的 payload 数据；
- `pcie_write_req_len`：本次写入字节数；
- `pcie_write_req_byte_enable`：根据地址低位和长度生成的字节使能；
- `pcie_write_req_tag = {desc_id, segment_index, beat_index}`。

当前阶段要求一拍 payload 落在当前 protected segment 内。如果 payload 超出 segment 边界，模块返回 bounds error。跨 segment 拼接、PMTU 切分和 4KB 物理页边界切分留给 7.7。

### Write Completion

PCIe/DMA write completion 返回后，模块检查 completion tag 和 status：

- tag 匹配且 status 成功时，输出 `write_done_valid`；
- tag mismatch 返回 `DMA_HW_ERR_TAG_MISMATCH`；
- completion error 或非 0 status 返回 `DMA_HW_ERR_CPL_ERROR`。

`write_done_*` 保存 desc_id、QPN、owner function、operation、累计写入字节数、segment index 和 last 标志。后续 7.9 会把这些成功/失败信息继续映射到 completion status。

### Refcount Release

7.4 对每个通过 MR/MW 检查的 segment 做了 refcount +1。7.6 在以下情况输出 `mr_ref_dec_valid`：

- 当前 segment 的 payload 写入完成；
- validation 阶段发现 unsupported operation、zero segment length、zero payload length、payload mismatch、bounds 或 address overflow；
- PCIe write completion 返回错误；
- completion tag mismatch。

这样设计的原因是：一旦 host write path 接收了 protected segment，它就成为释放该 MR/MW refcount token 的责任边界。即使后续写失败，也必须释放 refcount，否则 MR deregistration 可能一直等待 drain。

### Error Path

当前错误路径输出 `host_write_error_*`，覆盖：

- unsupported operation；
- zero protected segment length；
- zero payload length；
- payload desc_id/QPN/owner/operation mismatch；
- payload 超出 protected segment；
- 地址加法 overflow；
- write request backpressure timeout；
- PCIe write completion error；
- completion tag mismatch；
- payload input error。

这些错误当前只停在 DMA host write path 输出边界，不直接生成 CQE。后续 7.9 会把它们传播到 work completion status。

## PMTU 和 4KB Boundary Split

7.7 阶段新增 `rtl/dma/dma_segment_splitter.sv`。它位于 MR 保护检查之后、host read/write path 之前：

```text
dma_mr_integration
  -> dma_segment_splitter
  -> dma_host_read_path / dma_host_write_path
```

这样放置的原因是：splitter 输入已经是 protected segment，说明 lkey/rkey、access_flags、PD、bounds 和 VA->PA 都通过了检查。splitter 不再重复做安全校验，只负责把一个大的、合法的物理连续 segment 切成更适合 DMA request 和 RoCEv2 payload 的小段。

### Split 规则

每次输出的 `split_segment_len` 由以下约束共同决定：

```text
split_len = min(
  remaining_len,
  enable_pmtu_split ? pmtu_bytes : remaining_len,
  enable_4kb_boundary_split ? page_remaining : remaining_len,
  max_dma_segment_bytes == 0 ? 4096 : max_dma_segment_bytes
)
```

其中 4KB 页内剩余空间为：

```text
page_remaining = 4096 - current_pa[11:0]
```

如果 `current_pa` 已经 4KB 对齐，则 `current_pa[11:0] == 0`，`page_remaining = 4096`。

当前支持的合法 PMTU 配置为 256、512、1024、2048 和 4096 字节。`enable_pmtu_split=1` 且 `pmtu_bytes` 不在这些值中时，模块返回 `DMA_SPLIT_ERR_PMTU_CONFIG`。`max_dma_segment_bytes=0` 使用默认 4096 字节限制。

### 输出字段

每个 split segment 都会透传：

- `desc_id`
- `qpn`
- `owner_function`
- `pd_id`
- `operation`
- `segment_index`
- `mr_refcount_token`
- `flags`

同时新增：

- `split_segment_sub_index`：从 0 开始递增；
- `split_segment_va` / `split_segment_pa`：原 VA/PA 加上已经输出的字节数；
- `split_segment_byte_offset`：原 byte offset 加上已经输出的字节数；
- `split_segment_is_segment_last`：当前 protected segment 的最后一个 split 才为 1；
- `split_segment_is_wqe_last`：只有输入 `protected_segment_is_last=1` 且当前 split 是最后一个 split 时才为 1。

### Refcount Token

一个 protected segment 被拆成多个 split segment 时，所有 split segment 都携带同一个 `mr_refcount_token`。splitter 不释放 refcount，也不增加新的 refcount。

后续接线时需要注意：如果 7.5/7.6 直接消费 split segment，那么 refcount release 语义应以“原 protected segment 的所有 split 都完成”为准。当前阶段只定义和测试 split 输出，不实现跨 split 的 refcount 聚合释放；真实完成路径和错误传播会在后续 DMA 集成与 7.9 中继续收敛。

### Backpressure

`split_segment_ready=0` 时，splitter 保持当前 split segment，不丢数据。只有当前 protected segment 的所有 split 都输出完成后，`protected_segment_ready` 才会重新允许接收下一段。

这让下游 host read/write path 可以用普通 ready/valid 节奏消费 split segment，而上游 MR integration 不需要关心 PMTU 或页边界细节。

### Error Path

当前 splitter 覆盖以下错误：

- `protected_segment_len=0`；
- PMTU 配置非法；
- PA + length overflow；
- VA + length overflow；
- 计算出的 `split_len=0`；
- split sub_index overflow；
- output backpressure timeout 预留。

这些错误输出在 `split_segment_error_code` 上。当前阶段不把错误映射到 CQE；后续 7.9 会统一处理 DMA error propagation。

## DMA Arbitration

7.8 阶段新增 `rtl/dma/dma_arbiter.sv`。它把多个 DMA source 的请求收敛成一个 grant，用来在多个 active QP 和不同 DMA 子路径之间做可配置调度。

当前建模 7 个 source：

| Source | 典型来源 | 方向 |
| --- | --- | --- |
| `DMA_SRC_SQ_HOST_READ` | SQ Send host read | host read |
| `DMA_SRC_RQ_HOST_WRITE` | RQ Recv buffer write | host write |
| `DMA_SRC_RDMA_WRITE_HOST_READ` | RDMA Write payload read | host read |
| `DMA_SRC_RDMA_READ_RESP_WRITE` | RDMA Read response delivery | host write |
| `DMA_SRC_CQE_WRITE` | CQE write path | CQE write |
| `DMA_SRC_WQE_FETCH` | SQ/RQ WQE fetch | WQE fetch |
| `DMA_SRC_SGE_FETCH` | extended SGE list fetch | SGE fetch |

每个 source 使用 ready/valid 输入，并携带：

- `source_id`
- `qpn`
- `owner_function`
- `desc_id`
- `operation`
- `direction`
- `len`
- `priority`
- `weight`
- `payload`

grant 输出保留 `source_id`、`qpn` 和 `desc_id`，这是后续 7.9 DMA error propagation 的关键：任何 host read/write/fetch 错误都可以回溯到原始 source、QP 和 descriptor。

### Fixed Priority

固定优先级策略适合先保证关键路径低延迟。当前顺序是：

```text
CQE write
  > RQ host write / RDMA Read response host write
  > SQ host read / RDMA Write host read
  > WQE fetch / SGE fetch
```

这样设计是因为 CQE write 和入站写回通常直接影响 completion 可见性和接收路径推进；fetch 路径可以稍后再优化。

### Round-Robin

Round-robin 从 `last_grant_source` 的下一个 source 开始扫描，选择第一个 valid source。grant 被 `grant_ready` 接受后更新 `last_grant_source`。无 valid 的 source 会被跳过。

这个策略适合多个 QP/source 同时活跃时避免固定优先级长期偏向高优先级 source。

### Weighted Round-Robin

Weighted round-robin 为每个 source 使用 `weight`：

- `weight=0` 表示该 source disabled；
- 当前 source 最多连续服务 `weight` 次；
- `wrr_service_count` 记录当前 source 已连续服务次数；
- 达到 weight 后轮转到下一个 valid 且 weight 非 0 的 source。

这为不同 DMA 类型提供粗粒度带宽配额。例如 CQE write 可以保持较高响应性，而大 payload read/write 可以按权重分享带宽。

### Strict Priority With Starvation Guard

Starvation guard 为每个 source 维护 `wait_counter`：

- source valid 但没有被 grant 时，counter 增加；
- source 被 grant 后，counter 清零；
- counter 超过 `starvation_threshold` 时，`starvation_detected[source]` 置位；
- strict guard policy 会优先选择 starvation source，然后再回到 fixed priority。

这样能保留 strict priority 的低延迟特性，同时避免低优先级 fetch 或 payload path 长期拿不到 DMA 服务。

### Backpressure

当 `grant_ready=0` 时，arbiter 保持当前 grant，不选择新的 source。只有 grant 被接受时，对应 source 的 `req_ready` 才拉高；未被选中的 source `req_ready` 保持 0。

这条规则让上游 source 可以用普通 ready/valid 语义保持请求，不需要知道当前仲裁策略。

### 当前边界

7.8 只实现仲裁和公平性状态：

- 不执行真实 host read/write/fetch；
- 不重新做 MR lookup 或 PMTU split；
- 不实现跨 QP 的完整 credit/accounting；
- 不把错误转换为 CQE。

后续 7.9 会利用 grant 中携带的 `desc_id`、`qpn`、`source_id` 和 `direction`，把 DMA path 错误映射到 completion status。

## DMA Error Propagation

7.9 阶段新增 `rtl/dma/dma_error_propagation.sv`。它是 DMA 子系统的错误汇聚点：前面的 dispatcher、fetcher、SGE traversal、MR integration、splitter、host read/write path 和 arbiter 都可以把错误送到这里，然后统一转换成 CQ completion 能理解的状态。

### Error Source

当前定义 9 类错误来源：

| Source | 典型错误 |
| --- | --- |
| `DMA_ERR_SRC_DISPATCHER` | unsupported opcode、descriptor malformed |
| `DMA_ERR_SRC_WQE_FETCH` | WQE host read/decode 失败 |
| `DMA_ERR_SRC_SGE_FETCH` | extended SGE fetch 失败 |
| `DMA_ERR_SRC_SGE_TRAVERSAL` | SGE total length、overlap、index 错误 |
| `DMA_ERR_SRC_MR_INTEGRATION` | lkey/rkey、access_flags、PD、bounds、refcount 错误 |
| `DMA_ERR_SRC_SEGMENT_SPLIT` | PMTU/4KB split 配置或地址溢出错误 |
| `DMA_ERR_SRC_HOST_READ` | PCIe read response 或 payload 输出错误 |
| `DMA_ERR_SRC_HOST_WRITE` | PCIe write completion 或 payload 匹配错误 |
| `DMA_ERR_SRC_ARBITER` | arbitration/descriptor metadata malformed |

每条 error event 携带 `desc_id`、`qpn`、`cqn`、`owner_function`、`pd_id`、`operation`、`direction`、`segment_index`、`byte_offset`、`dma_error_code`、`fatal` 和 `retryable`。这些字段让后续 completion path 能定位是哪一个 WR、哪个 QP、哪一段 DMA 失败。

### Completion Status Mapping

`dma_error_propagation` 不直接写 CQE，而是输出 `completion_error_valid` 事件，交给 `completion_engine` 格式化 64-byte CQE。

| DMA error | Completion status | 说明 |
| --- | --- | --- |
| `DMA_ERR_MR_LOOKUP_MISS` | `CMPL_LOC_PROT_ERR` | MR/MW lookup miss 是本地保护错误。 |
| `DMA_ERR_KEY_DIRECTION` | `CMPL_LOC_PROT_ERR` 或 `CMPL_REM_ACCESS_ERR` | 本地路径映射本地保护错误；远端 operation 预留为 remote access error。 |
| `DMA_ERR_ACCESS_DENIED` | `CMPL_LOC_PROT_ERR` 或 `CMPL_REM_ACCESS_ERR` | access_flags/owner 拒绝访问。 |
| `DMA_ERR_PD_MISMATCH` | `CMPL_LOC_PROT_ERR` | QP PD 和 MR PD 不一致。 |
| `DMA_ERR_BOUNDS` | `CMPL_LOC_LEN_ERR` | VA/PA/length 越界。 |
| `DMA_ERR_SGE_LENGTH` | `CMPL_LOC_LEN_ERR` | SGE total length underrun/overrun。 |
| `DMA_ERR_SGE_OVERLAP` | `CMPL_LOC_PROT_ERR` | SGE 地址重叠会破坏 buffer 语义。 |
| `DMA_ERR_WQE_FETCH` | `CMPL_LOC_QP_OP_ERR` | WQE fetch/decode 失败，按 WR 错误处理。 |
| `DMA_ERR_SGE_FETCH` | `CMPL_LOC_QP_OP_ERR` | extended SGE list fetch 失败。 |
| `DMA_ERR_UNSUPPORTED_OPCODE` | `CMPL_LOC_QP_OP_ERR` | WQE/descriptor opcode 不支持。 |
| `DMA_ERR_PCIE_READ` | `CMPL_DMA_ERR` | host read path 的 PCIe/DMA 错误。 |
| `DMA_ERR_PCIE_WRITE` | `CMPL_DMA_ERR` | host write path 的 PCIe/DMA 错误。 |
| `DMA_ERR_CQ_OVERFLOW` | `CMPL_CQ_OVERFLOW_ERR` | CQ full/overflow。 |
| `DMA_ERR_ARB_MALFORMED` | `CMPL_LOC_QP_OP_ERR` | 仲裁输入 metadata 非法。 |
| `DMA_ERR_TIMEOUT` | `CMPL_GENERAL_ERR` | 当前阶段未实现 retry engine，先归入通用错误。 |

`completion_vendor_error` 会保留 source ID 和原始 DMA error code，便于仿真波形和驱动 debug。

### Fatal And Retryable

`fatal=0` 时，模块只生成错误 completion。这个路径适合单个 WR 失败但 QP 仍可继续工作的情况。

`fatal=1` 时，模块先生成错误 completion，再输出：

- `qp_error_req_valid`
- `qp_error_qpn`
- `qp_error_owner_function`
- `qp_error_code`
- `qp_error_desc_id`
- `qp_error_source_id`

这个请求交给 QP lifecycle/cleanup path 处理。这样设计的原因是 DMA error propagation 不拥有 QP context，也不应该直接修改 QP 状态；真正的 QP error transition、Doorbell blocking、pending work quiesce 和 flushed completion 仍由 4.6 的 cleanup manager 负责。

`retryable=1` 只输出 `retry_hint_*` 调试/预留信号。当前阶段不实现 retry engine，也不生成 RoCEv2 NAK 或 remote error packet；这些属于后续 transport 阶段。

### Arbitration And Backpressure

多个 error source 同时 valid 时，当前使用固定优先级：

```text
fatal error
  > MR/protection error
  > host read/write error
  > WQE/SGE fetch error
  > traversal/split error
  > arbiter/dispatcher error
```

当 `completion_error_ready=0` 时，模块保持当前 completion error event，不接收新的 source。fatal 错误还会在 completion 被接受后继续保持 `qp_error_req_valid`，直到 QP cleanup path ready。这个 ready/valid 规则保证错误不会因为下游 backpressure 而丢失。
