## ADDED Requirements

### Requirement: PCIe Gen5 x16 Endpoint
The RDMA SmartNIC SHALL define a PCIe Gen5 x16 endpoint architecture with configuration space, BAR mapping, DMA request/completion handling, MSI-X interrupt delivery, and SR-IOV-capable function isolation.

#### Scenario: Host enumerates PCIe endpoint
- **WHEN** the host performs PCIe configuration reads after reset
- **THEN** the endpoint SHALL expose a valid Type 0 configuration header and required PCIe capability structures for endpoint operation

#### Scenario: BAR access is routed by function and offset
- **WHEN** a host Memory Read or Memory Write targets BAR0, BAR2, or BAR4
- **THEN** the endpoint SHALL route the access to Doorbell, CSR, or MSI-X table/PBA logic according to the decoded BAR and offset

#### Scenario: MSI-X interrupt is generated
- **WHEN** a completion or asynchronous event requests an unmasked MSI-X vector
- **THEN** the endpoint SHALL generate a valid MSI-X transaction using the programmed message address and data

#### Scenario: SR-IOV function isolation
- **WHEN** a VF issues a CSR or Doorbell access
- **THEN** hardware SHALL restrict the access to resources owned by that VF and reject global PF-only register writes

### Requirement: RoCEv2 Transport
The RDMA SmartNIC SHALL implement RoCEv2 packet parsing and composition for Ethernet/IPv4/UDP/BTH-based traffic and SHALL support RC and UD transport behavior.

#### Scenario: Valid RoCEv2 packet is accepted
- **WHEN** an ingress packet has RoCEv2 EtherType or UDP destination port 4791 with valid IPv4 and BTH fields
- **THEN** the parser SHALL extract opcode, destination QPN, PSN, P_Key, and required extended headers

#### Scenario: Invalid RoCEv2 packet is dropped
- **WHEN** an ingress packet has invalid EtherType, IP protocol, UDP port, BTH transport version, checksum, or unsupported opcode
- **THEN** the parser SHALL drop the packet without consuming receive WQEs or writing CQEs

#### Scenario: RC packet sequencing is enforced
- **WHEN** an RC packet arrives with a PSN that does not match the expected receive PSN
- **THEN** hardware SHALL generate the appropriate ACK or NAK behavior and SHALL NOT deliver out-of-order payload to host memory

#### Scenario: UD packet delivery records source identity
- **WHEN** a valid UD packet is delivered to a receive queue
- **THEN** the resulting completion SHALL include source QPN and immediate data where applicable

### Requirement: RDMA Operations
The RDMA SmartNIC SHALL support RDMA Read, RDMA Write, Send, and Recv operations for supported QP types.

#### Scenario: Send operation completes
- **WHEN** userspace posts a Send work request to an RTS QP and the peer has a matching Recv WQE
- **THEN** hardware SHALL transfer the payload and generate successful completion entries according to QP signaling rules

#### Scenario: RDMA Write operation completes
- **WHEN** userspace posts an RDMA Write work request with a valid remote address and rkey
- **THEN** hardware SHALL read local SGE data, compose RoCEv2 write packets, and complete the operation after required transport semantics are satisfied

#### Scenario: RDMA Read operation completes
- **WHEN** userspace posts an RDMA Read work request with a valid remote address and rkey
- **THEN** hardware SHALL issue a read request, receive read response payload, write local memory through DMA, and generate a successful completion

#### Scenario: Recv operation consumes receive WQE
- **WHEN** an inbound Send packet targets a QP with posted Recv WQEs
- **THEN** hardware SHALL consume one Recv WQE, write payload to its SGE list, and emit a receive completion

### Requirement: Scatter-Gather DMA Engine
The RDMA SmartNIC SHALL provide a DMA engine that supports scatter-gather lists, host memory reads, host memory writes, PMTU segmentation, PCIe TLP generation, and error reporting.

#### Scenario: DMA traverses SGE list
- **WHEN** a work request references one or more SGEs
- **THEN** the DMA engine SHALL traverse the SGEs in order and transfer exactly the requested byte count without overlap or omission

#### Scenario: DMA uses MR translation
- **WHEN** a DMA transfer accesses a virtual address
- **THEN** the DMA engine SHALL use MR lookup results to translate to physical addresses and SHALL fail the operation if translation or permission checks fail

