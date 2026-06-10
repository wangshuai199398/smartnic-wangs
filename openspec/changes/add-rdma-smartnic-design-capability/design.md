## Context

This change defines a greenfield RDMA SmartNIC design capability. The target system is a prototype-verifiable high-performance NIC that attaches to the host through PCIe Gen5 x16, exposes RDMA Verbs semantics to software, and processes RoCEv2 traffic in hardware.

The system is split into four implementation layers:

1. **Hardware RTL**: PCIe endpoint, BAR/CSR register block, Doorbell capture, QP/CQ/MR managers, scatter-gather DMA, packet parser/builder, RoCEv2 transport, completion engine, MSI-X, SR-IOV, PFC/ECN/DCQCN, and top-level integration.
2. **Linux kernel driver**: PCIe probe/remove, CSR mailbox command submission, character device control plane, resource lifecycle, mmap Doorbell, DMA memory management, MSI-X interrupts, SR-IOV, and RDMA-facing operations.
3. **Userspace Verbs library**: libibverbs-compatible provider surface for device discovery, context management, PD/CQ/QP/MR/AH lifecycle, work request posting, CQ polling, notification, and async events.
4. **Verification and compatibility**: Cocotb/Verilator simulation, PCIe/Ethernet BFMs, host memory model, scoreboard, coverage, protocol compliance, perftest, UCX, and libfabric validation.

The first implementation target is FPGA prototype validation with vendor PCIe/MAC IP wrappers where required. The internal architecture must stay vendor-neutral so the same RTL partition can later be hardened for ASIC without changing the software-visible ABI.

## Goals / Non-Goals

**Goals:**

- Define a modular RDMA SmartNIC architecture that can be implemented and verified incrementally.
- Support PCIe Gen5 x16 host connectivity, BAR/CSR control, Doorbell submission, MSI-X interrupts, and SR-IOV virtualization.
- Support RoCEv2 over Ethernet with RC and UD QP types.
- Support RDMA Read, RDMA Write, Send, and Recv operations.
- Support QP, CQ, MR, PD, AH, Completion Queue, and Doorbell lifecycle management across hardware, driver, and userspace.
- Support scatter-gather DMA with MR translation, access permission checks, PMTU segmentation, and error completions.
- Provide a Linux kernel driver control plane with character device ioctls and mmap Doorbell pages.
- Provide a libibverbs-compatible userspace API suitable for perftest, UCX, and libfabric compatibility testing.
- Provide a Cocotb/Verilator verification plan with BFMs, scoreboards, coverage, protocol tests, and end-to-end tests.

**Non-Goals:**

- InfiniBand native link-layer support; v1 is RoCEv2 over Ethernet only.
- iWARP support.
- GPU Direct or peer-to-peer device memory in v1.
- Production Linux upstreaming in the first milestone; the initial driver can be out-of-tree while following upstream conventions.
- Multi-port NIC support in v1.
- Full ASIC physical design, timing closure, DFT, package design, or manufacturing signoff.

## Hardware Architecture

The hardware is organized as a layered datapath with a separate control plane. The main RTL top level is `smartnic_top`, which binds PCIe, control, RDMA state, DMA, packet processing, and MAC-facing interfaces.

```text
                            Host CPU / Memory
                                  |
                         PCIe Gen5 x16 Endpoint
                                  |
        +-------------------------+-------------------------+
        |                                                   |
  BAR/CSR/doorbell control                         DMA read/write TLPs
        |                                                   |
  +-----v------+     +----------+     +---------+     +------v------+
  | reg_block  |---->| qp_mgr   |---->| dma_eng |<--->| mr_mgr      |
  | csr_mailbox|     | cq_mgr   |     | sg dma  |     | translation |
  +-----+------+     +-----+----+     +----+----+     +-------------+
        |                  |               |
        |                  |               v
        |                  |       +---------------+
        |                  +------>| cmpl_engine   |----> CQE DMA writes
        |                          +---------------+
        |
        v
  +-------------+     +---------------+     +----------------+
  | doorbell    |---->| roce_engine   |---->| packet_builder |
  | decoder     |     | RC / UD       |     +-------+--------+
  +-------------+     +-------+-------+             |
                              ^                     v
                       +------+-------+      100GbE MAC/PHY wrapper
                       | packet_parser|
                       +--------------+
```

