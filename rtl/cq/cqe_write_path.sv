// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// CQE write path 最小实现。
//
// 本模块接收 completion_engine 已格式化的 64-byte CQE，查询 CQ context，
// 使用 cq_buffer_base_addr 和 producer_index 计算 host CQ buffer 地址，并
// 发出一个 64-byte DMA/PCIe memory write 请求。当前阶段只做基础 PI
// wraparound，不实现完整 producer/consumer overflow 检测或 MSI-X 通知。

`timescale 1ns/1ps

import smartnic_pkg::*;

module cqe_write_path (
    input  logic                         clk,                    // CQE write path 时钟。
    input  logic                         rst_n,                  // 低有效复位。

    // ------------------------------------------------------------------
    // Input from completion_engine
    // ------------------------------------------------------------------
    input  logic                         cqe_write_valid,        // completion_engine 输出的 CQE write 请求有效。
    output logic                         cqe_write_ready,        // 本模块可接收 CQE write 请求。
    input  logic [CQ_ID_W-1:0]           cqe_write_cqn,          // 目标 CQN。
    input  logic [VF_ID_W-1:0]           cqe_write_owner_function,// CQE 所属 function。
    input  logic [CQE_W-1:0]             cqe_write_data,         // 64-byte / 512-bit CQE packed 数据。
    input  logic                         cqe_write_solicited,    // CQE 是否为 solicited event。
    input  cmpl_status_e                 cqe_write_status,       // CQE completion status。
    input  logic                         cqe_write_error,        // completion_engine 标记的错误 CQE。

    // ------------------------------------------------------------------
    // CQ context lookup interface
    // ------------------------------------------------------------------
    output logic                         cq_lookup_valid,        // CQ context lookup 请求有效。
    input  logic                         cq_lookup_ready,        // CQ context table 可接收 lookup。
    output logic [CQ_ID_W-1:0]           cq_lookup_cqn,          // 要查询的 CQN。
    output logic [VF_ID_W-1:0]           cq_lookup_function_id,  // 查询所属 function。
    output logic                         cq_lookup_admin_bypass, // CQE write path 不使用 admin bypass。
    input  logic                         cq_lookup_rsp_valid,    // CQ context lookup 响应有效。
    output logic                         cq_lookup_rsp_ready,    // 本模块可接收 lookup 响应。
    input  logic                         cq_lookup_hit,          // CQ context 命中。
    input  logic                         cq_lookup_miss,         // CQ context 未命中。
    input  cq_table_status_e             cq_lookup_status,       // CQ context lookup 状态。
    input  cq_context_t                  cq_lookup_context,      // 命中的 CQ context。

    // ------------------------------------------------------------------
    // DMA / PCIe memory write request
    // ------------------------------------------------------------------
    output logic                         dma_write_valid,        // 64-byte memory write 请求有效。
    input  logic                         dma_write_ready,        // 下游 DMA/PCIe write path 可接收请求。
    output logic [ADDR_W-1:0]            dma_write_addr,         // CQE host buffer 写入地址。
    output logic [CQE_W-1:0]             dma_write_data,         // CQE 写入数据。
    output logic [15:0]                  dma_write_len,          // 写入长度，当前固定 64 bytes。
    output logic [CQE_DMA_BE_W-1:0]      dma_write_byte_enable,  // 64-byte byte enable。
    output logic [VF_ID_W-1:0]           dma_write_owner_function,// memory write 所属 function。
    output logic [15:0]                  dma_write_tag,          // 原型阶段调试 tag，使用 PI 低 16 位。
    output logic                         dma_write_error,        // 当前写请求是否携带错误 CQE 或路径错误。

    // ------------------------------------------------------------------
    // Overflow update request
    // ------------------------------------------------------------------
    output logic                         cq_overflow_set_valid,  // CQ full/overflow 时请求设置 overflow。
    output logic [CQ_ID_W-1:0]           cq_overflow_set_cqn,    // 要设置 overflow 的 CQN。
    output logic [VF_ID_W-1:0]           cq_overflow_set_owner_function,// overflow 所属 function。

    // ------------------------------------------------------------------
    // CQ producer update request
    // ------------------------------------------------------------------
    output logic                         cq_pi_update_valid,     // CQ producer index 更新请求有效。
    output logic [CQ_ID_W-1:0]           cq_pi_update_cqn,       // 要更新 PI 的 CQN。
    output logic [QUEUE_IDX_W-1:0]       cq_pi_update_new_producer_index,// 新 producer index。
    output logic [VF_ID_W-1:0]           cq_pi_update_owner_function,// 更新所属 function。
    output logic                         cqe_written_solicited,  // 已写入 CQE 的 solicited 标志。
    output cmpl_status_e                 cqe_written_status,     // 已写入 CQE 的 completion status。

    // ------------------------------------------------------------------
    // Debug/status
    // ------------------------------------------------------------------
    output cqe_write_path_state_e        debug_state,            // 当前 CQE write path 状态。
    output cqe_write_path_error_e        error_code              // 最近一次 CQE write path 错误码。
);

    cqe_write_path_state_e state_reg;
    cqe_write_path_error_e error_reg;
    logic [CQ_ID_W-1:0] cqn_reg;
    logic [VF_ID_W-1:0] owner_function_reg;
    logic [CQE_W-1:0] cqe_data_reg;
    logic solicited_reg;
    cmpl_status_e status_reg;
    logic cqe_error_reg;
    cq_context_t cq_ctx_reg;
    logic [ADDR_W-1:0] cqe_addr_reg;
    logic [QUEUE_IDX_W-1:0] next_pi_reg;
    logic lookup_issued_reg;
    logic pi_update_issued_reg;

    logic input_fire;
    logic lookup_fire;
    logic lookup_rsp_fire;
    logic dma_fire;
    logic lookup_ok;
    logic depth_zero;
    logic addr_aligned;
    logic [ADDR_W-1:0] calculated_addr;
    logic [QUEUE_IDX_W-1:0] index_next_producer;
    logic [QUEUE_IDX_W-1:0] index_next_consumer;
    logic index_has_space;
    logic index_empty;
    logic index_full;
    logic index_overflow;
    cq_index_error_e index_error;
    cqe_write_path_error_e lookup_error_next;
    cqe_write_path_error_e check_error_next;

    assign debug_state = state_reg;
    assign error_code = error_reg;

    assign cqe_write_ready = (state_reg == CQE_WR_STATE_IDLE);
    assign input_fire = cqe_write_valid && cqe_write_ready;

    assign cq_lookup_valid = (state_reg == CQE_WR_STATE_LOOKUP_CQ) && !lookup_issued_reg;
    assign cq_lookup_cqn = cqn_reg;
    assign cq_lookup_function_id = owner_function_reg;
    assign cq_lookup_admin_bypass = 1'b0;
    assign cq_lookup_rsp_ready = (state_reg == CQE_WR_STATE_CHECK_SPACE);
    assign lookup_fire = cq_lookup_valid && cq_lookup_ready;
    assign lookup_rsp_fire = cq_lookup_rsp_valid && cq_lookup_rsp_ready;

    assign lookup_ok = cq_lookup_hit &&
                       !cq_lookup_miss &&
                       (cq_lookup_status == CQ_TABLE_STATUS_OK) &&
                       cq_lookup_context.valid &&
                       (cq_lookup_context.owner_function == owner_function_reg);

    assign depth_zero = (cq_ctx_reg.cq_depth == '0);
    assign calculated_addr = cq_ctx_reg.cq_buffer_base_addr +
                             (ADDR_W'(cq_ctx_reg.producer_index) * ADDR_W'(CQE_BYTES));
    assign addr_aligned = ((calculated_addr & CQE_ADDR_ALIGN_MASK) == '0);

    assign dma_write_valid = (state_reg == CQE_WR_STATE_ISSUE_WRITE);
    assign dma_write_addr = cqe_addr_reg;
    assign dma_write_data = cqe_data_reg;
    assign dma_write_len = 16'(CQE_BYTES);
    assign dma_write_byte_enable = {CQE_DMA_BE_W{1'b1}};
    assign dma_write_owner_function = owner_function_reg;
    assign dma_write_tag = cq_ctx_reg.producer_index;
    assign dma_write_error = cqe_error_reg || (error_reg != CQE_WR_ERR_NONE);
    assign dma_fire = dma_write_valid && dma_write_ready;

    assign cq_overflow_set_valid = (state_reg == CQE_WR_STATE_ERROR) &&
                                   (error_reg == CQE_WR_ERR_OVERFLOW);
    assign cq_overflow_set_cqn = cqn_reg;
    assign cq_overflow_set_owner_function = owner_function_reg;

    assign cq_pi_update_valid = (state_reg == CQE_WR_STATE_UPDATE_PI) && !pi_update_issued_reg;
    assign cq_pi_update_cqn = cqn_reg;
    assign cq_pi_update_new_producer_index = next_pi_reg;
    assign cq_pi_update_owner_function = owner_function_reg;
    assign cqe_written_solicited = solicited_reg;
    assign cqe_written_status = status_reg;

    function automatic cqe_write_path_error_e lookup_status_to_error(
        input cq_table_status_e status_i,
        input logic hit_i,
        input logic miss_i,
        input cq_context_t ctx_i,
        input logic [VF_ID_W-1:0] owner_function_i
    );
        begin
            if (!hit_i || miss_i || !ctx_i.valid || (status_i == CQ_TABLE_STATUS_MISS)) begin
                return CQE_WR_ERR_CQ_MISS;
            end
            if ((status_i == CQ_TABLE_STATUS_PERMISSION) ||
                (ctx_i.owner_function != owner_function_i)) begin
                return CQE_WR_ERR_PERMISSION;
            end
            if (status_i == CQ_TABLE_STATUS_ALIAS) begin
                return CQE_WR_ERR_CQ_ALIAS;
            end
            if (status_i != CQ_TABLE_STATUS_OK) begin
                return CQE_WR_ERR_CQ_MISS;
            end
            return CQE_WR_ERR_NONE;
        end
    endfunction

    function automatic cqe_write_path_error_e index_error_to_write_error(input cq_index_error_e error_i);
        begin
            unique case (error_i)
                CQ_INDEX_ERR_NONE:       return CQE_WR_ERR_NONE;
                CQ_INDEX_ERR_DEPTH_ZERO: return CQE_WR_ERR_DEPTH_ZERO;
                CQ_INDEX_ERR_OVERFLOW:   return CQE_WR_ERR_OVERFLOW;
                default:                 return CQE_WR_ERR_ADDR_ALIGN;
            endcase
        end
    endfunction

    cq_index_manager index_manager (
        .cq_index_req_valid(1'b1),
        .cq_index_req_cqn(cqn_reg),
        .cq_index_req_owner_function(owner_function_reg),
        .current_producer_index(cq_ctx_reg.producer_index),
        .current_consumer_index(cq_ctx_reg.consumer_index),
        .cq_depth(cq_ctx_reg.cq_depth),
        .current_overflow(cq_ctx_reg.overflow),
        .cqe_write_commit(1'b1),
        .cq_arm_consumer_update(1'b0),
        .cq_arm_consumer_index('0),
        .overflow_clear_valid(1'b0),
        .next_producer_index(index_next_producer),
        .next_consumer_index(index_next_consumer),
        .cq_has_space(index_has_space),
        .cq_empty(index_empty),
        .cq_full(index_full),
        .cq_overflow(index_overflow),
        .index_error_code(index_error)
    );

    always_comb begin
        lookup_error_next = lookup_status_to_error(cq_lookup_status,
                                                  cq_lookup_hit,
                                                  cq_lookup_miss,
                                                  cq_lookup_context,
                                                  owner_function_reg);
        check_error_next = CQE_WR_ERR_NONE;

        if (index_error != CQ_INDEX_ERR_NONE) begin
            check_error_next = index_error_to_write_error(index_error);
        end else if (depth_zero) begin
            check_error_next = CQE_WR_ERR_DEPTH_ZERO;
        end else if (!index_has_space || cq_ctx_reg.overflow || index_full || index_overflow) begin
            check_error_next = CQE_WR_ERR_OVERFLOW;
        end else if (!addr_aligned) begin
            check_error_next = CQE_WR_ERR_ADDR_ALIGN;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= CQE_WR_STATE_IDLE;
            error_reg <= CQE_WR_ERR_NONE;
            cqn_reg <= '0;
            owner_function_reg <= '0;
            cqe_data_reg <= '0;
            solicited_reg <= 1'b0;
            status_reg <= CMPL_SUCCESS;
            cqe_error_reg <= 1'b0;
            cq_ctx_reg <= '0;
            cqe_addr_reg <= '0;
            next_pi_reg <= '0;
            lookup_issued_reg <= 1'b0;
            pi_update_issued_reg <= 1'b0;
        end else begin
            unique case (state_reg)
                CQE_WR_STATE_IDLE: begin
                    error_reg <= CQE_WR_ERR_NONE;
                    lookup_issued_reg <= 1'b0;
                    pi_update_issued_reg <= 1'b0;

                    if (input_fire) begin
                        cqn_reg <= cqe_write_cqn;
                        owner_function_reg <= cqe_write_owner_function;
                        cqe_data_reg <= cqe_write_data;
                        solicited_reg <= cqe_write_solicited;
                        status_reg <= cqe_write_status;
                        cqe_error_reg <= cqe_write_error;
                        state_reg <= CQE_WR_STATE_LOOKUP_CQ;
                    end
                end

                CQE_WR_STATE_LOOKUP_CQ: begin
                    if (lookup_fire) begin
                        lookup_issued_reg <= 1'b1;
                        state_reg <= CQE_WR_STATE_CHECK_SPACE;
                    end
                end

                CQE_WR_STATE_CHECK_SPACE: begin
                    if (lookup_rsp_fire) begin
                        if (!lookup_ok) begin
                            error_reg <= lookup_error_next;
                            state_reg <= CQE_WR_STATE_ERROR;
                        end else begin
                            cq_ctx_reg <= cq_lookup_context;
                            state_reg <= CQE_WR_STATE_CALC_ADDR;
                        end
                    end
                end

                CQE_WR_STATE_CALC_ADDR: begin
                    if (check_error_next != CQE_WR_ERR_NONE) begin
                        error_reg <= check_error_next;
                        state_reg <= CQE_WR_STATE_ERROR;
                    end else begin
                        cqe_addr_reg <= calculated_addr;
                        next_pi_reg <= index_next_producer;
                        state_reg <= CQE_WR_STATE_ISSUE_WRITE;
                    end
                end

                CQE_WR_STATE_ISSUE_WRITE: begin
                    if (dma_fire) begin
                        state_reg <= CQE_WR_STATE_UPDATE_PI;
                    end
                end

                CQE_WR_STATE_UPDATE_PI: begin
                    pi_update_issued_reg <= 1'b1;
                    state_reg <= CQE_WR_STATE_DONE;
                end

                CQE_WR_STATE_DONE: begin
                    state_reg <= CQE_WR_STATE_IDLE;
                end

                CQE_WR_STATE_ERROR: begin
                    state_reg <= CQE_WR_STATE_IDLE;
                end

                default: begin
                    state_reg <= CQE_WR_STATE_IDLE;
                end
            endcase
        end
    end

endmodule : cqe_write_path
