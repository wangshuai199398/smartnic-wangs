## 1. Project Structure and Shared Definitions

- [x] 1.1 Create RTL directory structure for `pcie`, `reg`, `dma`, `qp`, `cq`, `mr`, `packet`, `transport`, `congestion`, `virt`, `completion`, `common`, and `top`.
- [x] 1.2 Create Linux driver directory structure with files for PCIe core, CSR mailbox, character device, mmap, resources, interrupts, SR-IOV, sysfs/debugfs, and RDMA-facing operations.
- [x] 1.3 Create userspace library directory structure for device/context, PD, CQ, QP, MR, AH, work request posting, CQ polling, Doorbell helpers, and provider metadata.
- [x] 1.4 Create Cocotb/Verilator verification directory structure for BFMs, host memory model, scoreboard, unit tests, integration tests, compliance tests, compatibility tests, coverage, and regression scripts.
- [x] 1.5 Define shared constants and packed formats for WQE, CQE, QP context, CQ context, MR entry, AH entry, CSR commands, Doorbell payloads, opcodes, and completion statuses.
- [x] 1.6 Add top-level build targets for RTL lint, Verilator simulation, Cocotb tests, driver build, userspace library build, regression, and coverage reporting.

## 2. PCIe Endpoint and Register Control Plane

- [x] 2.1 Implement PCIe endpoint wrapper interfaces for configuration, inbound TLP, outbound TLP, DMA request/completion, MSI-X, and function identity.
- [x] 2.2 Implement PCIe configuration space with Type 0 header and required PCIe/MSI-X/SR-IOV/AER/ATS capability structures.
- [x] 2.3 Implement BAR decoder for BAR0 Doorbell aperture, BAR2 CSR space, and BAR4 MSI-X table/PBA space.
- [x] 2.4 Implement CSR mailbox command protocol with command ID, arguments, GO/DONE, status, error code, timeout, and owner function fields.
- [x] 2.5 Implement MSI-X table, pending-bit array, vector masking, interrupt arbitration, and outbound MSI-X transaction generation.
- [x] 2.6 Implement SR-IOV function identity plumbing and per-function access checks for CSR and Doorbell paths.
- [x] 2.7 Add PCIe endpoint unit tests for configuration reads, BAR routing, CSR command lifecycle, MSI-X masking, and VF access rejection.

## 3. Doorbell and Queue Submission Path

- [x] 3.1 Implement Doorbell address decoder that maps BAR0 offsets to QP SQ, QP RQ, and CQ arm operations.
- [x] 3.2 Implement per-function Doorbell aperture checks for PF and VF ownership.
- [x] 3.3 Implement SQ Doorbell payload parsing and QP producer index update.
- [x] 3.4 Implement RQ Doorbell payload parsing and QP producer index update.
- [x] 3.5 Implement CQ arm Doorbell parsing with consumer index and solicited-only flag.
- [x] 3.6 Add Doorbell unit tests for SQ, RQ, CQ arm, producer wraparound, invalid QPN, and cross-VF rejection.

## 4. QP Manager

- [x] 4.1 Implement QP context table with QPN tag matching, QP type, state, PD, CQs, queue base addresses, depths, producer/consumer indices, PSN state, retry state, and owner function.
- [x] 4.2 Implement QP lifecycle commands for create, modify, query, destroy, and error transition.
- [x] 4.3 Implement IBTA-compatible QP state transition validation for RESET, INIT, RTR, RTS, SQD, SQE, and ERR states.
- [x] 4.4 Implement SQ engine that fetches WQEs, validates QP state, decodes work request opcode, and dispatches to DMA or transport logic.
- [x] 4.5 Implement RQ engine that consumes Recv WQEs for inbound Send payloads and dispatches writes to DMA.
- [x] 4.6 Implement QP destruction and error cleanup with pending work quiesce and flushed completions.
- [x] 4.7 Add QP tests for lifecycle, legal/illegal state transitions, SQ processing, RQ processing, error transition, and QPN alias prevention.

