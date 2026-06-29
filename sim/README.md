# `sim/` 目录

这个目录用于存放仿真、验证和兼容性测试相关内容。

当前已经包含 `sim/cocotb` 模块级测试入口和 reusable BFM。后续这里会继续扩展：

- Verilator 仿真配置
- Ethernet/RoCEv2 BFM
- 主机内存模型
- Scoreboard
- 模块级测试
- 端到端集成测试
- perftest、UCX、libfabric 兼容性测试入口

PCIe BFM 已在 `sim/cocotb/bfm/pcie_bfm.py` 中提供 host-side function identity、config-space、BAR、MMIO、completion 和 MSI-X helper。运行：

```sh
make -C sim/cocotb test-pcie-bfm
```

Ethernet/RoCEv2 BFM 已在 `sim/cocotb/bfm/roce_ethernet_bfm.py` 中提供 Ethernet/VLAN/FCS、IPv4/UDP checksum、RoCEv2 BTH/RETH/AETH/DETH/ImmDt、CNP、PFC pause/resume、packet injection/observation queue 和显式错误注入 helper。运行：

```sh
make -C sim/cocotb test-roce-ethernet-bfm
```

Host memory model 已在 `sim/cocotb/bfm/host_memory_model.py` 中提供 byte-addressable DMA-visible backing store、aligned DMA buffer allocation、DMA read/write visibility、byte enable、transaction history 和 data integrity helper。运行：

```sh
make -C sim/cocotb test-host-memory-model
```

RDMA scoreboard 已在 `sim/cocotb/bfm/rdma_scoreboard.py` 中提供 expected WR tracking、WR-to-CQE matching、payload comparison、PSN tracking、retry checks 和 error completion validation。运行：

```sh
make -C sim/cocotb test-rdma-scoreboard
```

RDMA functional coverage collector 已在 `sim/cocotb/bfm/rdma_coverage.py` 中提供 opcode、QP state、CQ status、MR permission、message size、SGE count、QP type 和 congestion event bins。运行：

```sh
make -C sim/cocotb test-rdma-coverage
```

14.6 模块级 smoke suite 已在 `sim/cocotb/test_module_level_stage14.py` 中提供，复用 PCIe/RoCE BFM、host memory model、scoreboard 和 coverage，快速覆盖 PCIe、Doorbell、QP、CQ、MR、DMA、packet、transport、congestion 和 top-level reset 的模块级 contract。运行：

```sh
make -C sim/cocotb test-module-level-stage14
make -C sim/cocotb module-level-tests
make module-test
```

14.7 RDMA/RoCE integration suite 已在 `sim/cocotb/test_rdma_integration_stage14.py` 中提供，复用 PCIe BFM、Ethernet/RoCEv2 BFM、host memory model、scoreboard 和 coverage，覆盖 Doorbell-to-CQE、RC Send、RDMA Write、RDMA Read、UD Send、MSI-X 和 SR-IOV isolation 的跨模块语义。运行：

```sh
make -C sim/cocotb test-rdma-integration-stage14
make -C sim/cocotb rdma-integration-tests
make integration-test
```

14.8 RoCEv2/RDMA protocol compliance suite 已在 `sim/cocotb/test_roce_protocol_compliance_stage14.py` 中提供，覆盖 header fields、ACK/NAK、RNR、immediate data、invalid packets 和 ICRC placeholder behavior。运行：

```sh
make -C sim/cocotb test-roce-protocol-compliance-stage14
make -C sim/cocotb protocol-compliance-tests
make protocol-test
```

14.9 regression runner 已在 `tests/run_rdma_regression.sh` 中提供。它复用现有 Makefile、BFM/unit、module、integration、protocol、compatibility 和 coverage targets，生成日志和 summary，不新增测试内容。常用命令：

```sh
tests/run_rdma_regression.sh --mode smoke
tests/run_rdma_regression.sh --mode full
tests/run_rdma_regression.sh --sim verilator module integration protocol
make regression
make coverage
```

默认日志写入 `build/rdma-regression/<timestamp>/`，包括 `summary.txt`、`coverage.txt` 和每个阶段的独立 log。缺少可选工具或 simulator 时，对应阶段会按现有 target 语义 skip 或在 summary 中报告。
