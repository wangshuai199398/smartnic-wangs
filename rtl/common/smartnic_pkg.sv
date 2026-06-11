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