### RTL Module Partition

| Module | Responsibility | Key Inputs | Key Outputs |
| --- | --- | --- | --- |
| `pcie_ep` | PCIe Gen5 endpoint wrapper, config space, inbound/outbound TLP adaptation | PCIe hard IP streams, config reads/writes, DMA completions | BAR accesses, DMA requests, MSI-X TLPs, function identity |
| `bar_mapper` | Decode BAR0/BAR2/BAR4 addresses and offsets | Inbound Memory Read/Write TLPs | Doorbell writes, CSR accesses, MSI-X table accesses |
| `reg_block` | CSR register file and mailbox command dispatch | BAR2 CSR reads/writes, command parameters | QP/CQ/MR/AH commands, status, errors |
| `doorbell_decoder` | Decode mmap Doorbell writes | BAR0 writes with requester/function identity | SQ producer update, RQ producer update, CQ arm request |
| `sriov_guard` | Enforce PF/VF ownership and resource isolation | requester ID, function ID, QPN/CQN/MR handles, BAR offset | allow/deny, security/error counters |
| `qp_mgr` | QP context table, state machine, SQ/RQ engines | CSR commands, Doorbells, ingress packet metadata | WQE dispatch, Recv buffer descriptors, QP state updates |
| `cq_mgr` | CQ context table, producer/consumer state, arm and moderation | completion events, CQ arm writes, consumer updates | CQE write requests, MSI-X requests, overflow status |
| `mr_mgr` | MR/MW table, lkey/rkey lookup, permission and PD checks | MR commands, DMA lookup requests, remote access requests | PA translation, access grant/deny, MR refcount |
| `dma_engine` | Scatter-gather host memory read/write engine | WQE descriptors, SGE lists, MR translations | PCIe MemRd/MemWr requests, payload streams, DMA errors |
| `packet_parser` | Parse Ethernet/IPv4/UDP/BTH/extended RoCEv2 headers | RX MAC stream | opcode, QPN, PSN, RETH/AETH/DETH/ImmDt, payload stream |
| `packet_builder` | Build RoCEv2 packets and responses | TX descriptors, payload stream, ACK/NAK/CNP requests | TX MAC stream |
| `roce_engine` | RC/UD transport semantics | parsed packets, QP context, WQE dispatch | DMA commands, ACK/NAK/CNP, completions |
| `dcqcn_pfc` | ECN/CNP/DCQCN and PFC-aware scheduling | ECN marks, CNP packets, PFC pause state | rate updates, pacing tokens, TX backpressure |
| `cmpl_engine` | Normalize completion events and format CQEs | QP/DMA/transport results | 64-byte CQEs and CQ write requests |
| `top_integration` | Clock/reset, CDC, module wiring, wrappers | board-level PCIe/MAC clocks and resets | integrated SmartNIC datapath |

### Internal Interfaces

The RTL should use explicit ready/valid streaming interfaces rather than implicit shared state between blocks. The major internal interfaces are:

- **CSR command interface**: `cmd_valid`, `cmd_opcode`, `cmd_func`, `cmd_args`, `cmd_ready`, `rsp_valid`, `rsp_status`, `rsp_data`.
- **Doorbell interface**: `db_valid`, `db_type`, `db_func`, `db_qpn_or_cqn`, `db_producer_idx`, `db_consumer_idx`, `db_solicited_only`.
- **WQE dispatch interface**: `wqe_valid`, `qpn`, `opcode`, `wr_id`, `sge_count`, `remote_va`, `rkey`, `length`, `flags`.
- **MR lookup interface**: `lookup_valid`, `lookup_is_local`, `lookup_key`, `lookup_pd`, `lookup_va`, `lookup_len`, `lookup_perm`, `lookup_hit`, `lookup_pa`, `lookup_error`.
- **DMA command interface**: `dma_cmd_valid`, `op`, `qpn`, `wr_id`, `sge_list_ref`, `remote_meta`, `dma_done`, `dma_error`.
- **Packet metadata interface**: `pkt_meta_valid`, `opcode`, `qpn`, `psn`, `pkey`, `reth`, `aeth`, `deth`, `imm_data`, `payload_len`.
- **Completion interface**: `cmpl_valid`, `cqn`, `qpn`, `wr_id`, `opcode`, `status`, `byte_count`, `src_qpn`, `imm_data`.

