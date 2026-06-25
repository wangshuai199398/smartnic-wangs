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
    parameter int PCIE_TLP_DATA_W  = 256;  // PCIe TLP 流数据位宽，后续可按 FPGA IP 调整。
    parameter int PCIE_TLP_KEEP_W  = PCIE_TLP_DATA_W / 32; // TLP 流 dword 有效掩码位宽。
    parameter int PCIE_TLP_USER_W  = 32;   // TLP sideband/user 元数据位宽。
    parameter int PCIE_BAR_W       = 3;    // PCIe BAR 编号位宽，覆盖 BAR0 到 BAR5。
    parameter int PCIE_TAG_W       = 10;   // PCIe request tag 位宽，支持扩展 tag。
    parameter int PCIE_REQ_ID_W    = 16;   // Requester/Completer ID 位宽：bus/device/function。
    parameter int PCIE_CFG_ADDR_W  = 12;   // PCIe 配置空间 dword 地址位宽。
    parameter int PCIE_CFG_DATA_W  = 32;   // PCIe 配置空间读写数据位宽。
    parameter int PCIE_CFG_BE_W    = 4;    // PCIe 配置空间 byte enable 位宽。
    parameter int PCIE_TLP_LEN_W   = 16;   // TLP payload 长度位宽，单位由接口约定定义。
    parameter int PCIE_TC_W        = 3;    // PCIe Traffic Class 位宽。
    parameter int PCIE_ATTR_W      = 3;    // PCIe attributes 位宽。
    parameter int PCIE_BAR_OFFSET_W = 32;  // BAR 内 offset 位宽。
    parameter int PCIE_BAR_DATA_W   = 32;  // BAR 访问数据位宽，当前阶段按 dword 访问建模。
    parameter int PCIE_BAR_BE_W     = 4;   // BAR 访问 byte enable 位宽。

    parameter logic [15:0] SMARTNIC_VENDOR_ID    = 16'h1d0f; // 原型阶段使用的 Vendor ID，占位值。
    parameter logic [15:0] SMARTNIC_DEVICE_ID    = 16'h5a10; // RDMA SmartNIC 原型 Device ID，占位值。
    parameter logic [15:0] SMARTNIC_SUBSYS_ID    = 16'h0001; // 子系统 ID，占位值。
    parameter logic [15:0] SMARTNIC_SUBSYS_VENDOR_ID = SMARTNIC_VENDOR_ID; // 子系统 Vendor ID。
    parameter logic [7:0]  SMARTNIC_REVISION_ID  = 8'h01;   // 配置空间 revision ID。
    parameter logic [23:0] SMARTNIC_CLASS_CODE   = 24'h020000; // 网络控制器 class code。

    parameter int PCIE_BAR0_ID      = 0;     // BAR0：Doorbell aperture。
    parameter int PCIE_BAR2_ID      = 2;     // BAR2：CSR/MMIO 空间。
    parameter int PCIE_BAR4_ID      = 4;     // BAR4：MSI-X table/PBA 空间。
    parameter logic [31:0] PCIE_BAR0_RESET = 32'h0000_000c; // 64-bit prefetchable memory BAR 占位属性。
    parameter logic [31:0] PCIE_BAR2_RESET = 32'h0000_0000; // 32-bit memory BAR 占位属性。
    parameter logic [31:0] PCIE_BAR4_RESET = 32'h0000_0000; // 32-bit memory BAR 占位属性。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] PCIE_BAR0_SIZE = 32'h1000_0000; // BAR0 Doorbell aperture：256 MB。

    parameter logic [PCIE_BAR_OFFSET_W-1:0] DB_PAGE_SIZE = 32'h0000_1000; // 单个 QP/CQ Doorbell page 大小：4 KiB。
    parameter int DB_PAGE_SHIFT = 12; // Doorbell page offset 到资源编号的 shift。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] DB_SQ_OFFSET = 32'h0000_0000; // page 内 SQ Doorbell offset。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] DB_RQ_OFFSET = 32'h0000_0008; // page 内 RQ Doorbell offset。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] DB_CQ_ARM_OFFSET = 32'h0000_0010; // page 内 CQ arm Doorbell offset。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] DB_DOORBELL_STRIDE = 32'h0000_0008; // 当前阶段 Doorbell dword 间隔。
    parameter int DB_SEQUENCE_W = 8; // Doorbell sequence 位宽，用于调试/乱序检测预留。
    parameter int DB_FLAGS_W = 8; // Doorbell flags 位宽。
    parameter logic [DB_FLAGS_W-1:0] SQ_DB_FLAG_SIGNAL = 8'h01; // SQ Doorbell 请求 signaled completion 的提示位。
    parameter logic [DB_FLAGS_W-1:0] SQ_DB_FLAG_FENCE = 8'h02; // SQ Doorbell 携带 fence 语义的提示位。
    parameter logic [DB_FLAGS_W-1:0] SQ_DB_FLAGS_ALLOWED = SQ_DB_FLAG_SIGNAL | SQ_DB_FLAG_FENCE; // 当前阶段允许的软件 flags。
    parameter logic [DB_FLAGS_W-1:0] RQ_DB_FLAG_SOLICITED = 8'h01; // RQ Doorbell 提示后续接收 completion 可携带 solicited 语义。
    parameter logic [DB_FLAGS_W-1:0] RQ_DB_FLAGS_ALLOWED = RQ_DB_FLAG_SOLICITED; // 当前阶段允许的 RQ Doorbell flags。
    parameter logic [DB_FLAGS_W-1:0] CQ_ARM_DB_FLAG_SOLICITED_ONLY = 8'h01; // CQ arm 只允许 solicited CQE 触发通知。
    parameter logic [DB_FLAGS_W-1:0] CQ_ARM_DB_FLAGS_ALLOWED = CQ_ARM_DB_FLAG_SOLICITED_ONLY; // 当前阶段允许的 CQ arm flags。

    parameter logic [PCIE_BAR_OFFSET_W-1:0] PCIE_BAR2_SIZE = 32'h0001_0000; // BAR2 CSR space：64 KB。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] PCIE_BAR4_SIZE = 32'h0000_4000; // BAR4 MSI-X table/PBA：16 KB。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] PCIE_MSIX_TABLE_OFFSET = 32'h0000_0000; // MSI-X table 起始 offset。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] PCIE_MSIX_TABLE_SIZE = 32'h0000_0800; // MSI-X table 占位窗口大小。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] PCIE_MSIX_PBA_OFFSET = 32'h0000_0800; // MSI-X PBA 起始 offset。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] PCIE_MSIX_PBA_SIZE = 32'h0000_0800; // MSI-X PBA 占位窗口大小。
    parameter int PCIE_MSIX_VECTOR_COUNT = 8; // 原型阶段 MSI-X vector 数量。
    parameter int PCIE_MSIX_VECTOR_ID_W = 3; // 8 个 MSI-X vector 的索引位宽。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] PCIE_MSIX_ENTRY_SIZE = 32'h0000_0010; // MSI-X table entry 大小：16 字节。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] PCIE_MSIX_MODERATION_OFFSET = 32'h0000_1000; // 中断调节控制寄存器 offset。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] PCIE_MSIX_MOD_TIMER_OFFSET = 32'h0000_1004; // moderation_timer 寄存器 offset。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] PCIE_MSIX_MOD_COUNT_OFFSET = 32'h0000_1008; // moderation_count 寄存器 offset。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] PCIE_MSIX_MODERATION_SIZE = 32'h0000_0010; // MSI-X 调节寄存器窗口大小。
    parameter int PCIE_MSIX_CQ_VECTOR = 0; // CQ completion 默认使用的 vector。
    parameter int PCIE_MSIX_ADMIN_VECTOR = 1; // admin/mailbox 默认使用的 vector。
    parameter int PCIE_MSIX_ERROR_VECTOR = 2; // error event 默认使用的 vector。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] CSR_MAILBOX_BASE = 32'h0000_0100; // BAR2 mailbox 起始 offset。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] CSR_MAILBOX_SIZE = 32'h0000_0100; // BAR2 mailbox 窗口大小。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] CSR_MB_COMMAND_ID_OFFSET = 32'h0000_0100; // command_id 寄存器。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] CSR_MB_OWNER_FUNCTION_OFFSET = 32'h0000_0104; // owner_function 寄存器。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] CSR_MB_CONTROL_OFFSET = 32'h0000_0108; // go/done/busy/error 控制寄存器。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] CSR_MB_STATUS_OFFSET = 32'h0000_010c; // mailbox status 寄存器。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] CSR_MB_ERROR_CODE_OFFSET = 32'h0000_0110; // mailbox error_code 寄存器。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] CSR_MB_TIMEOUT_COUNTER_OFFSET = 32'h0000_0114; // timeout_counter 寄存器。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] CSR_MB_ARG0_OFFSET = 32'h0000_0120; // arg0 参数寄存器。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] CSR_MB_ARG1_OFFSET = 32'h0000_0124; // arg1 参数寄存器。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] CSR_MB_ARG2_OFFSET = 32'h0000_0128; // arg2 参数寄存器。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] CSR_MB_ARG3_OFFSET = 32'h0000_012c; // arg3 参数寄存器。
    parameter logic [31:0] CSR_MB_TIMEOUT_LIMIT = 32'd1024; // mailbox BUSY 状态最大等待周期。
    parameter logic [31:0] CSR_MB_MIN_BUSY_CYCLES = 32'd1; // 原型阶段命令最少 BUSY 周期。

    parameter int SRIOV_MAX_PF = 1; // 原型阶段只建模一个 PF。
    parameter int SRIOV_MAX_VF = 8; // 原型阶段最多建模 8 个 VF。
    parameter int SRIOV_FUNCTION_COUNT = SRIOV_MAX_PF + SRIOV_MAX_VF; // PF 与 VF 的 function 总数。
    parameter logic [VF_ID_W-1:0] SRIOV_PF_FUNCTION_ID = '0; // PF 使用 function_id 0。
    parameter logic [QP_ID_W-1:0] SRIOV_QP_WINDOW_SIZE = 24'd1024; // 每个 VF 默认 QP 资源窗口大小。
    parameter logic [CQ_ID_W-1:0] SRIOV_CQ_WINDOW_SIZE = 24'd1024; // 每个 VF 默认 CQ 资源窗口大小。
    parameter logic [MR_ID_W-1:0] SRIOV_MR_WINDOW_SIZE = 24'd1024; // 每个 VF 默认 MR 资源窗口大小。
    parameter logic [PCIE_BAR_OFFSET_W-1:0] SRIOV_DOORBELL_WINDOW_SIZE = 32'h0100_0000; // 每个 VF 默认 Doorbell aperture 大小。
    parameter logic [CQ_VECTOR_W-1:0] SRIOV_MSIX_VECTOR_WINDOW_SIZE = 12'd1; // 每个 VF 默认 MSI-X vector 配额。

    parameter logic [7:0] PCIE_CAP_ID_PM    = 8'h01; // Power Management capability ID。
    parameter logic [7:0] PCIE_CAP_ID_MSIX  = 8'h11; // MSI-X capability ID。
    parameter logic [7:0] PCIE_CAP_ID_PCIE  = 8'h10; // PCI Express capability ID。
    parameter logic [15:0] PCIE_EXT_CAP_ID_AER = 16'h0001; // AER extended capability ID。
    parameter logic [15:0] PCIE_EXT_CAP_ID_ATS = 16'h000f; // ATS extended capability ID。
    parameter logic [15:0] PCIE_EXT_CAP_ID_SRIOV = 16'h0010; // SR-IOV extended capability ID。

    parameter logic [7:0] PCIE_CAP_PTR_PCIE  = 8'h40; // PCIe capability 起始 byte offset。
    parameter logic [7:0] PCIE_CAP_PTR_MSIX  = 8'h60; // MSI-X capability 起始 byte offset。
    parameter logic [11:0] PCIE_EXT_CAP_PTR_AER = 12'h100; // AER extended capability 起始 byte offset。
    parameter logic [11:0] PCIE_EXT_CAP_PTR_ATS = 12'h140; // ATS extended capability 起始 byte offset。
    parameter logic [11:0] PCIE_EXT_CAP_PTR_SRIOV = 12'h180; // SR-IOV extended capability 起始 byte offset。

    parameter int WQE_BYTES       = 64;   // 硬件 WQE 大小，单位为字节。
    parameter int WQE_W           = WQE_BYTES * 8; // WQE packed 宽度：64 字节 / 512 bit。
    parameter int CQE_BYTES       = 64;   // 硬件 CQE 大小，单位为字节。
    parameter int CQE_W           = CQE_BYTES * 8; // CQE packed 宽度：64 字节 / 512 bit。
    parameter int MAX_SGE         = 256;  // 单个 Work Request 支持的最大 SGE 数量。
    parameter int DMA_SGE_COUNT_W = 9;    // SGE fetch 请求计数位宽，可表达 0..256。
    parameter int SGE_BYTES       = 32;   // DMA SGE descriptor 大小，单位为字节。
    parameter int SGE_W           = SGE_BYTES * 8; // DMA SGE descriptor packed 宽度。
    parameter int WQE_INLINE_SGE_COUNT = 2; // 7.2 阶段 WQE 内最多直接携带/派生的 inline SGE 数量。
    parameter int INLINE_DATA_BYTES = 32; // WQE inline payload 预留窗口大小。
    parameter int INLINE_DATA_W   = INLINE_DATA_BYTES * 8; // inline payload packed 宽度。
    parameter int DMA_HOST_READ_TAG_W = 16; // fetcher 发起 host read 使用的 tag 位宽。
    parameter int DMA_READ_TAG_W = 32; // payload host read path 使用的 tag 位宽。
    parameter int DMA_WRITE_TAG_W = 32; // payload host write path 使用的 tag 位宽。
    parameter int DMA_PAYLOAD_DATA_W = PCIE_TLP_DATA_W; // transport payload stream 数据位宽。
    parameter int DMA_PAYLOAD_KEEP_W = DMA_PAYLOAD_DATA_W / 8; // payload stream byte-enable/keep 位宽。
    parameter int DMA_MAX_READ_BYTES = DMA_PAYLOAD_DATA_W / 8; // 7.5 阶段单个 host read chunk 最大字节数。
    parameter int DMA_MAX_WRITE_BYTES = DMA_PAYLOAD_DATA_W / 8; // 7.6 阶段单个 host write beat 最大字节数。
    parameter int DMA_BYTE_OFFSET_W = DMA_LEN_W; // SGE traversal 输出的 WR 内字节偏移位宽。
    parameter int DMA_TOTAL_LEN_W = DMA_LEN_W + 1; // 总长度累计多 1 bit，用于检测 32-bit length 溢出。
    parameter int DMA_SPLIT_SUB_INDEX_W = 16; // 一个 protected segment 内 split segment 序号位宽。
    parameter int PAGE_4KB_BYTES = 4096; // 4KB 物理页边界大小，7.7 阶段用于 DMA segment split。
    parameter int PAGE_4KB_OFFSET_W = 12; // 4KB page offset 位宽。
    parameter int DMA_SPLIT_DEFAULT_MAX_BYTES = 4096; // max_dma_segment_bytes 为 0 时使用的默认限制。
    parameter int DMA_SPLIT_TIMEOUT_CYCLES = 1024; // split output backpressure 预留超时周期。
    parameter int MAX_DMA_ARB_SOURCES = 7; // 7.8 阶段建模的 DMA arbitration source 数量。
    parameter int DMA_ARB_SOURCE_ID_W = 3; // 7 个 source 的 source_id 位宽。
    parameter int DMA_ARB_PRIORITY_W = 4; // DMA arbitration priority 位宽。
    parameter int DMA_ARB_WEIGHT_W = 8; // Weighted round-robin weight/counter 位宽。
    parameter int DMA_ARB_PAYLOAD_W = 256; // 仲裁透传 payload/metadata 位宽。
    parameter int DMA_ARB_WAIT_COUNTER_W = 16; // starvation wait counter 位宽。
    parameter logic [DMA_ARB_WAIT_COUNTER_W-1:0] DMA_ARB_DEFAULT_STARVATION_THRESHOLD = 16'd64; // 默认 starvation guard 阈值。
    parameter int MAX_DMA_ERROR_SOURCES = 9; // 7.9 阶段统一汇聚的 DMA error source lane 数量。
    parameter int DMA_ERROR_SOURCE_ID_W = 4; // DMA error source ID 位宽，覆盖 dispatcher/fetch/MR/host/arbiter。
    parameter int SGE_TRAVERSAL_TIMEOUT_CYCLES = 1024; // 等待 SGE last 标志的超时周期。
    parameter int MAX_QP          = 1 << QP_ID_W; // 逻辑 QPN 空间大小。
    parameter int MAX_CQ          = 1 << CQ_ID_W; // 逻辑 CQN 空间大小。
    parameter int MAX_MR          = 1 << 14;      // 初始 MR 表规模目标：16K 条目。
    parameter int PMTU_BYTES      = 4096;         // 默认 PMTU 分段边界。
    parameter int QP_TABLE_DEPTH  = 1024;         // 原型阶段片上 QP context 表项数量。
    parameter int QP_TABLE_INDEX_W = 10;          // QP context 表 slot 索引位宽，覆盖 1024 项。
    parameter int CQ_TABLE_DEPTH  = 1024;         // 原型阶段片上 CQ context 表项数量。
    parameter int CQ_TABLE_INDEX_W = 10;          // CQ context 表 slot 索引位宽，覆盖 1024 项。
    parameter int MR_TABLE_DEPTH  = 1024;         // 原型阶段片上 MR 表项数量。
    parameter int MR_TABLE_INDEX_W = 10;          // MR 表 slot 索引位宽，覆盖 1024 项。
    parameter int AH_TABLE_DEPTH  = 256;          // 原型阶段片上 AH 表项数量。
    parameter int AH_TABLE_INDEX_W = 8;           // AH 表 slot 索引位宽，覆盖 256 项。
    parameter int MR_REFCOUNT_W   = 16;           // MR in-flight DMA 引用计数位宽。
    parameter int SG_ENTRY_BYTES  = 32;           // pinned SG entry 格式大小，单位为字节。
    parameter int SG_ENTRY_W      = SG_ENTRY_BYTES * 8; // pinned SG entry packed 宽度。
    parameter int MR_REG_MAX_SG_ENTRIES = 1;      // 6.2 阶段只支持单段/线性 SG list。
    parameter logic [5:0] MR_ACCESS_LOCAL_READ    = 6'b000001; // 本地 DMA read 权限 bit。
    parameter logic [5:0] MR_ACCESS_LOCAL_WRITE   = 6'b000010; // 本地 DMA write / Recv write 权限 bit。
    parameter logic [5:0] MR_ACCESS_REMOTE_READ   = 6'b000100; // 远端 RDMA Read 权限 bit。
    parameter logic [5:0] MR_ACCESS_REMOTE_WRITE  = 6'b001000; // 远端 RDMA Write 权限 bit。
    parameter logic [5:0] MR_ACCESS_REMOTE_ATOMIC = 6'b010000; // 远端 Atomic 权限 bit。
    parameter logic [5:0] MR_ACCESS_MW_BIND       = 6'b100000; // Memory Window bind 权限 bit。
    parameter logic [5:0] MR_ACCESS_FLAGS_ALLOWED = 6'h3f; // 当前定义的 MR access flags 位图。
    parameter int MR_DEREG_TIMEOUT_CYCLES = 1024; // deregistration 等待 refcount drain 的超时周期。

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
        RDMA_OP_SEND_WITH_INV        = 8'h09, // Send 操作，并使远端 key 失效。
        RDMA_OP_NOP                  = 8'hff  // 空 WQE；只推进 SQ consumer index。
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

    typedef enum logic [3:0] {
        QP_TABLE_STATUS_OK         = 4'd0, // QP 表访问成功。
        QP_TABLE_STATUS_MISS       = 4'd1, // 按 QPN 查找未命中。
        QP_TABLE_STATUS_PERMISSION = 4'd2, // function 与 owner_func 不匹配。
        QP_TABLE_STATUS_ALIAS      = 4'd3, // 发现同一个 QPN 会落入多个有效表项。
        QP_TABLE_STATUS_FULL       = 4'd4, // 新建 QP context 时没有空闲表项。
        QP_TABLE_STATUS_INVALID    = 4'd5  // 输入字段或上游 Doorbell 更新无效。
    } qp_table_status_e;

    typedef enum logic [3:0] {
        CQ_TABLE_STATUS_OK         = 4'd0, // CQ 表访问成功。
        CQ_TABLE_STATUS_MISS       = 4'd1, // 按 CQN 查找未命中。
        CQ_TABLE_STATUS_PERMISSION = 4'd2, // function 与 owner_func 不匹配。
        CQ_TABLE_STATUS_ALIAS      = 4'd3, // 发现同一个 CQN 会落入多个有效表项。
        CQ_TABLE_STATUS_FULL       = 4'd4, // 新建 CQ context 时没有空闲表项。
        CQ_TABLE_STATUS_INVALID    = 4'd5  // 输入字段或上游更新无效。
    } cq_table_status_e;

    typedef enum logic [3:0] {
        MR_TABLE_STATUS_OK         = 4'd0, // MR 表访问成功。
        MR_TABLE_STATUS_MISS       = 4'd1, // 按 lkey/rkey 查找未命中。
        MR_TABLE_STATUS_PERMISSION = 4'd2, // function 与 owner_function 不匹配。
        MR_TABLE_STATUS_ALIAS      = 4'd3, // lkey 或 rkey 在多个有效表项中重复。
        MR_TABLE_STATUS_FULL       = 4'd4, // 新建 MR entry 时没有空闲表项。
        MR_TABLE_STATUS_INVALID    = 4'd5, // 输入字段无效。
        MR_TABLE_STATUS_BOUNDS     = 4'd6, // VA/length 超出 MR 范围或地址加法溢出。
        MR_TABLE_STATUS_LENGTH     = 4'd7, // check_len 为 0 或 length 字段无效。
        MR_TABLE_STATUS_REF_OVER   = 4'd8, // refcount 增加时溢出。
        MR_TABLE_STATUS_REF_UNDER  = 4'd9, // refcount 减少时下溢。
        MR_TABLE_STATUS_PENDING    = 4'd10 // MR 正在注销，不允许新的 lookup/check。
    } mr_table_status_e;

    typedef enum logic [3:0] {
        MR_REG_STATE_IDLE          = 4'd0, // 等待 REGISTER_MR 请求。
        MR_REG_STATE_VALIDATE_REQ  = 4'd1, // 校验请求字段。
        MR_REG_STATE_ALLOC_ENTRY   = 4'd2, // 选择空闲 MR table slot。
        MR_REG_STATE_FETCH_SG      = 4'd3, // 发起 pinned SG entry fetch。
        MR_REG_STATE_VALIDATE_SG   = 4'd4, // 校验 SG entry。
        MR_REG_STATE_BUILD_ENTRY   = 4'd5, // 构造 mr_entry_t。
        MR_REG_STATE_WRITE_TABLE   = 4'd6, // 写入 MR table。
        MR_REG_STATE_RESPOND       = 4'd7, // 返回成功响应。
        MR_REG_STATE_ERROR         = 4'd8  // 返回错误响应。
    } mr_registration_state_e;

    typedef enum logic [15:0] {
        MR_REG_ERR_NONE            = 16'h0000, // 无错误。
        MR_REG_ERR_LENGTH          = 16'h0001, // 注册 length 为 0 或 SG length 不足。
        MR_REG_ERR_PAGE_SIZE       = 16'h0002, // page_size 不合法或与 SG entry 不匹配。
        MR_REG_ERR_VA_ALIGN        = 16'h0003, // virtual_base_addr 未按 page_size 对齐。
        MR_REG_ERR_SG_COUNT        = 16'h0004, // sg_entry_count 为 0。
        MR_REG_ERR_UNSUPPORTED_SG  = 16'h0005, // 当前阶段不支持多段 SG list。
        MR_REG_ERR_ACCESS_FLAGS    = 16'h0006, // access_flags 包含未知 bit。
        MR_REG_ERR_KEY             = 16'h0007, // lkey/rkey 为 0。
        MR_REG_ERR_FUNCTION        = 16'h0008, // owner function 未启用或不合法。
        MR_REG_ERR_TABLE_FULL      = 16'h0009, // MR table 没有空闲 entry。
        MR_REG_ERR_ALIAS           = 16'h000a, // lkey/rkey alias。
        MR_REG_ERR_SG_FETCH        = 16'h000b, // SG entry fetch 失败。
        MR_REG_ERR_PA_ALIGN        = 16'h000c, // physical_base_addr 未按 page_size 对齐。
        MR_REG_ERR_PA_OVERFLOW     = 16'h000d, // physical_base_addr + length 溢出。
        MR_REG_ERR_TABLE_WRITE     = 16'h000e  // MR table 写入返回其他错误。
    } mr_registration_error_e;

    typedef enum logic [3:0] {
        MR_DEREG_STATE_IDLE        = 4'd0, // 等待 DEREGISTER_MR 请求。
        MR_DEREG_STATE_LOOKUP      = 4'd1, // 通过 MR table read 查找 MR。
        MR_DEREG_STATE_CHECK       = 4'd2, // 检查 owner、PD、pending 状态。
        MR_DEREG_STATE_MARK_PENDING= 4'd3, // 写回 pending_deregister=1。
        MR_DEREG_STATE_WAIT_ZERO   = 4'd4, // 等待 refcount drain 到 0。
        MR_DEREG_STATE_CLEAR_ENTRY = 4'd5, // 清除 valid/refcount/access flags 等字段。
        MR_DEREG_STATE_RESPOND     = 4'd6, // 返回成功响应。
        MR_DEREG_STATE_ERROR       = 4'd7  // 返回错误响应。
    } mr_deregistration_state_e;

    typedef enum logic [15:0] {
        MR_DEREG_ERR_NONE          = 16'h0000, // 无错误。
        MR_DEREG_ERR_INVALID_KEY   = 16'h0001, // deregister key 为 0。
        MR_DEREG_ERR_LOOKUP_MISS   = 16'h0002, // MR lookup/read 未命中。
        MR_DEREG_ERR_PERMISSION    = 16'h0003, // owner_function 不匹配。
        MR_DEREG_ERR_PD_MISMATCH   = 16'h0004, // 请求 PD 与 MR entry PD 不匹配。
        MR_DEREG_ERR_PENDING       = 16'h0005, // MR 已经处于 pending_deregister。
        MR_DEREG_ERR_TIMEOUT       = 16'h0006, // 等待 refcount drain 超时。
        MR_DEREG_ERR_REFCOUNT      = 16'h0007, // refcount 非法状态。
        MR_DEREG_ERR_TABLE_WRITE   = 16'h0008  // MR table 写回失败。
    } mr_deregistration_error_e;

    typedef enum logic [3:0] {
        MR_OP_LOCAL_DMA_READ       = 4'd0, // 本地 DMA 读取 host buffer，例如 Send/RDMA Write payload read。
        MR_OP_LOCAL_DMA_WRITE      = 4'd1, // 本地 DMA 写 host buffer，例如 RDMA Read response 写入。
        MR_OP_LOCAL_RECV_WRITE     = 4'd2, // Recv path 将入站 Send payload 写入本地 Recv buffer。
        MR_OP_REMOTE_RDMA_READ     = 4'd3, // 对端 RDMA Read 读取本端内存。
        MR_OP_REMOTE_RDMA_WRITE    = 4'd4, // 对端 RDMA Write 写入本端内存。
        MR_OP_REMOTE_ATOMIC        = 4'd5, // 对端 atomic 操作，后续阶段检查权限。
        MR_OP_MW_BIND              = 4'd6  // Memory Window bind，方向/权限细节留给 6.7。
    } mr_operation_e;

    localparam mr_operation_e MR_OP_LOCAL_READ   = MR_OP_LOCAL_DMA_READ;    // 6.5 权限检查短别名。
    localparam mr_operation_e MR_OP_LOCAL_WRITE  = MR_OP_LOCAL_DMA_WRITE;   // 6.5 权限检查短别名。
    localparam mr_operation_e MR_OP_REMOTE_READ  = MR_OP_REMOTE_RDMA_READ;  // 6.5 权限检查短别名。
    localparam mr_operation_e MR_OP_REMOTE_WRITE = MR_OP_REMOTE_RDMA_WRITE; // 6.5 权限检查短别名。

    typedef enum logic [15:0] {
        MR_KEY_CHECK_ERR_NONE                = 16'h0000, // key 方向和 table check 均成功。
        MR_KEY_CHECK_ERR_INVALID_KEY         = 16'h0001, // key 为 0。
        MR_KEY_CHECK_ERR_LOCAL_KEY_REQUIRED  = 16'h0002, // 本地操作必须使用 lkey。
        MR_KEY_CHECK_ERR_REMOTE_KEY_REQUIRED = 16'h0003, // 远端操作必须使用 rkey。
        MR_KEY_CHECK_ERR_INVALID_OPERATION   = 16'h0004, // operation 未定义或当前阶段不支持。
        MR_KEY_CHECK_ERR_LOOKUP_MISS         = 16'h0005, // lkey/rkey lookup 未命中。
        MR_KEY_CHECK_ERR_PERMISSION          = 16'h0006, // owner_function 不匹配。
        MR_KEY_CHECK_ERR_PENDING             = 16'h0007, // MR 正在 pending_deregister。
        MR_KEY_CHECK_ERR_LENGTH              = 16'h0008, // 访问长度为 0 或 MR 长度非法。
        MR_KEY_CHECK_ERR_BOUNDS              = 16'h0009, // VA/len 超出 MR 范围。
        MR_KEY_CHECK_ERR_TABLE               = 16'h000a  // MR table 返回其他错误。
    } mr_key_check_error_e;

    typedef enum logic [15:0] {
        MR_ACCESS_ERR_NONE              = 16'h0000, // access_flags 和基础合法性检查成功。
        MR_ACCESS_ERR_INVALID_ENTRY     = 16'h0001, // MR entry 无效。
        MR_ACCESS_ERR_PENDING           = 16'h0002, // MR 正在 pending_deregister。
        MR_ACCESS_ERR_PERMISSION        = 16'h0003, // owner_function 不匹配。
        MR_ACCESS_ERR_LENGTH            = 16'h0004, // 访问长度为 0 或 MR 长度非法。
        MR_ACCESS_ERR_BOUNDS            = 16'h0005, // VA/len 超出 MR 范围。
        MR_ACCESS_ERR_ADDR_OVERFLOW     = 16'h0006, // 地址加法溢出。
        MR_ACCESS_ERR_ACCESS_DENIED     = 16'h0007, // operation 对应的 access flag 未置位。
        MR_ACCESS_ERR_UNKNOWN_OPERATION = 16'h0008, // operation 未定义。
        MR_ACCESS_ERR_MW_PARENT         = 16'h0009  // MW 权限超过 parent mask，完整逻辑留给 6.7。
    } mr_access_check_error_e;

    typedef enum logic [15:0] {
        MR_PD_CHECK_ERR_NONE              = 16'h0000, // PD 检查成功。
        MR_PD_CHECK_ERR_INVALID_ENTRY     = 16'h0001, // MR entry 无效。
        MR_PD_CHECK_ERR_PENDING           = 16'h0002, // MR 正在 pending_deregister。
        MR_PD_CHECK_ERR_PERMISSION        = 16'h0003, // owner_function 不匹配。
        MR_PD_CHECK_ERR_MISSING_QP_PD     = 16'h0004, // 调用方未提供有效 QP PD。
        MR_PD_CHECK_ERR_PD_MISMATCH       = 16'h0005, // QP PD 与 MR PD 不匹配。
        MR_PD_CHECK_ERR_INVALID_OPERATION = 16'h0006, // operation 未定义。
        MR_PD_CHECK_ERR_MW_PARENT_PD      = 16'h0007  // MW parent PD mismatch 预留。
    } mr_pd_check_error_e;

    typedef enum logic [4:0] {
        MW_STATE_IDLE                       = 5'd0,  // 等待 bind/unbind/QP error invalidate 请求。
        MW_STATE_LOOKUP_PARENT_MR           = 5'd1,  // 按 parent_lkey 读取父 MR。
        MW_STATE_VALIDATE_PARENT            = 5'd2,  // 校验父 MR valid/owner/PD/pending/MW。
        MW_STATE_VALIDATE_RANGE             = 5'd3,  // 校验 bind VA/length 落在父 MR 范围内。
        MW_STATE_VALIDATE_PERMISSION_SUBSET = 5'd4,  // 校验 MW 权限是父 MR 权限子集。
        MW_STATE_CHECK_ALIAS                = 5'd5,  // 按 mw_rkey 检查 key alias。
        MW_STATE_BUILD_MW_ENTRY             = 5'd6,  // 构造 Memory Window entry。
        MW_STATE_WRITE_MW_ENTRY             = 5'd7,  // 写入 Memory Window entry。
        MW_STATE_LOOKUP_MW                  = 5'd8,  // unbind 时按 mw_rkey 查找 MW。
        MW_STATE_CHECK_PERMISSION           = 5'd9,  // unbind 时检查 owner/PD/MW 类型。
        MW_STATE_MARK_INVALIDATING          = 5'd10, // 设置 pending_deregister/invalidating。
        MW_STATE_WAIT_REFCOUNT_ZERO         = 5'd11, // 等待 MW refcount drain。
        MW_STATE_CLEAR_MW_ENTRY             = 5'd12, // 清除 MW entry valid。
        MW_STATE_QP_SCAN                    = 5'd13, // QP error invalidation 扫描相关 MW。
        MW_STATE_RESPOND                    = 5'd14, // 返回响应。
        MW_STATE_ERROR                      = 5'd15  // 返回错误。
    } mw_state_e;

    typedef enum logic [15:0] {
        MW_ERR_NONE               = 16'h0000, // 无错误。
        MW_ERR_PARENT_MISS        = 16'h0001, // parent_lkey lookup miss。
        MW_ERR_PARENT_PENDING     = 16'h0002, // parent MR 正在注销。
        MW_ERR_PARENT_IS_MW       = 16'h0003, // 禁止 MW over MW。
        MW_ERR_RANGE              = 16'h0004, // bind 范围超出 parent MR 或地址溢出。
        MW_ERR_LENGTH             = 16'h0005, // bind length 为 0。
        MW_ERR_RKEY               = 16'h0006, // mw_rkey 为 0。
        MW_ERR_ALIAS              = 16'h0007, // mw_rkey alias。
        MW_ERR_PERMISSION_SUBSET  = 16'h0008, // MW 权限不是 parent MR 权限子集。
        MW_ERR_OWNER              = 16'h0009, // owner_function mismatch。
        MW_ERR_PD                 = 16'h000a, // PD mismatch。
        MW_ERR_MW_MISS            = 16'h000b, // unbind mw_rkey lookup miss。
        MW_ERR_NOT_MW             = 16'h000c, // unbind 目标不是 Memory Window。
        MW_ERR_TIMEOUT            = 16'h000d, // refcount drain 或 QP invalidation 超时。
        MW_ERR_TABLE              = 16'h000e, // MR table read/write 返回其他错误。
        MW_ERR_UNSUPPORTED_FLAGS  = 16'h000f  // 当前阶段不支持的 MW 权限位。
    } mw_error_e;

    // ---------------------------------------------------------------------
    // DMA descriptor / dispatcher
    // ---------------------------------------------------------------------

    typedef enum logic [3:0] {
        DMA_OP_SEND           = 4'd0, // Send payload 从 host memory 读出后交给 transport。
        DMA_OP_RECV           = 4'd1, // 入站 Send payload 写入本地 Recv buffer。
        DMA_OP_RDMA_WRITE     = 4'd2, // RDMA Write 本地 payload host read。
        DMA_OP_RDMA_READ_REQ  = 4'd3, // 本地发起 RDMA Read request，后续接 transport path。
        DMA_OP_RDMA_READ_RESP = 4'd4, // 收到 RDMA Read response 后 host write。
        DMA_OP_CQE_WRITE      = 4'd5, // 64-byte CQE 写入 host CQ buffer。
        DMA_OP_WQE_FETCH      = 4'd6, // SQ/RQ WQE fetch。
        DMA_OP_SGE_FETCH      = 4'd7, // 扩展 SGE list fetch。
        DMA_OP_NOP            = 4'd8, // 空 descriptor，只用于测试/保活。
        DMA_OP_ERROR          = 4'hf  // 错误 descriptor。
    } dma_opcode_e;

    typedef enum logic [2:0] {
        DMA_DIR_HOST_READ  = 3'd0, // 从 host memory 读 payload 或 descriptor。
        DMA_DIR_HOST_WRITE = 3'd1, // 向 host memory 写 payload。
        DMA_DIR_CQE_WRITE  = 3'd2, // 向 host CQ buffer 写 64-byte CQE。
        DMA_DIR_WQE_FETCH  = 3'd3, // 读取 WQE。
        DMA_DIR_SGE_FETCH  = 3'd4  // 读取扩展 SGE list。
    } dma_direction_e;

    typedef enum logic [3:0] {
        DMA_DISP_STATE_IDLE        = 4'd0, // 等待任一输入 source。
        DMA_DISP_STATE_SELECT_INPUT= 4'd1, // 已选择 source，准备进入校验。
        DMA_DISP_STATE_VALIDATE    = 4'd2, // 校验 opcode/length/owner_function。
        DMA_DISP_STATE_ROUTE       = 4'd3, // 根据 opcode 选择目标输出。
        DMA_DISP_STATE_WAIT_READY  = 4'd4, // 等待目标输出 ready，保持 descriptor 不丢。
        DMA_DISP_STATE_DONE        = 4'd5, // 本次 dispatch 完成。
        DMA_DISP_STATE_ERROR       = 4'd6  // 输出 dma_error。
    } dma_dispatch_state_e;

    typedef enum logic [15:0] {
        DMA_DISP_ERR_NONE          = 16'h0000, // 无错误。
        DMA_DISP_ERR_UNSUPPORTED   = 16'h0001, // opcode 当前不支持。
        DMA_DISP_ERR_LENGTH        = 16'h0002, // length 为 0，且 opcode 不是 NOP。
        DMA_DISP_ERR_FUNCTION      = 16'h0003, // owner_function 不在当前 PF/VF function 范围内。
        DMA_DISP_ERR_DIRECTION     = 16'h0004  // opcode 与 direction 不匹配。
    } dma_dispatch_error_e;

    typedef enum logic [3:0] {
        DMA_MR_STATE_IDLE          = 4'd0, // 等待 dma_segment。
        DMA_MR_STATE_ACCEPT        = 4'd1, // 锁存当前 segment 和 key 方向。
        DMA_MR_STATE_KEY_CHECK     = 4'd2, // 调用 mr_key_checker。
        DMA_MR_STATE_ACCESS_CHECK  = 4'd3, // 调用 mr_access_checker。
        DMA_MR_STATE_PD_CHECK      = 4'd4, // 调用 mr_pd_checker。
        DMA_MR_STATE_TRANSLATE     = 4'd5, // 锁存 VA->PA 结果和访问权限。
        DMA_MR_STATE_REFCOUNT_INC  = 4'd6, // 对命中的 MR/MW 做 refcount +1。
        DMA_MR_STATE_EMIT          = 4'd7, // 输出 protected segment。
        DMA_MR_STATE_ERROR         = 4'd8  // 输出错误响应。
    } dma_mr_integration_state_e;

    typedef enum logic [15:0] {
        DMA_MR_ERR_NONE              = 16'h0000, // 无错误。
        DMA_MR_ERR_INVALID_KEY       = 16'h0001, // key 为 0。
        DMA_MR_ERR_KEY_DIRECTION     = 16'h0002, // lkey/rkey 使用方向错误。
        DMA_MR_ERR_LOOKUP_MISS       = 16'h0003, // MR lookup 未命中。
        DMA_MR_ERR_PENDING           = 16'h0004, // MR/MW 正在注销或 invalidating。
        DMA_MR_ERR_ACCESS_DENIED     = 16'h0005, // access_flags 不允许该操作。
        DMA_MR_ERR_PD_MISMATCH       = 16'h0006, // QP PD 与 MR/MW PD 不匹配。
        DMA_MR_ERR_BOUNDS            = 16'h0007, // VA/length 超出 MR/MW 范围。
        DMA_MR_ERR_ADDR_OVERFLOW     = 16'h0008, // 地址加法溢出。
        DMA_MR_ERR_ZERO_LENGTH       = 16'h0009, // segment length 为 0。
        DMA_MR_ERR_PERMISSION        = 16'h000a, // owner_function 不匹配。
        DMA_MR_ERR_MW_INVALIDATING   = 16'h000b, // Memory Window 正在 invalidating。
        DMA_MR_ERR_REFCOUNT_OVERFLOW = 16'h000c, // refcount +1 溢出。
        DMA_MR_ERR_UNSUPPORTED_OP    = 16'h000d, // operation 映射不支持。
        DMA_MR_ERR_CHECKER           = 16'h000e  // checker 或 MR table 返回其他错误。
    } dma_mr_error_e;

    typedef enum logic [3:0] {
        DMA_HR_STATE_IDLE            = 4'd0, // 等待 protected segment。
        DMA_HR_STATE_ACCEPT_SEGMENT  = 4'd1, // 锁存 segment。
        DMA_HR_STATE_VALIDATE        = 4'd2, // 校验 operation、length、PA。
        DMA_HR_STATE_ISSUE_READ_REQ  = 4'd3, // 发出一个 PCIe/DMA read chunk。
        DMA_HR_STATE_WAIT_READ_RESP  = 4'd4, // 等待读响应。
        DMA_HR_STATE_EMIT_PAYLOAD    = 4'd5, // 输出 payload stream。
        DMA_HR_STATE_RELEASE_REF     = 4'd6, // 释放 MR/MW refcount token。
        DMA_HR_STATE_DONE            = 4'd7, // 当前 segment 完成。
        DMA_HR_STATE_ERROR           = 4'd8  // 输出错误/释放 refcount 后返回。
    } dma_host_read_state_e;

    typedef enum logic [15:0] {
        DMA_HR_ERR_NONE              = 16'h0000, // 无错误。
        DMA_HR_ERR_UNSUPPORTED_OP    = 16'h0001, // 非 host-read operation。
        DMA_HR_ERR_ZERO_LENGTH       = 16'h0002, // protected segment length 为 0。
        DMA_HR_ERR_ADDR_INVALID      = 16'h0003, // PA 为 0 或地址字段非法。
        DMA_HR_ERR_ADDR_OVERFLOW     = 16'h0004, // PA + length 溢出。
        DMA_HR_ERR_REQ_TIMEOUT       = 16'h0005, // read request 长时间无法发出。
        DMA_HR_ERR_RESP_ERROR        = 16'h0006, // PCIe/DMA read response 报错。
        DMA_HR_ERR_TAG_MISMATCH      = 16'h0007, // response tag 与当前请求不匹配。
        DMA_HR_ERR_LEN_MISMATCH      = 16'h0008, // response len 与当前 chunk 不匹配。
        DMA_HR_ERR_PAYLOAD_STALL     = 16'h0009, // payload ready 长时间不响应。
        DMA_HR_ERR_REF_RELEASE       = 16'h000a  // refcount release 返回错误，当前阶段预留。
    } dma_host_read_error_e;

    typedef struct packed {
        logic [15:0]                desc_id;          // 关联 descriptor ID。
        logic [DMA_SGE_COUNT_W-1:0] segment_index;    // 关联 segment index。
        logic [6:0]                 chunk_index;      // segment 内 read chunk 序号。
    } dma_read_tag_t;

    typedef enum logic [3:0] {
        DMA_HW_STATE_IDLE            = 4'd0, // 等待 protected segment。
        DMA_HW_STATE_ACCEPT_SEGMENT  = 4'd1, // 锁存 protected segment。
        DMA_HW_STATE_WAIT_PAYLOAD    = 4'd2, // 等待 transport/RQ payload。
        DMA_HW_STATE_VALIDATE_WRITE  = 4'd3, // 校验 payload 与 segment 匹配和范围。
        DMA_HW_STATE_ISSUE_WRITE_REQ = 4'd4, // 发出一个 PCIe/DMA write request。
        DMA_HW_STATE_WAIT_WRITE_CPL  = 4'd5, // 等待 write completion。
        DMA_HW_STATE_EMIT_DONE       = 4'd6, // 输出 write_done。
        DMA_HW_STATE_RELEASE_REF     = 4'd7, // 释放 MR/MW refcount token。
        DMA_HW_STATE_DONE            = 4'd8, // 当前 segment 完成。
        DMA_HW_STATE_ERROR           = 4'd9  // 输出错误/释放 refcount 后返回。
    } dma_host_write_state_e;

    typedef enum logic [15:0] {
        DMA_HW_ERR_NONE              = 16'h0000, // 无错误。
        DMA_HW_ERR_UNSUPPORTED_OP    = 16'h0001, // 非 host-write operation。
        DMA_HW_ERR_ZERO_SEGMENT_LEN  = 16'h0002, // protected segment length 为 0。
        DMA_HW_ERR_ZERO_PAYLOAD_LEN  = 16'h0003, // payload length 为 0。
        DMA_HW_ERR_PAYLOAD_MISMATCH  = 16'h0004, // payload desc_id/qpn/owner/operation 不匹配。
        DMA_HW_ERR_BOUNDS            = 16'h0005, // payload 超出 protected segment 范围。
        DMA_HW_ERR_ADDR_OVERFLOW     = 16'h0006, // write 地址加法溢出。
        DMA_HW_ERR_CPL_ERROR         = 16'h0007, // PCIe/DMA write completion 报错。
        DMA_HW_ERR_TAG_MISMATCH      = 16'h0008, // completion tag 与当前请求不匹配。
        DMA_HW_ERR_REQ_TIMEOUT       = 16'h0009, // write request 长时间无法发出。
        DMA_HW_ERR_PAYLOAD_ERROR     = 16'h000a, // 上游 payload 已携带错误。
        DMA_HW_ERR_REF_RELEASE       = 16'h000b  // refcount release 返回错误，当前阶段预留。
    } dma_host_write_error_e;

    typedef struct packed {
        logic [15:0]                desc_id;          // 关联 descriptor ID。
        logic [DMA_SGE_COUNT_W-1:0] segment_index;    // 关联 segment index。
        logic [6:0]                 beat_index;       // segment 内 write beat 序号。
    } dma_write_tag_t;

    typedef enum logic [3:0] {
        DMA_SPLIT_STATE_IDLE          = 4'd0, // 等待 protected segment。
        DMA_SPLIT_STATE_ACCEPT        = 4'd1, // 锁存 protected segment。
        DMA_SPLIT_STATE_VALIDATE_CFG  = 4'd2, // 校验 length、PMTU、地址范围和配置。
        DMA_SPLIT_STATE_CALC_PAGE     = 4'd3, // 计算当前 PA 到 4KB 页边界的剩余字节。
        DMA_SPLIT_STATE_CALC_LEN      = 4'd4, // 根据 remaining/PMTU/page/max 计算 split_len。
        DMA_SPLIT_STATE_EMIT          = 4'd5, // 输出一个 split segment。
        DMA_SPLIT_STATE_UPDATE        = 4'd6, // 更新 remaining/emitted/sub_index。
        DMA_SPLIT_STATE_DONE          = 4'd7, // 当前 protected segment 全部拆分完成。
        DMA_SPLIT_STATE_ERROR         = 4'd8  // 输出错误 split segment 后返回。
    } dma_segment_split_state_e;

    typedef enum logic [15:0] {
        DMA_SPLIT_ERR_NONE            = 16'h0000, // 无错误。
        DMA_SPLIT_ERR_ZERO_LENGTH     = 16'h0001, // protected_segment_len 为 0。
        DMA_SPLIT_ERR_PMTU_CONFIG     = 16'h0002, // enable_pmtu_split 时 pmtu_bytes 非法。
        DMA_SPLIT_ERR_MAX_CONFIG      = 16'h0003, // max_dma_segment_bytes 配置非法。
        DMA_SPLIT_ERR_PA_OVERFLOW     = 16'h0004, // PA + length 溢出。
        DMA_SPLIT_ERR_VA_OVERFLOW     = 16'h0005, // VA + length 溢出。
        DMA_SPLIT_ERR_ZERO_SPLIT      = 16'h0006, // 计算出的 split_len 为 0。
        DMA_SPLIT_ERR_SUB_INDEX_OVER  = 16'h0007, // split sub_index 溢出。
        DMA_SPLIT_ERR_OUTPUT_TIMEOUT  = 16'h0008  // split_segment_ready 长时间不响应，当前阶段预留。
    } dma_segment_split_error_e;

    typedef struct packed {
        logic [15:0]                         desc_id;          // 来源 descriptor ID。
        logic [QP_ID_W-1:0]                  qpn;              // segment 所属 QPN。
        logic [VF_ID_W-1:0]                  owner_function;   // 所属 PF/VF function。
        logic [PD_ID_W-1:0]                  pd_id;            // 已校验 PD。
        mr_operation_e                       operation;        // 已校验 operation。
        logic [DMA_SGE_COUNT_W-1:0]          segment_index;    // 原 protected segment index。
        logic [DMA_SPLIT_SUB_INDEX_W-1:0]    sub_index;        // 当前 protected segment 内 split 序号。
        logic [ADDR_W-1:0]                   va;               // 当前 split 的 VA。
        logic [ADDR_W-1:0]                   pa;               // 当前 split 的 PA。
        logic [DMA_LEN_W-1:0]                len;              // 当前 split 长度。
        logic [DMA_BYTE_OFFSET_W-1:0]        byte_offset;      // WR payload 内偏移。
        logic                                is_segment_last;  // 是否为当前 protected segment 的最后一个 split。
        logic                                is_wqe_last;      // 是否同时为 WQE 的最后一个 split。
        mr_ref_token_t                       mr_refcount_token;// 原 protected segment 的 MR/MW refcount token。
        logic [15:0]                         flags;            // flags 透传。
        dma_segment_split_error_e            error_code;       // split 错误码，成功为 NONE。
    } split_segment_t;

    typedef enum logic [1:0] {
        DMA_ARB_POLICY_FIXED_PRIORITY = 2'd0, // 固定优先级：CQE > RQ/RDMA read response > SQ/RDMA write > fetch。
        DMA_ARB_POLICY_ROUND_ROBIN    = 2'd1, // 从 last_grant_source 后一个 source 开始轮转。
        DMA_ARB_POLICY_WEIGHTED_RR    = 2'd2, // 按每个 source 的 weight 连续服务。
        DMA_ARB_POLICY_STRICT_GUARD   = 2'd3  // 严格优先级，但 starvation source 可临时提升。
    } dma_arb_policy_e;

    typedef enum logic [3:0] {
        DMA_ARB_STATE_IDLE            = 4'd0, // 等待任意 source valid。
        DMA_ARB_STATE_COLLECT         = 4'd1, // 采样当前 valid/metadata。
        DMA_ARB_STATE_SELECT_POLICY   = 4'd2, // 根据配置选择 fixed/RR/WRR/guard。
        DMA_ARB_STATE_SELECT_SOURCE   = 4'd3, // 选择 winning source。
        DMA_ARB_STATE_HOLD_GRANT      = 4'd4, // 保持 grant，等待下游 ready。
        DMA_ARB_STATE_UPDATE_FAIRNESS = 4'd5, // 更新 last_grant、weight 和 wait counters。
        DMA_ARB_STATE_DONE            = 4'd6, // 本次 grant 完成。
        DMA_ARB_STATE_ERROR           = 4'd7  // 策略或内部状态错误。
    } dma_arb_state_e;

    typedef enum logic [DMA_ARB_SOURCE_ID_W-1:0] {
        DMA_SRC_SQ_HOST_READ          = 3'd0, // SQ Send host read。
        DMA_SRC_RQ_HOST_WRITE         = 3'd1, // RQ Recv host write。
        DMA_SRC_RDMA_WRITE_HOST_READ  = 3'd2, // RDMA Write payload host read。
        DMA_SRC_RDMA_READ_RESP_WRITE  = 3'd3, // RDMA Read response host write。
        DMA_SRC_CQE_WRITE             = 3'd4, // CQE host memory write。
        DMA_SRC_WQE_FETCH             = 3'd5, // WQE fetch。
        DMA_SRC_SGE_FETCH             = 3'd6  // SGE fetch。
    } dma_source_id_e;

    typedef enum logic [3:0] {
        DMA_ARB_ERR_NONE              = 4'd0, // 无错误。
        DMA_ARB_ERR_NO_VALID          = 4'd1, // 没有可 grant 的 source。
        DMA_ARB_ERR_INVALID_POLICY    = 4'd2, // 未知 arbitration policy。
        DMA_ARB_ERR_INVALID_SOURCE    = 4'd3  // 选出的 source_id 越界。
    } dma_arb_error_e;

    typedef struct packed {
        dma_source_id_e             source_id;       // 请求来源。
        logic [QP_ID_W-1:0]         qpn;             // 请求关联 QPN。
        logic [VF_ID_W-1:0]         owner_function;  // 请求所属 function。
        logic [15:0]                desc_id;         // descriptor ID，后续错误/完成路径使用。
        mr_operation_e              operation;       // MR/DMA operation。
        dma_direction_e             direction;       // host read/write/fetch/CQE write 方向。
        logic [DMA_LEN_W-1:0]       len;             // 请求长度。
        logic [DMA_ARB_PRIORITY_W-1:0] priority;     // source 内部优先级。
        logic [DMA_ARB_WEIGHT_W-1:0] weight;         // WRR weight，0 表示 disabled。
        logic [DMA_ARB_PAYLOAD_W-1:0] payload;       // 透传 metadata/payload。
    } dma_arb_req_t;

    typedef struct packed {
        dma_source_id_e             source_id;       // grant 来源。
        logic [QP_ID_W-1:0]         qpn;             // grant 关联 QPN。
        logic [VF_ID_W-1:0]         owner_function;  // grant 所属 function。
        logic [15:0]                desc_id;         // descriptor ID。
        mr_operation_e              operation;       // operation。
        dma_direction_e             direction;       // 方向。
        logic [DMA_LEN_W-1:0]       len;             // 长度。
        logic [DMA_ARB_PAYLOAD_W-1:0] payload;       // 透传 metadata/payload。
        dma_arb_policy_e            policy_used;     // 本次 grant 使用的 policy。
    } dma_arb_grant_t;

    typedef enum logic [DMA_ERROR_SOURCE_ID_W-1:0] {
        DMA_ERR_SRC_DISPATCHER      = 4'd0, // dma_descriptor_dispatcher 报告 descriptor/opcode 错误。
        DMA_ERR_SRC_WQE_FETCH       = 4'd1, // dma_wqe_sge_fetcher 的 WQE fetch/decode 错误。
        DMA_ERR_SRC_SGE_FETCH       = 4'd2, // dma_wqe_sge_fetcher 的 extended SGE fetch 错误。
        DMA_ERR_SRC_SGE_TRAVERSAL   = 4'd3, // dma_sge_traversal 的长度/重叠/索引错误。
        DMA_ERR_SRC_MR_INTEGRATION  = 4'd4, // dma_mr_integration 的 key/权限/PD/地址错误。
        DMA_ERR_SRC_SEGMENT_SPLIT   = 4'd5, // dma_segment_splitter 的 PMTU/4KB 分段错误。
        DMA_ERR_SRC_HOST_READ       = 4'd6, // dma_host_read_path 的 PCIe read/payload 错误。
        DMA_ERR_SRC_HOST_WRITE      = 4'd7, // dma_host_write_path 的 PCIe write/payload 错误。
        DMA_ERR_SRC_ARBITER         = 4'd8  // dma_arbiter 的 malformed request 或策略错误。
    } dma_error_source_e;

    typedef enum logic [15:0] {
        DMA_ERR_NONE                = 16'h0000, // 无错误。
        DMA_ERR_MR_LOOKUP_MISS      = 16'h0001, // MR/MW lookup miss。
        DMA_ERR_KEY_DIRECTION       = 16'h0002, // lkey/rkey 使用方向错误。
        DMA_ERR_ACCESS_DENIED       = 16'h0003, // access_flags 或 owner_function 拒绝访问。
        DMA_ERR_PD_MISMATCH         = 16'h0004, // QP PD 与 MR/MW PD 不匹配。
        DMA_ERR_BOUNDS              = 16'h0005, // VA/PA/length 越界或 bounds check 失败。
        DMA_ERR_SGE_LENGTH          = 16'h0006, // SGE total length underrun/overrun。
        DMA_ERR_SGE_OVERLAP         = 16'h0007, // SGE 虚拟地址范围重叠。
        DMA_ERR_WQE_FETCH           = 16'h0008, // WQE fetch 或 decode 失败。
        DMA_ERR_SGE_FETCH           = 16'h0009, // extended SGE fetch 失败。
        DMA_ERR_UNSUPPORTED_OPCODE  = 16'h000a, // WQE 或 descriptor opcode 不受支持。
        DMA_ERR_PCIE_READ           = 16'h000b, // PCIe/DMA read response 报错。
        DMA_ERR_PCIE_WRITE          = 16'h000c, // PCIe/DMA write completion 报错。
        DMA_ERR_CQ_OVERFLOW         = 16'h000d, // CQ full/overflow。
        DMA_ERR_ARB_MALFORMED       = 16'h000e, // arbitration/descriptor metadata malformed。
        DMA_ERR_TIMEOUT             = 16'h000f, // 等待 ready/response 超时。
        DMA_ERR_GENERAL             = 16'h00ff  // 未分类 DMA 错误。
    } dma_error_code_e;

    typedef enum logic [3:0] {
        DMA_ERR_PROP_STATE_IDLE        = 4'd0, // 等待任一 DMA error source。
        DMA_ERR_PROP_STATE_SELECT      = 4'd1, // 按 fatal/保护/host/fetch/split/arbiter 优先级选择。
        DMA_ERR_PROP_STATE_CAPTURE     = 4'd2, // 锁存被选中的 error event。
        DMA_ERR_PROP_STATE_MAP_STATUS  = 4'd3, // 将 DMA error code 映射为 completion status。
        DMA_ERR_PROP_STATE_EMIT_CMPL   = 4'd4, // 输出 completion error event。
        DMA_ERR_PROP_STATE_EMIT_QP_ERR = 4'd5, // fatal 错误额外输出 QP error request。
        DMA_ERR_PROP_STATE_DONE        = 4'd6, // 当前错误处理完成。
        DMA_ERR_PROP_STATE_ERROR       = 4'd7  // 内部状态异常。
    } dma_error_propagation_state_e;

    typedef struct packed {
        dma_error_source_e          source_id;       // 报错子模块来源。
        logic [15:0]                desc_id;         // descriptor ID，用于 debug 和 completion 关联。
        logic [QP_ID_W-1:0]         qpn;             // 错误关联 QPN。
        logic [CQ_ID_W-1:0]         cqn;             // 错误 completion 目标 CQN；未知时为 0。
        logic [VF_ID_W-1:0]         owner_function;  // 错误所属 PF/VF function。
        logic [PD_ID_W-1:0]         pd_id;           // 错误关联 PD。
        mr_operation_e              operation;       // 报错时正在执行的 MR/DMA operation。
        dma_direction_e             direction;       // 报错 DMA 方向。
        logic [DMA_SGE_COUNT_W-1:0] segment_index;   // 报错 segment index。
        logic [DMA_BYTE_OFFSET_W-1:0] byte_offset;   // WR 内报错字节偏移。
        dma_error_code_e            dma_error_code;  // 统一 DMA error code。
        cmpl_status_e               original_status; // 上游若已有 completion status，可透传或覆盖。
        logic                       fatal;           // 1 表示需要请求 QP 进入 error cleanup。
        logic                       retryable;       // 1 表示后续 retry engine 可以考虑重试，当前阶段只透传语义。
        logic [WR_ID_W-1:0]         wr_id;           // 原始 WR ID；未知时为 0。
        rdma_opcode_e               opcode;          // 原始 RDMA/WQE opcode；未知时可为 NOP。
        logic [DMA_LEN_W-1:0]       byte_len;        // 已处理或报错相关 byte_len。
        logic                       solicited;       // 错误 completion 是否按 solicited 语义通知。
    } dma_error_event_t;

    typedef rdma_opcode_e wqe_opcode_e; // WQE opcode 与 RDMA Work Request opcode 共用编码。

    typedef enum logic [1:0] {
        QUEUE_TYPE_SQ = 2'd0, // Send Queue WQE。
        QUEUE_TYPE_RQ = 2'd1  // Receive Queue WQE。
    } queue_type_e;

    typedef enum logic [2:0] {
        WQE_FETCH_STATE_IDLE       = 3'd0, // 等待 WQE fetch 请求。
        WQE_FETCH_STATE_CALC_ADDR  = 3'd1, // 计算 WQE host 地址。
        WQE_FETCH_STATE_ISSUE_READ = 3'd2, // 发起 WQE host read。
        WQE_FETCH_STATE_WAIT_RESP  = 3'd3, // 等待 WQE read response。
        WQE_FETCH_STATE_DECODE     = 3'd4, // 解码 WQE 字段。
        WQE_FETCH_STATE_RESPOND    = 3'd5, // 输出 WQE fetch response。
        WQE_FETCH_STATE_ERROR      = 3'd6  // 输出 WQE fetch error。
    } wqe_fetch_state_e;

    typedef enum logic [3:0] {
        SGE_FETCH_STATE_IDLE        = 4'd0, // 等待 SGE fetch 请求。
        SGE_FETCH_STATE_VALIDATE    = 4'd1, // 校验 SGE count/start index。
        SGE_FETCH_STATE_CALC_ADDR   = 4'd2, // 计算当前 SGE 地址。
        SGE_FETCH_STATE_ISSUE_READ  = 4'd3, // 发起当前 SGE host read。
        SGE_FETCH_STATE_WAIT_RESP   = 4'd4, // 等待当前 SGE response。
        SGE_FETCH_STATE_DECODE      = 4'd5, // 解码 SGE entry。
        SGE_FETCH_STATE_EMIT        = 4'd6, // 输出当前 SGE entry。
        SGE_FETCH_STATE_NEXT        = 4'd7, // 推进到下一个 SGE。
        SGE_FETCH_STATE_DONE        = 4'd8, // 输出 list done。
        SGE_FETCH_STATE_ERROR       = 4'd9  // 输出 SGE fetch error。
    } sge_fetch_state_e;

    typedef enum logic [15:0] {
        WQE_FETCH_ERR_NONE          = 16'h0000, // 无错误。
        WQE_FETCH_ERR_STRIDE_ZERO   = 16'h0001, // WQE stride 为 0。
        WQE_FETCH_ERR_ADDR_OVERFLOW = 16'h0002, // WQE 地址计算溢出。
        WQE_FETCH_ERR_HOST_READ     = 16'h0003, // host read response 报错。
        WQE_FETCH_ERR_OPCODE        = 16'h0004, // WQE opcode 不支持。
        WQE_FETCH_ERR_MALFORMED     = 16'h0005  // WQE 字段组合非法。
    } wqe_fetch_error_e;

    typedef enum logic [15:0] {
        SGE_FETCH_ERR_NONE          = 16'h0000, // 无错误。
        SGE_FETCH_ERR_COUNT_ZERO    = 16'h0001, // SGE fetch count 为 0。
        SGE_FETCH_ERR_TOO_MANY      = 16'h0002, // SGE count 超过 256。
        SGE_FETCH_ERR_ADDR_OVERFLOW = 16'h0003, // SGE 地址计算溢出。
        SGE_FETCH_ERR_HOST_READ     = 16'h0004  // host read response 报错。
    } sge_fetch_error_e;

    typedef enum logic [1:0] {
        WQE_FETCH_STATUS_OK     = 2'd0, // WQE fetch 成功。
        WQE_FETCH_STATUS_ERROR  = 2'd1  // WQE fetch 失败。
    } wqe_fetch_status_e;

    typedef enum logic [1:0] {
        SGE_FETCH_STATUS_OK     = 2'd0, // SGE fetch 成功。
        SGE_FETCH_STATUS_ERROR  = 2'd1  // SGE fetch 失败。
    } sge_fetch_status_e;

    parameter logic [7:0] WQE_FLAG_INLINE_DATA = 8'h04; // WQE flags 中表示 inline data 存在的 bit。
    parameter logic [7:0] WQE_FLAG_EXT_SGE     = 8'h08; // WQE flags 中表示使用 extended SGE list 的 bit。

    typedef enum logic [3:0] {
        SGE_TRAV_STATE_IDLE             = 4'd0,  // 等待新的 SGE stream。
        SGE_TRAV_STATE_ACCEPT_SGE       = 4'd1,  // 锁存当前 SGE 字段。
        SGE_TRAV_STATE_CHECK_ZERO_LEN   = 4'd2,  // 检查 SGE length 是否为 0。
        SGE_TRAV_STATE_CHECK_ADDR       = 4'd3,  // 检查 addr + length 是否溢出。
        SGE_TRAV_STATE_CHECK_INDEX      = 4'd4,  // 检查 SGE index 是否单调递增且不超过 255。
        SGE_TRAV_STATE_CHECK_OVERLAP    = 4'd5,  // 与已接受 SGE 范围比较，检查重叠。
        SGE_TRAV_STATE_EMIT_SEGMENT     = 4'd6,  // 输出规范化 DMA segment。
        SGE_TRAV_STATE_UPDATE_ACCOUNT   = 4'd7,  // 更新累计长度、byte_offset 和 seen range。
        SGE_TRAV_STATE_CHECK_TOTAL      = 4'd8,  // last SGE 后检查累计长度是否等于 expected_total_len。
        SGE_TRAV_STATE_DONE             = 4'd9,  // 当前 SGE list 完成。
        SGE_TRAV_STATE_ERROR            = 4'd10  // 输出 traversal error。
    } sge_traversal_state_e;

    typedef enum logic [15:0] {
        SGE_TRAV_ERR_NONE            = 16'h0000, // 无错误。
        SGE_TRAV_ERR_ZERO_LENGTH     = 16'h0001, // SGE length 为 0，当前阶段拒绝。
        SGE_TRAV_ERR_LENGTH_UNDERRUN = 16'h0002, // last 到来时累计长度小于 expected_total_len。
        SGE_TRAV_ERR_LENGTH_OVERRUN  = 16'h0003, // 累计长度超过 expected_total_len。
        SGE_TRAV_ERR_TOTAL_OVERFLOW  = 16'h0004, // 总长度累计发生 32-bit 溢出。
        SGE_TRAV_ERR_ADDR_OVERFLOW   = 16'h0005, // SGE addr + length 溢出。
        SGE_TRAV_ERR_OVERLAP         = 16'h0006, // 当前 SGE 范围与之前 SGE 范围重叠。
        SGE_TRAV_ERR_INDEX_ORDER     = 16'h0007, // SGE index 非单调递增或重复。
        SGE_TRAV_ERR_INDEX_RANGE     = 16'h0008, // SGE index 超过 255。
        SGE_TRAV_ERR_MISSING_LAST    = 16'h0009, // 已开始 list，但 last 长时间未到。
        SGE_TRAV_ERR_EXPECTED_LEN    = 16'h000a  // expected_total_len 为 0 或 inline length 不匹配。
    } sge_traversal_error_e;

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

    typedef enum logic [1:0] {
        CMPL_EVENT_SQ      = 2'd0, // SQ/send-side completion event。
        CMPL_EVENT_RQ      = 2'd1, // RQ/receive-side completion event。
        CMPL_EVENT_CLEANUP = 2'd2, // QP destroy/error cleanup 产生的 flushed completion。
        CMPL_EVENT_ERROR   = 2'd3  // 数据通路或控制路径报告的错误 completion。
    } completion_event_type_e;

    typedef enum logic [2:0] {
        CMPL_SRC_SQ        = 3'd0, // 事件来自 SQ engine。
        CMPL_SRC_RQ        = 3'd1, // 事件来自 RQ engine。
        CMPL_SRC_CLEANUP   = 3'd2, // 事件来自 QP cleanup manager。
        CMPL_SRC_DMA       = 3'd3, // 事件来自 DMA engine。
        CMPL_SRC_TRANSPORT = 3'd4, // 事件来自 RoCEv2 transport。
        CMPL_SRC_ERROR     = 3'd5  // 事件来自错误汇聚路径。
    } completion_source_e;

    typedef enum logic [15:0] {
        CQE_SYNDROME_NONE        = 16'h0000, // CQE 无额外错误 syndrome。
        CQE_SYNDROME_CQ_LOOKUP   = 16'h0001, // CQN 查找失败或 CQ 无效。
        CQE_SYNDROME_PERMISSION  = 16'h0002, // completion event function 与 CQ owner 不匹配。
        CQE_SYNDROME_FLUSH       = 16'h0003, // QP cleanup 产生的 WR_FLUSH_ERR。
        CQE_SYNDROME_SOURCE_ERR  = 16'h0004, // 上游 SQ/RQ/DMA/transport 报告错误。
        CQE_SYNDROME_BAD_EVENT   = 16'h0005  // completion event 类型或字段不受支持。
    } cqe_syndrome_e;

    typedef enum logic [2:0] {
        CMPL_ENG_STATE_IDLE      = 3'd0, // 等待 completion event。
        CMPL_ENG_STATE_LOOKUP_CQ = 3'd1, // 向 CQ context table 发起 CQN lookup。
        CMPL_ENG_STATE_WAIT_CQ   = 3'd2, // 等待 CQ lookup 响应。
        CMPL_ENG_STATE_FORMAT    = 3'd3, // 根据 event 和 lookup 结果格式化 64-byte CQE。
        CMPL_ENG_STATE_WRITE     = 3'd4  // 向后续 CQE write path 输出 CQE write request。
    } completion_engine_state_e;

    typedef enum logic [15:0] {
        CMPL_ENG_ERR_NONE        = 16'h0000, // 无错误。
        CMPL_ENG_ERR_CQ_MISS     = 16'h0001, // CQN lookup miss 或 CQ context invalid。
        CMPL_ENG_ERR_PERMISSION  = 16'h0002, // owner_function 与 CQ owner 不匹配。
        CMPL_ENG_ERR_CQ_ALIAS    = 16'h0003, // CQ table 返回 CQN alias。
        CMPL_ENG_ERR_BAD_EVENT   = 16'h0004  // event 类型或字段非法。
    } completion_engine_error_e;

    typedef enum logic [3:0] {
        CQE_WR_STATE_IDLE        = 4'd0, // 等待 completion_engine 的 CQE write request。
        CQE_WR_STATE_LOOKUP_CQ   = 4'd1, // 查询 CQ context。
        CQE_WR_STATE_CHECK_SPACE = 4'd2, // 检查 CQ context、owner、depth 和 overflow 预留状态。
        CQE_WR_STATE_CALC_ADDR   = 4'd3, // 计算 CQE host buffer 地址和下一 producer index。
        CQE_WR_STATE_ISSUE_WRITE = 4'd4, // 发出 64-byte DMA/PCIe memory write 请求。
        CQE_WR_STATE_UPDATE_PI   = 4'd5, // 输出 CQ producer index 更新请求。
        CQE_WR_STATE_DONE        = 4'd6, // 本次 CQE 写入流程完成。
        CQE_WR_STATE_ERROR       = 4'd7  // 本次 CQE 写入流程失败。
    } cqe_write_path_state_e;

    typedef enum logic [15:0] {
        CQE_WR_ERR_NONE          = 16'h0000, // 无错误。
        CQE_WR_ERR_CQ_MISS       = 16'h0001, // CQ lookup miss 或 CQ context invalid。
        CQE_WR_ERR_PERMISSION    = 16'h0002, // owner_function 与 CQ owner 不匹配。
        CQE_WR_ERR_CQ_ALIAS      = 16'h0003, // CQ table 返回 CQN alias。
        CQE_WR_ERR_DEPTH_ZERO    = 16'h0004, // CQ depth 为 0。
        CQE_WR_ERR_ADDR_ALIGN    = 16'h0005, // CQE 写入地址不是 64-byte aligned。
        CQE_WR_ERR_OVERFLOW      = 16'h0006, // CQ context 已标记 overflow，完整处理留给 5.4。
        CQE_WR_ERR_DMA_BACKPRESSURE = 16'h0007 // DMA write 长时间不 ready 的错误预留。
    } cqe_write_path_error_e;

    typedef enum logic [15:0] {
        CQ_INDEX_ERR_NONE        = 16'h0000, // CQ index 计算成功。
        CQ_INDEX_ERR_DEPTH_ZERO  = 16'h0001, // CQ depth 为 0。
        CQ_INDEX_ERR_PROD_RANGE  = 16'h0002, // producer_index 超过 cq_depth - 1。
        CQ_INDEX_ERR_CONS_RANGE  = 16'h0003, // consumer_index 超过 cq_depth - 1。
        CQ_INDEX_ERR_ARM_RANGE   = 16'h0004, // CQ arm 提交的新 consumer index 越界。
        CQ_INDEX_ERR_OVERFLOW    = 16'h0005  // CQ full 时仍提交 CQE write commit。
    } cq_index_error_e;

    typedef enum logic [3:0] {
        CQ_NOTIFY_STATE_IDLE       = 4'd0, // 等待 CQE commit 或 moderation timer tick。
        CQ_NOTIFY_STATE_LOOKUP_CQ  = 4'd1, // 查询 CQ context。
        CQ_NOTIFY_STATE_CHECK_ARM  = 4'd2, // 检查 armed/polling/error immediate 语义。
        CQ_NOTIFY_STATE_CHECK_SOL  = 4'd3, // 检查 solicited_only 语义。
        CQ_NOTIFY_STATE_UPDATE_MOD = 4'd4, // 更新 moderation counter/timer 状态。
        CQ_NOTIFY_STATE_WAIT_TIMER = 4'd5, // 已有 pending completion，等待 timer tick。
        CQ_NOTIFY_STATE_ISSUE_MSIX = 4'd6, // 输出 MSI-X request。
        CQ_NOTIFY_STATE_CLEAR_ARM  = 4'd7, // 输出清 armed/moderation 更新。
        CQ_NOTIFY_STATE_DONE       = 4'd8, // 本次通知流程完成。
        CQ_NOTIFY_STATE_ERROR      = 4'd9  // 通知流程失败。
    } cq_notification_state_e;

    typedef enum logic [3:0] {
        CQ_NOTIFY_REASON_COMPLETION = 4'd0, // 普通 completion 触发通知。
        CQ_NOTIFY_REASON_SOLICITED  = 4'd1, // solicited completion 触发通知。
        CQ_NOTIFY_REASON_MOD_COUNT  = 4'd2, // moderation count 达到阈值。
        CQ_NOTIFY_REASON_MOD_TIMER  = 4'd3, // moderation timer 到期。
        CQ_NOTIFY_REASON_ERROR      = 4'd4  // 错误 completion 立即通知。
    } cq_notification_reason_e;

    typedef enum logic [15:0] {
        CQ_NOTIFY_ERR_NONE          = 16'h0000, // 无错误。
        CQ_NOTIFY_ERR_CQ_MISS       = 16'h0001, // CQ lookup miss 或 CQ context invalid。
        CQ_NOTIFY_ERR_PERMISSION    = 16'h0002, // owner_function 与 CQ owner 不匹配。
        CQ_NOTIFY_ERR_VECTOR        = 16'h0003, // CQ context 中 MSI-X vector 非法。
        CQ_NOTIFY_ERR_MODERATION    = 16'h0004  // moderation 配置非法或不一致。
    } cq_notification_error_e;

    parameter logic [15:0] CQE_FMT_FLAG_HAS_IMM   = 16'h0001; // CQE 携带 immediate data。
    parameter logic [15:0] CQE_FMT_FLAG_SOLICITED = 16'h0002; // CQE 是 solicited event。
    parameter logic [15:0] CQE_FMT_FLAG_ERROR     = 16'h0004; // CQE status 表示错误。
    parameter logic [15:0] CQE_FMT_FLAG_FLUSH     = 16'h0008; // CQE 来自 cleanup flush。
    parameter logic [15:0] CQE_FMT_FLAG_RECV      = 16'h0010; // CQE 描述 receive-side completion。
    parameter logic [15:0] CQE_FMT_FLAG_SEND      = 16'h0020; // CQE 描述 send-side completion。
    parameter logic [ADDR_W-1:0] CQE_ADDR_ALIGN_MASK = ADDR_W'(CQE_BYTES - 1); // CQE 写入地址 64B 对齐掩码。
    parameter int CQE_DMA_BE_W = CQE_BYTES; // 64-byte CQE memory write 的 byte enable 位宽。
    parameter logic CQ_RESERVED_SLOT_ENABLE = 1'b1; // CQ full 判断采用 reserved-one-entry 方案。

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
        CSR_CMD_QP_TO_ERROR      = 16'h0304, // 将 Queue Pair 切入 ERR 状态。
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

    typedef enum logic [2:0] {
        CSR_MB_STATE_IDLE  = 3'd0, // 等待软件写 command_id 和参数。
        CSR_MB_STATE_GO    = 3'd1, // 软件写 go=1，命令刚被提交。
        CSR_MB_STATE_BUSY  = 3'd2, // 硬件已接受命令，正在处理。
        CSR_MB_STATE_DONE  = 3'd3, // 命令完成，done=1。
        CSR_MB_STATE_ERROR = 3'd4  // 非法命令、超时或非法访问。
    } csr_mailbox_state_e;

    typedef enum logic [7:0] {
        CSR_MB_STATUS_IDLE    = 8'h00, // mailbox 空闲。
        CSR_MB_STATUS_BUSY    = 8'h01, // mailbox 正在处理命令。
        CSR_MB_STATUS_SUCCESS = 8'h02, // 命令成功完成。
        CSR_MB_STATUS_FAILED  = 8'h03  // 命令失败。
    } csr_mailbox_status_e;

    typedef enum logic [15:0] {
        CSR_MB_ERR_NONE        = 16'h0000, // 无错误。
        CSR_MB_ERR_INVALID_CMD = 16'h0001, // command_id 不受当前阶段支持。
        CSR_MB_ERR_TIMEOUT     = 16'h0002, // 命令 BUSY 时间超过 timeout limit。
        CSR_MB_ERR_BUSY        = 16'h0003, // mailbox 忙时收到新的 go。
        CSR_MB_ERR_BAD_OFFSET  = 16'h0004  // CSR mailbox offset 不受支持。
    } csr_mailbox_error_e;

    // ---------------------------------------------------------------------
    // QP lifecycle 命令状态
    // ---------------------------------------------------------------------

    typedef enum logic [2:0] {
        QP_LC_STATE_IDLE    = 3'd0, // 等待 admin/CSR 命令。
        QP_LC_STATE_LOOKUP  = 3'd1, // 访问 QP context table，确认目标 QPN 是否存在。
        QP_LC_STATE_EXECUTE = 3'd2, // 根据命令构造下一步操作或响应。
        QP_LC_STATE_UPDATE  = 3'd3, // 将 create/modify/destroy/error 结果写回 QP 表。
        QP_LC_STATE_DONE    = 3'd4, // 命令成功完成，等待上游接收响应。
        QP_LC_STATE_ERROR   = 3'd5, // 命令失败，等待上游接收错误响应。
        QP_LC_STATE_CLEANUP = 3'd6  // 等待 QP cleanup manager 完成 destroy/error cleanup。
    } qp_lifecycle_state_e;

    typedef enum logic [7:0] {
        QP_LC_STATUS_IDLE    = 8'h00, // lifecycle manager 空闲。
        QP_LC_STATUS_BUSY    = 8'h01, // 命令处理中。
        QP_LC_STATUS_SUCCESS = 8'h02, // 命令成功。
        QP_LC_STATUS_FAILED  = 8'h03  // 命令失败。
    } qp_lifecycle_status_e;

    typedef enum logic [15:0] {
        QP_LC_ERR_NONE          = 16'h0000, // 无错误。
        QP_LC_ERR_INVALID_CMD   = 16'h0001, // 不支持的 QP lifecycle 命令。
        QP_LC_ERR_NOT_FOUND     = 16'h0002, // 目标 QPN 不存在。
        QP_LC_ERR_DUPLICATE_QPN = 16'h0003, // CREATE_QP 发现 QPN 已存在。
        QP_LC_ERR_PERMISSION    = 16'h0004, // owner_function 不匹配。
        QP_LC_ERR_TABLE_FULL    = 16'h0005, // QP context table 没有空闲表项。
        QP_LC_ERR_INVALID_OWNER = 16'h0006, // owner_function 不是合法 PF/VF。
        QP_LC_ERR_BAD_STATE     = 16'h0007, // 初始状态或状态字段不受当前阶段接受。
        QP_LC_ERR_TABLE_ERROR   = 16'h0008, // QP context table 返回未分类错误。
        QP_LC_ERR_STATE_TRANSITION = 16'h0009, // QP 状态迁移不合法。
        QP_LC_ERR_MISSING_ATTR  = 16'h000a  // 状态迁移缺少必需属性。
    } qp_lifecycle_error_e;

    typedef enum logic [15:0] {
        QP_STATE_VAL_ERR_NONE       = 16'h0000, // 状态迁移校验通过。
        QP_STATE_VAL_ERR_TRANSITION = 16'h0009, // 当前状态到目标状态不允许。
        QP_STATE_VAL_ERR_MISSING_ATTR = 16'h000a, // 目标状态迁移缺少必需属性。
        QP_STATE_VAL_ERR_QP_TYPE    = 16'h000b  // 当前 QP type 不受该迁移规则支持。
    } qp_state_validate_error_e;

    typedef enum logic [3:0] {
        SQ_ENG_STATE_IDLE       = 4'd0, // 等待 Doorbell/scheduler 输入。
        SQ_ENG_STATE_LOOKUP_QP  = 4'd1, // 读取 QP context。
        SQ_ENG_STATE_CHECK_STATE= 4'd2, // 检查 QP state 和 SQ 是否非空。
        SQ_ENG_STATE_FETCH_WQE  = 4'd3, // 发起并等待 WQE fetch。
        SQ_ENG_STATE_DECODE_WQE = 4'd4, // 解码 WQE opcode。
        SQ_ENG_STATE_DISPATCH   = 4'd5, // 分发到 DMA/transport/local invalidate/NOP。
        SQ_ENG_STATE_UPDATE_CI  = 4'd6, // 更新 SQ consumer index。
        SQ_ENG_STATE_ERROR      = 4'd7  // 输出错误/completion 请求。
    } sq_engine_state_e;

    typedef enum logic [3:0] {
        RQ_ENG_STATE_IDLE            = 4'd0, // 等待 transport RX 入站 Send。
        RQ_ENG_STATE_LOOKUP_QP       = 4'd1, // 读取 QP context。
        RQ_ENG_STATE_CHECK_STATE     = 4'd2, // 检查 QP state 是否允许接收。
        RQ_ENG_STATE_CHECK_RQ_AVAILABLE = 4'd3, // 检查 RQ 是否有 Recv WQE。
        RQ_ENG_STATE_FETCH_RECV_WQE  = 4'd4, // 发起并等待 Recv WQE fetch。
        RQ_ENG_STATE_DECODE_RECV_WQE = 4'd5, // 解码 Recv WQE buffer/length/lkey。
        RQ_ENG_STATE_DISPATCH_DMA_WRITE = 4'd6, // 分发 DMA write 请求。
        RQ_ENG_STATE_UPDATE_CI       = 4'd7, // 更新 RQ consumer index。
        RQ_ENG_STATE_COMPLETE        = 4'd8, // 生成 receive completion 请求。
        RQ_ENG_STATE_ERROR           = 4'd9  // 输出错误/RNR 请求。
    } rq_engine_state_e;

    typedef enum logic [15:0] {
        SQ_ENG_ERR_NONE             = 16'h0000, // 无错误。
        SQ_ENG_ERR_LOOKUP_MISS      = 16'h0001, // QPN lookup/read 未命中。
        SQ_ENG_ERR_PERMISSION       = 16'h0002, // owner_function 不匹配。
        SQ_ENG_ERR_BAD_STATE        = 16'h0003, // 当前 QP state 不允许处理 SQ WQE。
        SQ_ENG_ERR_UNSUPPORTED_OPCODE = 16'h0004, // WQE opcode 当前阶段不支持。
        SQ_ENG_ERR_FETCH            = 16'h0005, // WQE fetch response 报错。
        SQ_ENG_ERR_QUEUE_INDEX      = 16'h0006, // SQ depth/index 不合法。
        SQ_ENG_ERR_DISABLED         = 16'h0007  // SQ engine 未使能。
    } sq_engine_error_e;

    typedef enum logic [15:0] {
        RQ_ENG_ERR_NONE             = 16'h0000, // 无错误。
        RQ_ENG_ERR_LOOKUP_MISS      = 16'h0001, // QPN lookup/read 未命中。
        RQ_ENG_ERR_PERMISSION       = 16'h0002, // owner_function 不匹配。
        RQ_ENG_ERR_BAD_STATE        = 16'h0003, // 当前 QP state 不允许接收 Send。
        RQ_ENG_ERR_RNR              = 16'h0004, // RQ 为空，没有可用 Recv WQE。
        RQ_ENG_ERR_FETCH            = 16'h0005, // Recv WQE fetch response 报错。
        RQ_ENG_ERR_LOCAL_LEN        = 16'h0006, // 入站 payload 长度大于 Recv buffer 长度。
        RQ_ENG_ERR_DMA              = 16'h0007, // DMA write dispatch/response 报错。
        RQ_ENG_ERR_QUEUE_INDEX      = 16'h0008, // RQ depth/index 不合法。
        RQ_ENG_ERR_DISABLED         = 16'h0009  // RQ engine 未使能。
    } rq_engine_error_e;

    typedef enum logic [3:0] {
        QP_CLEAN_STATE_IDLE          = 4'd0, // 等待 destroy/error cleanup 请求。
        QP_CLEAN_STATE_LOCK_QP       = 4'd1, // 读取并锁定目标 QP context。
        QP_CLEAN_STATE_BLOCK_DB      = 4'd2, // 通知 Doorbell path 阻止新的 SQ/RQ/CQ arm 更新。
        QP_CLEAN_STATE_QUIESCE       = 4'd3, // 等待 SQ/RQ/DMA/transport in-flight work 归零。
        QP_CLEAN_STATE_FLUSH_SQ      = 4'd4, // 为未消费 SQ WQE 生成 flushed completion。
        QP_CLEAN_STATE_FLUSH_RQ      = 4'd5, // 为未消费 RQ WQE 生成 flushed receive completion/indication。
        QP_CLEAN_STATE_UPDATE_CTX    = 4'd6, // 写回 destroy 或 ERR context。
        QP_CLEAN_STATE_DONE          = 4'd7, // cleanup 成功完成。
        QP_CLEAN_STATE_ERROR         = 4'd8  // cleanup 失败。
    } qp_cleanup_state_e;

    typedef enum logic [1:0] {
        QP_CLEAN_REASON_NONE         = 2'd0, // 无 cleanup 请求。
        QP_CLEAN_REASON_DESTROY      = 2'd1, // DESTROY_QP 触发的资源释放。
        QP_CLEAN_REASON_ERROR        = 2'd2  // QP_TO_ERROR 或数据通路错误触发的错误清理。
    } qp_cleanup_reason_e;

    typedef enum logic [15:0] {
        QP_CLEAN_ERR_NONE            = 16'h0000, // 无错误。
        QP_CLEAN_ERR_LOOKUP_MISS     = 16'h0001, // QPN 不存在或已被销毁。
        QP_CLEAN_ERR_PERMISSION      = 16'h0002, // cleanup 请求 function 不是 QP owner。
        QP_CLEAN_ERR_TIMEOUT         = 16'h0003, // 等待 in-flight work 或 completion ready 超时。
        QP_CLEAN_ERR_BACKPRESSURE    = 16'h0004, // completion path 长时间 backpressure。
        QP_CLEAN_ERR_REPEATED_REQ    = 16'h0005, // cleanup 忙时收到重复请求。
        QP_CLEAN_ERR_ALREADY_ERR     = 16'h0006, // error cleanup 请求的 QP 已在 ERR 状态。
        QP_CLEAN_ERR_ALREADY_DESTROYED = 16'h0007, // destroy 请求的 QP 已无有效 context。
        QP_CLEAN_ERR_TABLE_ERROR     = 16'h0008  // QP context table 返回未分类错误。
    } qp_cleanup_error_e;

    parameter int QP_CLEANUP_TIMEOUT_CYCLES = 1024; // 原型阶段 cleanup 等待超时默认周期数。

    parameter logic [31:0] QP_MOD_MASK_STATE       = 32'h0000_0001; // MODIFY_QP 更新 QP state。
    parameter logic [31:0] QP_MOD_MASK_TYPE        = 32'h0000_0002; // MODIFY_QP 更新 QP type。
    parameter logic [31:0] QP_MOD_MASK_PD          = 32'h0000_0004; // MODIFY_QP 更新 Protection Domain。
    parameter logic [31:0] QP_MOD_MASK_CQ          = 32'h0000_0008; // MODIFY_QP 更新 send/recv CQ。
    parameter logic [31:0] QP_MOD_MASK_QUEUE_ADDR  = 32'h0000_0010; // MODIFY_QP 更新 SQ/RQ base address。
    parameter logic [31:0] QP_MOD_MASK_QUEUE_DEPTH = 32'h0000_0020; // MODIFY_QP 更新 SQ/RQ depth。
    parameter logic [31:0] QP_MOD_MASK_QUEUE_INDEX = 32'h0000_0040; // MODIFY_QP 更新 SQ/RQ producer/consumer index。
    parameter logic [31:0] QP_MOD_MASK_PSN         = 32'h0000_0080; // MODIFY_QP 更新 PSN 状态。
    parameter logic [31:0] QP_MOD_MASK_RETRY       = 32'h0000_0100; // MODIFY_QP 更新 retry/RNR retry。
    parameter logic [31:0] QP_MOD_MASK_REMOTE_QPN  = 32'h0000_0200; // MODIFY_QP 更新 remote QPN。
    parameter logic [31:0] QP_MOD_MASK_KEYS        = 32'h0000_0400; // MODIFY_QP 更新 pkey/qkey。
    parameter logic [31:0] QP_MOD_MASK_AH          = 32'h0000_0800; // MODIFY_QP 更新 AH。
    parameter logic [31:0] QP_MOD_MASK_ERROR       = 32'h0000_1000; // MODIFY_QP 更新 error_state/error_code。

    parameter logic [31:0] QP_ATTR_MASK_PD          = 32'h0000_0001; // 状态迁移需要 PD。
    parameter logic [31:0] QP_ATTR_MASK_CQ          = 32'h0000_0002; // 状态迁移需要 send/recv CQ。
    parameter logic [31:0] QP_ATTR_MASK_QUEUE_ADDR  = 32'h0000_0004; // 状态迁移需要 SQ/RQ base address。
    parameter logic [31:0] QP_ATTR_MASK_QUEUE_DEPTH = 32'h0000_0008; // 状态迁移需要 SQ/RQ depth。
    parameter logic [31:0] QP_ATTR_MASK_REMOTE_QPN  = 32'h0000_0010; // RC RTR 需要 remote QPN。
    parameter logic [31:0] QP_ATTR_MASK_RQ_PSN      = 32'h0000_0020; // RTR 需要接收/expected PSN。
    parameter logic [31:0] QP_ATTR_MASK_AH          = 32'h0000_0040; // RTR 需要路径/Address Handle 信息。
    parameter logic [31:0] QP_ATTR_MASK_SQ_PSN      = 32'h0000_0080; // RTS 需要发送 PSN。
    parameter logic [31:0] QP_ATTR_MASK_RETRY       = 32'h0000_0100; // RC RTS 需要 retry/RNR retry 参数。

    // ---------------------------------------------------------------------
    // Doorbell 类型
    // ---------------------------------------------------------------------

    typedef enum logic [3:0] {
        DB_TYPE_NONE   = 4'd0, // 无效/无 Doorbell。
        DB_TYPE_SQ     = 4'd1, // Send Queue producer 更新。
        DB_TYPE_RQ     = 4'd2, // Receive Queue producer 更新。
        DB_TYPE_CQ_ARM = 4'd3  // Completion Queue arm/update。
    } doorbell_type_e;

    typedef enum logic [3:0] {
        DB_ERR_NONE          = 4'd0, // Doorbell 处理成功。
        DB_ERR_NOT_SQ        = 4'd1, // 当前模块只接受 SQ Doorbell。
        DB_ERR_ACCESS_DENIED = 4'd2, // PF/VF 权限检查失败。
        DB_ERR_INVALID_QPN   = 4'd3, // QPN 不存在或 QP 上下文无效。
        DB_ERR_BAD_PAYLOAD   = 4'd4, // payload 格式或 flags 不合法。
        DB_ERR_NOT_RQ        = 4'd5, // 当前模块只接受 RQ Doorbell。
        DB_ERR_NOT_CQ_ARM    = 4'd6, // 当前模块只接受 CQ arm Doorbell。
        DB_ERR_INVALID_CQN   = 4'd7  // CQN 不存在或 CQ 上下文无效。
    } doorbell_error_e;

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
    // PCIe wrapper 使用的基础枚举
    // ---------------------------------------------------------------------

    typedef enum logic [1:0] {
        PCIE_CFG_RSP_OK      = 2'd0, // 配置访问成功。
        PCIE_CFG_RSP_UR      = 2'd1, // Unsupported Request，访问不支持的配置寄存器。
        PCIE_CFG_RSP_CRS     = 2'd2, // Configuration Retry Status，设备暂时未就绪。
        PCIE_CFG_RSP_ERROR   = 2'd3  // 其他配置访问错误。
    } pcie_cfg_status_e;

    typedef enum logic [2:0] {
        PCIE_TLP_MEM_READ    = 3'd0, // Memory Read 请求。
        PCIE_TLP_MEM_WRITE   = 3'd1, // Memory Write 请求。
        PCIE_TLP_CPL         = 3'd2, // Completion without data。
        PCIE_TLP_CPLD        = 3'd3, // Completion with data。
        PCIE_TLP_MSG         = 3'd4, // Message TLP，例如 MSI-X。
        PCIE_TLP_OTHER       = 3'd7  // 其他/暂未分类 TLP。
    } pcie_tlp_type_e;

    typedef enum logic [2:0] {
        PCIE_BAR_RSP_OK              = 3'd0, // BAR 访问已被接受并路由。
        PCIE_BAR_RSP_UNSUPPORTED     = 3'd1, // 访问了未支持的 BAR。
        PCIE_BAR_RSP_BAD_OFFSET      = 3'd2, // offset 超出该 BAR 的合法窗口。
        PCIE_BAR_RSP_MISALIGNED      = 3'd3, // 当前阶段不支持非 dword 对齐访问。
        PCIE_BAR_RSP_TARGET_ERROR    = 3'd4  // 下游目标报告错误，后续阶段使用。
    } pcie_bar_rsp_status_e;

    typedef enum logic [3:0] {
        SRIOV_ACCESS_BAR0_DOORBELL = 4'd0, // 检查 BAR0 Doorbell aperture 访问。
        SRIOV_ACCESS_BAR2_CSR      = 4'd1, // 检查 BAR2 CSR/mailbox 访问。
        SRIOV_ACCESS_BAR4_MSIX     = 4'd2, // 检查 BAR4 MSI-X table/PBA 访问。
        SRIOV_ACCESS_QP            = 4'd3, // 检查 QP 编号是否属于该 function。
        SRIOV_ACCESS_CQ            = 4'd4, // 检查 CQ 编号是否属于该 function。
        SRIOV_ACCESS_MR            = 4'd5  // 检查 MR 编号是否属于该 function。
    } sriov_access_type_e;

    typedef enum logic [3:0] {
        SRIOV_ACCESS_OK           = 4'd0, // 访问通过。
        SRIOV_ACCESS_DENIED       = 4'd1, // 访问被权限策略拒绝。
        SRIOV_ACCESS_DISABLED     = 4'd2, // 目标 function 未启用。
        SRIOV_ACCESS_BAD_FUNCTION = 4'd3, // function_id 或 requester_id 无法映射到合法 function。
        SRIOV_ACCESS_OUT_OF_RANGE = 4'd4, // 资源 ID、BAR offset 或 vector 超出该 function 窗口。
        SRIOV_ACCESS_PF_ONLY      = 4'd5  // 当前访问只允许 PF 或 trusted function。
    } sriov_access_status_e;

    typedef struct packed {
        logic [31:0]                  msg_addr_low;  // MSI-X message address 低 32 位。
        logic [31:0]                  msg_addr_high; // MSI-X message address 高 32 位。
        logic [31:0]                  msg_data;      // MSI-X message data。
        logic [31:0]                  vector_ctrl;   // vector control，bit0 为 mask。
    } msix_table_entry_t;

    typedef struct packed {
        logic                         is_pf;         // 1 表示 PF，0 表示 VF。
        logic [7:0]                   pf_id;         // PF 编号；原型阶段固定为 0。
        logic [VF_ID_W-1:0]           vf_id;         // VF 编号；PF 访问时为 0。
        logic [VF_ID_W-1:0]           function_id;   // 统一 function ID：PF=0，VF 从 1 开始。
        logic [PCIE_REQ_ID_W-1:0]     requester_id;  // PCIe requester ID，用于从 TLP 反查 function。
        logic                         enabled;       // 该 function 是否允许发起访问。
        logic                         trusted;       // 该 function 是否允许执行受信控制面操作。
    } sriov_function_identity_t;

    typedef struct packed {
        logic [QP_ID_W-1:0]           qp_base;       // 该 function 可访问的第一个 QP 编号。
        logic [QP_ID_W-1:0]           qp_limit;      // 该 function 可访问的最后一个 QP 编号，包含该值。
        logic [CQ_ID_W-1:0]           cq_base;       // 该 function 可访问的第一个 CQ 编号。
        logic [CQ_ID_W-1:0]           cq_limit;      // 该 function 可访问的最后一个 CQ 编号，包含该值。
        logic [MR_ID_W-1:0]           mr_base;       // 该 function 可访问的第一个 MR handle。
        logic [MR_ID_W-1:0]           mr_limit;      // 该 function 可访问的最后一个 MR handle，包含该值。
        logic [PCIE_BAR_OFFSET_W-1:0] doorbell_base; // 该 function 的 BAR0 Doorbell 起始 offset。
        logic [PCIE_BAR_OFFSET_W-1:0] doorbell_limit;// 该 function 的 BAR0 Doorbell 结束 offset，包含该值。
        logic [CQ_VECTOR_W-1:0]       msix_vector_base;  // 该 function 可使用的第一个 MSI-X vector。
        logic [CQ_VECTOR_W-1:0]       msix_vector_limit; // 该 function 可使用的最后一个 MSI-X vector，包含该值。
    } sriov_resource_window_t;

    // ---------------------------------------------------------------------
    // Packed 数据结构
    // ---------------------------------------------------------------------

    typedef struct packed {
        logic [ADDR_W-1:0]          addr;            // SGE 指向的 host 虚拟地址。
        logic [DMA_LEN_W-1:0]       length;          // 该 SGE 覆盖的字节数。
        logic [KEY_W-1:0]           lkey;            // 访问该 SGE 使用的 local key。
        logic [15:0]                flags;           // SGE flags，后续用于只读、last、invalidate 等语义。
        logic [111:0]               reserved;        // 保留位，保证 sge_t 为 32 字节。
    } sge_t;

    typedef struct packed {
        logic [INLINE_DATA_W-1:0]   data;            // WQE 中直接携带的 inline payload 数据。
    } inline_data_t;

    typedef struct packed {
        wqe_opcode_e                opcode;          // Work Request 操作类型。
        logic [7:0]                 flags;           // WR flags，含 inline data / extended SGE list 标志。
        logic [DMA_SGE_COUNT_W-1:0] sge_count;       // WR 引用的 SGE 总数，最大 256。
        logic [1:0]                 inline_sge_count;// WQE 内可直接派生/携带的 inline SGE 数量。
        logic                       inline_present;  // inline payload 是否存在。
        logic [15:0]                inline_len;      // inline payload 长度。
        logic [WR_ID_W-1:0]         wr_id;           // 应用传入的不透明 WR ID。
        logic [ADDR_W-1:0]          local_va;        // 第一个本地 buffer 或 inline SGE 地址。
        logic [KEY_W-1:0]           lkey;            // 第一个本地 SGE lkey。
        logic [DMA_LEN_W-1:0]       length;          // WR 总长度。
        logic [ADDR_W-1:0]          remote_va;       // RDMA Read/Write 远端虚拟地址。
        logic [KEY_W-1:0]           rkey;            // RDMA Read/Write 远端 rkey。
        logic [31:0]                imm_data;        // immediate data。
        logic [ADDR_W-1:0]          extended_sge_list_addr; // extended SGE list host 地址。
        logic [83:0]                reserved;        // 保留位，保证 send_wqe_t 为 64 字节。
    } send_wqe_t;

    typedef send_wqe_t recv_wqe_t; // 当前阶段 Recv WQE 复用同一基础格式。

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
        logic [WR_ID_W-1:0]        wr_id;           // 从 WQE 复制回来的应用 WR ID。
        logic [QP_ID_W-1:0]        qpn;             // 产生该 completion 的本地 QP。
        rdma_opcode_e              opcode;          // 已完成 Work Request 的操作码或 receive 语义 opcode。
        cmpl_status_e              status;          // Completion 完成状态。
        logic [DMA_LEN_W-1:0]      byte_len;        // 已完成的字节数。
        logic [31:0]               imm_data;        // CQE_FMT_FLAG_HAS_IMM 置位时有效的 immediate data。
        logic                      has_imm;         // 是否携带 immediate data。
        logic                      solicited;       // 是否为 solicited completion。
        logic [31:0]               vendor_error;    // 设备私有错误详情。
        logic [VF_ID_W-1:0]        owner_function;  // 拥有该 CQE 的 PF/VF function。
        logic [CQ_ID_W-1:0]        cqn;             // 目标 CQ 编号。
        cqe_syndrome_e             syndrome;        // 硬件内部错误归因，便于驱动调试。
        logic [15:0]               flags;           // CQE flags：imm、solicited、error、flush、recv/send 等。
        logic [63:0]               timestamp;       // 用于性能分析/调试的设备时间戳；当前阶段由输入透传/置零。
        logic                      valid;           // CQE 有效位。
        logic                      owner_bit;       // CQ ring owner bit 预留，后续随 producer wraparound 更新。
        logic [171:0]              reserved;        // 保留位，保证 CQE 总宽度为 64 字节。
    } cqe_t;

    typedef struct packed {
        completion_event_type_e    event_type;      // SQ、RQ、cleanup flush 或 error event。
        logic [QP_ID_W-1:0]        qpn;             // 产生 completion 的 QPN。
        logic [CQ_ID_W-1:0]        cqn;             // 目标 CQN。
        logic [VF_ID_W-1:0]        owner_function;  // completion 所属 PF/VF function。
        logic [WR_ID_W-1:0]        wr_id;           // 应回填到 CQE 的 WR ID。
        rdma_opcode_e              opcode;          // 原始 WR opcode 或 receive completion opcode。
        cmpl_status_e              status;          // 上游 completion 状态。
        logic [DMA_LEN_W-1:0]      byte_len;        // 完成字节数。
        logic [31:0]               imm_data;        // immediate data。
        logic                      has_imm;         // immediate data 是否有效。
        logic                      solicited;       // 是否为 solicited event。
        logic [31:0]               vendor_error;    // 上游错误码或设备私有错误。
        completion_source_e        source_engine;   // 事件来源模块。
    } completion_event_t;

    typedef struct packed {
        logic [VF_ID_W-1:0]         owner_func;      // 产生 dispatch 的 PF/VF function。
        logic [QP_ID_W-1:0]         qpn;             // 产生 dispatch 的 QPN。
        rdma_opcode_e               opcode;          // WQE opcode。
        qp_type_e                   qp_type;         // QP 类型，后续 transport 选择 RC/UD 行为。
        logic [PD_ID_W-1:0]         pd_id;           // 与 QP 关联的 Protection Domain。
        logic [CQ_ID_W-1:0]         send_cqn;        // Send completion 使用的 CQ。
        logic [QUEUE_IDX_W-1:0]     sq_consumer;     // 被消费的 SQ WQE index。
        wqe_t                       wqe;             // 原始 WQE 内容。
    } sq_dispatch_req_t;

    typedef struct packed {
        logic [VF_ID_W-1:0]         owner_func;      // DMA write 所属 PF/VF function。
        logic [QP_ID_W-1:0]         qpn;             // 接收入站 Send 的 QPN。
        logic [PD_ID_W-1:0]         pd_id;           // 与 QP 关联的 Protection Domain。
        logic [WR_ID_W-1:0]         wr_id;           // Recv WQE 的 WR ID。
        logic [ADDR_W-1:0]          dst_addr;        // Recv buffer 目标地址。
        logic [KEY_W-1:0]           lkey;            // Recv buffer 本地 key。
        logic [DMA_LEN_W-1:0]       length;          // 需要写入的入站 payload 长度。
        logic [7:0]                 flags;           // Recv WQE flags，后续用于 scatter-gather/inline 语义。
    } rq_dma_write_req_t;

    typedef struct packed {
        logic                       desc_valid;       // descriptor 是否有效。
        logic [15:0]                desc_id;          // descriptor ID，用于错误和 completion 回传。
        dma_opcode_e                dma_opcode;       // DMA 操作类型。
        logic [QP_ID_W-1:0]         qpn;              // 相关 QPN；CQE/fetch 可为 0。
        logic [CQ_ID_W-1:0]         cqn;              // 相关 CQN；非 CQE path 可为 0。
        logic [VF_ID_W-1:0]         owner_function;   // 拥有该 DMA 请求的 PF/VF function。
        logic [PD_ID_W-1:0]         pd_id;            // QP/MR 所属 Protection Domain。
        logic [WR_ID_W-1:0]         wr_id;            // 原始 WR ID 或 completion 关联 ID。
        logic [KEY_W-1:0]           local_key;        // 本地 lkey。
        logic [KEY_W-1:0]           remote_key;       // 远端 rkey。
        logic [ADDR_W-1:0]          local_va;         // 本地虚拟地址。
        logic [ADDR_W-1:0]          remote_va;        // 远端虚拟地址。
        logic [ADDR_W-1:0]          physical_addr;    // 已翻译物理/DMA 地址；7.4 前可为 0。
        logic [DMA_LEN_W-1:0]       length;           // 本 descriptor 本次请求长度。
        logic [DMA_LEN_W-1:0]       byte_len_remaining;// WR 剩余长度，SGE traversal 后续使用。
        logic [SGE_COUNT_W-1:0]     sge_count;        // WQE 中的 SGE 数量。
        logic [SGE_COUNT_W-1:0]     sge_index;        // 当前处理的 SGE index。
        logic                       inline_data_present;// WQE 是否携带 inline data。
        logic [15:0]                inline_data_len;  // inline data 长度。
        dma_direction_e             direction;        // 目标 DMA 方向/子路径。
        logic                       solicited;        // completion 是否为 solicited。
        logic                       has_imm;          // 是否携带 immediate data。
        logic [31:0]                imm_data;         // immediate data。
        logic                       completion_required;// 该 descriptor 完成后是否需要 completion。
        dma_dispatch_error_e        error_code;       // descriptor 内携带的错误码/预留。
        logic [63:0]                user_context;     // 不透明上下文，供上游关联调试或 completion。
    } dma_desc_t;

    typedef struct packed {
        logic [15:0]                desc_id;          // 来源 descriptor ID，用于回传错误和 completion。
        logic [QP_ID_W-1:0]         qpn;              // 该 segment 所属 QPN。
        logic [VF_ID_W-1:0]         owner_function;   // 拥有该 segment 的 PF/VF function。
        logic [PD_ID_W-1:0]         pd_id;            // QP/MR 所属 Protection Domain。
        mr_operation_e              operation;        // 后续 MR checker 使用的访问类型。
        logic [DMA_SGE_COUNT_W-1:0] sge_index;        // 原始 SGE index，范围 0..255。
        logic [ADDR_W-1:0]          va;               // SGE 虚拟地址，7.4 再做 MR 翻译。
        logic [DMA_LEN_W-1:0]       len;              // 当前 segment 长度。
        logic [KEY_W-1:0]           lkey;             // 当前 SGE 使用的本地 key。
        logic [KEY_W-1:0]           rkey;             // 远端访问使用的 remote key，7.4 使用。
        logic                       is_remote;        // 1 表示使用 rkey/remote permission path。
        logic [15:0]                flags;            // SGE flags，后续保留给 DMA/MR 语义。
        logic [DMA_BYTE_OFFSET_W-1:0] byte_offset;    // 当前 segment 在整个 WR payload 中的字节偏移。
        logic                       is_last;          // 该 segment 是否是 WR 的最后一个 SGE。
    } dma_segment_t;

    typedef struct packed {
        logic [KEY_W-1:0]           key;              // refcount 后续 ref_dec 使用的 lkey/rkey。
        logic                       is_remote;        // 1 表示 key 是 rkey，0 表示 key 是 lkey。
        logic [VF_ID_W-1:0]         owner_function;   // ref_dec 时校验 owner_function。
        logic [MR_ID_W-1:0]         mr_id;            // 命中的 MR/MW handle，便于调试和后续 scoreboard。
    } mr_ref_token_t;

    typedef struct packed {
        logic [15:0]                desc_id;          // 来源 descriptor ID。
        logic [QP_ID_W-1:0]         qpn;              // segment 所属 QPN。
        logic [VF_ID_W-1:0]         owner_function;   // segment 所属 PF/VF function。
        logic [PD_ID_W-1:0]         pd_id;            // 已通过校验的 PD。
        mr_operation_e              operation;        // 已通过校验的 MR operation。
        logic [DMA_SGE_COUNT_W-1:0] segment_index;    // 原始 SGE/segment index。
        logic [ADDR_W-1:0]          va;               // 原始虚拟地址。
        logic [ADDR_W-1:0]          pa;               // 经 MR/MW 转换后的物理/DMA 地址。
        logic [DMA_LEN_W-1:0]       len;              // 当前 protected segment 长度。
        logic [KEY_W-1:0]           key;              // 本次实际使用的 lkey 或 rkey。
        logic [15:0]                flags;            // segment flags，透传给后续 DMA/transport。
        logic [DMA_BYTE_OFFSET_W-1:0] byte_offset;    // WR payload 内字节偏移。
        logic                       is_last;          // 是否是 WR 最后一段。
        logic [5:0]                 access_flags;     // MR/MW entry 的 access_flags。
        mr_ref_token_t              refcount_token;   // 后续 DMA 完成后 ref_dec 使用的 token。
        dma_mr_error_e              error_code;       // protected path 错误码；成功为 NONE。
    } protected_dma_segment_t;

    typedef struct packed {
        logic [15:0]                desc_id;          // 来源 descriptor ID。
        logic [QP_ID_W-1:0]         qpn;              // payload 所属 QPN。
        logic [VF_ID_W-1:0]         owner_function;   // payload 所属 function。
        mr_operation_e              operation;        // payload 对应 operation。
        logic [DMA_PAYLOAD_DATA_W-1:0] data;          // 从 host memory 读出的 payload 数据。
        logic [15:0]                len;              // 本拍 payload 有效字节数。
        logic [DMA_BYTE_OFFSET_W-1:0] byte_offset;    // WR payload 内偏移。
        logic [DMA_SGE_COUNT_W-1:0] segment_index;    // 来源 segment index。
        logic                       segment_last;     // 当前 segment 的最后一个 read chunk。
        logic                       wqe_last;         // 当前 WQE/WR 的最后一个 payload chunk。
        dma_host_read_error_e       error_code;       // payload path 错误码；正常为 NONE。
    } dma_payload_stream_t;

    typedef struct packed {
        logic [VF_ID_W-1:0]         owner_func;      // completion 所属 PF/VF function。
        logic [QP_ID_W-1:0]         qpn;             // 接收完成的 QPN。
        logic [CQ_ID_W-1:0]         cqn;             // receive completion 使用的 CQ。
        logic [WR_ID_W-1:0]         wr_id;           // Recv WQE 的 WR ID。
        cmpl_status_e               status;          // completion 状态。
        logic [DMA_LEN_W-1:0]       byte_count;      // 接收的 payload 字节数。
        logic                       recv_with_imm;   // 1 表示 RECV_WITH_IMM，0 表示普通 RECV。
        logic                       has_imm;         // 是否携带 immediate data。
        logic [31:0]                imm_data;        // immediate data。
        logic                       solicited;       // 是否为 solicited event。
        rq_engine_error_e           error_code;      // RQ engine 错误码。
    } rq_completion_req_t;

    typedef struct packed {
        logic [VF_ID_W-1:0]         owner_func;      // flushed completion 所属 PF/VF function。
        logic [QP_ID_W-1:0]         qpn;             // 被 cleanup 的 QPN。
        logic [CQ_ID_W-1:0]         cqn;             // SQ 使用 send CQ，RQ 使用 recv CQ。
        cmpl_status_e               status;          // cleanup flush 使用 CMPL_WR_FLUSH_ERR。
        logic                       is_sq;           // 1 表示 SQ flushed completion。
        logic                       is_rq;           // 1 表示 RQ flushed completion/indication。
        logic [QUEUE_IDX_W-1:0]     queue_index;     // 被 flush 的 SQ/RQ slot index。
        qp_cleanup_reason_e         reason;          // destroy 或 error cleanup 来源。
    } qp_flush_completion_req_t;

    typedef struct packed {
        logic [ADDR_W-1:0]          physical_base_addr; // pinned 物理/DMA 段起始地址。
        logic [DMA_LEN_W-1:0]       length;             // 该 SG entry 覆盖的字节数。
        logic [31:0]                page_count;         // 该段包含的页数量。
        logic [PAGE_SHIFT_W-1:0]    page_size;          // 页大小 log2(bytes)。
        logic [15:0]                flags;              // pinned/只读/调试等 SG 标志预留。
        logic [105:0]               reserved;           // 保留位，保证 SG entry 为 32 字节。
    } sg_entry_t;

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
        logic                       error_state;    // 该 QP 是否已进入错误处理状态。
        logic [15:0]                error_code;     // QP 最近一次错误的设备内部错误码。
    } qp_context_t;

    typedef struct packed {
        logic                       valid;          // CQ 上下文条目已分配。
        logic [CQ_ID_W-1:0]         cqn;            // Completion Queue Number tag。
        logic [ADDR_W-1:0]          cq_buffer_base_addr; // CQE ring buffer 的主机地址。
        logic [QUEUE_DEPTH_W-1:0]   cq_depth;       // CQE 槽位数量。
        logic [QUEUE_IDX_W-1:0]     producer_index; // 硬件下一次要写入的 CQE index。
        logic [QUEUE_IDX_W-1:0]     consumer_index; // 软件通过 poll/arm 提交的 consumer index。
        logic [VF_ID_W-1:0]         owner_function; // 拥有该 CQ 的 PF/VF function。
        logic [CQ_VECTOR_W-1:0]     msix_vector;    // 与该 CQ 关联的 MSI-X vector。
        logic [15:0]                moderation_count; // 非零时每 N 个 completion 触发一次通知。
        logic [15:0]                moderation_timer;// 中断调节定时器，单位由具体实现定义。
        logic [15:0]                moderation_counter; // 当前 moderation completion 计数。
        logic                       moderation_timer_active; // moderation timer 是否正在计时。
        logic                       armed;          // CQ 通知已 arm。
        logic                       solicited_only; // 仅 solicited CQE 可以触发通知。
        logic                       overflow;       // 已检测到 CQ 溢出。
        logic                       error_state;    // CQ 是否处于错误状态。
        logic [15:0]                error_code;     // CQ 最近一次错误码。
    } cq_context_t;

    typedef struct packed {
        logic                       valid;             // MR 表项有效。
        logic [MR_ID_W-1:0]         mr_id;             // 驱动可见的 MR handle。
        logic [KEY_W-1:0]           lkey;              // 本地 DMA 操作使用的 local key。
        logic [KEY_W-1:0]           rkey;              // 入站远端操作使用的 remote key。
        logic [ADDR_W-1:0]          virtual_base_addr; // 该 MR 覆盖的首个虚拟地址。
        logic [ADDR_W-1:0]          physical_base_addr;// 该 MR 段对应的首个物理/DMA 地址。
        logic [DMA_LEN_W-1:0]       length;            // 该 MR 表项覆盖的字节数。
        logic [PAGE_SHIFT_W-1:0]    page_size;         // 页大小 log2(bytes)，例如 4 KiB 对应 12。
        logic [5:0]                 access_flags;      // 由 mr_access_bit_e 索引的访问权限位图。
        logic [PD_ID_W-1:0]         pd_id;             // 与该 MR 关联的 Protection Domain。
        logic [VF_ID_W-1:0]         owner_function;    // 拥有该 MR 的 PF/VF function。
        logic [MR_REFCOUNT_W-1:0]   refcount;          // 正在进行的 DMA 引用数量。
        logic                       pending_deregister;// 已请求注销，等待 refcount 清零。
        logic                       memory_window;     // 1 表示 Memory Window 表项，绑定规则留给 6.7。
        logic                       invalidating;       // MW 正在 unbind 或 QP error invalidation。
        logic [QP_ID_W-1:0]         bound_qpn;          // 绑定该 MW 的 QPN，用于 QP error invalidation。
        logic [KEY_W-1:0]           parent_mr_key;     // Memory Window 绑定的父 MR key，6.7 使用。
        logic                       error_state;       // 该 MR 是否处于错误状态。
        logic [15:0]                error_code;        // MR 最近一次错误码。
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
        logic [63:0]                dgid_hi;        // 目的 GID 高 64 bit，用于后续 GRH/GID 派生。
        logic [63:0]                dgid_lo;        // 目的 GID 低 64 bit，用于后续 IPv6/GRH 扩展。
        logic [7:0]                 sgid_index;     // 本地 GID table 索引，驱动创建 AH 时填入。
        logic [19:0]                flow_label;     // GID/GRH 派生 flow label 元数据。
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
        logic [DB_FLAGS_W-1:0]       flags;                  // SQ Doorbell flags，当前支持 signal/fence 占位。
        logic [DB_SEQUENCE_W-1:0]    doorbell_sequence;      // 软件递增的 Doorbell sequence，便于后续调试/乱序检测。
        logic [QUEUE_IDX_W-1:0]      new_sq_producer_index;  // 软件写入的新 SQ producer index。
    } sq_doorbell_payload_t;

    typedef struct packed {
        logic [DB_FLAGS_W-1:0]       flags;                  // RQ Doorbell flags，当前支持 solicited 占位。
        logic [DB_SEQUENCE_W-1:0]    doorbell_sequence;      // 软件递增的 Doorbell sequence，便于后续调试/乱序检测。
        logic [QUEUE_IDX_W-1:0]      new_rq_producer_index;  // 软件写入的新 RQ producer index。
    } rq_doorbell_payload_t;

    typedef struct packed {
        logic [DB_FLAGS_W-1:0]       flags;                  // CQ arm flags，bit0 表示 solicited-only。
        logic [DB_SEQUENCE_W-1:0]    arm_sequence;           // 软件递增的 CQ arm sequence，便于后续调试/乱序检测。
        logic [QUEUE_IDX_W-1:0]      consumer_index;         // 软件观察到的 CQ consumer index。
    } cq_arm_doorbell_payload_t;

    // RoCEv2 packet parser 共享常量和元数据格式。
    localparam logic [15:0] ETH_TYPE_IPV4     = 16'h0800; // IPv4 EtherType。
    localparam logic [15:0] ETH_TYPE_IPV6     = 16'h86dd; // IPv6 EtherType；10.1 阶段只解析 traffic class/ECN。
    localparam logic [15:0] ETH_TYPE_VLAN     = 16'h8100; // 802.1Q VLAN EtherType。
    localparam logic [15:0] ETH_TYPE_QINQ     = 16'h88a8; // 802.1ad QinQ EtherType，本阶段只识别一层 VLAN。
    localparam logic [7:0]  IP_PROTO_UDP      = 8'h11;   // IPv4 UDP protocol number。
    localparam logic [15:0] ROCEV2_UDP_PORT   = 16'd4791; // RoCEv2 UDP destination port。
    localparam logic [3:0]  BTH_TRANSPORT_VER = 4'h0;    // RoCEv2 BTH transport version。
    localparam logic [3:0]  IPV4_VERSION      = 4'h4;    // IPv4 version 字段。
    localparam logic [3:0]  IPV6_VERSION      = 4'h6;    // IPv6 version 字段。
    localparam logic [3:0]  IPV4_MIN_IHL      = 4'h5;    // 当前最小实现只支持无 IPv4 option 的 20B header。
    localparam logic [1:0]  ECN_NOT_ECT       = 2'b00;   // 非 ECN capable transport。
    localparam logic [1:0]  ECN_ECT1          = 2'b01;   // ECN capable transport(1)。
    localparam logic [1:0]  ECN_ECT0          = 2'b10;   // ECN capable transport(0)。
    localparam logic [1:0]  ECN_CE            = 2'b11;   // Congestion Experienced 标记。

    typedef enum logic [7:0] {
        ROCE_OPCODE_SEND_ONLY       = 8'h04,
        ROCE_OPCODE_SEND_ONLY_IMM   = 8'h05,
        ROCE_OPCODE_RDMA_WRITE_ONLY = 8'h0a,
        ROCE_OPCODE_RDMA_WRITE_ONLY_IMM = 8'h0b,
        ROCE_OPCODE_RDMA_READ_REQ   = 8'h0c,
        ROCE_OPCODE_RDMA_READ_RESP  = 8'h10,
        ROCE_OPCODE_ACK             = 8'h11,
        ROCE_OPCODE_CNP             = 8'h81,
        ROCE_OPCODE_UD_SEND_ONLY    = 8'h64
    } roce_opcode_e;

    typedef enum logic [3:0] {
        PKT_PARSE_STATUS_OK                 = 4'd0,
        PKT_PARSE_STATUS_NEED_MORE_DATA     = 4'd1,
        PKT_PARSE_STATUS_SHORT_FRAME        = 4'd2,
        PKT_PARSE_STATUS_UNSUPPORTED_LAYOUT = 4'd3
    } packet_parse_status_e;

    typedef enum logic [4:0] {
        PKT_VALIDATION_OK              = 5'd0,
        PKT_VALIDATION_ERR_PARSE       = 5'd1,
        PKT_VALIDATION_ERR_ETHERTYPE   = 5'd2,
        PKT_VALIDATION_ERR_IP_VERSION  = 5'd3,
        PKT_VALIDATION_ERR_IHL         = 5'd4,
        PKT_VALIDATION_ERR_PROTOCOL    = 5'd5,
        PKT_VALIDATION_ERR_UDP_PORT    = 5'd6,
        PKT_VALIDATION_ERR_BTH_VERSION = 5'd7,
        PKT_VALIDATION_ERR_OPCODE      = 5'd8,
        PKT_VALIDATION_ERR_CHECKSUM    = 5'd9,
        PKT_VALIDATION_ERR_LENGTH      = 5'd10
    } packet_validation_error_e;

    typedef enum logic [4:0] {
        PKT_PAYLOAD_OK                    = 5'd0,
        PKT_PAYLOAD_ERR_META_STATUS       = 5'd1,
        PKT_PAYLOAD_ERR_LENGTH            = 5'd2,
        PKT_PAYLOAD_ERR_MULTI_BEAT_STUB   = 5'd3,
        PKT_PAYLOAD_ERR_FRAME_NOT_LAST    = 5'd4
    } packet_payload_error_e;

    typedef enum logic [4:0] {
        PKT_BUILD_OK                    = 5'd0,
        PKT_BUILD_ERR_UNSUPPORTED       = 5'd1,
        PKT_BUILD_ERR_LENGTH            = 5'd2,
        PKT_BUILD_ERR_MULTI_BEAT_STUB   = 5'd3
    } packet_build_error_e;

    typedef enum logic [3:0] {
        PKT_ICRC_STATUS_PLACEHOLDER = 4'd0,
        PKT_ICRC_STATUS_UNCHECKED   = 4'd1,
        PKT_ICRC_STATUS_MISMATCH    = 4'd2
    } packet_icrc_status_e;

    typedef struct packed {
        logic [15:0]            desc_id;        // 来源 descriptor ID，透传给后续 transport/completion/debug。
        logic [QP_ID_W-1:0]     qpn;            // 上游关联的本地 QPN，入站场景可由后续 QP lookup 覆盖。
        logic [CQ_ID_W-1:0]     cqn;            // 上游关联的 CQN，后续 completion path 使用。
        logic [VF_ID_W-1:0]     owner_function; // 该 packet metadata 所属 PF/VF function。
        logic [PD_ID_W-1:0]     pd_id;          // 该 packet metadata 所属 Protection Domain。
        roce_opcode_e           opcode;         // BTH opcode。
        packet_parse_status_e   status;         // 8.1 只表示结构性解析状态，协议合法性留给 8.2。
        logic [15:0]            frame_len;      // 原始帧长度，供 8.2 packet length 校验。
        logic [15:0]            ethertype;      // 解出的一层或 VLAN 内层 EtherType。
        logic                   has_vlan;       // 是否识别到一层 VLAN header。
        logic [15:0]            vlan_tci;       // VLAN TCI，未带 VLAN 时为 0。
        logic [3:0]             ip_version;     // IPv4 version 字段。
        logic [3:0]             ip_ihl;         // IPv4 IHL，当前 validator 只接受 5。
        logic [7:0]             ip_dsfield;     // IPv4 DS field 或 IPv6 traffic class 原始值。
        logic [7:0]             ipv6_traffic_class; // IPv6 traffic class；IPv4 包为 0。
        logic [1:0]             ecn;            // DS/traffic class 低 2 bit 的 ECN 字段。
        logic                   ecn_valid;      // 该包是否带有可解析 ECN 字段。
        logic                   ecn_ce;         // ECN 字段是否为 CE(11)，供拥塞控制后续生成 CNP。
        logic [15:0]            ip_total_length;// IPv4 total length。
        logic [7:0]             ip_protocol;    // IPv4 protocol，应为 UDP。
        logic [15:0]            ip_checksum;    // IPv4 header checksum 原始字段；校验结果由外部 checksum checker 输入。
        logic [31:0]            ipv4_src;       // IPv4 源地址。
        logic [31:0]            ipv4_dst;       // IPv4 目的地址。
        logic [15:0]            udp_src_port;   // UDP 源端口。
        logic [15:0]            udp_dst_port;   // UDP 目的端口。
        logic [15:0]            udp_length;     // UDP length 字段。
        logic [15:0]            udp_checksum;   // UDP checksum 原始字段；checksum 计算留给独立 checker。
        logic [3:0]             bth_transport_version; // BTH transport version。
        logic [PKEY_W-1:0]      pkey;           // BTH P_Key。
        logic [QP_ID_W-1:0]     dest_qpn;       // BTH destination QPN。
        logic [PSN_W-1:0]       psn;            // BTH packet sequence number。
        logic                   has_reth;       // opcode 是否携带 RETH。
        logic [ADDR_W-1:0]      remote_va;      // RETH remote virtual address。
        logic [KEY_W-1:0]       rkey;           // RETH remote key。
        logic [DMA_LEN_W-1:0]   dma_length;     // RETH DMA length。
        logic                   has_aeth;       // opcode 是否携带 AETH。
        logic [31:0]            aeth;           // AETH 原始字段。
        logic                   has_deth;       // UD opcode 是否携带 DETH。
        logic [QKEY_W-1:0]      qkey;           // DETH Q_Key。
        logic [QP_ID_W-1:0]     src_qpn;        // DETH source QPN。
        logic                   has_imm;        // opcode 是否携带 immediate data。
        logic [31:0]            imm_data;       // Immediate data。
        logic [31:0]            icrc;           // invariant CRC 字段的原始值；8.1 不计算/校验。
        logic [15:0]            payload_offset; // payload 在 frame 中的字节偏移。
        logic [15:0]            payload_len;    // payload 字节数，已扣除尾部 ICRC。
    } packet_meta_t;

    typedef struct packed {
        logic [15:0]            desc_id;        // 来源 descriptor ID，供 DMA/completion/debug 关联。
        logic [QP_ID_W-1:0]     qpn;            // 本地关联 QPN。
        logic [CQ_ID_W-1:0]     cqn;            // 后续 completion 使用的 CQN。
        logic [VF_ID_W-1:0]     owner_function; // 所属 PF/VF function。
        logic [PD_ID_W-1:0]     pd_id;          // Protection Domain。
        roce_opcode_e           opcode;         // RoCEv2 opcode。
        packet_payload_error_e  status;         // payload extraction 状态。
        logic [15:0]            error_code;     // payload extraction 错误码，成功为 0。
        logic [1:0]             ecn;            // 从 ingress IP header 继承的 ECN 字段。
        logic                   ecn_valid;      // ECN 字段是否有效。
        logic                   ecn_ce;         // 是否检测到 CE 标记。
        logic [511:0]           data;           // 当前 beat 对齐后的 payload 数据。
        logic [15:0]            payload_len;    // 本次输出 payload 总长度。
        logic [15:0]            valid_bytes;    // 当前 data 中有效 payload 字节数。
        logic [15:0]            byte_offset;    // 当前 payload beat 在整个 packet payload 中的偏移。
        logic                   first;          // 当前 beat 是否为 payload 第一拍。
        logic                   last;           // 当前 beat 是否为 payload 最后一拍。
        logic                   has_imm;        // 是否携带 immediate data。
        logic [31:0]            imm_data;       // immediate data。
        logic [ADDR_W-1:0]      remote_va;      // RETH remote VA，供 transport/DMA 后续使用。
        logic [KEY_W-1:0]       rkey;           // RETH rkey。
        logic [DMA_LEN_W-1:0]   dma_length;     // RETH DMA length。
        logic [QP_ID_W-1:0]     dest_qpn;       // BTH destination QPN。
        logic [PSN_W-1:0]       psn;            // BTH PSN。
    } packet_payload_stream_t;

    typedef struct packed {
        logic [15:0]            desc_id;        // 来源 descriptor ID。
        logic [QP_ID_W-1:0]     qpn;            // 本地 QPN。
        logic [CQ_ID_W-1:0]     cqn;            // completion/debug 关联 CQN。
        logic [VF_ID_W-1:0]     owner_function; // 所属 PF/VF function。
        logic [PD_ID_W-1:0]     pd_id;          // Protection Domain。
        roce_opcode_e           opcode;         // 需要构造的 RoCEv2 opcode。
        packet_build_error_e    status;         // packet builder 状态。
        logic [15:0]            error_code;     // builder 错误码，成功为 0。
        logic [47:0]            dst_mac;        // Ethernet destination MAC。
        logic [47:0]            src_mac;        // Ethernet source MAC。
        logic                   has_vlan;       // 是否插入单层 VLAN。
        logic [15:0]            vlan_tci;       // VLAN TCI。
        logic [31:0]            src_ipv4;       // IPv4 source。
        logic [31:0]            dst_ipv4;       // IPv4 destination。
        logic [15:0]            udp_src_port;   // UDP source port。
        logic [15:0]            udp_dst_port;   // UDP destination port，通常为 4791。
        logic [PKEY_W-1:0]      pkey;           // BTH P_Key。
        logic [QP_ID_W-1:0]     dest_qpn;       // BTH destination QPN。
        logic [QP_ID_W-1:0]     src_qpn;        // DETH source QPN。
        logic [PSN_W-1:0]       psn;            // BTH PSN。
        logic [ADDR_W-1:0]      remote_va;      // RETH remote virtual address。
        logic [KEY_W-1:0]       rkey;           // RETH remote key。
        logic [DMA_LEN_W-1:0]   dma_length;     // RETH DMA length。
        logic [31:0]            aeth;           // AETH / ACK / NAK 原始字段。
        logic [QKEY_W-1:0]      qkey;           // DETH Q_Key。
        logic                   has_imm;        // 是否构造 ImmDt。
        logic [31:0]            imm_data;       // Immediate data。
        logic [511:0]           payload_data;   // 单 beat payload 数据。
        logic [15:0]            payload_len;    // payload 长度。
        logic [31:0]            icrc_placeholder; // 8.4 占位 ICRC，8.5 替换为真实计算。
    } packet_build_req_t;

    typedef struct packed {
        logic [15:0]            desc_id;        // 来源 descriptor ID。
        logic [QP_ID_W-1:0]     qpn;            // 关联 QPN。
        logic [CQ_ID_W-1:0]     cqn;            // 关联 CQN。
        logic [VF_ID_W-1:0]     owner_function; // 所属 function。
        logic [PD_ID_W-1:0]     pd_id;          // Protection Domain。
        roce_opcode_e           opcode;         // RoCEv2 opcode。
        packet_icrc_status_e    status;         // ICRC placeholder 状态。
        logic [15:0]            error_code;     // ICRC 错误/限制码。
        logic [31:0]            icrc_value;     // 输出给 builder 或 validator 的 ICRC 字段。
        logic                   compatibility_limited; // 1 表示当前不是真实 ICRC，不能用于互操作。
    } packet_icrc_result_t;

    parameter int CNP_RATE_LIMIT_W = 16; // CNP per-QP rate limit/cooldown 计数位宽。
    parameter int CNP_COUNTER_W    = 32; // CNP debug counter 位宽。

    typedef enum logic [1:0] {
        CNP_CONGESTION_ECN    = 2'd0, // ECN CE mark 触发。
        CNP_CONGESTION_QUEUE  = 2'd1, // queue-level threshold 触发。
        CNP_CONGESTION_PORT   = 2'd2, // port-level threshold 触发。
        CNP_CONGESTION_UNKNOWN = 2'd3 // 调试/保留。
    } cnp_congestion_type_e;

    typedef enum logic [3:0] {
        CNP_GEN_STATUS_OK           = 4'd0, // CNP 生成请求成功。
        CNP_GEN_STATUS_RATE_LIMITED = 4'd1, // per-QP rate limit 未到期。
        CNP_GEN_STATUS_DISABLED     = 4'd2, // CNP 生成未使能。
        CNP_GEN_STATUS_BACKPRESSURE = 4'd3  // 下游 builder 暂时不可接收。
    } cnp_gen_status_e;

    typedef enum logic [3:0] {
        CNP_CLASS_STATUS_OK          = 4'd0, // 有效 CNP。
        CNP_CLASS_STATUS_NOT_CNP     = 4'd1, // 不是 CNP packet。
        CNP_CLASS_STATUS_MALFORMED   = 4'd2, // parser/UDP/opcode 字段不合法。
        CNP_CLASS_STATUS_QP_MISS     = 4'd3, // 目标 QP 不存在或未激活。
        CNP_CLASS_STATUS_BACKPRESSURE = 4'd4 // DCQCN 事件队列反压。
    } cnp_class_status_e;

    typedef struct packed {
        logic [15:0]              desc_id;        // 来源 packet/descriptor ID。
        logic [QP_ID_W-1:0]       qpn;            // 被 CNP 反馈影响的 QP。
        logic [CQ_ID_W-1:0]       cqn;            // 调试/完成关联 CQN。
        logic [VF_ID_W-1:0]       owner_function; // 所属 PF/VF function。
        logic [PD_ID_W-1:0]       pd_id;          // Protection Domain。
        cnp_congestion_type_e     congestion_type;// ECN/queue/port 拥塞来源。
        logic [QP_ID_W-1:0]       source_qpn;     // CNP 来源 QP/port 标识，若未知则为 0。
        cnp_class_status_e        status;         // 分类状态。
        logic [15:0]              error_code;     // 错误码，成功为 0。
    } cnp_event_t;

    parameter int DCQCN_RATE_W = 32; // DCQCN rate 定点/抽象速率位宽。
    parameter int DCQCN_ALPHA_W = 16; // DCQCN alpha 位宽，最大值表示 1.0。
    parameter logic [DCQCN_ALPHA_W-1:0] DCQCN_ALPHA_MAX = {DCQCN_ALPHA_W{1'b1}}; // alpha 饱和值。
    parameter int DCQCN_COUNTER_W = 32; // DCQCN debug counter 位宽。

    typedef enum logic [1:0] {
        DCQCN_STATE_NORMAL    = 2'd0, // 已恢复到 target_rate。
        DCQCN_STATE_CONGESTED = 2'd1, // 刚收到 CNP，执行 multiplicative decrease。
        DCQCN_STATE_RECOVERY  = 2'd2  // recovery timer 驱动 additive increase。
    } dcqcn_state_e;

    typedef struct packed {
        logic [QP_ID_W-1:0]       qpn;            // 被更新的 QP。
        logic [VF_ID_W-1:0]       owner_function; // 所属 PF/VF function。
        logic [DCQCN_RATE_W-1:0]  current_rate;   // 当前速率，供 10.4 pacing 使用。
        logic [DCQCN_RATE_W-1:0]  target_rate;    // 目标速率。
        logic [DCQCN_RATE_W-1:0]  min_rate;       // 下限速率。
        logic [DCQCN_ALPHA_W-1:0] alpha;          // DCQCN alpha。
        dcqcn_state_e             state;          // NORMAL/CONGESTED/RECOVERY。
    } dcqcn_rate_update_t;

    parameter int PACER_TOKEN_W = 64; // token bucket token/容量位宽。
    parameter int PACER_TIME_W = 32;  // pacing 时间戳/周期计数位宽。
    parameter int PACER_PACKET_LEN_W = 16; // TX packet size 位宽。
    parameter int PACER_COUNTER_W = 32; // pacing debug counter 位宽。

    typedef enum logic [1:0] {
        PACER_STATUS_ALLOWED   = 2'd0, // token 足够，允许发送。
        PACER_STATUS_THROTTLED = 2'd1, // token 不足，阻塞/暂停该 QP 发送。
        PACER_STATUS_DISABLED  = 2'd2, // pacer 未使能，旁路允许。
        PACER_STATUS_INVALID   = 2'd3  // QP/bucket 未配置或请求无效。
    } pacer_status_e;

    typedef struct packed {
        logic [15:0]              desc_id;        // TX 请求来源 descriptor ID。
        logic [QP_ID_W-1:0]       qpn;            // 待发送 packet 所属 QP。
        logic [VF_ID_W-1:0]       owner_function; // 所属 PF/VF function。
        logic [PD_ID_W-1:0]       pd_id;          // Protection Domain。
        roce_opcode_e             opcode;         // packet/WR opcode。
        logic [PACER_PACKET_LEN_W-1:0] packet_size; // 本次发送需要消耗的 token 数。
    } pacer_tx_req_t;

    typedef struct packed {
        logic [15:0]              desc_id;        // 与请求对应。
        logic [QP_ID_W-1:0]       qpn;            // QP。
        logic [VF_ID_W-1:0]       owner_function; // 所属 function。
        logic [PD_ID_W-1:0]       pd_id;          // Protection Domain。
        roce_opcode_e             opcode;         // opcode。
        logic [PACER_TOKEN_W-1:0] tokens_after;   // 判定后的 token 数。
        pacer_status_e            status;         // allow/throttle/invalid。
    } pacer_decision_t;

    parameter int PFC_PRIORITY_COUNT = 8; // 802.1Qbb 定义 8 个 traffic class/priority。
    parameter int PFC_PRIORITY_W = 3; // PFC priority 编号位宽。
    parameter int PFC_TIMER_W = 16; // pause quanta/timer 原型计数位宽。
    parameter int PFC_COUNTER_W = 32; // PFC debug counter 位宽。

    typedef enum logic [0:0] {
        PFC_STATE_ACTIVE = 1'b0, // 该 priority 可调度 TX。
        PFC_STATE_PAUSED = 1'b1  // 该 priority 暂停，TX scheduler 必须反压。
    } pfc_pause_state_e;

    parameter int RC_SEND_OUTSTANDING_DEPTH = 4; // 9.1 最小 RC send outstanding window 深度。
    parameter int RC_SEND_RETRY_TIMER_W = 16; // retry timer 计数位宽。
    parameter int RC_SEND_RETRY_COUNT_W = 8; // retry count 位宽。

    typedef enum logic [4:0] {
        RC_SEND_STATUS_OK              = 5'd0,
        RC_SEND_STATUS_NOT_CONFIGURED  = 5'd1,
        RC_SEND_STATUS_WINDOW_FULL     = 5'd2,
        RC_SEND_STATUS_RETRY_EXHAUSTED = 5'd3,
        RC_SEND_STATUS_ACK_MISS        = 5'd4
    } rc_send_status_e;

    typedef struct packed {
        logic [15:0]            desc_id;        // 来源 descriptor ID。
        logic [QP_ID_W-1:0]     qpn;            // RC QP number。
        logic [CQ_ID_W-1:0]     cqn;            // 后续 completion/debug 关联 CQ。
        logic [VF_ID_W-1:0]     owner_function; // 所属 PF/VF function。
        logic [PD_ID_W-1:0]     pd_id;          // Protection Domain。
        roce_opcode_e           opcode;         // SEND/RDMA_WRITE/RDMA_READ_REQ 等。
        rc_send_status_e        status;         // 请求状态，正常为 OK。
        logic [15:0]            error_code;     // 错误码，正常为 0。
        logic [WR_ID_W-1:0]     wr_id;          // Work Request ID，completion/debug 使用。
        logic [15:0]            payload_len;    // 本次 packet payload 长度。
        logic                   solicited;      // BTH solicited event hint。
        logic                   completion_required; // 是否需要后续 completion。
        packet_build_req_t      build_req;      // 交给 packet builder 的 frame 构造请求。
    } transport_tx_req_t;

    typedef struct packed {
        logic [15:0]            desc_id;        // 来源 descriptor ID。
        logic [QP_ID_W-1:0]     qpn;            // RC QP number。
        logic [CQ_ID_W-1:0]     cqn;            // completion/debug 关联 CQ。
        logic [VF_ID_W-1:0]     owner_function; // 所属 function。
        logic [PD_ID_W-1:0]     pd_id;          // Protection Domain。
        roce_opcode_e           opcode;         // RoCEv2 opcode。
        rc_send_status_e        status;         // 发送侧状态。
        logic [15:0]            error_code;     // 错误码，正常为 0。
        logic [WR_ID_W-1:0]     wr_id;          // Work Request ID。
        logic [PSN_W-1:0]       psn;            // 分配给 packet 的 PSN。
        logic                   is_retry;       // 1 表示 retry 重新发包。
        logic [RC_SEND_RETRY_COUNT_W-1:0] retry_count; // 当前剩余 retry 次数。
        packet_build_req_t      build_req;      // 已写入 PSN 的 packet builder 请求。
    } transport_rc_packet_t;

    typedef struct packed {
        logic [QP_ID_W-1:0]     qpn;            // ACK 所属 QPN。
        logic [VF_ID_W-1:0]     owner_function; // ACK 所属 function。
        logic [PSN_W-1:0]       ack_psn;        // 累积 ACK 到该 PSN。
        logic                   retry_hint;     // NAK/retry hint 预留；9.1 仅作为 retry 触发提示。
    } transport_ack_event_t;

    parameter int RC_RECV_ACK_COALESCE_W = 8; // 9.2 ACK 合并计数位宽。
    parameter int RC_RECV_ACK_TIMER_W = 16;   // 9.2 ACK 合并 timer 位宽。

    typedef enum logic [4:0] {
        RC_RECV_STATUS_OK          = 5'd0,
        RC_RECV_STATUS_DUPLICATE   = 5'd1,
        RC_RECV_STATUS_GAP_NAK     = 5'd2,
        RC_RECV_STATUS_RNR_NAK     = 5'd3,
        RC_RECV_STATUS_BAD_OPCODE  = 5'd4,
        RC_RECV_STATUS_NOT_READY   = 5'd5
    } rc_recv_status_e;

    typedef enum logic [3:0] {
        RC_NAK_NONE     = 4'd0,
        RC_NAK_SEQUENCE = 4'd1,
        RC_NAK_RNR      = 4'd2,
        RC_NAK_OPCODE   = 4'd3
    } rc_nak_code_e;

    typedef struct packed {
        logic [15:0]            desc_id;        // 来源 descriptor ID。
        logic [QP_ID_W-1:0]     qpn;            // 本地 QPN。
        logic [CQ_ID_W-1:0]     cqn;            // 后续 completion/debug 关联 CQ。
        logic [VF_ID_W-1:0]     owner_function; // 所属 PF/VF function。
        logic [PD_ID_W-1:0]     pd_id;          // Protection Domain。
        roce_opcode_e           opcode;         // 入站 RoCEv2 opcode。
        rc_recv_status_e        status;         // RX transport 处理结果。
        logic [15:0]            error_code;     // 错误码，正常为 0。
        logic [PSN_W-1:0]       packet_psn;     // 当前 packet PSN。
        logic [PSN_W-1:0]       expected_psn;   // 处理后或 NAK 指向的期望 PSN。
        logic [PSN_W-1:0]       ack_psn;        // ACK/NAK 携带的 PSN。
        logic                   is_ack;         // 1 表示 ACK。
        logic                   is_nak;         // 1 表示 NAK。
        logic                   is_rnr;         // 1 表示 RNR NAK。
        logic                   duplicate;      // 1 表示 duplicate/replay packet。
        logic                   gap;            // 1 表示 packet_psn 高于 expected_psn。
        rc_nak_code_e           nak_code;       // NAK 原因。
        logic [31:0]            aeth;           // 供 packet builder 使用的最小 AETH placeholder。
    } transport_rx_ack_event_t;

    typedef enum logic [4:0] {
        RC_READ_STATUS_OK              = 5'd0,
        RC_READ_STATUS_QP_LOOKUP_MISS  = 5'd1,
        RC_READ_STATUS_QP_TYPE_ERR     = 5'd2,
        RC_READ_STATUS_QP_STATE_ERR    = 5'd3,
        RC_READ_STATUS_MR_DENIED       = 5'd4,
        RC_READ_STATUS_PD_MISMATCH     = 5'd5,
        RC_READ_STATUS_PSN_MISMATCH    = 5'd6,
        RC_READ_STATUS_LENGTH_MISMATCH = 5'd7,
        RC_READ_STATUS_DMA_READ_ERR    = 5'd8,
        RC_READ_STATUS_DMA_WRITE_ERR   = 5'd9,
        RC_READ_STATUS_OUTSTANDING_FULL = 5'd10,
        RC_READ_STATUS_RETRY_TODO      = 5'd11
    } rc_rdma_read_status_e;

    typedef struct packed {
        logic [15:0]            desc_id;        // SQ/DMA descriptor ID。
        logic [QP_ID_W-1:0]     qpn;            // requester 本地 QPN。
        logic [CQ_ID_W-1:0]     cqn;            // requester completion CQN。
        logic [VF_ID_W-1:0]     owner_function; // requester 所属 function。
        logic [PD_ID_W-1:0]     pd_id;          // requester PD。
        logic [WR_ID_W-1:0]     wr_id;          // 原始 RDMA Read WR ID。
        qp_type_e               qp_type;        // 必须为 RC。
        qp_state_e              qp_state;       // 必须允许发送，最小实现要求 RTS。
        logic [QP_ID_W-1:0]     remote_qpn;     // responder QPN。
        logic [PSN_W-1:0]       request_psn;    // Read Request 消耗的 PSN。
        logic [PSN_W-1:0]       expected_resp_psn; // 期望首个 Read Response PSN。
        logic [ADDR_W-1:0]      local_va;       // 本地接收 buffer VA。
        logic [KEY_W-1:0]       local_lkey;     // 本地接收 buffer lkey。
        logic [ADDR_W-1:0]      remote_va;      // 远端读取 VA。
        logic [KEY_W-1:0]       remote_rkey;    // 远端 rkey。
        logic [DMA_LEN_W-1:0]   length;         // 读取总长度。
        logic [7:0]             retry_count;    // retry 参数预留。
        logic [7:0]             rnr_retry_count;// RNR retry 参数预留。
    } rc_rdma_read_req_t;

    typedef struct packed {
        logic                   valid;          // outstanding context 有效。
        logic [15:0]            desc_id;        // descriptor ID。
        logic [QP_ID_W-1:0]     qpn;            // requester QPN。
        logic [CQ_ID_W-1:0]     cqn;            // completion CQN。
        logic [VF_ID_W-1:0]     owner_function; // requester function。
        logic [PD_ID_W-1:0]     pd_id;          // requester PD。
        logic [WR_ID_W-1:0]     wr_id;          // WR ID。
        logic [ADDR_W-1:0]      local_va;       // 本地写入 VA。
        logic [KEY_W-1:0]       local_lkey;     // 本地 lkey。
        logic [DMA_LEN_W-1:0]   total_len;      // 请求总长度。
        logic [DMA_LEN_W-1:0]   received_len;   // 已接收响应字节数。
        logic [PSN_W-1:0]       next_resp_psn;  // 期望的下一个 response PSN。
    } rc_rdma_read_outstanding_t;

    typedef struct packed {
        logic [15:0]            desc_id;        // descriptor ID。
        logic [QP_ID_W-1:0]     qpn;            // requester QPN。
        logic [CQ_ID_W-1:0]     cqn;            // completion CQN。
        logic [VF_ID_W-1:0]     owner_function; // requester function。
        logic [PD_ID_W-1:0]     pd_id;          // requester PD。
        logic [WR_ID_W-1:0]     wr_id;          // WR ID。
        logic [ADDR_W-1:0]      local_va;       // 写入目标 VA。
        logic [KEY_W-1:0]       local_lkey;     // 本地 lkey。
        logic [511:0]           data;           // response payload 数据。
        logic [15:0]            byte_len;       // 本 beat 有效字节数。
        logic [DMA_LEN_W-1:0]   byte_offset;    // RDMA Read WR 内偏移。
        logic                   last;           // 当前 beat 是否完成整个 RDMA Read。
        rc_rdma_read_status_e   status;         // 写入请求状态。
        logic [15:0]            error_code;     // 错误码。
    } rc_rdma_read_local_write_t;

    typedef enum logic [4:0] {
        RC_IMM_STATUS_OK          = 5'd0,
        RC_IMM_STATUS_RNR         = 5'd1,
        RC_IMM_STATUS_REMOTE_DENY = 5'd2,
        RC_IMM_STATUS_BAD_OPCODE  = 5'd3,
        RC_IMM_STATUS_MALFORMED   = 5'd4
    } rc_imm_status_e;

    typedef enum logic [3:0] {
        AH_TABLE_STATUS_OK         = 4'd0, // AH create/update/lookup/delete 成功。
        AH_TABLE_STATUS_MISS       = 4'd1, // AH ID 未命中。
        AH_TABLE_STATUS_ALIAS      = 4'd2, // 同一个 AH ID 出现多个 valid 表项。
        AH_TABLE_STATUS_PERMISSION = 4'd3, // owner_function 或 PD 不匹配。
        AH_TABLE_STATUS_FULL       = 4'd4, // 没有空闲 AH table slot。
        AH_TABLE_STATUS_INVALID    = 4'd5  // AH entry 无效或字段不满足最小要求。
    } ah_table_status_e;

    typedef enum logic [4:0] {
        UD_TX_STATUS_OK             = 5'd0, // UD SEND 已接受并生成 packet/completion。
        UD_TX_STATUS_BAD_QP_TYPE    = 5'd1, // 请求不是 UD QP，避免误走 RC connection 语义。
        UD_TX_STATUS_UNSUPPORTED_OP = 5'd2, // UD transmit 当前只支持 SEND。
        UD_TX_STATUS_AH_MISS        = 5'd3, // WQE 指向的 AH 不存在或无效。
        UD_TX_STATUS_AH_PERMISSION  = 5'd4, // AH owner/PD 与请求不匹配。
        UD_TX_STATUS_MISSING_QKEY   = 5'd5  // AH/WQE 未提供可放入 DETH 的 Q_Key。
    } ud_tx_status_e;

    typedef struct packed {
        logic [15:0]            desc_id;        // 来源 descriptor / SQ slot ID。
        logic [QP_ID_W-1:0]     qpn;            // 本地 UD QPN，也是 DETH source QPN。
        logic [CQ_ID_W-1:0]     cqn;            // 本地 send completion 写入的 CQ。
        logic [VF_ID_W-1:0]     owner_function; // 发起 UD SEND 的 PF/VF function。
        logic [PD_ID_W-1:0]     pd_id;          // QP 所属 Protection Domain，用于 AH 权限检查。
        logic [WR_ID_W-1:0]     wr_id;          // 原始 WR ID，回填到本地 send completion。
        qp_type_e               qp_type;        // 必须为 QP_TYPE_UD。
        rdma_opcode_e           opcode;         // 当前仅支持 RDMA_OP_SEND。
        logic [AH_ID_W-1:0]     ah_id;          // WQE/WR 中携带的 Address Handle ID。
        logic [QP_ID_W-1:0]     dest_qpn;       // UD BTH destination QPN。
        logic [QKEY_W-1:0]      qkey;           // 可选 WQE Q_Key；为 0 时使用 AH qkey。
        logic [PSN_W-1:0]       psn;            // UD packet PSN，通常来自 QP/SQ 侧分配。
        logic [511:0]           payload_data;   // 单 beat UD payload，占位给后续 DMA payload stream。
        logic [15:0]            payload_len;    // UD SEND payload 字节数。
        logic                   solicited;      // 是否请求 solicited completion/packet hint。
        logic                   completion_required; // 是否生成本地 send completion。
    } ud_tx_req_t;

    typedef enum logic [4:0] {
        UD_RX_STATUS_OK             = 5'd0, // UD packet 已通过检查并生成 receive completion seed。
        UD_RX_STATUS_INVALID_DETH   = 5'd1, // packet 缺失 DETH 或 DETH 字段无效。
        UD_RX_STATUS_QKEY_MISMATCH  = 5'd2, // DETH Q_Key 与目标 UD QP qkey 不匹配。
        UD_RX_STATUS_MISSING_RQ_WQE = 5'd3, // 目标 QP 没有可消费的 Recv WQE。
        UD_RX_STATUS_MALFORMED      = 5'd4, // opcode/status/payload 元数据不符合 UD receive 最小要求。
        UD_RX_STATUS_QP_ERROR       = 5'd5, // QP lookup/type/state/permission 检查失败。
        UD_RX_STATUS_DMA_ERROR      = 5'd6  // payload 写入 receive buffer 的 DMA stub 报错。
    } ud_rx_status_e;

    typedef struct packed {
        logic [31:0] invalid_deth;   // 缺失或无效 DETH drop 计数。
        logic [31:0] qkey_mismatch;  // Q_Key 不匹配 drop 计数。
        logic [31:0] missing_rq_wqe; // 无 Recv WQE drop 计数。
        logic [31:0] malformed;      // malformed/unsupported UD packet drop 计数。
    } ud_rx_counters_t;

    typedef struct packed {
        completion_event_t       event;      // 送往 completion_engine 的基础 receive completion event。
        logic [QP_ID_W-1:0]      source_qpn; // DETH source QPN，后续 CQE/parser 用于 Verbs wc.src_qp。
    } ud_rx_completion_t;

    typedef struct packed {
        csr_cmd_e                   cmd_id;         // Mailbox 命令操作码。
        logic [VF_ID_W-1:0]         func_id;        // 拥有该命令的 PF/VF function。
        logic [15:0]                seq;            // 驱动用于匹配响应的 sequence number。
        logic [15:0]                arg_len;        // 有效命令参数字节数。
        logic [31:0]                status;         // 命令完成状态/错误码。
    } csr_cmd_hdr_t;

endpackage : smartnic_pkg
