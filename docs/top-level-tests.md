# Top-Level Tests

本文记录 11.7 阶段新增的顶层测试。当前仓库尚未提供完整 `smartnic_top` RTL 仿真 testbench，因此 11.7 使用结构检查加轻量语义模型，确保 11.1 到 11.6 已接出的顶层路径不会在后续修改中被意外断开。

## 测试文件

```text
sim/cocotb/test_top_level_paths.py
```

该测试纳入 `make top-test` 和 `make cocotb`。

## 覆盖范围

| 场景 | 覆盖方式 |
| --- | --- |
| Reset | 检查 `rst_sync_1`、`rst_sync_2`、`core_rst_n` 以及主要 datapath instance 使用同步 reset。 |
| CSR command | 检查 BAR2 CSR fabric、CSR 子窗口寄存器和 byte-enable 写模型。 |
| Doorbell-to-CQE minimal loop | 检查 BAR0 Doorbell 到 SQ scheduler、QP PI update、RC send hook、completion engine 和 CQE write hook。 |
| RC Send | 检查 `rc_pipeline_top` 中 DMA read、SEND packet 和 SQ completion 顺序。 |
| RDMA Write | 检查 `rdma_write_read_engine` 中 DMA read、RETH WRITE packet 和 completion path。 |
| RDMA Read | 检查 READ request、single outstanding response hook、PSN mismatch error、DMA write 和 completion path。 |
| UD Send | 检查 `ud_datapath_top` 中 AH lookup、DETH/Q_Key、DMA read hook、packet builder 和 send completion。 |
| MSI-X completion interrupt | 检查 `cq_notification` 和 `pcie_msix` 的 MSI-X request contract，并用模型验证 CQ armed、solicited_only 和 vector mask 条件。 |

## 为什么是结构/模型测试

11.7 的任务目标是“添加顶层测试”，不是重新实现完整 BFM。真实 PCIe Root Complex、host memory model、Ethernet/RoCEv2 BFM、scoreboard 和 coverage 会在 14.x 阶段完成。因此本阶段测试重点是：

- top-level 端口和 instance 是否存在；
- 已完成路径的 mux 是否覆盖 RC、RDMA 和 UD；
- completion event 是否能进入 completion engine；
- CQ arm、CQ notification 和 MSI-X 模块之间的行为契约是否有模型覆盖；
- 当前 stub/TODO 是否被显式保留，而不是被误认为完整协议实现。

## 当前 Stub / TODO

- `smartnic_top` 尚未完整实例化 `cq_notification` 到 `pcie_msix` 的硬件闭环；11.7 测试用模型覆盖 MSI-X completion interrupt 条件。
- Doorbell-to-CQE 当前验证到 completion engine / CQE write hook，不验证真实 host CQ buffer 写回。
- RDMA Write/Read 和 UD path 仍使用测试 hook，不读取真实 SQ/RQ WQE。
- 完整端到端仿真需要 14.x 的 BFM、host memory model 和 scoreboard。