## Data Path Design

### Send / RDMA Write TX Path

```text
userspace WQE write
  -> SQ Doorbell MMIO
  -> doorbell_decoder
  -> qp_mgr SQ engine
  -> DMA local SGE reads through mr_mgr
  -> roce_engine assigns PSN and transport metadata
  -> packet_builder emits RoCEv2 frames
  -> MAC TX
  -> cmpl_engine writes send completion when signaled and transport rules allow
```

For Send, the payload is read from local SGEs and delivered to the peer's RQ. For RDMA Write, the local payload is read through DMA and packetized with remote virtual address and rkey in RETH. RC QPs require PSN tracking and ACK/NAK handling; UD QPs use AH/DETH metadata and do not maintain RC sequencing state.

### Receive / Send RX Path

```text
MAC RX
  -> packet_parser
  -> roce_engine validates QP, opcode, P_Key/Q_Key, PSN
  -> qp_mgr RQ engine consumes Recv WQE
  -> dma_engine writes payload into local SGEs through mr_mgr
  -> cmpl_engine formats receive CQE
  -> cq_mgr writes CQE and optionally triggers MSI-X
```

Ingress packets must not consume RQ entries until the packet is recognized as valid for the target QP. Invalid packets are dropped before DMA side effects. RC sequence errors produce ACK/NAK behavior without delivering out-of-order payload to host memory.

### RDMA Read Path

RDMA Read has two asymmetric halves:

- **Requester side**: SQ engine dispatches RDMA Read, packet builder sends read request, response packets are matched by QP/PSN, DMA writes response payload into local SGEs, and completion is generated after all requested bytes arrive.
- **Responder side**: parser receives read request, mr_mgr validates remote rkey and access permissions, dma_engine reads local memory, packet_builder sends one or more read response packets.

The requester must track outstanding read requests per QP and match responses to the original WR. The responder must segment responses by PMTU and respect RC sequencing.

### CQE and Interrupt Path

Completion events from QP, DMA, and transport are normalized by `cmpl_engine`. `cq_mgr` writes 64-byte CQEs to host memory through DMA/PCIe MemWr and updates the CQ producer index. MSI-X is generated when:

- CQ is armed and the completion satisfies the arm condition.
- interrupt moderation count reaches the configured threshold.
- moderation timer expires.
- asynchronous events such as QP fatal, CQ overflow, or device removal occur.

## Control Path Design

Control traffic uses BAR2 CSR space and a mailbox command model. The driver writes command parameters, writes a GO bit, polls or waits for DONE, and reads status/error fields.

```text
driver ioctl
  -> smartnic_csr_cmd()
  -> BAR2 mailbox writes
  -> reg_block command decoder
  -> target manager command interface
  -> status/error response
  -> driver returns ioctl result
```

The control plane covers:

- device reset and feature discovery
- PD allocation and deallocation
- CQ create, destroy, query, and arm configuration
- QP create, modify, query, destroy, and error transition
- MR register, deregister, query, and memory window operations
- AH create and destroy for UD addressing
- MSI-X vector configuration and event queue control
- SR-IOV VF enablement, quota assignment, and per-function cleanup
- PFC/ECN/DCQCN parameter configuration

Fast-path WQE posting does not use the CSR mailbox. It uses mmap queue buffers plus Doorbell writes.

## Register Interface

### BAR Layout