#### Scenario: DMA segments large transfer
- **WHEN** a transfer exceeds the configured PMTU or a 4KB physical page boundary
- **THEN** the DMA engine SHALL split the transfer into legal segments before issuing PCIe transactions or packet payloads

#### Scenario: DMA error produces completion
- **WHEN** DMA encounters an invalid address, permission failure, PCIe completion error, or length violation
- **THEN** hardware SHALL stop the affected work request and generate an error CQE with the corresponding status

### Requirement: QP Lifecycle Management
The RDMA SmartNIC SHALL manage QP creation, modification, query, destruction, Doorbell processing, state transitions, SQ processing, and RQ processing.

#### Scenario: QP state transition is valid
- **WHEN** the driver requests a legal state transition such as RESET to INIT, INIT to RTR, or RTR to RTS
- **THEN** hardware SHALL update the QP context and expose the new state to subsequent queries

#### Scenario: QP state transition is invalid
- **WHEN** the driver requests an illegal state transition such as RESET directly to RTS
- **THEN** hardware SHALL reject the command and SHALL NOT modify the QP context

#### Scenario: SQ Doorbell starts work processing
- **WHEN** userspace writes a QP SQ Doorbell with a new producer index
- **THEN** hardware SHALL identify the QP, fetch newly posted WQEs, and dispatch valid work requests to DMA or transport logic

#### Scenario: QP destruction flushes work
- **WHEN** a QP is destroyed while work requests are pending
- **THEN** hardware and driver SHALL prevent new work, flush pending work with error completions where required, and release QP resources

### Requirement: CQ Lifecycle and Completion Queue
The RDMA SmartNIC SHALL manage CQ creation, destruction, producer and consumer indices, CQE formatting, polling mode, notification mode, interrupt moderation, and overflow handling.

#### Scenario: CQE is written with required fields
- **WHEN** a work request completes
- **THEN** hardware SHALL write a 64-byte CQE containing status, opcode, WR ID, QPN, byte count, immediate data, and error information as applicable

#### Scenario: Userspace polls CQ
- **WHEN** userspace calls the completion polling API
- **THEN** the userspace library SHALL read CQEs from the mmap CQ buffer, convert them to Verbs work completions, and update the consumer index

#### Scenario: CQ notification is armed
- **WHEN** userspace requests CQ notification
- **THEN** hardware SHALL record the arm state and generate MSI-X only when the notification condition is satisfied

#### Scenario: CQ overflow is detected
- **WHEN** hardware would overwrite an unconsumed CQE
- **THEN** hardware SHALL mark CQ overflow and report an error without corrupting unrelated queue entries

### Requirement: MR Lifecycle and Memory Protection
The RDMA SmartNIC SHALL manage MR registration, deregistration, lkey/rkey generation, access permissions, protection domains, memory windows, and address translation.

#### Scenario: MR registration creates keys
- **WHEN** the driver registers a pinned memory region
- **THEN** hardware or driver-managed control logic SHALL create MR table entries and return usable lkey and rkey values to userspace

#### Scenario: Local access uses lkey
- **WHEN** local DMA accesses a registered MR
- **THEN** hardware SHALL validate the lkey, address range, length, protection domain, and local access permissions

#### Scenario: Remote access uses rkey
- **WHEN** an inbound RoCEv2 operation accesses host memory
- **THEN** hardware SHALL validate the rkey, address range, length, protection domain, and remote access permissions before DMA writes or reads occur

#### Scenario: MR deregistration waits for active DMA
- **WHEN** an MR is deregistered while DMA is in flight
- **THEN** hardware and driver SHALL prevent new accesses and SHALL NOT release the MR entry until active DMA references are complete

### Requirement: Doorbell Interface
The RDMA SmartNIC SHALL expose mmap-capable Doorbell pages for fast-path SQ, RQ, and CQ arm submission.

#### Scenario: SQ Doorbell write is decoded
- **WHEN** userspace writes the SQ Doorbell offset for a QP
- **THEN** hardware SHALL decode the owning QP and update the SQ producer index

#### Scenario: RQ Doorbell write is decoded
- **WHEN** userspace writes the RQ Doorbell offset for a QP
- **THEN** hardware SHALL decode the owning QP and update the RQ producer index

