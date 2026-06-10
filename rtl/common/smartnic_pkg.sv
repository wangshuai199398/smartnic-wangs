// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// RDMA SmartNIC shared constants and packed data structures.
//
// This package intentionally contains no datapath logic. It defines the common
// types that future RTL modules, driver UAPI definitions, userspace library
// formats, and Cocotb tests should agree on.

package smartnic_pkg;

    // ---------------------------------------------------------------------
    // Base widths and architectural limits
    // ---------------------------------------------------------------------

    parameter int ADDR_W          = 64;   // Host virtual/physical address width.
    parameter int DMA_LEN_W       = 32;   // DMA byte length width; supports up to 4 GiB - 1 per operation field.
    parameter int QP_ID_W         = 24;   // Queue Pair Number width used by RoCEv2 BTH destination QPN.
    parameter int CQ_ID_W         = 24;   // Completion Queue Number width used inside the device.
    parameter int MR_ID_W         = 24;   // Memory Region handle/index width used by control plane.
    parameter int PD_ID_W         = 24;   // Protection Domain identifier width.
    parameter int AH_ID_W         = 24;   // Address Handle identifier width for UD.
    parameter int VF_ID_W         = 16;   // PF/VF owner function identifier width.
    parameter int WR_ID_W         = 64;   // Work Request ID returned in completions.
    parameter int KEY_W           = 32;   // lkey/rkey width.
    parameter int PSN_W           = 24;   // RoCEv2 packet sequence number width.
    parameter int PKEY_W          = 16;   // Partition key width carried in BTH.
    parameter int QKEY_W          = 32;   // UD Q_Key width carried in DETH.
    parameter int MSN_W           = 24;   // Message sequence number width for ACK/AETH-like metadata.
    parameter int QUEUE_IDX_W     = 16;   // SQ/RQ/CQ producer and consumer index width.
    parameter int QUEUE_DEPTH_W   = 16;   // Queue depth field width.
    parameter int SGE_COUNT_W     = 8;    // Number of SGEs referenced by a WQE.
    parameter int CQ_VECTOR_W     = 12;   // MSI-X vector index width; supports 4096 vectors.
    parameter int PAGE_SHIFT_W    = 6;    // Encoded page-size shift width.

    parameter int WQE_BYTES       = 64;   // Hardware WQE size in bytes.
    parameter int CQE_BYTES       = 64;   // Hardware CQE size in bytes.
    parameter int MAX_SGE         = 256;  // Maximum scatter-gather entries per work request.
    parameter int MAX_QP          = 1 << QP_ID_W; // Logical QPN space.
    parameter int MAX_CQ          = 1 << CQ_ID_W; // Logical CQN space.
    parameter int MAX_MR          = 1 << 14;      // Initial MR table scale target: 16K entries.
    parameter int PMTU_BYTES      = 4096;         // Default PMTU segmentation boundary.

    // ---------------------------------------------------------------------
    // RDMA work request opcodes
    // ---------------------------------------------------------------------

    typedef enum logic [7:0] {
        RDMA_OP_SEND                 = 8'h00, // Send payload to a posted receive WQE.
        RDMA_OP_SEND_WITH_IMM        = 8'h01, // Send plus immediate data in completion.
        RDMA_OP_RDMA_WRITE           = 8'h02, // Write local payload to remote memory.
        RDMA_OP_RDMA_WRITE_WITH_IMM  = 8'h03, // RDMA Write plus immediate data.
        RDMA_OP_RDMA_READ            = 8'h04, // Read remote memory into local memory.
        RDMA_OP_ATOMIC_CMP_SWAP      = 8'h05, // Atomic compare-and-swap; reserved for later stages.
        RDMA_OP_ATOMIC_FETCH_ADD     = 8'h06, // Atomic fetch-and-add; reserved for later stages.
        RDMA_OP_BIND_MW              = 8'h07, // Bind memory window to an MR.
        RDMA_OP_LOCAL_INV            = 8'h08, // Local key invalidation.
        RDMA_OP_SEND_WITH_INV        = 8'h09  // Send and invalidate remote key.
    } rdma_opcode_e;

    // ---------------------------------------------------------------------
    // QP type and state
    // ---------------------------------------------------------------------

    typedef enum logic [2:0] {
        QP_TYPE_RC  = 3'd0, // Reliable Connection.
        QP_TYPE_UC  = 3'd1, // Unreliable Connection; reserved for future use.
        QP_TYPE_UD  = 3'd2, // Unreliable Datagram.
        QP_TYPE_RAW = 3'd3  // Raw packet; reserved for debug/prototype use.
    } qp_type_e;

    typedef enum logic [3:0] {
        QP_STATE_RESET = 4'd0, // QP exists but is not initialized.
        QP_STATE_INIT  = 4'd1, // Local attributes are configured.
        QP_STATE_RTR   = 4'd2, // Ready to receive.
        QP_STATE_RTS   = 4'd3, // Ready to send.
        QP_STATE_SQD   = 4'd4, // Send queue draining.
        QP_STATE_SQE   = 4'd5, // Send queue error.
        QP_STATE_ERR   = 4'd6  // Fatal/error state.
    } qp_state_e;

    // ---------------------------------------------------------------------
    // Completion status
    // ---------------------------------------------------------------------

    typedef enum logic [7:0] {
        CMPL_SUCCESS             = 8'h00, // Work request completed successfully.
        CMPL_LOC_LEN_ERR         = 8'h01, // Local length or SGE length violation.
        CMPL_LOC_QP_OP_ERR       = 8'h02, // Operation not valid for current QP state/type.
        CMPL_LOC_PROT_ERR        = 8'h03, // Local protection failure: lkey, PD, or access flag.
        CMPL_WR_FLUSH_ERR        = 8'h04, // Work request flushed during QP error/destroy.
        CMPL_MW_BIND_ERR         = 8'h05, // Memory window bind failed.
        CMPL_BAD_RESP_ERR        = 8'h06, // Bad response packet or unexpected opcode.
        CMPL_REM_ACCESS_ERR      = 8'h07, // Remote access failure reported by peer.
        CMPL_REM_OP_ERR          = 8'h08, // Remote operation failure reported by peer.
        CMPL_RETRY_EXC_ERR       = 8'h09, // RC retry count exceeded.
        CMPL_RNR_RETRY_EXC_ERR   = 8'h0a, // RNR retry count exceeded.
        CMPL_CQ_OVERFLOW_ERR     = 8'h0b, // CQ overflow detected.
        CMPL_DMA_ERR             = 8'h0c, // PCIe/DMA transfer error.
        CMPL_GENERAL_ERR         = 8'hff  // Unclassified error.
    } cmpl_status_e;

    // ---------------------------------------------------------------------
    // CSR mailbox commands
    // ---------------------------------------------------------------------

    typedef enum logic [15:0] {
        CSR_CMD_NOP              = 16'h0000, // No operation.
        CSR_CMD_QUERY_DEVICE     = 16'h0001, // Query device capabilities.
        CSR_CMD_ALLOC_PD         = 16'h0100, // Allocate a protection domain.
        CSR_CMD_DEALLOC_PD       = 16'h0101, // Free a protection domain.
        CSR_CMD_CREATE_CQ        = 16'h0200, // Create a completion queue.
        CSR_CMD_DESTROY_CQ       = 16'h0201, // Destroy a completion queue.
        CSR_CMD_QUERY_CQ         = 16'h0202, // Query CQ context.
        CSR_CMD_CREATE_QP        = 16'h0300, // Create a queue pair.
        CSR_CMD_MODIFY_QP        = 16'h0301, // Modify QP attributes/state.
        CSR_CMD_QUERY_QP         = 16'h0302, // Query QP context.
        CSR_CMD_DESTROY_QP       = 16'h0303, // Destroy a queue pair.
        CSR_CMD_REG_MR           = 16'h0400, // Register a memory region.
        CSR_CMD_DEREG_MR         = 16'h0401, // Deregister a memory region.
        CSR_CMD_BIND_MW          = 16'h0402, // Bind a memory window.
        CSR_CMD_INVALIDATE_MW    = 16'h0403, // Invalidate a memory window.
        CSR_CMD_CREATE_AH        = 16'h0500, // Create an address handle.
        CSR_CMD_DESTROY_AH       = 16'h0501, // Destroy an address handle.
        CSR_CMD_CONFIG_MSIX      = 16'h0600, // Configure MSI-X behavior.
        CSR_CMD_CONFIG_VF        = 16'h0700, // Configure SR-IOV VF resources.
        CSR_CMD_CONFIG_DCQCN     = 16'h0800, // Configure congestion control.
        CSR_CMD_READ_STATS       = 16'h0900  // Read statistics counters.
    } csr_cmd_e;

    // ---------------------------------------------------------------------
    // Doorbell type
    // ---------------------------------------------------------------------

    typedef enum logic [3:0] {
        DB_TYPE_NONE   = 4'd0, // Invalid/no doorbell.
        DB_TYPE_SQ     = 4'd1, // Send Queue producer update.
        DB_TYPE_RQ     = 4'd2, // Receive Queue producer update.
        DB_TYPE_CQ_ARM = 4'd3  // Completion Queue arm/update.
    } doorbell_type_e;

    // ---------------------------------------------------------------------
    // Access flags and CQ flags
    // ---------------------------------------------------------------------

    typedef enum logic [2:0] {
        MR_ACC_LOCAL_READ   = 3'd0, // Local DMA read from MR is allowed.
        MR_ACC_LOCAL_WRITE  = 3'd1, // Local DMA write to MR is allowed.
        MR_ACC_REMOTE_READ  = 3'd2, // Remote RDMA Read from MR is allowed.
        MR_ACC_REMOTE_WRITE = 3'd3, // Remote RDMA Write to MR is allowed.
        MR_ACC_REMOTE_ATOMIC= 3'd4, // Remote atomic access is allowed.
        MR_ACC_MW_BIND      = 3'd5  // Memory Window bind is allowed.
    } mr_access_bit_e;

    typedef enum logic [3:0] {
        CQE_FLAG_NONE      = 4'h0, // No extra CQE flags.
        CQE_FLAG_SIGNALED  = 4'h1, // Completion generated for a signaled WR.
        CQE_FLAG_SOLICITED = 4'h2, // Solicited event completion.
        CQE_FLAG_IMM       = 4'h4, // Immediate data field is valid.
        CQE_FLAG_INV       = 4'h8  // Invalidated rkey field is valid.
    } cqe_flag_e;

    // ---------------------------------------------------------------------
    // Packed data structures
    // ---------------------------------------------------------------------

    typedef struct packed {
        rdma_opcode_e              opcode;          // Work request operation type.
        logic [7:0]                flags;           // WR flags such as signaled, solicited, fence, inline.
        logic [SGE_COUNT_W-1:0]    sge_count;       // Number of SGEs referenced by this WQE.
        logic [WR_ID_W-1:0]        wr_id;           // Opaque application WR ID returned in CQE.
        logic [ADDR_W-1:0]         local_va;        // First local virtual address or inline SGE base.
        logic [KEY_W-1:0]          lkey;            // Local key for local MR access.
        logic [DMA_LEN_W-1:0]      length;          // Total byte count requested by this WR.
        logic [ADDR_W-1:0]         remote_va;       // Remote virtual address for RDMA Read/Write.
        logic [KEY_W-1:0]          rkey;            // Remote key for remote memory access.
        logic [31:0]               imm_data;        // Immediate data for Send/Write with immediate.
        logic [KEY_W-1:0]          inv_rkey;        // Remote key to invalidate for Send with invalidate.
        logic [63:0]               compare_add;     // Atomic compare value or fetch-add operand.
        logic [63:0]               swap;            // Atomic swap value.
    } wqe_t;

    typedef struct packed {
        cmpl_status_e              status;          // Completion status.
        rdma_opcode_e              opcode;          // Completed work request opcode.
        logic [7:0]                flags;           // CQE flags such as immediate/solicited/invalidated.
        logic [WR_ID_W-1:0]        wr_id;           // Application WR ID copied from WQE.
        logic [QP_ID_W-1:0]        qpn;             // Local QP that produced this completion.
        logic [QP_ID_W-1:0]        src_qpn;         // Source QPN for UD receive completions.
        logic [DMA_LEN_W-1:0]      byte_count;      // Number of bytes completed.
        logic [31:0]               imm_data;        // Immediate data if CQE_FLAG_IMM is set.
        logic [KEY_W-1:0]          inv_rkey;        // Invalidated rkey if CQE_FLAG_INV is set.
        logic [63:0]               timestamp;       // Device timestamp for profiling/debug.
        logic [31:0]               vendor_err;      // Device-specific error detail.
    } cqe_t;

    typedef struct packed {
        logic                       valid;          // QP context entry is allocated.
        logic [VF_ID_W-1:0]         owner_func;     // PF/VF function that owns this QP.
        logic [QP_ID_W-1:0]         qpn;            // Full QPN tag; prevents low-bit aliasing.
        qp_type_e                   qp_type;        // RC, UD, or reserved QP type.
        qp_state_e                  state;          // Current QP state.
        logic [PD_ID_W-1:0]         pd_id;          // Protection Domain associated with this QP.
        logic [CQ_ID_W-1:0]         send_cqn;       // CQ used for send completions.
        logic [CQ_ID_W-1:0]         recv_cqn;       // CQ used for receive completions.
        logic [ADDR_W-1:0]          sq_base;        // Host address of Send Queue buffer.
        logic [ADDR_W-1:0]          rq_base;        // Host address of Receive Queue buffer.
        logic [QUEUE_DEPTH_W-1:0]   sq_depth;       // Number of WQE slots in SQ.
        logic [QUEUE_DEPTH_W-1:0]   rq_depth;       // Number of WQE slots in RQ.
        logic [QUEUE_IDX_W-1:0]     sq_producer;    // Latest SQ producer index written by software.
        logic [QUEUE_IDX_W-1:0]     sq_consumer;    // Next SQ WQE index to be consumed by hardware.
        logic [QUEUE_IDX_W-1:0]     rq_producer;    // Latest RQ producer index written by software.
        logic [QUEUE_IDX_W-1:0]     rq_consumer;    // Next RQ WQE index to be consumed by hardware.
        logic [QP_ID_W-1:0]         remote_qpn;     // Peer QPN for RC connections.
        logic [PSN_W-1:0]           sq_psn;         // Next send PSN.
        logic [PSN_W-1:0]           rq_psn;         // Expected receive PSN.
        logic [PSN_W-1:0]           last_acked_psn; // Last acknowledged PSN for replay/ACK tracking.
        logic [7:0]                 retry_count;    // Remaining or configured retry count.
        logic [7:0]                 rnr_retry_count;// Remaining or configured RNR retry count.
        logic [15:0]                pkey;           // Partition key used in BTH validation.
        logic [QKEY_W-1:0]          qkey;           // UD Q_Key for DETH validation.
        logic [AH_ID_W-1:0]         ah_id;          // Default address handle for UD send path.
    } qp_context_t;

    typedef struct packed {
        logic                       valid;          // CQ context entry is allocated.
        logic [VF_ID_W-1:0]         owner_func;     // PF/VF function that owns this CQ.
        logic [CQ_ID_W-1:0]         cqn;            // Completion Queue Number tag.
        logic [ADDR_W-1:0]          cq_base;        // Host address of CQ buffer.
        logic [QUEUE_DEPTH_W-1:0]   cq_depth;       // Number of CQE slots.
        logic [QUEUE_IDX_W-1:0]     producer;       // Hardware producer index.
        logic [QUEUE_IDX_W-1:0]     consumer;       // Software consumer index observed by hardware.
        logic [CQ_VECTOR_W-1:0]     msix_vector;    // MSI-X vector associated with this CQ.
        logic [15:0]                moderation_cnt; // Interrupt after N completions when nonzero.
        logic [15:0]                moderation_timer;// Interrupt moderation timer in implementation-defined ticks.
        logic                       armed;          // CQ notification is armed.
        logic                       solicited_only; // Only solicited CQEs should trigger notification.
        logic                       overflow;       // CQ overflow has been detected.
    } cq_context_t;

    typedef struct packed {
        logic                       valid;          // MR table entry is active.
        logic                       pending_dereg;  // Deregistration requested; wait for refcount to drain.
        logic [VF_ID_W-1:0]         owner_func;     // PF/VF function that owns this MR.
        logic [MR_ID_W-1:0]         mr_id;          // Driver-visible MR handle.
        logic [PD_ID_W-1:0]         pd_id;          // Protection Domain associated with this MR.
        logic [KEY_W-1:0]           lkey;           // Local key used by local DMA operations.
        logic [KEY_W-1:0]           rkey;           // Remote key used by inbound remote operations.
        logic [ADDR_W-1:0]          va_base;        // First virtual address covered by this MR.
        logic [ADDR_W-1:0]          pa_base;        // First physical/DMA address backing this MR segment.
        logic [DMA_LEN_W-1:0]       length;         // Number of bytes covered by this MR entry.
        logic [PAGE_SHIFT_W-1:0]    page_shift;     // Page size as log2(bytes), e.g. 12 for 4 KiB.
        logic [5:0]                 access_flags;   // Bit mask indexed by mr_access_bit_e.
        logic [15:0]                refcount;       // Number of in-flight DMA references.
    } mr_entry_t;

    typedef struct packed {
        logic                       valid;          // AH entry is active.
        logic [VF_ID_W-1:0]         owner_func;     // PF/VF function that owns this AH.
        logic [AH_ID_W-1:0]         ah_id;          // Address Handle identifier.
        logic [PD_ID_W-1:0]         pd_id;          // Protection Domain associated with this AH.
        logic [47:0]                dst_mac;        // Destination Ethernet MAC address.
        logic [31:0]                dst_ipv4;       // Destination IPv4 address.
        logic [15:0]                udp_src_port;   // UDP source port used for RoCEv2 flow hashing.
        logic [15:0]                udp_dst_port;   // UDP destination port; normally 4791.
        logic [PKEY_W-1:0]          pkey;           // Partition key to place in BTH.
        logic [QKEY_W-1:0]          qkey;           // Q_Key to place in DETH for UD.
        logic [7:0]                 traffic_class;  // IPv4 DSCP/ECN traffic class metadata.
        logic [7:0]                 hop_limit;      // IPv4 TTL-like hop limit.
        logic [2:0]                 service_level;  // Service level / priority class.
    } ah_entry_t;

    typedef struct packed {
        doorbell_type_e             db_type;        // SQ, RQ, or CQ arm doorbell type.
        logic [VF_ID_W-1:0]         func_id;        // PF/VF function issuing the doorbell.
        logic [QP_ID_W-1:0]         qpn;            // Target QPN for SQ/RQ doorbells.
        logic [CQ_ID_W-1:0]         cqn;            // Target CQN for CQ arm doorbells.
        logic [QUEUE_IDX_W-1:0]     producer_idx;   // New SQ/RQ producer index.
        logic [QUEUE_IDX_W-1:0]     consumer_idx;   // CQ consumer index snapshot for arm.
        logic                       solicited_only; // CQ arm should trigger only on solicited CQEs.
    } doorbell_t;

    typedef struct packed {
        csr_cmd_e                   cmd_id;         // Mailbox command opcode.
        logic [VF_ID_W-1:0]         func_id;        // PF/VF function owning the command.
        logic [15:0]                seq;            // Driver sequence number for response matching.
        logic [15:0]                arg_len;        // Number of valid command argument bytes.
        logic [31:0]                status;         // Command completion status/error code.
    } csr_cmd_hdr_t;

endpackage : smartnic_pkg