| BAR | Size | Purpose | Access |
| --- | --- | --- | --- |
| BAR0 | 256 MB target | Doorbell aperture for SQ, RQ, and CQ arm pages | mmap write-mostly |
| BAR2 | 64 KB target | CSR registers and mailbox command interface | driver MMIO |
| BAR4 | 16 KB target | MSI-X table and pending-bit array | kernel PCI/MSI-X |

The exact BAR sizes can be adjusted for FPGA prototype constraints, but software-visible offsets must remain stable once the ABI is published.

### BAR0 Doorbell Aperture

Doorbell pages are assigned per resource and per function. A recommended layout is:

```text
BAR0 + function_base(func)
  + qpn * 0x1000
      + 0x000 SQ Doorbell: producer index + flags
      + 0x008 RQ Doorbell: producer index + flags
      + 0x010 CQ Arm Doorbell: consumer index + solicited_only
```

The hardware decodes QPN/CQN from the page offset and validates ownership using requester/function identity. Doorbell writes from a VF outside its assigned aperture are rejected or ignored without side effects.

### BAR2 CSR Register Groups

| Offset Range | Name | Purpose |
| --- | --- | --- |
| `0x0000-0x00ff` | Device control/status | reset, status, feature bits, version, health |
| `0x0100-0x01ff` | Mailbox command | command ID, GO/DONE, status, function ID, argument window |
| `0x0200-0x02ff` | Interrupt control | MSI-X vector mapping, event masks, moderation defaults |
| `0x0300-0x03ff` | Queue defaults | max QP/CQ/MR, queue depth limits, WQE/CQE size |
| `0x0400-0x04ff` | SR-IOV control | VF enable, VF quotas, VF BAR aperture base/limit |
| `0x0500-0x05ff` | Congestion control | DCQCN alpha/rate parameters, ECN/CNP counters, PFC config |
| `0x0600-0x06ff` | Statistics | packet counters, DMA counters, CQ overflow, QP errors |
| `0x0700-0x07ff` | Debug and trace | optional trace controls for prototype builds |

### Mailbox Command ABI

Mailbox commands use a common envelope:

| Field | Description |
| --- | --- |
| `cmd_id` | Operation such as CREATE_QP, MODIFY_QP, CREATE_CQ, REG_MR |
| `func_id` | PF/VF owner function |
| `seq` | Driver-assigned sequence number to match responses |
| `arg_len` | Number of valid argument bytes |
| `args[]` | Command-specific payload |
| `go` | Driver writes 1 to start command |
| `done` | Hardware writes 1 when command completes |
| `status` | success or failure code |
| `error_detail` | command-specific error detail |

Representative commands:

- `QUERY_DEVICE`
- `ALLOC_PD`, `DEALLOC_PD`
- `CREATE_CQ`, `DESTROY_CQ`, `QUERY_CQ`
- `CREATE_QP`, `MODIFY_QP`, `QUERY_QP`, `DESTROY_QP`
- `REG_MR`, `DEREG_MR`, `BIND_MW`, `INVALIDATE_MW`
- `CREATE_AH`, `DESTROY_AH`
- `CONFIG_MSIX`, `CONFIG_VF`, `CONFIG_DCQCN`, `READ_STATS`

## Software Stack

### Linux Kernel Driver

The Linux driver owns device initialization, privileged resource management, memory pinning, and mapping of safe fast-path regions to userspace.

Recommended file split:

| File | Responsibility |
| --- | --- |
| `smartnic_main.c` | module init/exit, PCI driver registration |
| `smartnic_pci.c` | probe/remove, BAR mapping, DMA mask, reset |
| `smartnic_csr.c` | CSR mailbox helpers and command serialization |
| `smartnic_cdev.c` | character device open/release/ioctl/poll |
| `smartnic_mmap.c` | mmap offset allocator and VMA mapping validation |
| `smartnic_resource.c` | PD/CQ/QP/MR/AH handle allocators and ownership |
| `smartnic_qp.c` | QP create/modify/query/destroy command handling |
| `smartnic_cq.c` | CQ create/destroy/query, event and interrupt integration |
| `smartnic_mr.c` | page pinning, DMA mapping, MR registration and deregistration |
| `smartnic_ah.c` | address handle lifecycle |
| `smartnic_intr.c` | MSI-X handlers and async event queue |
| `smartnic_sriov.c` | VF enable/disable, quotas, per-function cleanup |
| `smartnic_sysfs.c` | counters, device attributes, congestion parameters |