## 5. CQ Manager and Completion Engine

- [x] 5.1 Implement CQ context table with buffer address, depth, producer index, consumer index, owner function, MSI-X vector, moderation count, moderation timer, and arm state.
- [x] 5.2 Implement completion engine that accepts work completion events and formats 64-byte CQEs.
- [ ] 5.3 Implement CQE write path that calculates host CQ buffer address and emits DMA/PCIe memory writes.
- [ ] 5.4 Implement CQ producer/consumer wraparound logic and overflow detection.
- [ ] 5.5 Implement CQ notification logic for polling mode, solicited events, interrupt moderation count, and moderation timer.
- [ ] 5.6 Add CQ tests for CQE formatting, producer/consumer updates, overflow, CQ arm races, moderation count, and MSI-X request generation.

## 6. MR Manager and Memory Protection

- [ ] 6.1 Implement MR table with valid bit, lkey, rkey, virtual base, physical base, length, page size, access flags, PD, owner function, and refcount.
- [ ] 6.2 Implement MR registration command handling from pinned scatter-gather page lists.
- [ ] 6.3 Implement MR deregistration with pending-deregister state and in-flight DMA refcount drain.
- [ ] 6.4 Implement local lkey and remote rkey direction checks.
- [ ] 6.5 Implement access permission checks for local read/write, remote read/write, remote atomic, and memory window bind.
- [ ] 6.6 Implement protection domain checks for local and remote operations.
- [ ] 6.7 Implement memory window bind, unbind, permission subset validation, and invalidation on QP error where required.
- [ ] 6.8 Add MR tests for registration, deregistration, translation, bounds rejection, PD mismatch, key direction, permission rejection, and memory window binding.

## 7. Scatter-Gather DMA Engine

- [ ] 7.1 Implement DMA descriptor format and dispatcher for Send, Recv, RDMA Write, RDMA Read, and CQE writes.
- [ ] 7.2 Implement WQE and SGE fetch support for inline and extended SGE lists up to 256 entries.
- [ ] 7.3 Implement SGE traversal with total-length accounting and zero-overlap validation.
- [ ] 7.4 Implement MR lookup and permission integration for every DMA segment.
- [ ] 7.5 Implement host memory read path for Send and RDMA Write payload generation.
- [ ] 7.6 Implement host memory write path for Recv and RDMA Read response payload delivery.
- [ ] 7.7 Implement PMTU and 4KB physical page boundary segmentation.
- [ ] 7.8 Implement DMA arbitration across active QPs with configurable fairness policy.
- [ ] 7.9 Implement DMA error propagation into completion status.
- [ ] 7.10 Add DMA tests for single SGE, multi-SGE, 256 SGE, unaligned segments, 4KB boundary split, arbitration fairness, and error injection.

## 8. Packet Parser and Packet Builder

- [ ] 8.1 Implement ingress packet parser for Ethernet, optional VLAN, IPv4, UDP, BTH, RETH, AETH, DETH, ImmDt, and invariant CRC fields.
- [ ] 8.2 Implement ingress validation for EtherType, IP version, IHL, protocol, UDP port, BTH transport version, opcode, checksum, and packet length.
- [ ] 8.3 Implement payload extraction interface from parser to receive DMA and transport logic.
- [ ] 8.4 Implement packet builder for Ethernet, IPv4, UDP, BTH, RETH, AETH, DETH, ImmDt, ACK, NAK, CNP, and payload frames.
- [ ] 8.5 Implement ICRC calculation or a clearly isolated placeholder with tests marking compatibility limitations.
- [ ] 8.6 Add packet tests for every supported opcode, invalid packet drop, header field extraction, header generation, payload alignment, and ICRC behavior.

## 9. RoCEv2 Transport Engine

