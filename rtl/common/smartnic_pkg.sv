// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// RDMA SmartNIC 共享常量和 packed 数据结构。
//
// 这个 package 故意不包含任何数据通路逻辑。它只定义后续 RTL 模块、
// 驱动 UAPI、用户态库格式和 Cocotb 测试需要共同遵守的类型。

package smartnic_pkg;

    // ---------------------------------------------------------------------
    // 基础位宽和架构规模限制
    // ---------------------------------------------------------------------

    parameter int ADDR_W          = 64;   // 主机虚拟/物理地址位宽。
    parameter int DMA_LEN_W       = 32;   // DMA 字节长度位宽；单个操作字段最多表达 4 GiB - 1。
    parameter int QP_ID_W         = 24;   // QP 编号位宽，对应 RoCEv2 BTH 中的目标 QPN。
    parameter int CQ_ID_W         = 24;   // 设备内部 CQ 编号位宽。
    parameter int MR_ID_W         = 24;   // 控制面使用的 MR handle/索引位宽。
    parameter int PD_ID_W         = 24;   // Protection Domain 标识符位宽。
    parameter int AH_ID_W         = 24;   // UD 使用的 Address Handle 标识符位宽。
    parameter int VF_ID_W         = 16;   // PF/VF 所属 function 标识符位宽。
    parameter int WR_ID_W         = 64;   // completion 中返回的 Work Request ID 位宽。
    parameter int KEY_W           = 32;   // lkey/rkey 位宽。
    parameter int PSN_W           = 24;   // RoCEv2 包序列号 PSN 位宽。
    parameter int PKEY_W          = 16;   // BTH 中携带的 P_Key 位宽。
    parameter int QKEY_W          = 32;   // DETH 中携带的 UD Q_Key 位宽。
    parameter int MSN_W           = 24;   // ACK/AETH 类元数据使用的消息序列号位宽。
    parameter int QUEUE_IDX_W     = 16;   // SQ/RQ/CQ producer 和 consumer 索引位宽。
    parameter int QUEUE_DEPTH_W   = 16;   // 队列深度字段位宽。
    parameter int SGE_COUNT_W     = 8;    // 一个 WQE 引用的 SGE 数量位宽。
    parameter int CQ_VECTOR_W     = 12;   // MSI-X vector 索引位宽；支持 4096 个 vector。
    parameter int PAGE_SHIFT_W    = 6;    // 页大小 shift 编码位宽。

    parameter int WQE_BYTES       = 64;   // 硬件 WQE 大小，单位为字节。
    parameter int CQE_BYTES       = 64;   // 硬件 CQE 大小，单位为字节。
    parameter int MAX_SGE         = 256;  // 单个 Work Request 支持的最大 SGE 数量。
    parameter int MAX_QP          = 1 << QP_ID_W; // 逻辑 QPN 空间大小。
    parameter int MAX_CQ          = 1 << CQ_ID_W; // 逻辑 CQN 空间大小。
    parameter int MAX_MR          = 1 << 14;      // 初始 MR 表规模目标：16K 条目。
    parameter int PMTU_BYTES      = 4096;         // 默认 PMTU 分段边界。

    // ---------------------------------------------------------------------
    // RDMA Work Request 操作码
    // ---------------------------------------------------------------------

    typedef enum logic [7:0] {
        RDMA_OP_SEND                 = 8'h00, // 将 payload 发送到对端已投递的接收 WQE。
        RDMA_OP_SEND_WITH_IMM        = 8'h01, // Send 操作，并在 completion 中携带 immediate data。
        RDMA_OP_RDMA_WRITE           = 8'h02, // 将本地 payload 写入远端内存。
        RDMA_OP_RDMA_WRITE_WITH_IMM  = 8'h03, // RDMA Write 操作，并携带 immediate data。
        RDMA_OP_RDMA_READ            = 8'h04, // 从远端内存读取数据到本地内存。
        RDMA_OP_ATOMIC_CMP_SWAP      = 8'h05, // 原子 compare-and-swap；后续阶段预留。
        RDMA_OP_ATOMIC_FETCH_ADD     = 8'h06, // 原子 fetch-and-add；后续阶段预留。
        RDMA_OP_BIND_MW              = 8'h07, // 将 Memory Window 绑定到某个 MR。
        RDMA_OP_LOCAL_INV            = 8'h08, // 本地 key 失效。
        RDMA_OP_SEND_WITH_INV        = 8'h09  // Send 操作，并使远端 key 失效。
    } rdma_opcode_e;

    // ---------------------------------------------------------------------
    // QP 类型和状态
    // ---------------------------------------------------------------------

    typedef enum logic [2:0] {
        QP_TYPE_RC  = 3'd0, // Reliable Connection，可靠连接。
        QP_TYPE_UC  = 3'd1, // Unreliable Connection，后续阶段预留。
        QP_TYPE_UD  = 3'd2, // Unreliable Datagram，不可靠数据报。
        QP_TYPE_RAW = 3'd3  // Raw packet，调试/原型阶段预留。
    } qp_type_e;

    typedef enum logic [3:0] {
        QP_STATE_RESET = 4'd0, // QP 已存在，但尚未初始化。
        QP_STATE_INIT  = 4'd1, // 本地属性已配置。
        QP_STATE_RTR   = 4'd2, // Ready to Receive，可以接收。
        QP_STATE_RTS   = 4'd3, // Ready to Send，可以发送。
        QP_STATE_SQD   = 4'd4, // Send Queue Draining，发送队列排空中。
        QP_STATE_SQE   = 4'd5, // Send Queue Error，发送队列错误。
        QP_STATE_ERR   = 4'd6  // 致命错误/错误状态。
    } qp_state_e;

    // ---------------------------------------------------------------------
    // Completion 完成状态
    // ---------------------------------------------------------------------

    typedef enum logic [7:0] {
        CMPL_SUCCESS             = 8'h00, // Work Request 成功完成。
        CMPL_LOC_LEN_ERR         = 8'h01, // 本地长度或 SGE 长度违规。
        CMPL_LOC_QP_OP_ERR       = 8'h02, // 当前 QP 状态/类型不允许该操作。
        CMPL_LOC_PROT_ERR        = 8'h03, // 本地保护错误：lkey、PD 或访问权限失败。
        CMPL_WR_FLUSH_ERR        = 8'h04, // QP 错误/销毁过程中 Work Request 被 flush。
        CMPL_MW_BIND_ERR         = 8'h05, // Memory Window 绑定失败。
        CMPL_BAD_RESP_ERR        = 8'h06, // 响应包错误或出现非预期 opcode。
        CMPL_REM_ACCESS_ERR      = 8'h07, // 对端报告远端访问错误。
        CMPL_REM_OP_ERR          = 8'h08, // 对端报告远端操作错误。
        CMPL_RETRY_EXC_ERR       = 8'h09, // RC 重试次数耗尽。
        CMPL_RNR_RETRY_EXC_ERR   = 8'h0a, // RNR 重试次数耗尽。
        CMPL_CQ_OVERFLOW_ERR     = 8'h0b, // 检测到 CQ 溢出。
        CMPL_DMA_ERR             = 8'h0c, // PCIe/DMA 传输错误。
        CMPL_GENERAL_ERR         = 8'hff  // 未分类通用错误。
    } cmpl_status_e;

    // ---------------------------------------------------------------------
    // CSR mailbox 命令
    // ---------------------------------------------------------------------

    typedef enum logic [15:0] {
        CSR_CMD_NOP              = 16'h0000, // 空操作。
        CSR_CMD_QUERY_DEVICE     = 16'h0001, // 查询设备能力。
        CSR_CMD_ALLOC_PD         = 16'h0100, // 分配 Protection Domain。
        CSR_CMD_DEALLOC_PD       = 16'h0101, // 释放 Protection Domain。
        CSR_CMD_CREATE_CQ        = 16'h0200, // 创建 Completion Queue。
        CSR_CMD_DESTROY_CQ       = 16'h0201, // 销毁 Completion Queue。
        CSR_CMD_QUERY_CQ         = 16'h0202, // 查询 CQ 上下文。
        CSR_CMD_CREATE_QP        = 16'h0300, // 创建 Queue Pair。
        CSR_CMD_MODIFY_QP        = 16'h0301, // 修改 QP 属性/状态。
        CSR_CMD_QUERY_QP         = 16'h0302, // 查询 QP 上下文。
        CSR_CMD_DESTROY_QP       = 16'h0303, // 销毁 Queue Pair。
        CSR_CMD_REG_MR           = 16'h0400, // 注册 Memory Region。
        CSR_CMD_DEREG_MR         = 16'h0401, // 注销 Memory Region。
        CSR_CMD_BIND_MW          = 16'h0402, // 绑定 Memory Window。
        CSR_CMD_INVALIDATE_MW    = 16'h0403, // 使 Memory Window 失效。
        CSR_CMD_CREATE_AH        = 16'h0500, // 创建 Address Handle。
        CSR_CMD_DESTROY_AH       = 16'h0501, // 销毁 Address Handle。
        CSR_CMD_CONFIG_MSIX      = 16'h0600, // 配置 MSI-X 行为。
        CSR_CMD_CONFIG_VF        = 16'h0700, // 配置 SR-IOV VF 资源。
        CSR_CMD_CONFIG_DCQCN     = 16'h0800, // 配置拥塞控制。
        CSR_CMD_READ_STATS       = 16'h0900  // 读取统计计数器。
    } csr_cmd_e;

    // ---------------------------------------------------------------------
    // Doorbell 类型
    // ---------------------------------------------------------------------

    typedef enum logic [3:0] {
        DB_TYPE_NONE   = 4'd0, // 无效/无 Doorbell。
        DB_TYPE_SQ     = 4'd1, // Send Queue producer 更新。
        DB_TYPE_RQ     = 4'd2, // Receive Queue producer 更新。
        DB_TYPE_CQ_ARM = 4'd3  // Completion Queue arm/update。
    } doorbell_type_e;

    // ---------------------------------------------------------------------
    // 访问权限标志和 CQ 标志
    // ---------------------------------------------------------------------

    typedef enum logic [2:0] {
        MR_ACC_LOCAL_READ   = 3'd0, // 允许本地 DMA 从 MR 读取。
        MR_ACC_LOCAL_WRITE  = 3'd1, // 允许本地 DMA 写入 MR。
        MR_ACC_REMOTE_READ  = 3'd2, // 允许远端 RDMA Read 读取 MR。
        MR_ACC_REMOTE_WRITE = 3'd3, // 允许远端 RDMA Write 写入 MR。
        MR_ACC_REMOTE_ATOMIC= 3'd4, // 允许远端原子访问。
        MR_ACC_MW_BIND      = 3'd5  // 允许绑定 Memory Window。
    } mr_access_bit_e;

    typedef enum logic [3:0] {
        CQE_FLAG_NONE      = 4'h0, // 没有额外 CQE 标志。
        CQE_FLAG_SIGNALED  = 4'h1, // 由 signaled WR 生成的 completion。
        CQE_FLAG_SOLICITED = 4'h2, // solicited event completion。
        CQE_FLAG_IMM       = 4'h4, // immediate data 字段有效。
        CQE_FLAG_INV       = 4'h8  // invalidated rkey 字段有效。
    } cqe_flag_e;

    // ---------------------------------------------------------------------
    // Packed 数据结构
    // ---------------------------------------------------------------------

    typedef struct packed {
        rdma_opcode_e              opcode;          // Work Request 操作类型。
        logic [7:0]                flags;           // WR 标志，例如 signaled、solicited、fence、inline。
        logic [SGE_COUNT_W-1:0]    sge_count;       // 该 WQE 引用的 SGE 数量。
        logic [WR_ID_W-1:0]        wr_id;           // 应用传入的不透明 WR ID，会在 CQE 中返回。
        logic [ADDR_W-1:0]         local_va;        // 第一个本地虚拟地址或 inline SGE 基地址。
        logic [KEY_W-1:0]          lkey;            // 本地 MR 访问使用的 local key。
        logic [DMA_LEN_W-1:0]      length;          // 该 WR 请求的总字节数。
        logic [ADDR_W-1:0]         remote_va;       // RDMA Read/Write 使用的远端虚拟地址。
        logic [KEY_W-1:0]          rkey;            // 远端内存访问使用的 remote key。
        logic [31:0]               imm_data;        // Send/Write with immediate 使用的 immediate data。
        logic [KEY_W-1:0]          inv_rkey;        // Send with invalidate 需要失效的远端 key。
        logic [63:0]               compare_add;     // 原子 compare 值或 fetch-add 操作数。
        logic [63:0]               swap;            // 原子 swap 值。
    } wqe_t;

    typedef struct packed {
        cmpl_status_e              status;          // Completion 完成状态。
        rdma_opcode_e              opcode;          // 已完成 Work Request 的操作码。
        logic [7:0]                flags;           // CQE 标志，例如 immediate/solicited/invalidated。
        logic [WR_ID_W-1:0]        wr_id;           // 从 WQE 复制回来的应用 WR ID。
        logic [QP_ID_W-1:0]        qpn;             // 产生该 completion 的本地 QP。
        logic [QP_ID_W-1:0]        src_qpn;         // UD 接收 completion 中的源 QPN。
        logic [DMA_LEN_W-1:0]      byte_count;      // 已完成的字节数。
        logic [31:0]               imm_data;        // CQE_FLAG_IMM 置位时有效的 immediate data。
        logic [KEY_W-1:0]          inv_rkey;        // CQE_FLAG_INV 置位时有效的失效 rkey。
        logic [63:0]               timestamp;       // 用于性能分析/调试的设备时间戳。
        logic [31:0]               vendor_err;      // 设备私有错误详情。
    } cqe_t;

    typedef struct packed {
        logic                       valid;          // QP 上下文条目已分配。
        logic [VF_ID_W-1:0]         owner_func;     // 拥有该 QP 的 PF/VF function。
        logic [QP_ID_W-1:0]         qpn;            // 完整 QPN tag，用于防止低位别名命中。
        qp_type_e                   qp_type;        // RC、UD 或预留 QP 类型。
        qp_state_e                  state;          // 当前 QP 状态。
        logic [PD_ID_W-1:0]         pd_id;          // 与该 QP 关联的 Protection Domain。
        logic [CQ_ID_W-1:0]         send_cqn;       // 发送 completion 使用的 CQ。
        logic [CQ_ID_W-1:0]         recv_cqn;       // 接收 completion 使用的 CQ。
        logic [ADDR_W-1:0]          sq_base;        // Send Queue buffer 的主机地址。
        logic [ADDR_W-1:0]          rq_base;        // Receive Queue buffer 的主机地址。
        logic [QUEUE_DEPTH_W-1:0]   sq_depth;       // SQ 中 WQE 槽位数量。
        logic [QUEUE_DEPTH_W-1:0]   rq_depth;       // RQ 中 WQE 槽位数量。
        logic [QUEUE_IDX_W-1:0]     sq_producer;    // 软件写入的最新 SQ producer index。
        logic [QUEUE_IDX_W-1:0]     sq_consumer;    // 硬件下一次要消费的 SQ WQE index。
        logic [QUEUE_IDX_W-1:0]     rq_producer;    // 软件写入的最新 RQ producer index。
        logic [QUEUE_IDX_W-1:0]     rq_consumer;    // 硬件下一次要消费的 RQ WQE index。
        logic [QP_ID_W-1:0]         remote_qpn;     // RC 连接的对端 QPN。
        logic [PSN_W-1:0]           sq_psn;         // 下一个发送 PSN。
        logic [PSN_W-1:0]           rq_psn;         // 期望接收的 PSN。
        logic [PSN_W-1:0]           last_acked_psn; // 上一次已确认 PSN，用于 replay/ACK 跟踪。
        logic [7:0]                 retry_count;    // 剩余或配置的重试次数。
        logic [7:0]                 rnr_retry_count;// 剩余或配置的 RNR 重试次数。
        logic [15:0]                pkey;           // BTH 校验使用的 Partition Key。
        logic [QKEY_W-1:0]          qkey;           // DETH 校验使用的 UD Q_Key。
        logic [AH_ID_W-1:0]         ah_id;          // UD 发送路径默认使用的 Address Handle。
    } qp_context_t;

    typedef struct packed {
        logic                       valid;          // CQ 上下文条目已分配。
        logic [VF_ID_W-1:0]         owner_func;     // 拥有该 CQ 的 PF/VF function。
        logic [CQ_ID_W-1:0]         cqn;            // Completion Queue Number tag。
        logic [ADDR_W-1:0]          cq_base;        // CQ buffer 的主机地址。
        logic [QUEUE_DEPTH_W-1:0]   cq_depth;       // CQE 槽位数量。
        logic [QUEUE_IDX_W-1:0]     producer;       // 硬件 producer index。
        logic [QUEUE_IDX_W-1:0]     consumer;       // 硬件观察到的软件 consumer index。
        logic [CQ_VECTOR_W-1:0]     msix_vector;    // 与该 CQ 关联的 MSI-X vector。
        logic [15:0]                moderation_cnt; // 非零时每 N 个 completion 触发一次中断。
        logic [15:0]                moderation_timer;// 中断调节定时器，单位由具体实现定义。
        logic                       armed;          // CQ 通知已 arm。
        logic                       solicited_only; // 仅 solicited CQE 可以触发通知。
        logic                       overflow;       // 已检测到 CQ 溢出。
    } cq_context_t;

    typedef struct packed {
        logic                       valid;          // MR 表项有效。
        logic                       pending_dereg;  // 已请求注销，等待 refcount 清零。
        logic [VF_ID_W-1:0]         owner_func;     // 拥有该 MR 的 PF/VF function。
        logic [MR_ID_W-1:0]         mr_id;          // 驱动可见的 MR handle。
        logic [PD_ID_W-1:0]         pd_id;          // 与该 MR 关联的 Protection Domain。
        logic [KEY_W-1:0]           lkey;           // 本地 DMA 操作使用的 local key。
        logic [KEY_W-1:0]           rkey;           // 入站远端操作使用的 remote key。
        logic [ADDR_W-1:0]          va_base;        // 该 MR 覆盖的首个虚拟地址。
        logic [ADDR_W-1:0]          pa_base;        // 该 MR 段对应的首个物理/DMA 地址。
        logic [DMA_LEN_W-1:0]       length;         // 该 MR 表项覆盖的字节数。
        logic [PAGE_SHIFT_W-1:0]    page_shift;     // 页大小 log2(bytes)，例如 4 KiB 对应 12。
        logic [5:0]                 access_flags;   // 由 mr_access_bit_e 索引的访问权限位图。
        logic [15:0]                refcount;       // 正在进行的 DMA 引用数量。
    } mr_entry_t;

    typedef struct packed {
        logic                       valid;          // AH 表项有效。
        logic [VF_ID_W-1:0]         owner_func;     // 拥有该 AH 的 PF/VF function。
        logic [AH_ID_W-1:0]         ah_id;          // Address Handle 标识符。
        logic [PD_ID_W-1:0]         pd_id;          // 与该 AH 关联的 Protection Domain。
        logic [47:0]                dst_mac;        // 目标以太网 MAC 地址。
        logic [31:0]                dst_ipv4;       // 目标 IPv4 地址。
        logic [15:0]                udp_src_port;   // RoCEv2 流哈希使用的 UDP 源端口。
        logic [15:0]                udp_dst_port;   // UDP 目的端口，通常为 4791。
        logic [PKEY_W-1:0]          pkey;           // 放入 BTH 的 Partition Key。
        logic [QKEY_W-1:0]          qkey;           // UD DETH 中使用的 Q_Key。
        logic [7:0]                 traffic_class;  // IPv4 DSCP/ECN traffic class 元数据。
        logic [7:0]                 hop_limit;      // 类似 IPv4 TTL 的 hop limit。
        logic [2:0]                 service_level;  // 服务等级/优先级类别。
    } ah_entry_t;

    typedef struct packed {
        doorbell_type_e             db_type;        // SQ、RQ 或 CQ arm Doorbell 类型。
        logic [VF_ID_W-1:0]         func_id;        // 发起 Doorbell 的 PF/VF function。
        logic [QP_ID_W-1:0]         qpn;            // SQ/RQ Doorbell 的目标 QPN。
        logic [CQ_ID_W-1:0]         cqn;            // CQ arm Doorbell 的目标 CQN。
        logic [QUEUE_IDX_W-1:0]     producer_idx;   // 新的 SQ/RQ producer index。
        logic [QUEUE_IDX_W-1:0]     consumer_idx;   // CQ arm 使用的 consumer index 快照。
        logic                       solicited_only; // CQ arm 是否只对 solicited CQE 触发。
    } doorbell_t;

    typedef struct packed {
        csr_cmd_e                   cmd_id;         // Mailbox 命令操作码。
        logic [VF_ID_W-1:0]         func_id;        // 拥有该命令的 PF/VF function。
        logic [15:0]                seq;            // 驱动用于匹配响应的 sequence number。
        logic [15:0]                arg_len;        // 有效命令参数字节数。
        logic [31:0]                status;         // 命令完成状态/错误码。
    } csr_cmd_hdr_t;

endpackage : smartnic_pkg