Driver responsibilities:

- Map BAR0/BAR2/BAR4 and expose only authorized mmap regions.
- Pin userspace pages for MR registration and convert them into hardware MR table entries.
- Allocate coherent or DMA-mapped queue buffers for SQ, RQ, and CQ where needed.
- Track ownership of every PD, CQ, QP, MR, AH, Doorbell page, and mmap offset per file descriptor and per PF/VF.
- Clean up resources on process exit, device hot-remove, driver unload, and VF disable.
- Return Linux errno-compatible failures for mailbox status codes.

### Character Device and ioctl Surface

The first implementation can expose `/dev/smartnicX` or `/dev/infiniband/uverbsX`-compatible control. The stable ioctl set should include:

| ioctl | Purpose | Key Outputs |
| --- | --- | --- |
| `QUERY_DEVICE` | Read device capabilities | max QP/CQ/MR, WQE/CQE sizes, feature bits |
| `ALLOC_PD` / `DEALLOC_PD` | Manage protection domains | PD handle |
| `CREATE_CQ` / `DESTROY_CQ` | Manage completion queues | CQN, CQ mmap offset, CQ arm Doorbell offset |
| `CREATE_QP` / `MODIFY_QP` / `QUERY_QP` / `DESTROY_QP` | Manage queue pairs | QPN, SQ/RQ mmap offsets, Doorbell offsets |
| `REG_MR` / `DEREG_MR` | Register and deregister memory | MR handle, lkey, rkey |
| `CREATE_AH` / `DESTROY_AH` | Manage UD address handles | AH handle |
| `GET_EVENT` | Retrieve async events | event type, QPN/CQN/port |

### mmap Model

The driver returns opaque mmap offsets to userspace. Userspace never invents offsets. The VMA fault or mmap handler validates:

- file descriptor owns the resource
- resource is still alive
- PF/VF function matches the owner
- requested size and protection bits match the mapping type

Mapping types:

- SQ buffer
- RQ buffer
- CQ buffer
- QP SQ Doorbell page
- QP RQ Doorbell page
- CQ arm Doorbell page

### Userspace Verbs Library

The userspace library translates Verbs API calls into driver ioctls and fast-path mmap writes. The API surface includes:

- device discovery: `ibv_get_device_list`, `ibv_free_device_list`, `ibv_get_device_name`
- context: `ibv_open_device`, `ibv_close_device`
- query: `ibv_query_device`, `ibv_query_port`, `ibv_query_gid`, `ibv_query_pkey`
- PD: `ibv_alloc_pd`, `ibv_dealloc_pd`
- CQ: `ibv_create_cq`, `ibv_destroy_cq`, `ibv_poll_cq`, `ibv_req_notify_cq`
- QP: `ibv_create_qp`, `ibv_modify_qp`, `ibv_query_qp`, `ibv_destroy_qp`
- MR: `ibv_reg_mr`, `ibv_dereg_mr`
- AH: `ibv_create_ah`, `ibv_destroy_ah`
- WR posting: `ibv_post_send`, `ibv_post_recv`
- async events: `ibv_get_async_event`, `ibv_ack_async_event`

Fast-path rules:

- `ibv_post_send` formats one or more hardware WQEs into the SQ buffer, uses a release barrier, then writes one SQ Doorbell for the batch.
- `ibv_post_recv` formats one or more receive WQEs into the RQ buffer, uses a release barrier, then writes one RQ Doorbell for the batch.
- `ibv_poll_cq` reads CQEs from the mmap CQ buffer, converts them to `ibv_wc`, advances the consumer index, and optionally updates hardware-visible consumer state.
- `ibv_req_notify_cq` writes the CQ arm Doorbell with consumer index and solicited-only state.