- [ ] 9.1 Implement RC send-side PSN allocation, outstanding packet tracking, ACK processing, retry timer, and retry exhaustion handling.
- [ ] 9.2 Implement RC receive-side PSN validation, duplicate/replay drop, gap NAK generation, ACK coalescing, and RNR NAK generation.
- [ ] 9.3 Implement RDMA Read request and response sequencing for RC QPs.
- [ ] 9.4 Implement RDMA Write and Send immediate-data handling.
- [ ] 9.5 Implement UD transmit path with AH lookup, DETH generation, Q_Key handling, and no connection state.
- [ ] 9.6 Implement UD receive path with DETH parsing, Q_Key validation, source QPN reporting, and failure counters.
- [ ] 9.7 Implement address handle table for destination MAC, IP, UDP port, GID-derived fields, and service level metadata.
- [ ] 9.8 Add transport tests for RC Send, RDMA Write, RDMA Read, UD Send, PSN errors, retries, RNR, immediate data, and Q_Key rejection.

## 10. PFC ECN DCQCN and Scheduling

- [ ] 10.1 Implement ECN detection from ingress packets and pass congestion marks to transport and congestion logic.
- [ ] 10.2 Implement CNP packet generation and CNP receive classification.
- [ ] 10.3 Implement DCQCN state machine with configurable alpha, rate decrease, rate recovery, target rate, and minimum rate.
- [ ] 10.4 Implement per-QP token bucket or equivalent transmit pacing.
- [ ] 10.5 Implement PFC pause handling for configured priority and transmit scheduler backpressure.
- [ ] 10.6 Add congestion tests for ECN-to-CNP, CNP rate update, rate recovery, pacing, PFC pause/resume, and malformed CNP handling.

## 11. Top-Level RTL Integration

- [ ] 11.1 Implement `smartnic_top` with all major RTL blocks instantiated and connected through stable internal interfaces.
- [ ] 11.2 Connect PCIe BAR/CSR control path to QP, CQ, MR, AH, MSI-X, SR-IOV, and congestion-control registers.
- [ ] 11.3 Connect Doorbell path to QP SQ/RQ and CQ arm logic.
- [ ] 11.4 Connect QP, DMA, packet, transport, completion, and CQ managers for RC Send/Recv minimal loop.
- [ ] 11.5 Connect RDMA Write and RDMA Read datapaths.
- [ ] 11.6 Connect UD transmit and receive datapaths.
- [ ] 11.7 Add top-level tests for reset, CSR command, Doorbell-to-CQE minimal loop, RC Send, RDMA Write, RDMA Read, UD Send, and MSI-X completion interrupt.

## 12. Linux Kernel Driver

- [ ] 12.1 Implement PCIe driver probe/remove with BAR mapping, DMA mask setup, reset, feature discovery, and teardown.
- [ ] 12.2 Implement CSR mailbox helper with timeout, error-code mapping, and locking.
- [ ] 12.3 Implement character device open, release, ioctl dispatch, mmap, and poll operations.
- [ ] 12.4 Implement resource allocators for PD, CQ, QP, MR, AH, Doorbell pages, queue buffers, and mmap offsets.
- [ ] 12.5 Implement CQ create/destroy/query ioctls and CQ buffer mapping.
- [ ] 12.6 Implement QP create/modify/query/destroy ioctls and SQ/RQ buffer plus Doorbell mappings.
- [ ] 12.7 Implement MR register/deregister ioctls using page pinning and DMA mapping.
- [ ] 12.8 Implement AH create/destroy ioctls for UD addressing.
- [ ] 12.9 Implement MSI-X interrupt handlers for CQ events and async events.
- [ ] 12.10 Implement SR-IOV enable/disable, VF resource quotas, and per-function cleanup.
- [ ] 12.11 Implement hot-remove and process-release cleanup for all resources owned by a file descriptor.
- [ ] 12.12 Add driver build and static analysis targets.

