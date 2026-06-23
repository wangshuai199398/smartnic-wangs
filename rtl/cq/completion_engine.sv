// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// Completion engine 最小实现。
//
// 本模块接收 SQ/RQ/cleanup/error 路径产生的 completion event，查询 CQ
// context，检查 CQN 和 owner_function，然后格式化 64-byte CQE。当前阶段
// 不计算 CQE host 地址，不写 host CQ buffer，不更新 CQ producer index，
// 也不触发 MSI-X；这些内容留给 5.3、5.4 和 5.5。

`timescale 1ns/1ps

import smartnic_pkg::*;

module completion_engine (
    input  logic                         clk,                    // completion engine 时钟。
    input  logic                         rst_n,                  // 低有效复位。

    // ------------------------------------------------------------------
    // Completion event input
    // ------------------------------------------------------------------
    input  logic                         event_valid,            // 上游 completion event 有效。
    output logic                         event_ready,            // 本模块可接收 completion event。
    input  completion_event_type_e       event_type,             // SQ、RQ、cleanup 或 error event。
    input  logic [QP_ID_W-1:0]           qpn,                    // 产生 completion 的 QPN。
    input  logic [CQ_ID_W-1:0]           cqn,                    // 目标 CQN。
    input  logic [VF_ID_W-1:0]           owner_function,         // completion 所属 PF/VF function。
    input  logic [WR_ID_W-1:0]           wr_id,                  // 应写入 CQE 的 WR ID。
    input  rdma_opcode_e                 opcode,                 // 原始 WR opcode。
    input  cmpl_status_e                 status,                 // 上游 completion 状态。
    input  logic [DMA_LEN_W-1:0]         byte_len,               // 完成字节数。
    input  logic [31:0]                  imm_data,               // immediate data。
    input  logic                         has_imm,                // immediate data 是否有效。
    input  logic                         solicited,              // 是否为 solicited completion。
    input  logic [31:0]                  vendor_error,           // 上游私有错误码。
    input  completion_source_e           source_engine,          // 事件来源模块。

    // ------------------------------------------------------------------
    // CQ context lookup interface
    // ------------------------------------------------------------------
    output logic                         cq_lookup_valid,        // CQ context lookup 请求有效。
    input  logic                         cq_lookup_ready,        // CQ context table 可接收 lookup。
    output logic [CQ_ID_W-1:0]           cq_lookup_cqn,          // 要查询的 CQN。
    output logic [VF_ID_W-1:0]           cq_lookup_function_id,  // 查询所属 function。
    output logic                         cq_lookup_admin_bypass, // completion path 不使用 admin bypass。
    input  logic                         cq_lookup_rsp_valid,    // CQ context lookup 响应有效。
    output logic                         cq_lookup_rsp_ready,    // 本模块可接收 lookup 响应。
    input  logic                         cq_lookup_hit,          // CQ context 命中。
    input  logic                         cq_lookup_miss,         // CQ context 未命中。
    input  cq_table_status_e             cq_lookup_status,       // CQ context lookup 状态。
    input  cq_context_t                  cq_lookup_context,      // 命中的 CQ context。

    // ------------------------------------------------------------------
    // CQE write request output
    // ------------------------------------------------------------------
    output logic                         cqe_write_valid,        // 格式化后的 CQE write 请求有效。
    input  logic                         cqe_write_ready,        // 下游 CQE write path 可接收请求。
    output logic [CQ_ID_W-1:0]           cqe_write_cqn,          // CQE 目标 CQN。
    output logic [VF_ID_W-1:0]           cqe_write_owner_function,// CQE 所属 function。
    output logic [CQE_W-1:0]             cqe_write_data,         // 64-byte / 512-bit CQE packed 数据。
    output logic                         cqe_write_solicited,    // CQE 是否为 solicited completion。
    output cmpl_status_e                 cqe_write_status,       // CQE completion status。
    output logic                         cqe_write_error,        // 本次 CQE 表示错误或 lookup/权限失败。

    // ------------------------------------------------------------------
    // Debug/status
    // ------------------------------------------------------------------
    output completion_engine_state_e     debug_state,            // 当前 completion engine 状态。
    output completion_engine_error_e     error_code              // 最近一次 completion engine 错误码。
);

    completion_engine_state_e state_reg;
    completion_event_t event_reg;
    cqe_t cqe_reg;
    completion_engine_error_e error_reg;
    logic lookup_issued_reg;
    cq_context_t cq_ctx_reg;
    cq_table_status_e cq_status_reg;
    logic cq_hit_reg;

    logic event_fire;
    logic lookup_fire;
    logic lookup_rsp_fire;
    logic write_fire;
    logic lookup_ok;
    cqe_t formatted_cqe;
    cmpl_status_e effective_status;
    cqe_syndrome_e effective_syndrome;
    logic [15:0] effective_flags;
    rdma_opcode_e effective_opcode;
    logic effective_error;
    completion_engine_error_e lookup_error_next;

    assign debug_state = state_reg;
    assign error_code = error_reg;

    assign event_ready = (state_reg == CMPL_ENG_STATE_IDLE);
    assign event_fire = event_valid && event_ready;

    assign cq_lookup_valid = (state_reg == CMPL_ENG_STATE_LOOKUP_CQ) && !lookup_issued_reg;
    assign cq_lookup_cqn = event_reg.cqn;
    assign cq_lookup_function_id = event_reg.owner_function;
    assign cq_lookup_admin_bypass = 1'b0;
    assign cq_lookup_rsp_ready = (state_reg == CMPL_ENG_STATE_WAIT_CQ);
    assign lookup_fire = cq_lookup_valid && cq_lookup_ready;
    assign lookup_rsp_fire = cq_lookup_rsp_valid && cq_lookup_rsp_ready;

    assign lookup_ok = cq_hit_reg &&
                       !cq_lookup_miss &&
                       (cq_status_reg == CQ_TABLE_STATUS_OK) &&
                       cq_ctx_reg.valid &&
                       (cq_ctx_reg.owner_function == event_reg.owner_function);

    assign cqe_write_valid = (state_reg == CMPL_ENG_STATE_WRITE);
    assign cqe_write_cqn = event_reg.cqn;
    assign cqe_write_owner_function = event_reg.owner_function;
    assign cqe_write_data = cqe_reg;
    assign cqe_write_solicited = cqe_reg.solicited;
    assign cqe_write_status = cqe_reg.status;
    assign cqe_write_error = (cqe_reg.status != CMPL_SUCCESS) || (error_reg != CMPL_ENG_ERR_NONE);
    assign write_fire = cqe_write_valid && cqe_write_ready;

    function automatic completion_event_t build_event(
        input completion_event_type_e event_type_i,
        input logic [QP_ID_W-1:0]     qpn_i,
        input logic [CQ_ID_W-1:0]     cqn_i,
        input logic [VF_ID_W-1:0]     owner_function_i,
        input logic [WR_ID_W-1:0]     wr_id_i,
        input rdma_opcode_e           opcode_i,
        input cmpl_status_e           status_i,
        input logic [DMA_LEN_W-1:0]   byte_len_i,
        input logic [31:0]            imm_data_i,
        input logic                   has_imm_i,
        input logic                   solicited_i,
        input logic [31:0]            vendor_error_i,
        input completion_source_e     source_engine_i
    );
        completion_event_t next_event;
        begin
            next_event.event_type = event_type_i;
            next_event.qpn = qpn_i;
            next_event.cqn = cqn_i;
            next_event.owner_function = owner_function_i;
            next_event.wr_id = wr_id_i;
            next_event.opcode = opcode_i;
            next_event.status = status_i;
            next_event.byte_len = byte_len_i;
            next_event.imm_data = imm_data_i;
            next_event.has_imm = has_imm_i;
            next_event.solicited = solicited_i;
            next_event.vendor_error = vendor_error_i;
            next_event.source_engine = source_engine_i;
            return next_event;
        end
    endfunction

    function automatic completion_engine_error_e lookup_status_to_error(
        input cq_table_status_e status_i,
        input logic hit_i,
        input cq_context_t ctx_i,
        input logic [VF_ID_W-1:0] owner_function_i
    );
        begin
            if (!hit_i || !ctx_i.valid || (status_i == CQ_TABLE_STATUS_MISS)) begin
                return CMPL_ENG_ERR_CQ_MISS;
            end
            if ((status_i == CQ_TABLE_STATUS_PERMISSION) ||
                (ctx_i.owner_function != owner_function_i)) begin
                return CMPL_ENG_ERR_PERMISSION;
            end
            if (status_i == CQ_TABLE_STATUS_ALIAS) begin
                return CMPL_ENG_ERR_CQ_ALIAS;
            end
            if (status_i != CQ_TABLE_STATUS_OK) begin
                return CMPL_ENG_ERR_CQ_MISS;
            end
            return CMPL_ENG_ERR_NONE;
        end
    endfunction

    always_comb begin
        lookup_error_next = lookup_status_to_error(cq_status_reg,
                                                  cq_hit_reg,
                                                  cq_ctx_reg,
                                                  event_reg.owner_function);
        effective_status = event_reg.status;
        effective_syndrome = CQE_SYNDROME_NONE;
        effective_flags = 16'h0000;
        effective_opcode = event_reg.opcode;
        effective_error = 1'b0;

        if (!lookup_ok) begin
            effective_status = CMPL_GENERAL_ERR;
            effective_error = 1'b1;
            if (lookup_error_next == CMPL_ENG_ERR_PERMISSION) begin
                effective_syndrome = CQE_SYNDROME_PERMISSION;
            end else begin
                effective_syndrome = CQE_SYNDROME_CQ_LOOKUP;
            end
        end else begin
            unique case (event_reg.event_type)
                CMPL_EVENT_SQ: begin
                    effective_flags |= CQE_FMT_FLAG_SEND;
                    effective_syndrome = (event_reg.status == CMPL_SUCCESS) ?
                                         CQE_SYNDROME_NONE : CQE_SYNDROME_SOURCE_ERR;
                end
                CMPL_EVENT_RQ: begin
                    effective_flags |= CQE_FMT_FLAG_RECV;
                    effective_opcode = event_reg.opcode;
                    effective_syndrome = (event_reg.status == CMPL_SUCCESS) ?
                                         CQE_SYNDROME_NONE : CQE_SYNDROME_SOURCE_ERR;
                end
                CMPL_EVENT_CLEANUP: begin
                    effective_flags |= CQE_FMT_FLAG_FLUSH;
                    effective_status = CMPL_WR_FLUSH_ERR;
                    effective_syndrome = CQE_SYNDROME_FLUSH;
                end
                CMPL_EVENT_ERROR: begin
                    effective_status = (event_reg.status == CMPL_SUCCESS) ?
                                       CMPL_GENERAL_ERR : event_reg.status;
                    effective_syndrome = CQE_SYNDROME_SOURCE_ERR;
                end
                default: begin
                    effective_status = CMPL_GENERAL_ERR;
                    effective_syndrome = CQE_SYNDROME_BAD_EVENT;
                    effective_error = 1'b1;
                end
            endcase
        end

        if (event_reg.has_imm) begin
            effective_flags |= CQE_FMT_FLAG_HAS_IMM;
        end
        if (event_reg.solicited) begin
            effective_flags |= CQE_FMT_FLAG_SOLICITED;
        end
        if ((effective_status != CMPL_SUCCESS) || effective_error) begin
            effective_flags |= CQE_FMT_FLAG_ERROR;
        end

        formatted_cqe = '0;
        formatted_cqe.wr_id = event_reg.wr_id;
        formatted_cqe.qpn = event_reg.qpn;
        formatted_cqe.opcode = effective_opcode;
        formatted_cqe.status = effective_status;
        formatted_cqe.byte_len = event_reg.byte_len;
        formatted_cqe.imm_data = event_reg.imm_data;
        formatted_cqe.has_imm = event_reg.has_imm;
        formatted_cqe.solicited = event_reg.solicited;
        formatted_cqe.vendor_error = event_reg.vendor_error;
        formatted_cqe.owner_function = event_reg.owner_function;
        formatted_cqe.cqn = event_reg.cqn;
        formatted_cqe.syndrome = effective_syndrome;
        formatted_cqe.flags = effective_flags;
        formatted_cqe.timestamp = 64'h0000_0000_0000_0000;
        formatted_cqe.valid = 1'b1;
        formatted_cqe.owner_bit = 1'b0;
        formatted_cqe.reserved = '0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= CMPL_ENG_STATE_IDLE;
            event_reg <= '0;
            cqe_reg <= '0;
            error_reg <= CMPL_ENG_ERR_NONE;
            lookup_issued_reg <= 1'b0;
            cq_ctx_reg <= '0;
            cq_status_reg <= CQ_TABLE_STATUS_MISS;
            cq_hit_reg <= 1'b0;
        end else begin
            unique case (state_reg)
                CMPL_ENG_STATE_IDLE: begin
                    lookup_issued_reg <= 1'b0;
                    error_reg <= CMPL_ENG_ERR_NONE;
                    if (event_fire) begin
                        event_reg <= build_event(event_type,
                                                 qpn,
                                                 cqn,
                                                 owner_function,
                                                 wr_id,
                                                 opcode,
                                                 status,
                                                 byte_len,
                                                 imm_data,
                                                 has_imm,
                                                 solicited,
                                                 vendor_error,
                                                 source_engine);
                        state_reg <= CMPL_ENG_STATE_LOOKUP_CQ;
                    end
                end

                CMPL_ENG_STATE_LOOKUP_CQ: begin
                    if (lookup_fire) begin
                        lookup_issued_reg <= 1'b1;
                        state_reg <= CMPL_ENG_STATE_WAIT_CQ;
                    end
                end

                CMPL_ENG_STATE_WAIT_CQ: begin
                    if (lookup_rsp_fire) begin
                        cq_ctx_reg <= cq_lookup_context;
                        cq_status_reg <= cq_lookup_status;
                        cq_hit_reg <= cq_lookup_hit && !cq_lookup_miss;
                        state_reg <= CMPL_ENG_STATE_FORMAT;
                    end
                end

                CMPL_ENG_STATE_FORMAT: begin
                    cqe_reg <= formatted_cqe;
                    error_reg <= lookup_ok ? CMPL_ENG_ERR_NONE : lookup_error_next;
                    state_reg <= CMPL_ENG_STATE_WRITE;
                end

                CMPL_ENG_STATE_WRITE: begin
                    if (write_fire) begin
                        state_reg <= CMPL_ENG_STATE_IDLE;
                    end
                end

                default: begin
                    state_reg <= CMPL_ENG_STATE_IDLE;
                end
            endcase
        end
    end

endmodule : completion_engine