Compatibility target:

- perftest: RC Send, RDMA Write, RDMA Read
- UCX: verbs-backed RC smoke tests
- libfabric: verbs provider smoke tests for supported operations
- UD: basic Send/Recv and AH behavior

## Verification Architecture

The verification environment uses Cocotb/Verilator for development feedback and regression.

Testbench components:

- **PCIe BFM**: configuration cycles, Memory Read/Write TLPs, completions, MSI-X, requester/function identity.
- **Ethernet/RoCE BFM**: packet construction and parsing for RoCEv2 opcodes, ACK/NAK, CNP, invalid packet injection.
- **Host memory model**: byte-addressable memory backing DMA reads/writes and CQ buffer observation.
- **Scoreboard**: WR-to-CQE matching, payload comparison, PSN tracking, retry behavior, CQ overflow, and error status checking.
- **Coverage model**: opcodes, QP states, QP types, completion statuses, MR permissions, message sizes, SGE counts, congestion events, and SR-IOV access cases.

Verification stages:

1. Module tests for PCIe, BAR, CSR, Doorbell, QP, CQ, MR, DMA, packet parser/builder, RC/UD, and congestion modules.
2. Integration tests for Doorbell-to-CQE, RC Send/Recv, RDMA Write, RDMA Read, UD Send/Recv, MSI-X, and SR-IOV isolation.
3. Protocol compliance tests for RoCEv2 headers, ACK/NAK, RNR, DETH/RETH/AETH, immediate data, invalid packet drop, and ICRC behavior.
4. Compatibility tests using userspace examples, perftest, UCX, and libfabric where the simulation/prototype environment permits.
5. Performance tests for Doorbell-to-CQE latency, Doorbell-to-wire latency, DMA bandwidth, packet rate, completion rate, and interrupt moderation behavior.

## Decisions

### D1: Layered RTL Architecture

The RTL SHALL be split into PCIe, register/control, DMA, QP manager, CQ manager, MR manager, packet parser, packet builder, RoCEv2 engine, completion engine, congestion control, virtualization, and top-level integration blocks.

Rationale: PCIe transport, RDMA state, memory protection, and packet processing have different timing and verification concerns. Layering makes module-level tests practical and allows incremental integration.

Alternative considered: a monolithic RDMA engine. It was rejected because it makes protocol, DMA, and resource-management bugs difficult to isolate.

### D2: Doorbell-Based Fast Path

The userspace library SHALL mmap Doorbell pages and queue buffers where appropriate. Work requests are written into host-visible queues and submitted by a single MMIO Doorbell write.

Rationale: This follows the standard RDMA fast path and avoids syscall overhead for every work request.

Alternative considered: ioctl-per-WR submission. It was rejected because it cannot meet low-latency and high-throughput RDMA requirements.

### D3: Hardware QP/CQ/MR State, Software Control Plane

The driver owns resource creation, teardown, memory pinning, and policy. Hardware owns QP state used on the datapath, CQE production, MR key/address/permission checks, and DMA execution.

Rationale: This division keeps rare control operations flexible in software while keeping high-frequency packet and DMA operations in hardware.

### D4: CSR Mailbox for Resource Management

The driver SHALL use a CSR mailbox command protocol for QP/CQ/MR/AH/PD management commands. Each command includes operation ID, parameters, owner/function identity where applicable, GO/DONE status, and error reporting.

Rationale: A mailbox gives the driver a stable hardware ABI while allowing internal RTL modules to evolve.

### D5: libibverbs-Compatible Userspace Surface

The userspace library SHALL provide familiar Verbs APIs including device discovery, open/close, query, PD/CQ/QP/MR/AH lifecycle, post_send, post_recv, poll_cq, req_notify_cq, and async events.

Rationale: Compatibility with perftest, UCX, and libfabric is a core adoption requirement.

### D6: Cocotb/Verilator First Verification

