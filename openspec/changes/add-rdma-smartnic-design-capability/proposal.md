## Why

Modern data-center storage, AI/ML training, distributed databases, and HPC workloads need low-latency, high-throughput networking with CPU-bypass semantics. This change introduces a complete RDMA SmartNIC design capability so the project can specify, implement, prototype, and validate a high-performance RoCEv2 NIC from RTL through Linux driver and userspace Verbs integration.

## What Changes

- Define a prototype-verifiable RDMA SmartNIC chip architecture with PCIe Gen5 x16 host attachment and a 100GbE-class RoCEv2 packet path.
- Add hardware RTL module boundaries for PCIe endpoint, BAR/CSR register block, Doorbell capture, QP/CQ/MR managers, scatter-gather DMA engine, RoCEv2 parser/composer, RC/UD transport engines, completion engine, MSI-X, SR-IOV, PFC/ECN/DCQCN, and top-level integration.
- Specify RDMA operations for RDMA Read, RDMA Write, Send, and Recv with RC and UD QP types.
- Specify QP, CQ, MR, PD, AH, Completion Queue, and Doorbell lifecycle semantics across hardware, kernel driver, and userspace library layers.
- Define a Linux kernel driver control plane using PCIe probe/remove, character device ioctls, mmap Doorbell pages, resource allocation, MSI-X interrupt handling, SR-IOV management, and RDMA subsystem-facing interfaces.
- Define a libibverbs-compatible userspace Verbs API provider surface for device discovery, context management, PD/CQ/QP/MR/AH operations, work request posting, completion polling, and async events.
- Define Cocotb/Verilator simulation and verification strategy, including PCIe and Ethernet BFMs, host memory model, scoreboard, coverage, module-level tests, integration tests, and protocol compliance tests.
- Define compatibility validation targets for perftest, UCX, and libfabric workloads.

## Capabilities

### New Capabilities

- `rdma-smartnic`: Complete RDMA SmartNIC design capability covering hardware architecture, software interfaces, userspace Verbs API, verification, and compatibility validation.

### Modified Capabilities

None.

## Impact

- **OpenSpec**: Adds a new `rdma-smartnic` capability spec and implementation task plan.
- **RTL**: Future implementation will add SystemVerilog modules for PCIe, DMA, QP/CQ/MR, RoCEv2 transport, completion, interrupts, virtualization, congestion control, and top-level integration.
- **Linux driver**: Future implementation will add a kernel driver with character device control plane, mmap Doorbell support, resource lifecycle management, MSI-X, and SR-IOV support.
- **Userspace library**: Future implementation will add a libibverbs-compatible provider/library exposing standard Verbs APIs.
- **Verification**: Future implementation will add Cocotb/Verilator testbenches, BFMs, scoreboards, coverage, protocol tests, and compatibility tests for perftest, UCX, and libfabric.