#### Scenario: Doorbell write is isolated per function
- **WHEN** a VF writes a Doorbell page outside its assigned aperture
- **THEN** hardware SHALL reject the write or ignore it without affecting another function's resources

### Requirement: PFC ECN DCQCN Congestion Control
The RDMA SmartNIC SHALL support lossless Ethernet integration with PFC awareness, ECN detection, CNP processing, and DCQCN rate control.

#### Scenario: ECN marked packet triggers congestion response
- **WHEN** hardware receives a RoCEv2 packet with ECN congestion indication
- **THEN** hardware SHALL generate or schedule the required congestion notification behavior for the affected flow

#### Scenario: CNP updates transmit rate
- **WHEN** hardware receives a valid CNP for a QP
- **THEN** DCQCN logic SHALL reduce or recover the QP transmit rate according to configured parameters

#### Scenario: PFC pause state affects transmit scheduling
- **WHEN** PFC pause is active for the configured priority
- **THEN** hardware SHALL stop transmitting affected traffic until pause expires while preserving queue state

### Requirement: Linux Kernel Driver Interface
The RDMA SmartNIC SHALL define a Linux kernel driver interface for PCIe device management, resource lifecycle, character device control, mmap, MSI-X, and SR-IOV.

#### Scenario: Driver probes device
- **WHEN** Linux discovers a matching PCIe device
- **THEN** the driver SHALL enable the device, map BARs, configure DMA masks, initialize interrupts, initialize hardware, and register user-visible control interfaces

#### Scenario: Character device creates QP
- **WHEN** userspace issues a CREATE_QP ioctl with valid CQ and PD handles
- **THEN** the driver SHALL allocate QP resources, program hardware context, allocate queue memory, and return QPN plus mmap offsets

#### Scenario: mmap exposes Doorbell page
- **WHEN** userspace mmaps a valid Doorbell offset returned by the driver
- **THEN** the driver SHALL map only the authorized Doorbell page for that process or function

#### Scenario: Driver handles hot remove
- **WHEN** the PCIe device is removed
- **THEN** the driver SHALL quiesce hardware, notify userspace where possible, release resources, unmap BARs, and unregister interfaces

### Requirement: Userspace Verbs API
The RDMA SmartNIC SHALL provide a libibverbs-compatible userspace API for device discovery, context management, PD/CQ/QP/MR/AH lifecycle, work request posting, completion polling, notification, and async events.

#### Scenario: Application opens device
- **WHEN** an application requests the device list and opens a SmartNIC device
- **THEN** the userspace library SHALL open the driver control device, query attributes, and prepare mmap mappings required for fast-path operation

#### Scenario: Application posts send work request
- **WHEN** an application calls the send-posting API with a valid QP and WR chain
- **THEN** the userspace library SHALL format hardware WQEs, write them to the SQ, and ring the SQ Doorbell once per batch

#### Scenario: Application polls completion
- **WHEN** an application polls a CQ with completed CQEs
- **THEN** the userspace library SHALL return Verbs-compatible work completions with correct status and metadata

#### Scenario: Middleware compatibility is tested
- **WHEN** perftest, UCX, or libfabric runs against the userspace API
- **THEN** the implementation SHALL provide compatible behavior for the supported RC and UD operations

### Requirement: Cocotb Verilator Verification
The RDMA SmartNIC SHALL include a Cocotb/Verilator verification environment with module tests, integration tests, scoreboards, BFMs, coverage, and regression automation.

#### Scenario: Module-level tests run
- **WHEN** the module test suite is executed
- **THEN** tests SHALL cover PCIe, DMA, QP, CQ, MR, RoCEv2 parser/composer, transport, Doorbell, MSI-X, and congestion-control modules

#### Scenario: End-to-end RC test runs
- **WHEN** the integration test posts an RC Send or RDMA Write through the simulated datapath
- **THEN** the scoreboard SHALL observe Doorbell capture, WQE processing, DMA movement, packet processing, and CQE generation

#### Scenario: Verification coverage is reported
- **WHEN** regression completes
- **THEN** the verification environment SHALL report functional coverage for opcodes, QP states, completion statuses, errors, message sizes, SGE counts, and transport types

#### Scenario: Compatibility tests are represented
- **WHEN** compatibility validation is run
- **THEN** the test plan SHALL include perftest, UCX, and libfabric scenarios for supported operations and QP types