The project SHALL use Cocotb/Verilator as the primary development verification environment, with Python BFMs for PCIe and Ethernet, a host memory model, scoreboards, and coverage.

Rationale: Python-based verification accelerates packet generation, randomized testing, and scoreboard development. Commercial simulators and formal tools can be added later for signoff.

### D7: Incremental Prototype Milestones

Implementation SHOULD proceed through milestones:

1. CSR/Doorbell/QP/CQ minimal completion loop.
2. DMA memory read/write loopback.
3. RC Send/Recv in simulation.
4. RDMA Write/Read in simulation.
5. UD Send/Recv.
6. Driver and userspace integration.
7. perftest/UCX/libfabric compatibility.
8. FPGA prototype.

Rationale: A full RDMA NIC has too many moving pieces to validate all at once. A staged plan keeps each milestone observable.

### D8: Vendor-Neutral Core with FPGA Wrappers

The core RTL SHALL use vendor-neutral internal streaming and command interfaces. Vendor-specific PCIe and MAC IP shall be isolated behind wrappers.

Rationale: FPGA prototyping may require Xilinx or Intel hard IP, but the SmartNIC architecture should remain portable and ASIC-ready.

### D9: Hardware-Enforced SR-IOV Isolation

PF/VF ownership SHALL be tracked in hardware-visible resource tables and checked on CSR, Doorbell, and datapath access.

Rationale: VF isolation cannot rely only on driver allocation policy. Hardware must reject cross-function accesses even if software is compromised or buggy.

## Risks / Trade-offs

- **[Scope size]** The complete SmartNIC spans RTL, driver, userspace, and verification. -> Mitigation: implement in milestone order and keep acceptance tests per milestone.
- **[PCIe Gen5 and 100GbE IP dependencies]** FPGA platforms may require vendor PCIe/MAC wrappers. -> Mitigation: define vendor-neutral internal interfaces and isolate wrappers.
- **[RoCEv2 interoperability]** Real NICs and switches differ in edge behavior. -> Mitigation: include protocol compliance tests plus soft-roce and perftest compatibility tests.
- **[libibverbs ABI drift]** A hand-written provider can diverge from expected Verbs semantics. -> Mitigation: test against perftest, UCX, and libfabric early.
- **[Simulation performance]** Full-system Verilator tests can be slow. -> Mitigation: prioritize module-level tests, use scoreboards, and reserve long tests for regression.
- **[SR-IOV isolation]** VF isolation must be enforced in hardware, not just in driver policy. -> Mitigation: include requester/function ownership in CSR, Doorbell, and resource tables.
- **[MR security and correctness]** Incorrect key, PD, or bounds checks can corrupt host memory. -> Mitigation: keep MR lookup centralized and require all DMA paths to use it.
- **[Register ABI stability]** Early CSR layout changes can break driver and userspace tests. -> Mitigation: version the ABI and reserve space in each register group.

## Migration Plan

This is a new capability, so there is no runtime migration. Implementation should begin by creating the source tree and test infrastructure, then proceed through the milestone sequence in D7.

Rollback strategy for implementation changes is per milestone: each milestone must keep its tests passing before the next milestone begins. If a milestone fails, revert or disable only that milestone's new integration while keeping lower-level module tests intact.

## Open Questions

- Which FPGA board is the first prototype target: Xilinx Alveo, Intel Agilex, or another platform?
- Which 100GbE MAC and PCIe endpoint IP wrappers will be used for FPGA prototype builds?
- Should the userspace library be a standalone libsmartnic shim first, or a proper libibverbs provider plugin from the beginning?
- What minimum compatibility matrix is required for perftest, UCX, and libfabric before considering the prototype usable?
- What QP/CQ/MR scale is required for v1 FPGA prototype versus final ASIC target?
- Should BAR0 expose one 4KB Doorbell page per QP/CQ, or should it use a compressed aperture with explicit resource IDs in the Doorbell payload?
- Should CQ consumer index updates be written through a CQ Doorbell or maintained purely in host memory with periodic hardware reads?
