// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// DMA protected segment splitter 最小实现。
//
// 本模块位于 dma_mr_integration 和 host read/write path 之间，只负责把已经
// 完成 MR/PD/权限检查的 protected segment 拆成满足 PMTU、4KB 物理页边界和
// max DMA segment 限制的 split segment。当前阶段不做真实 DMA、不释放 MR refcount。

`timescale 1ns/1ps

import smartnic_pkg::*;

module dma_segment_splitter (
    input  logic                         clk,                         // splitter 时钟。
    input  logic                         rst_n,                       // 低有效复位。

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------
    input  logic [DMA_LEN_W-1:0]         pmtu_bytes,                  // PMTU 字节数，支持 256/512/1024/2048/4096。
    input  logic                         enable_pmtu_split,           // 1 表示按 PMTU 限制 split_len。
    input  logic                         enable_4kb_boundary_split,   // 1 表示禁止 split 跨 4KB PA 边界。
    input  logic [DMA_LEN_W-1:0]         max_dma_segment_bytes,       // 单个 DMA segment 最大字节数，0 使用默认 4096。

    // ------------------------------------------------------------------
    // Protected segment input from dma_mr_integration
    // ------------------------------------------------------------------
    input  logic                         protected_segment_valid,      // protected segment 有效。
    output logic                         protected_segment_ready,      // 本模块可接收 protected segment。
    input  logic [15:0]                  protected_segment_desc_id,    // 来源 descriptor ID。
    input  logic [QP_ID_W-1:0]           protected_segment_qpn,        // segment 所属 QPN。
    input  logic [VF_ID_W-1:0]           protected_segment_owner_function, // 所属 function。
    input  logic [PD_ID_W-1:0]           protected_segment_pd_id,      // 已校验 PD。
    input  mr_operation_e                protected_segment_operation,  // 已校验 operation。
    input  logic [DMA_SGE_COUNT_W-1:0]   protected_segment_index,      // 原 segment index。
    input  logic [ADDR_W-1:0]            protected_segment_va,         // 原 segment VA。
    input  logic [ADDR_W-1:0]            protected_segment_pa,         // 原 segment PA。
    input  logic [DMA_LEN_W-1:0]         protected_segment_len,        // 原 segment 长度。
    input  logic [DMA_BYTE_OFFSET_W-1:0] protected_segment_byte_offset,// WR payload 内偏移。
    input  logic                         protected_segment_is_last,    // 是否为 WQE 最后一段。
    input  mr_ref_token_t                protected_segment_mr_refcount_token, // refcount token。
    input  logic [15:0]                  protected_segment_flags,      // flags 透传。

    // ------------------------------------------------------------------
    // Split segment output
    // ------------------------------------------------------------------
    output logic                         split_segment_valid,          // split segment 有效。
    input  logic                         split_segment_ready,          // 下游可接收 split segment。
    output logic [15:0]                  split_segment_desc_id,        // descriptor ID。
    output logic [QP_ID_W-1:0]           split_segment_qpn,            // QPN。
    output logic [VF_ID_W-1:0]           split_segment_owner_function, // owner function。
    output logic [PD_ID_W-1:0]           split_segment_pd_id,          // PD。
    output mr_operation_e                split_segment_operation,      // operation。
    output logic [DMA_SGE_COUNT_W-1:0]   split_segment_index,          // 原 protected segment index。
    output logic [DMA_SPLIT_SUB_INDEX_W-1:0] split_segment_sub_index,  // split 序号。
    output logic [ADDR_W-1:0]            split_segment_va,             // 当前 split VA。
    output logic [ADDR_W-1:0]            split_segment_pa,             // 当前 split PA。
    output logic [DMA_LEN_W-1:0]         split_segment_len,            // 当前 split 长度。
    output logic [DMA_BYTE_OFFSET_W-1:0] split_segment_byte_offset,    // 当前 split payload 偏移。
    output logic                         split_segment_is_segment_last,// 是否为该 protected segment 最后一个 split。
    output logic                         split_segment_is_wqe_last,    // 是否为整个 WQE 最后一段。
    output mr_ref_token_t                split_segment_mr_refcount_token, // refcount token 透传。
    output logic [15:0]                  split_segment_flags,          // flags 透传。
    output dma_segment_split_error_e     split_segment_error_code,     // split 错误码。

    output dma_segment_split_state_e     debug_state                   // 调试观察 FSM 状态。
);

    dma_segment_split_state_e state_reg;

    logic [15:0] desc_id_reg;
    logic [QP_ID_W-1:0] qpn_reg;
    logic [VF_ID_W-1:0] owner_function_reg;
    logic [PD_ID_W-1:0] pd_id_reg;
    mr_operation_e operation_reg;
    logic [DMA_SGE_COUNT_W-1:0] segment_index_reg;
    logic [ADDR_W-1:0] base_va_reg;
    logic [ADDR_W-1:0] base_pa_reg;
    logic [DMA_LEN_W-1:0] original_len_reg;
    logic [DMA_BYTE_OFFSET_W-1:0] base_byte_offset_reg;
    logic protected_is_last_reg;
    mr_ref_token_t ref_token_reg;
    logic [15:0] flags_reg;

    logic [DMA_LEN_W-1:0] remaining_len_reg;
    logic [DMA_LEN_W-1:0] emitted_bytes_reg;
    logic [DMA_SPLIT_SUB_INDEX_W-1:0] sub_index_reg;
    logic [DMA_LEN_W-1:0] split_len_reg;
    dma_segment_split_error_e error_code_reg;
    logic [31:0] timeout_counter_reg;

    logic segment_fire;
    logic split_fire;
    logic pmtu_valid;
    logic [DMA_LEN_W-1:0] effective_pmtu;
    logic [DMA_LEN_W-1:0] effective_max;
    logic [DMA_LEN_W-1:0] page_remaining;
    logic [DMA_LEN_W-1:0] page_limit;
    logic [DMA_LEN_W-1:0] limit_after_pmtu;
    logic [DMA_LEN_W-1:0] limit_after_page;
    logic [DMA_LEN_W-1:0] calculated_split_len;
    logic [ADDR_W-1:0] current_va;
    logic [ADDR_W-1:0] current_pa;
    logic [DMA_BYTE_OFFSET_W-1:0] current_byte_offset;
    logic [ADDR_W-1:0] end_va;
    logic [ADDR_W-1:0] end_pa;
    logic va_overflow;
    logic pa_overflow;
    logic is_last_split;

    assign debug_state = state_reg;
    assign protected_segment_ready = (state_reg == DMA_SPLIT_STATE_IDLE) &&
                                     !split_segment_valid;
    assign segment_fire = protected_segment_valid && protected_segment_ready;
    assign split_fire = split_segment_valid && split_segment_ready;

    assign pmtu_valid = (pmtu_bytes == 32'd256)  ||
                        (pmtu_bytes == 32'd512)  ||
                        (pmtu_bytes == 32'd1024) ||
                        (pmtu_bytes == 32'd2048) ||
                        (pmtu_bytes == 32'd4096);
    assign effective_pmtu = enable_pmtu_split ? pmtu_bytes : DMA_LEN_W'(PMTU_BYTES);
    assign effective_max = (max_dma_segment_bytes == '0) ?
                           DMA_LEN_W'(DMA_SPLIT_DEFAULT_MAX_BYTES) :
                           max_dma_segment_bytes;

    assign current_va = base_va_reg + ADDR_W'(emitted_bytes_reg);
    assign current_pa = base_pa_reg + ADDR_W'(emitted_bytes_reg);
    assign current_byte_offset = base_byte_offset_reg + DMA_BYTE_OFFSET_W'(emitted_bytes_reg);
    assign end_va = base_va_reg + ADDR_W'(original_len_reg);
    assign end_pa = base_pa_reg + ADDR_W'(original_len_reg);
    assign va_overflow = (end_va < base_va_reg);
    assign pa_overflow = (end_pa < base_pa_reg);

    always_comb begin
        page_remaining = DMA_LEN_W'(PAGE_4KB_BYTES);
        if (current_pa[PAGE_4KB_OFFSET_W-1:0] != '0) begin
            page_remaining = DMA_LEN_W'(PAGE_4KB_BYTES) -
                             DMA_LEN_W'(current_pa[PAGE_4KB_OFFSET_W-1:0]);
        end
    end

    assign page_limit = enable_4kb_boundary_split ? page_remaining : remaining_len_reg;

    always_comb begin
        limit_after_pmtu = remaining_len_reg;
        if (enable_pmtu_split && (effective_pmtu < limit_after_pmtu)) begin
            limit_after_pmtu = effective_pmtu;
        end

        limit_after_page = limit_after_pmtu;
        if (page_limit < limit_after_page) begin
            limit_after_page = page_limit;
        end

        calculated_split_len = limit_after_page;
        if (effective_max < calculated_split_len) begin
            calculated_split_len = effective_max;
        end
    end

    assign is_last_split = (split_len_reg == remaining_len_reg);

    assign split_segment_desc_id = desc_id_reg;
    assign split_segment_qpn = qpn_reg;
    assign split_segment_owner_function = owner_function_reg;
    assign split_segment_pd_id = pd_id_reg;
    assign split_segment_operation = operation_reg;
    assign split_segment_index = segment_index_reg;
    assign split_segment_sub_index = sub_index_reg;
    assign split_segment_va = current_va;
    assign split_segment_pa = current_pa;
    assign split_segment_len = split_len_reg;
    assign split_segment_byte_offset = current_byte_offset;
    assign split_segment_is_segment_last = is_last_split && (error_code_reg == DMA_SPLIT_ERR_NONE);
    assign split_segment_is_wqe_last = split_segment_is_segment_last && protected_is_last_reg;
    assign split_segment_mr_refcount_token = ref_token_reg;
    assign split_segment_flags = flags_reg;
    assign split_segment_error_code = error_code_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= DMA_SPLIT_STATE_IDLE;
            desc_id_reg <= '0;
            qpn_reg <= '0;
            owner_function_reg <= '0;
            pd_id_reg <= '0;
            operation_reg <= MR_OP_LOCAL_DMA_READ;
            segment_index_reg <= '0;
            base_va_reg <= '0;
            base_pa_reg <= '0;
            original_len_reg <= '0;
            base_byte_offset_reg <= '0;
            protected_is_last_reg <= 1'b0;
            ref_token_reg <= '0;
            flags_reg <= '0;
            remaining_len_reg <= '0;
            emitted_bytes_reg <= '0;
            sub_index_reg <= '0;
            split_len_reg <= '0;
            error_code_reg <= DMA_SPLIT_ERR_NONE;
            timeout_counter_reg <= '0;
            split_segment_valid <= 1'b0;
        end else begin
            unique case (state_reg)
                DMA_SPLIT_STATE_IDLE: begin
                    split_segment_valid <= 1'b0;
                    error_code_reg <= DMA_SPLIT_ERR_NONE;
                    timeout_counter_reg <= '0;
                    if (segment_fire) begin
                        desc_id_reg <= protected_segment_desc_id;
                        qpn_reg <= protected_segment_qpn;
                        owner_function_reg <= protected_segment_owner_function;
                        pd_id_reg <= protected_segment_pd_id;
                        operation_reg <= protected_segment_operation;
                        segment_index_reg <= protected_segment_index;
                        base_va_reg <= protected_segment_va;
                        base_pa_reg <= protected_segment_pa;
                        original_len_reg <= protected_segment_len;
                        base_byte_offset_reg <= protected_segment_byte_offset;
                        protected_is_last_reg <= protected_segment_is_last;
                        ref_token_reg <= protected_segment_mr_refcount_token;
                        flags_reg <= protected_segment_flags;
                        remaining_len_reg <= protected_segment_len;
                        emitted_bytes_reg <= '0;
                        sub_index_reg <= '0;
                        state_reg <= DMA_SPLIT_STATE_ACCEPT;
                    end
                end

                DMA_SPLIT_STATE_ACCEPT: begin
                    state_reg <= DMA_SPLIT_STATE_VALIDATE_CFG;
                end

                DMA_SPLIT_STATE_VALIDATE_CFG: begin
                    if (original_len_reg == '0) begin
                        error_code_reg <= DMA_SPLIT_ERR_ZERO_LENGTH;
                        split_len_reg <= '0;
                        split_segment_valid <= 1'b1;
                        state_reg <= DMA_SPLIT_STATE_ERROR;
                    end else if (enable_pmtu_split && !pmtu_valid) begin
                        error_code_reg <= DMA_SPLIT_ERR_PMTU_CONFIG;
                        split_len_reg <= '0;
                        split_segment_valid <= 1'b1;
                        state_reg <= DMA_SPLIT_STATE_ERROR;
                    end else if (effective_max == '0) begin
                        error_code_reg <= DMA_SPLIT_ERR_MAX_CONFIG;
                        split_len_reg <= '0;
                        split_segment_valid <= 1'b1;
                        state_reg <= DMA_SPLIT_STATE_ERROR;
                    end else if (pa_overflow) begin
                        error_code_reg <= DMA_SPLIT_ERR_PA_OVERFLOW;
                        split_len_reg <= '0;
                        split_segment_valid <= 1'b1;
                        state_reg <= DMA_SPLIT_STATE_ERROR;
                    end else if (va_overflow) begin
                        error_code_reg <= DMA_SPLIT_ERR_VA_OVERFLOW;
                        split_len_reg <= '0;
                        split_segment_valid <= 1'b1;
                        state_reg <= DMA_SPLIT_STATE_ERROR;
                    end else begin
                        state_reg <= DMA_SPLIT_STATE_CALC_PAGE;
                    end
                end

                DMA_SPLIT_STATE_CALC_PAGE: begin
                    state_reg <= DMA_SPLIT_STATE_CALC_LEN;
                end

                DMA_SPLIT_STATE_CALC_LEN: begin
                    if (calculated_split_len == '0) begin
                        error_code_reg <= DMA_SPLIT_ERR_ZERO_SPLIT;
                        split_len_reg <= '0;
                        split_segment_valid <= 1'b1;
                        state_reg <= DMA_SPLIT_STATE_ERROR;
                    end else begin
                        split_len_reg <= calculated_split_len;
                        split_segment_valid <= 1'b1;
                        timeout_counter_reg <= '0;
                        state_reg <= DMA_SPLIT_STATE_EMIT;
                    end
                end

                DMA_SPLIT_STATE_EMIT: begin
                    if (split_fire) begin
                        split_segment_valid <= 1'b0;
                        timeout_counter_reg <= '0;
                        state_reg <= DMA_SPLIT_STATE_UPDATE;
                    end else begin
                        timeout_counter_reg <= timeout_counter_reg + 32'd1;
                        if (timeout_counter_reg >= DMA_SPLIT_TIMEOUT_CYCLES) begin
                            error_code_reg <= DMA_SPLIT_ERR_OUTPUT_TIMEOUT;
                            state_reg <= DMA_SPLIT_STATE_ERROR;
                        end
                    end
                end

                DMA_SPLIT_STATE_UPDATE: begin
                    emitted_bytes_reg <= emitted_bytes_reg + split_len_reg;
                    remaining_len_reg <= remaining_len_reg - split_len_reg;
                    if (is_last_split) begin
                        state_reg <= DMA_SPLIT_STATE_DONE;
                    end else if (sub_index_reg == {DMA_SPLIT_SUB_INDEX_W{1'b1}}) begin
                        error_code_reg <= DMA_SPLIT_ERR_SUB_INDEX_OVER;
                        split_len_reg <= '0;
                        split_segment_valid <= 1'b1;
                        state_reg <= DMA_SPLIT_STATE_ERROR;
                    end else begin
                        sub_index_reg <= sub_index_reg + 1'b1;
                        state_reg <= DMA_SPLIT_STATE_CALC_PAGE;
                    end
                end

                DMA_SPLIT_STATE_DONE: begin
                    state_reg <= DMA_SPLIT_STATE_IDLE;
                end

                DMA_SPLIT_STATE_ERROR: begin
                    if (split_fire) begin
                        split_segment_valid <= 1'b0;
                        state_reg <= DMA_SPLIT_STATE_IDLE;
                    end
                end

                default: begin
                    state_reg <= DMA_SPLIT_STATE_IDLE;
                    split_segment_valid <= 1'b0;
                    error_code_reg <= DMA_SPLIT_ERR_NONE;
                    timeout_counter_reg <= '0;
                end
            endcase
        end
    end

endmodule : dma_segment_splitter