## 13. Userspace Verbs Library

- [ ] 13.1 Implement device discovery and context open/close APIs.
- [ ] 13.2 Implement query_device, query_port, query_gid, and query_pkey APIs.
- [ ] 13.3 Implement PD alloc/dealloc APIs.
- [ ] 13.4 Implement CQ create/destroy/resize, poll_cq, and req_notify_cq APIs.
- [ ] 13.5 Implement QP create/modify/query/destroy APIs.
- [ ] 13.6 Implement MR register/deregister APIs.
- [ ] 13.7 Implement AH create/destroy APIs for UD.
- [ ] 13.8 Implement WQE builders for Send, Send with Immediate, RDMA Write, RDMA Write with Immediate, RDMA Read, and supported UD operations.
- [ ] 13.9 Implement post_send and post_recv batching with Doorbell memory barriers.
- [ ] 13.10 Implement CQE parser that returns Verbs-compatible work completions.
- [ ] 13.11 Implement async event retrieval and acknowledgement APIs.
- [ ] 13.12 Add pkg-config, provider metadata, examples, and userspace unit tests.

## 14. Cocotb Verilator Verification

- [ ] 14.1 Implement PCIe BFM for config, memory read/write, completions, MSI-X, and function identity.
- [ ] 14.2 Implement Ethernet/RoCEv2 BFM for packet construction, parsing, error injection, and CNP/PFC stimuli.
- [ ] 14.3 Implement host memory model with DMA read/write visibility and data integrity checks.
- [ ] 14.4 Implement scoreboard for WR-to-CQE matching, payload comparison, PSN tracking, retry behavior, and error statuses.
- [ ] 14.5 Implement functional coverage for opcodes, QP states, CQ statuses, MR permissions, message sizes, SGE counts, QP types, and congestion events.
- [ ] 14.6 Implement module-level Cocotb tests for PCIe, Doorbell, QP, CQ, MR, DMA, packet, transport, congestion, and top-level reset.
- [ ] 14.7 Implement integration tests for Doorbell-to-CQE, RC Send, RDMA Write, RDMA Read, UD Send, MSI-X, and SR-IOV isolation.
- [ ] 14.8 Implement protocol compliance tests for RoCEv2 header fields, ACK/NAK, RNR, immediate data, invalid packets, and ICRC behavior.
- [ ] 14.9 Implement regression script that runs lint, unit tests, integration tests, compatibility simulations, and coverage report generation.

## 15. Compatibility and Performance Validation

- [ ] 15.1 Add a minimal verbs example that opens the device, creates PD/CQ/QP/MR, posts Send/Recv, and polls completions.
- [ ] 15.2 Add perftest compatibility target for supported RC Send, RDMA Write, and RDMA Read tests.
- [ ] 15.3 Add UCX compatibility smoke tests for supported RC operations.
- [ ] 15.4 Add libfabric compatibility smoke tests for supported verbs-backed operations.
- [ ] 15.5 Add simulation performance counters for Doorbell-to-CQE latency, Doorbell-to-wire latency, DMA bandwidth, packet rate, and completion rate.
- [ ] 15.6 Add FPGA prototype checklist for board selection, PCIe IP wrapper, MAC IP wrapper, clocks, resets, constraints, loopback, and host driver loading.

## 16. Documentation and Acceptance

- [ ] 16.1 Document hardware module architecture and top-level data paths.
- [ ] 16.2 Document Linux driver ioctl ABI, mmap offsets, resource lifecycle, and error codes.
- [ ] 16.3 Document userspace Verbs API compatibility scope and known limitations.
- [ ] 16.4 Document verification strategy, test matrix, coverage goals, and how to run regression.
- [ ] 16.5 Verify `openspec validate add-rdma-smartnic-design-capability --strict` passes.
- [ ] 16.6 Verify all generated OpenSpec artifacts are ready for `/opsx:apply`.
