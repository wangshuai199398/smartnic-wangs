// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// DMA MR integration 最小实现。
//
// 本模块把 dma_sge_traversal 输出的 VA segment 接到 MR 保护检查管线：
// key direction/lookup -> access_flags -> PD -> VA->PA -> refcount +1。
// 当前阶段不实现 host memory read/write、PMTU/4KB split、DMA 仲裁或 completion error。

`timescale 1ns/1ps

import smartnic_pkg::*;

module dma_mr_integration (
    input  logic                         clk,                         // integration 时钟。
    input  logic                         rst_n,                       // 低有效复位。

    // ------------------------------------------------------------------
    // DMA segment input from SGE traversal
    // ------------------------------------------------------------------
    input  logic                         dma_segment_valid,           // 输入 segment 有效。
    output logic                         dma_segment_ready,           // 本模块可接收 segment。
    input  logic [15:0]                  dma_segment_desc_id,         // 来源 descriptor ID。
    input  logic [QP_ID_W-1:0]           dma_segment_qpn,             // segment 所属 QPN。
    input  logic [VF_ID_W-1:0]           dma_segment_owner_function,  // segment 所属 function。
    input  logic [PD_ID_W-1:0]           dma_segment_pd_id,           // QP PD。
    input  mr_operation_e                dma_segment_operation,       // 本次访问 operation。
    input  logic [DMA_SGE_COUNT_W-1:0]   dma_segment_index,           // SGE/segment index。
    input  logic [ADDR_W-1:0]            dma_segment_va,              // segment VA。
    input  logic [DMA_LEN_W-1:0]         dma_segment_len,             // segment 长度。
    input  logic [KEY_W-1:0]             dma_segment_lkey,            // 本地 lkey。
    input  logic [KEY_W-1:0]             dma_segment_rkey,            // 远端 rkey。
    input  logic                         dma_segment_is_remote,       // 1 使用 rkey/remote path。
    input  logic [15:0]                  dma_segment_flags,           // segment flags。
    input  logic [DMA_BYTE_OFFSET_W-1:0] dma_segment_byte_offset,     // WR payload 内偏移。
    input  logic                         dma_segment_is_last,         // 是否最后一段。

    // ------------------------------------------------------------------
    // Protected DMA segment output
    // ------------------------------------------------------------------
    output logic                         protected_segment_valid,     // protected segment 有效。
    input  logic                         protected_segment_ready,     // 下游可接收 protected segment。
    output logic [15:0]                  protected_segment_desc_id,   // 来源 descriptor ID。
    output logic [QP_ID_W-1:0]           protected_segment_qpn,       // segment 所属 QPN。
    output logic [VF_ID_W-1:0]           protected_segment_owner_function, // 所属 function。
    output logic [PD_ID_W-1:0]           protected_segment_pd_id,     // 已校验 PD。
    output mr_operation_e                protected_segment_operation, // 已校验 operation。
    output logic [DMA_SGE_COUNT_W-1:0]   protected_segment_index,     // segment index。
    output logic [ADDR_W-1:0]            protected_segment_va,        // 原始 VA。
    output logic [ADDR_W-1:0]            protected_segment_pa,        // 转换后的 PA。
    output logic [DMA_LEN_W-1:0]         protected_segment_len,       // segment 长度。
    output logic [KEY_W-1:0]             protected_segment_key,       // 实际使用的 lkey/rkey。
    output logic [DMA_BYTE_OFFSET_W-1:0] protected_segment_byte_offset,// WR payload 内偏移。
    output logic                         protected_segment_is_last,   // 是否最后一段。
    output logic [5:0]                   protected_segment_access_flags,// MR/MW access_flags。
    output mr_ref_token_t                protected_segment_mr_refcount_token, // 后续 ref_dec token。
    output dma_mr_error_e                protected_segment_error_code,// 成功为 NONE。

    // ------------------------------------------------------------------
    // Error output for descriptor-level error path
    // ------------------------------------------------------------------
    output logic                         dma_mr_error_valid,          // 错误响应有效。
    input  logic                         dma_mr_error_ready,          // 下游已接收错误。
    output logic [15:0]                  dma_mr_error_desc_id,        // 错误来源 descriptor ID。
    output logic [QP_ID_W-1:0]           dma_mr_error_qpn,            // 错误来源 QPN。
    output logic [DMA_SGE_COUNT_W-1:0]   dma_mr_error_segment_index,  // 出错 segment index。
    output dma_mr_error_e                dma_mr_error_code,           // 统一 DMA/MR 错误码。

    // ------------------------------------------------------------------
    // MR table check interface used by mr_key_checker
    // ------------------------------------------------------------------
    output logic                         mr_check_valid,              // 发往 MR table 的 bounds/check 请求。
    input  logic                         mr_check_ready,              // MR table 可接收 check。
    output logic [KEY_W-1:0]             mr_check_key,                // lkey 或 rkey。
    output logic [ADDR_W-1:0]            mr_check_va,                 // 访问 VA。
    output logic [DMA_LEN_W-1:0]         mr_check_len,                // 访问长度。
    output logic                         mr_check_is_remote,          // 1 使用 rkey，0 使用 lkey。
    output logic [VF_ID_W-1:0]           mr_check_owner_function,     // 发起访问的 function。
    output logic [PD_ID_W-1:0]           mr_check_pd_id,              // 发起访问的 PD。
    output logic                         mr_check_admin_bypass,       // 当前阶段固定为 0。
    input  logic                         mr_check_rsp_valid,          // MR table check 响应有效。
    output logic                         mr_check_rsp_ready,          // 本模块可接收 check 响应。
    input  logic                         mr_check_hit,                // MR table check 命中。
    input  mr_entry_t                    mr_check_entry,              // 命中的 MR/MW entry。
    input  logic [ADDR_W-1:0]            mr_check_pa,                 // MR table 计算出的 PA。
    input  mr_table_status_e             mr_check_error_code,         // MR table check 状态。

    // ------------------------------------------------------------------
    // MR refcount update interface
    // ------------------------------------------------------------------
    output logic                         mr_ref_inc_valid,            // refcount +1 请求。
    output logic                         mr_ref_dec_valid,            // 当前阶段固定为 0，ref_dec 留给真实 DMA 完成路径。
    input  logic                         mr_ref_update_ready,         // MR table 可接收 refcount 更新。
    output logic [KEY_W-1:0]             mr_ref_key,                  // refcount 使用的 key。
    output logic                         mr_ref_is_remote,            // 1 使用 rkey，0 使用 lkey。
    output logic [VF_ID_W-1:0]           mr_ref_owner_function,       // refcount owner function。
    output logic                         mr_ref_admin_bypass,         // 当前阶段固定为 0。
    input  logic                         mr_ref_update_rsp_valid,     // refcount 更新响应有效。
    output logic                         mr_ref_update_rsp_ready,     // 本模块可接收 refcount 响应。
    input  mr_table_status_e             mr_ref_update_status,        // refcount 更新状态。
    input  logic [MR_REFCOUNT_W-1:0]     mr_refcount_out,             // 更新后的 refcount。
    input  logic                         mr_refcount_zero,            // 更新后是否为 0。

    output dma_mr_integration_state_e    debug_state                  // 调试观察 FSM 状态。
);

    dma_mr_integration_state_e state_reg;
    logic key_check_req_issued_reg;
    logic access_check_req_issued_reg;
    logic pd_check_req_issued_reg;
    logic ref_inc_issued_reg;

    logic [15:0] desc_id_reg;
    logic [QP_ID_W-1:0] qpn_reg;
    logic [VF_ID_W-1:0] owner_function_reg;
    logic [PD_ID_W-1:0] pd_id_reg;
    mr_operation_e operation_reg;
    logic [DMA_SGE_COUNT_W-1:0] index_reg;
    logic [ADDR_W-1:0] va_reg;
    logic [DMA_LEN_W-1:0] len_reg;
    logic [KEY_W-1:0] lkey_reg;
    logic [KEY_W-1:0] rkey_reg;
    logic is_remote_reg;
    logic [15:0] flags_reg;
    logic [DMA_BYTE_OFFSET_W-1:0] byte_offset_reg;
    logic is_last_reg;

    logic [KEY_W-1:0] selected_key_reg;
    mr_entry_t key_entry_reg;
    logic [ADDR_W-1:0] key_pa_reg;
    mr_entry_t access_entry_reg;
    logic [ADDR_W-1:0] access_pa_reg;
    logic [5:0] access_flags_used_reg;
    mr_entry_t pd_entry_reg;
    logic [ADDR_W-1:0] protected_pa_reg;
    logic [5:0] access_flags_reg;
    mr_ref_token_t ref_token_reg;
    dma_mr_error_e error_code_reg;

    logic key_req_valid;
    logic key_req_ready;
    logic key_req_fire;
    logic key_resp_valid;
    logic key_resp_ready;
    logic key_allowed;
    mr_entry_t key_entry;
    logic [ADDR_W-1:0] key_physical_addr;
    mr_key_check_error_e key_error_code;

    logic access_req_valid;
    logic access_req_ready;
    logic access_req_fire;
    logic access_resp_valid;
    logic access_resp_ready;
    logic access_allowed;
    logic [ADDR_W-1:0] access_physical_addr;
    logic [5:0] access_flags_used;
    mr_access_check_error_e access_error_code;

    logic pd_req_valid;
    logic pd_req_ready;
    logic pd_req_fire;
    logic pd_resp_valid;
    logic pd_resp_ready;
    logic pd_allowed;
    logic [ADDR_W-1:0] pd_physical_addr;
    mr_entry_t pd_entry;
    mr_pd_check_error_e pd_error_code;

    logic ref_inc_fire;
    logic ref_rsp_fire;
    logic segment_fire;
    logic protected_fire;
    logic error_fire;
    logic operation_supported;

    assign debug_state = state_reg;
    assign dma_segment_ready = (state_reg == DMA_MR_STATE_IDLE) &&
                               !protected_segment_valid &&
                               !dma_mr_error_valid;
    assign segment_fire = dma_segment_valid && dma_segment_ready;
    assign protected_fire = protected_segment_valid && protected_segment_ready;
    assign error_fire = dma_mr_error_valid && dma_mr_error_ready;

    assign protected_segment_desc_id = desc_id_reg;
    assign protected_segment_qpn = qpn_reg;
    assign protected_segment_owner_function = owner_function_reg;
    assign protected_segment_pd_id = pd_id_reg;
    assign protected_segment_operation = operation_reg;
    assign protected_segment_index = index_reg;
    assign protected_segment_va = va_reg;
    assign protected_segment_pa = protected_pa_reg;
    assign protected_segment_len = len_reg;
    assign protected_segment_key = selected_key_reg;
    assign protected_segment_byte_offset = byte_offset_reg;
    assign protected_segment_is_last = is_last_reg;
    assign protected_segment_access_flags = access_flags_reg;
    assign protected_segment_mr_refcount_token = ref_token_reg;
    assign protected_segment_error_code = error_code_reg;

    assign dma_mr_error_desc_id = desc_id_reg;
    assign dma_mr_error_qpn = qpn_reg;
    assign dma_mr_error_segment_index = index_reg;
    assign dma_mr_error_code = error_code_reg;

    assign key_req_valid = (state_reg == DMA_MR_STATE_KEY_CHECK) &&
                           !key_check_req_issued_reg;
    assign key_req_fire = key_req_valid && key_req_ready;
    assign key_resp_ready = (state_reg == DMA_MR_STATE_KEY_CHECK);

    assign access_req_valid = (state_reg == DMA_MR_STATE_ACCESS_CHECK) &&
                              !access_check_req_issued_reg;
    assign access_req_fire = access_req_valid && access_req_ready;
    assign access_resp_ready = (state_reg == DMA_MR_STATE_ACCESS_CHECK);

    assign pd_req_valid = (state_reg == DMA_MR_STATE_PD_CHECK) &&
                          !pd_check_req_issued_reg;
    assign pd_req_fire = pd_req_valid && pd_req_ready;
    assign pd_resp_ready = (state_reg == DMA_MR_STATE_PD_CHECK);

    assign mr_ref_inc_valid = (state_reg == DMA_MR_STATE_REFCOUNT_INC) &&
                              !ref_inc_issued_reg;
    assign mr_ref_dec_valid = 1'b0;
    assign mr_ref_key = selected_key_reg;
    assign mr_ref_is_remote = is_remote_reg;
    assign mr_ref_owner_function = owner_function_reg;
    assign mr_ref_admin_bypass = 1'b0;
    assign mr_ref_update_rsp_ready = (state_reg == DMA_MR_STATE_REFCOUNT_INC);
    assign ref_inc_fire = mr_ref_inc_valid && mr_ref_update_ready;
    assign ref_rsp_fire = mr_ref_update_rsp_valid && mr_ref_update_rsp_ready;

    always_comb begin
        operation_supported = 1'b1;
        unique case (operation_reg)
            MR_OP_LOCAL_DMA_READ,
            MR_OP_LOCAL_DMA_WRITE,
            MR_OP_LOCAL_RECV_WRITE,
            MR_OP_REMOTE_RDMA_READ,
            MR_OP_REMOTE_RDMA_WRITE,
            MR_OP_REMOTE_ATOMIC,
            MR_OP_MW_BIND: operation_supported = 1'b1;
            default:       operation_supported = 1'b0;
        endcase
    end

    function automatic dma_mr_error_e map_key_error(input mr_key_check_error_e err);
        begin
            unique case (err)
                MR_KEY_CHECK_ERR_NONE:                return DMA_MR_ERR_NONE;
                MR_KEY_CHECK_ERR_INVALID_KEY:         return DMA_MR_ERR_INVALID_KEY;
                MR_KEY_CHECK_ERR_LOCAL_KEY_REQUIRED,
                MR_KEY_CHECK_ERR_REMOTE_KEY_REQUIRED: return DMA_MR_ERR_KEY_DIRECTION;
                MR_KEY_CHECK_ERR_INVALID_OPERATION:   return DMA_MR_ERR_UNSUPPORTED_OP;
                MR_KEY_CHECK_ERR_LOOKUP_MISS:         return DMA_MR_ERR_LOOKUP_MISS;
                MR_KEY_CHECK_ERR_PERMISSION:          return DMA_MR_ERR_PERMISSION;
                MR_KEY_CHECK_ERR_PENDING:             return DMA_MR_ERR_PENDING;
                MR_KEY_CHECK_ERR_LENGTH:              return DMA_MR_ERR_ZERO_LENGTH;
                MR_KEY_CHECK_ERR_BOUNDS:              return DMA_MR_ERR_BOUNDS;
                default:                              return DMA_MR_ERR_CHECKER;
            endcase
        end
    endfunction

    function automatic dma_mr_error_e map_access_error(input mr_access_check_error_e err);
        begin
            unique case (err)
                MR_ACCESS_ERR_NONE:              return DMA_MR_ERR_NONE;
                MR_ACCESS_ERR_INVALID_ENTRY:     return DMA_MR_ERR_LOOKUP_MISS;
                MR_ACCESS_ERR_PENDING:           return DMA_MR_ERR_PENDING;
                MR_ACCESS_ERR_PERMISSION:        return DMA_MR_ERR_PERMISSION;
                MR_ACCESS_ERR_LENGTH:            return DMA_MR_ERR_ZERO_LENGTH;
                MR_ACCESS_ERR_BOUNDS:            return DMA_MR_ERR_BOUNDS;
                MR_ACCESS_ERR_ADDR_OVERFLOW:     return DMA_MR_ERR_ADDR_OVERFLOW;
                MR_ACCESS_ERR_ACCESS_DENIED:     return DMA_MR_ERR_ACCESS_DENIED;
                MR_ACCESS_ERR_UNKNOWN_OPERATION: return DMA_MR_ERR_UNSUPPORTED_OP;
                default:                         return DMA_MR_ERR_CHECKER;
            endcase
        end
    endfunction

    function automatic dma_mr_error_e map_pd_error(input mr_pd_check_error_e err);
        begin
            unique case (err)
                MR_PD_CHECK_ERR_NONE:              return DMA_MR_ERR_NONE;
                MR_PD_CHECK_ERR_INVALID_ENTRY:     return DMA_MR_ERR_LOOKUP_MISS;
                MR_PD_CHECK_ERR_PENDING:           return DMA_MR_ERR_PENDING;
                MR_PD_CHECK_ERR_PERMISSION:        return DMA_MR_ERR_PERMISSION;
                MR_PD_CHECK_ERR_MISSING_QP_PD,
                MR_PD_CHECK_ERR_PD_MISMATCH:       return DMA_MR_ERR_PD_MISMATCH;
                MR_PD_CHECK_ERR_INVALID_OPERATION: return DMA_MR_ERR_UNSUPPORTED_OP;
                default:                           return DMA_MR_ERR_CHECKER;
            endcase
        end
    endfunction

    function automatic dma_mr_error_e map_ref_error(input mr_table_status_e status);
        begin
            unique case (status)
                MR_TABLE_STATUS_OK:         return DMA_MR_ERR_NONE;
                MR_TABLE_STATUS_MISS:       return DMA_MR_ERR_LOOKUP_MISS;
                MR_TABLE_STATUS_PERMISSION: return DMA_MR_ERR_PERMISSION;
                MR_TABLE_STATUS_PENDING:    return DMA_MR_ERR_PENDING;
                MR_TABLE_STATUS_REF_OVER:   return DMA_MR_ERR_REFCOUNT_OVERFLOW;
                default:                    return DMA_MR_ERR_CHECKER;
            endcase
        end
    endfunction

    mr_key_checker u_key_checker (
        .clk                         (clk),
        .rst_n                       (rst_n),
        .key_check_valid             (key_req_valid),
        .key_check_ready             (key_req_ready),
        .key_check_key               (selected_key_reg),
        .key_check_is_remote         (is_remote_reg),
        .key_check_operation         (operation_reg),
        .key_check_owner_function    (owner_function_reg),
        .key_check_pd_id             (pd_id_reg),
        .key_check_va                (va_reg),
        .key_check_len               (len_reg),
        .key_check_resp_valid        (key_resp_valid),
        .key_check_resp_ready        (key_resp_ready),
        .key_check_allowed           (key_allowed),
        .key_check_entry             (key_entry),
        .key_check_physical_addr     (key_physical_addr),
        .key_check_error_code        (key_error_code),
        .mr_check_valid              (mr_check_valid),
        .mr_check_ready              (mr_check_ready),
        .mr_check_key                (mr_check_key),
        .mr_check_va                 (mr_check_va),
        .mr_check_len                (mr_check_len),
        .mr_check_is_remote          (mr_check_is_remote),
        .mr_check_owner_function     (mr_check_owner_function),
        .mr_check_pd_id              (mr_check_pd_id),
        .mr_check_admin_bypass       (mr_check_admin_bypass),
        .mr_check_rsp_valid          (mr_check_rsp_valid),
        .mr_check_rsp_ready          (mr_check_rsp_ready),
        .mr_check_hit                (mr_check_hit),
        .mr_check_entry              (mr_check_entry),
        .mr_check_pa                 (mr_check_pa),
        .mr_check_error_code         (mr_check_error_code)
    );

    mr_access_checker u_access_checker (
        .clk                            (clk),
        .rst_n                          (rst_n),
        .access_check_valid             (access_req_valid),
        .access_check_ready             (access_req_ready),
        .access_check_operation         (operation_reg),
        .access_check_entry             (key_entry_reg),
        .access_check_va                (va_reg),
        .access_check_len               (len_reg),
        .access_check_is_remote         (is_remote_reg),
        .access_check_owner_function    (owner_function_reg),
        .access_check_pd_id             (pd_id_reg),
        .access_parent_permission_mask  ('0),
        .access_parent_permission_valid (1'b0),
        .access_check_resp_valid        (access_resp_valid),
        .access_check_resp_ready        (access_resp_ready),
        .access_allowed                 (access_allowed),
        .access_physical_addr           (access_physical_addr),
        .access_flags_used              (access_flags_used),
        .access_error_code              (access_error_code)
    );

    mr_pd_checker u_pd_checker (
        .clk                        (clk),
        .rst_n                      (rst_n),
        .pd_check_valid             (pd_req_valid),
        .pd_check_ready             (pd_req_ready),
        .pd_check_operation         (operation_reg),
        .pd_check_is_remote         (is_remote_reg),
        .pd_check_mr_entry          (access_entry_reg),
        .pd_check_qp_pd_id          (pd_id_reg),
        .pd_check_qp_pd_valid       (1'b1),
        .pd_check_mr_pd_id          (access_entry_reg.pd_id),
        .pd_check_qpn               (qpn_reg),
        .pd_check_owner_function    (owner_function_reg),
        .pd_check_va                (va_reg),
        .pd_check_len               (len_reg),
        .pd_check_physical_addr     (access_pa_reg),
        .pd_parent_pd_id            ('0),
        .pd_parent_pd_valid         (1'b0),
        .pd_check_resp_valid        (pd_resp_valid),
        .pd_check_resp_ready        (pd_resp_ready),
        .pd_check_allowed           (pd_allowed),
        .pd_check_physical_addr_out (pd_physical_addr),
        .pd_check_mr_entry_out      (pd_entry),
        .pd_check_error_code        (pd_error_code)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= DMA_MR_STATE_IDLE;
            key_check_req_issued_reg <= 1'b0;
            access_check_req_issued_reg <= 1'b0;
            pd_check_req_issued_reg <= 1'b0;
            ref_inc_issued_reg <= 1'b0;
            desc_id_reg <= '0;
            qpn_reg <= '0;
            owner_function_reg <= '0;
            pd_id_reg <= '0;
            operation_reg <= MR_OP_LOCAL_DMA_READ;
            index_reg <= '0;
            va_reg <= '0;
            len_reg <= '0;
            lkey_reg <= '0;
            rkey_reg <= '0;
            is_remote_reg <= 1'b0;
            flags_reg <= '0;
            byte_offset_reg <= '0;
            is_last_reg <= 1'b0;
            selected_key_reg <= '0;
            key_entry_reg <= '0;
            key_pa_reg <= '0;
            access_entry_reg <= '0;
            access_pa_reg <= '0;
            access_flags_used_reg <= '0;
            pd_entry_reg <= '0;
            protected_pa_reg <= '0;
            access_flags_reg <= '0;
            ref_token_reg <= '0;
            error_code_reg <= DMA_MR_ERR_NONE;
            protected_segment_valid <= 1'b0;
            dma_mr_error_valid <= 1'b0;
        end else begin
            unique case (state_reg)
                DMA_MR_STATE_IDLE: begin
                    error_code_reg <= DMA_MR_ERR_NONE;
                    key_check_req_issued_reg <= 1'b0;
                    access_check_req_issued_reg <= 1'b0;
                    pd_check_req_issued_reg <= 1'b0;
                    ref_inc_issued_reg <= 1'b0;

                    if (protected_fire) begin
                        protected_segment_valid <= 1'b0;
                    end
                    if (error_fire) begin
                        dma_mr_error_valid <= 1'b0;
                    end

                    if (segment_fire) begin
                        desc_id_reg <= dma_segment_desc_id;
                        qpn_reg <= dma_segment_qpn;
                        owner_function_reg <= dma_segment_owner_function;
                        pd_id_reg <= dma_segment_pd_id;
                        operation_reg <= dma_segment_operation;
                        index_reg <= dma_segment_index;
                        va_reg <= dma_segment_va;
                        len_reg <= dma_segment_len;
                        lkey_reg <= dma_segment_lkey;
                        rkey_reg <= dma_segment_rkey;
                        is_remote_reg <= dma_segment_is_remote;
                        flags_reg <= dma_segment_flags;
                        byte_offset_reg <= dma_segment_byte_offset;
                        is_last_reg <= dma_segment_is_last;
                        selected_key_reg <= dma_segment_is_remote ?
                                            dma_segment_rkey :
                                            dma_segment_lkey;
                        state_reg <= DMA_MR_STATE_ACCEPT;
                    end
                end

                DMA_MR_STATE_ACCEPT: begin
                    if (len_reg == '0) begin
                        error_code_reg <= DMA_MR_ERR_ZERO_LENGTH;
                        dma_mr_error_valid <= 1'b1;
                        state_reg <= DMA_MR_STATE_ERROR;
                    end else if (!operation_supported) begin
                        error_code_reg <= DMA_MR_ERR_UNSUPPORTED_OP;
                        dma_mr_error_valid <= 1'b1;
                        state_reg <= DMA_MR_STATE_ERROR;
                    end else begin
                        state_reg <= DMA_MR_STATE_KEY_CHECK;
                    end
                end

                DMA_MR_STATE_KEY_CHECK: begin
                    if (key_req_fire) begin
                        key_check_req_issued_reg <= 1'b1;
                    end

                    if (key_resp_valid && key_resp_ready) begin
                        key_check_req_issued_reg <= 1'b0;
                        if (!key_allowed) begin
                            error_code_reg <= map_key_error(key_error_code);
                            dma_mr_error_valid <= 1'b1;
                            state_reg <= DMA_MR_STATE_ERROR;
                        end else begin
                            key_entry_reg <= key_entry;
                            key_pa_reg <= key_physical_addr;
                            state_reg <= DMA_MR_STATE_ACCESS_CHECK;
                        end
                    end
                end

                DMA_MR_STATE_ACCESS_CHECK: begin
                    if (access_req_fire) begin
                        access_check_req_issued_reg <= 1'b1;
                    end

                    if (access_resp_valid && access_resp_ready) begin
                        access_check_req_issued_reg <= 1'b0;
                        if (!access_allowed) begin
                            error_code_reg <= (key_entry_reg.memory_window &&
                                               key_entry_reg.invalidating) ?
                                              DMA_MR_ERR_MW_INVALIDATING :
                                              map_access_error(access_error_code);
                            dma_mr_error_valid <= 1'b1;
                            state_reg <= DMA_MR_STATE_ERROR;
                        end else begin
                            access_entry_reg <= key_entry_reg;
                            access_pa_reg <= access_physical_addr;
                            access_flags_used_reg <= access_flags_used;
                            state_reg <= DMA_MR_STATE_PD_CHECK;
                        end
                    end
                end

                DMA_MR_STATE_PD_CHECK: begin
                    if (pd_req_fire) begin
                        pd_check_req_issued_reg <= 1'b1;
                    end

                    if (pd_resp_valid && pd_resp_ready) begin
                        pd_check_req_issued_reg <= 1'b0;
                        if (!pd_allowed) begin
                            error_code_reg <= map_pd_error(pd_error_code);
                            dma_mr_error_valid <= 1'b1;
                            state_reg <= DMA_MR_STATE_ERROR;
                        end else begin
                            pd_entry_reg <= pd_entry;
                            protected_pa_reg <= pd_physical_addr;
                            access_flags_reg <= pd_entry.access_flags;
                            state_reg <= DMA_MR_STATE_TRANSLATE;
                        end
                    end
                end

                DMA_MR_STATE_TRANSLATE: begin
                    if (pd_entry_reg.pending_deregister) begin
                        error_code_reg <= DMA_MR_ERR_PENDING;
                        dma_mr_error_valid <= 1'b1;
                        state_reg <= DMA_MR_STATE_ERROR;
                    end else if (pd_entry_reg.invalidating) begin
                        error_code_reg <= pd_entry_reg.memory_window ?
                                          DMA_MR_ERR_MW_INVALIDATING :
                                          DMA_MR_ERR_PENDING;
                        dma_mr_error_valid <= 1'b1;
                        state_reg <= DMA_MR_STATE_ERROR;
                    end else begin
                        ref_token_reg.key <= selected_key_reg;
                        ref_token_reg.is_remote <= is_remote_reg;
                        ref_token_reg.owner_function <= owner_function_reg;
                        ref_token_reg.mr_id <= pd_entry_reg.mr_id;
                        state_reg <= DMA_MR_STATE_REFCOUNT_INC;
                    end
                end

                DMA_MR_STATE_REFCOUNT_INC: begin
                    if (ref_inc_fire) begin
                        ref_inc_issued_reg <= 1'b1;
                    end

                    if (ref_rsp_fire) begin
                        ref_inc_issued_reg <= 1'b0;
                        if (mr_ref_update_status != MR_TABLE_STATUS_OK) begin
                            error_code_reg <= map_ref_error(mr_ref_update_status);
                            dma_mr_error_valid <= 1'b1;
                            state_reg <= DMA_MR_STATE_ERROR;
                        end else begin
                            error_code_reg <= DMA_MR_ERR_NONE;
                            protected_segment_valid <= 1'b1;
                            state_reg <= DMA_MR_STATE_EMIT;
                        end
                    end
                end

                DMA_MR_STATE_EMIT: begin
                    if (protected_fire) begin
                        protected_segment_valid <= 1'b0;
                        state_reg <= DMA_MR_STATE_IDLE;
                    end
                end

                DMA_MR_STATE_ERROR: begin
                    if (error_fire) begin
                        dma_mr_error_valid <= 1'b0;
                        state_reg <= DMA_MR_STATE_IDLE;
                    end
                end

                default: begin
                    state_reg <= DMA_MR_STATE_IDLE;
                    key_check_req_issued_reg <= 1'b0;
                    access_check_req_issued_reg <= 1'b0;
                    pd_check_req_issued_reg <= 1'b0;
                    ref_inc_issued_reg <= 1'b0;
                    protected_segment_valid <= 1'b0;
                    dma_mr_error_valid <= 1'b0;
                    error_code_reg <= DMA_MR_ERR_NONE;
                end
            endcase
        end
    end

    // 当前阶段保留 flags、key_pa、refcount_out/zero，后续 7.5/7.6/7.9 可用于调试或 error completion。
    logic unused_outputs;
    assign unused_outputs = ^{flags_reg, key_pa_reg, access_flags_used_reg, mr_refcount_out, mr_refcount_zero};

endmodule : dma_mr_integration
