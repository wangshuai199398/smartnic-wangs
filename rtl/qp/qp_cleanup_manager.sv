// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// QP cleanup manager 最小实现。
//
// 本模块负责 DESTROY_QP 和 QP_TO_ERROR 的清理框架：阻止新的 Doorbell，
// 等待 in-flight work 归零，为未消费 SQ/RQ slot 生成 flushed completion
// 请求，并通过 QP context table 写回销毁或 ERR 状态。当前阶段不实现真实
// DMA cancel、transport retry 清除或 CQE 写回。

`timescale 1ns/1ps

import smartnic_pkg::*;

module qp_cleanup_manager (
    input  logic                         clk,                    // cleanup manager 时钟。
    input  logic                         rst_n,                  // 低有效复位。

    // ------------------------------------------------------------------
    // Cleanup request inputs
    // ------------------------------------------------------------------
    input  logic                         destroy_qp_req_valid,   // DESTROY_QP cleanup 请求有效。
    output logic                         destroy_qp_req_ready,   // 本模块可接收 DESTROY_QP cleanup。
    input  logic [QP_ID_W-1:0]           destroy_qp_qpn,         // 要销毁的 QPN。
    input  logic [VF_ID_W-1:0]           destroy_qp_function_id, // 请求所属 PF/VF function。
    input  logic                         destroy_qp_admin_bypass,// PF/admin 权限绕过。
    input  logic [15:0]                  destroy_qp_sequence,    // 上游命令序号。

    input  logic                         error_qp_req_valid,     // QP_TO_ERROR 或数据通路错误 cleanup 请求。
    output logic                         error_qp_req_ready,     // 本模块可接收 error cleanup。
    input  logic [QP_ID_W-1:0]           error_qp_qpn,           // 要切入 ERR 的 QPN。
    input  logic [VF_ID_W-1:0]           error_qp_function_id,   // 请求所属 PF/VF function。
    input  logic                         error_qp_admin_bypass,  // PF/admin 权限绕过。
    input  logic [15:0]                  error_qp_error_code,    // 写入 QP context 的错误码。
    input  logic [15:0]                  error_qp_sequence,      // 上游命令/事件序号。

    // ------------------------------------------------------------------
    // QP context table read/write interface
    // ------------------------------------------------------------------
    output logic                         context_read_valid,     // QP context 读请求有效。
    input  logic                         context_read_ready,     // QP context table 可接收读请求。
    output logic [QP_ID_W-1:0]           context_read_qpn,       // 要读取的 QPN。
    output logic [VF_ID_W-1:0]           context_read_function_id,// 读取所属 function。
    output logic                         context_read_pf_bypass, // admin 权限绕过。
    input  logic                         context_read_rsp_valid, // QP context 读响应有效。
    output logic                         context_read_rsp_ready, // 本模块可接收读响应。
    input  logic                         context_read_hit,       // 读命中。
    input  qp_table_status_e             context_read_status,    // 读状态。
    input  qp_context_t                  context_read_data,      // 读出的 QP context。

    output logic                         context_write_valid,    // QP context 写请求有效。
    input  logic                         context_write_ready,    // QP context table 可接收写请求。
    output logic [QP_ID_W-1:0]           context_write_qpn,      // 要写回的 QPN。
    output logic [VF_ID_W-1:0]           context_write_function_id,// 写回所属 function。
    output logic                         context_write_pf_bypass,// admin 权限绕过。
    output qp_context_t                  context_write_data,     // 写回的 QP context。
    input  logic                         context_write_rsp_valid,// QP context 写响应有效。
    output logic                         context_write_rsp_ready,// 本模块可接收写响应。
    input  qp_table_status_e             context_write_status,   // 写状态。

    // ------------------------------------------------------------------
    // Doorbell blocking and in-flight quiesce inputs
    // ------------------------------------------------------------------
    output logic                         qp_block_doorbell_valid,// 通知 Doorbell path 阻止该 QP。
    input  logic                         qp_block_doorbell_ready,// Doorbell path 已接收 block 请求。
    output logic [QP_ID_W-1:0]           qp_block_doorbell_qpn,  // 被阻止 Doorbell 的 QPN。
    output logic [VF_ID_W-1:0]           qp_block_doorbell_function_id,// 被阻止 Doorbell 所属 function。

    input  logic [15:0]                  sq_inflight_count,      // 该 QP SQ engine in-flight work 数。
    input  logic [15:0]                  rq_inflight_count,      // 该 QP RQ engine in-flight work 数。
    input  logic [15:0]                  dma_inflight_count,     // 该 QP DMA in-flight work 数。
    input  logic [15:0]                  transport_inflight_count,// 该 QP transport in-flight work 数。
    input  logic [31:0]                  cleanup_timeout_limit,  // cleanup 等待超时周期；0 使用默认值。

    // ------------------------------------------------------------------
    // Flush completion request output
    // ------------------------------------------------------------------
    output logic                         flush_completion_valid, // flushed completion 请求有效。
    input  logic                         flush_completion_ready, // completion path 可接收请求。
    output qp_flush_completion_req_t     flush_completion_req,   // flushed completion 请求内容。

    // ------------------------------------------------------------------
    // Cleanup response
    // ------------------------------------------------------------------
    output logic                         cleanup_done_valid,     // cleanup 响应有效。
    input  logic                         cleanup_done_ready,     // 上游已接收 cleanup 响应。
    output logic [QP_ID_W-1:0]           cleanup_done_qpn,       // cleanup 响应 QPN。
    output logic [15:0]                  cleanup_done_sequence,  // cleanup 响应序号。
    output qp_cleanup_reason_e           cleanup_done_reason,    // cleanup 类型。
    output qp_cleanup_error_e            cleanup_done_error_code,// cleanup 错误码。
    output qp_context_t                  cleanup_done_context,   // cleanup 后 context 快照。

    // ------------------------------------------------------------------
    // Debug/status
    // ------------------------------------------------------------------
    output qp_cleanup_state_e            debug_state,            // 当前 cleanup FSM 状态。
    output qp_cleanup_error_e            debug_error_code        // 最近一次错误码。
);

    qp_cleanup_state_e state_reg;
    qp_cleanup_reason_e reason_reg;
    qp_cleanup_error_e error_reg;
    logic [QP_ID_W-1:0] qpn_reg;
    logic [VF_ID_W-1:0] function_id_reg;
    logic admin_bypass_reg;
    logic [15:0] sequence_reg;
    logic [15:0] request_error_code_reg;
    qp_context_t qp_ctx_reg;
    qp_context_t update_ctx_reg;
    logic [QUEUE_IDX_W-1:0] flush_sq_index_reg;
    logic [QUEUE_IDX_W-1:0] flush_rq_index_reg;
    logic read_issued_reg;
    logic write_issued_reg;
    logic block_issued_reg;
    logic flush_issued_reg;
    logic [31:0] timeout_counter_reg;

    logic destroy_fire;
    logic error_fire;
    logic read_fire;
    logic read_rsp_fire;
    logic write_fire;
    logic write_rsp_fire;
    logic block_fire;
    logic flush_fire;
    logic done_fire;
    logic all_inflight_drained;
    logic sq_flush_done;
    logic rq_flush_done;
    logic [QUEUE_IDX_W-1:0] next_sq_flush_index;
    logic [QUEUE_IDX_W-1:0] next_rq_flush_index;
    logic timeout_expired;
    logic [31:0] timeout_limit_effective;
    qp_flush_completion_req_t flush_req_next;

    assign debug_state = state_reg;
    assign debug_error_code = error_reg;

    assign destroy_qp_req_ready = (state_reg == QP_CLEAN_STATE_IDLE) && !error_qp_req_valid;
    assign error_qp_req_ready = (state_reg == QP_CLEAN_STATE_IDLE) && !destroy_qp_req_valid;
    assign destroy_fire = destroy_qp_req_valid && destroy_qp_req_ready;
    assign error_fire = error_qp_req_valid && error_qp_req_ready;

    assign context_read_valid = (state_reg == QP_CLEAN_STATE_LOCK_QP) && !read_issued_reg;
    assign context_read_qpn = qpn_reg;
    assign context_read_function_id = function_id_reg;
    assign context_read_pf_bypass = admin_bypass_reg;
    assign context_read_rsp_ready = (state_reg == QP_CLEAN_STATE_LOCK_QP);
    assign read_fire = context_read_valid && context_read_ready;
    assign read_rsp_fire = context_read_rsp_valid && context_read_rsp_ready;

    assign qp_block_doorbell_valid = (state_reg == QP_CLEAN_STATE_BLOCK_DB) && !block_issued_reg;
    assign qp_block_doorbell_qpn = qpn_reg;
    assign qp_block_doorbell_function_id = function_id_reg;
    assign block_fire = qp_block_doorbell_valid && qp_block_doorbell_ready;

    assign all_inflight_drained = (sq_inflight_count == 16'h0000) &&
                                  (rq_inflight_count == 16'h0000) &&
                                  (dma_inflight_count == 16'h0000) &&
                                  (transport_inflight_count == 16'h0000);

    assign sq_flush_done = (flush_sq_index_reg == qp_ctx_reg.sq_producer);
    assign rq_flush_done = (flush_rq_index_reg == qp_ctx_reg.rq_producer);
    assign next_sq_flush_index = (flush_sq_index_reg == (qp_ctx_reg.sq_depth - 1'b1)) ?
                                 '0 : (flush_sq_index_reg + 1'b1);
    assign next_rq_flush_index = (flush_rq_index_reg == (qp_ctx_reg.rq_depth - 1'b1)) ?
                                 '0 : (flush_rq_index_reg + 1'b1);

    assign timeout_limit_effective = (cleanup_timeout_limit == 32'h0000_0000) ?
                                     32'(QP_CLEANUP_TIMEOUT_CYCLES) :
                                     cleanup_timeout_limit;
    assign timeout_expired = (timeout_counter_reg >= timeout_limit_effective);

    assign flush_req_next.owner_func = qp_ctx_reg.owner_func;
    assign flush_req_next.qpn = qpn_reg;
    assign flush_req_next.cqn = (state_reg == QP_CLEAN_STATE_FLUSH_SQ) ?
                                qp_ctx_reg.send_cqn : qp_ctx_reg.recv_cqn;
    assign flush_req_next.status = CMPL_WR_FLUSH_ERR;
    assign flush_req_next.is_sq = (state_reg == QP_CLEAN_STATE_FLUSH_SQ);
    assign flush_req_next.is_rq = (state_reg == QP_CLEAN_STATE_FLUSH_RQ);
    assign flush_req_next.queue_index = (state_reg == QP_CLEAN_STATE_FLUSH_SQ) ?
                                        flush_sq_index_reg : flush_rq_index_reg;
    assign flush_req_next.reason = reason_reg;

    assign flush_completion_valid = ((state_reg == QP_CLEAN_STATE_FLUSH_SQ) && !sq_flush_done && !flush_issued_reg) ||
                                    ((state_reg == QP_CLEAN_STATE_FLUSH_RQ) && !rq_flush_done && !flush_issued_reg);
    assign flush_completion_req = flush_req_next;
    assign flush_fire = flush_completion_valid && flush_completion_ready;

    assign context_write_valid = (state_reg == QP_CLEAN_STATE_UPDATE_CTX) && !write_issued_reg;
    assign context_write_qpn = qpn_reg;
    assign context_write_function_id = function_id_reg;
    assign context_write_pf_bypass = admin_bypass_reg;
    assign context_write_data = update_ctx_reg;
    assign context_write_rsp_ready = (state_reg == QP_CLEAN_STATE_UPDATE_CTX);
    assign write_fire = context_write_valid && context_write_ready;
    assign write_rsp_fire = context_write_rsp_valid && context_write_rsp_ready;

    assign cleanup_done_qpn = qpn_reg;
    assign cleanup_done_sequence = sequence_reg;
    assign cleanup_done_reason = reason_reg;
    assign cleanup_done_error_code = error_reg;
    assign cleanup_done_context = (state_reg == QP_CLEAN_STATE_DONE) ? update_ctx_reg : qp_ctx_reg;
    assign done_fire = cleanup_done_valid && cleanup_done_ready;

    function automatic qp_cleanup_error_e table_status_to_cleanup_error(input qp_table_status_e status);
        begin
            unique case (status)
                QP_TABLE_STATUS_MISS:       return QP_CLEAN_ERR_LOOKUP_MISS;
                QP_TABLE_STATUS_PERMISSION: return QP_CLEAN_ERR_PERMISSION;
                default:                    return QP_CLEAN_ERR_TABLE_ERROR;
            endcase
        end
    endfunction

    function automatic qp_context_t build_update_context(
        input qp_context_t current_ctx,
        input qp_cleanup_reason_e reason,
        input logic [15:0] request_error_code,
        input logic [QUEUE_IDX_W-1:0] sq_ci,
        input logic [QUEUE_IDX_W-1:0] rq_ci
    );
        qp_context_t next_ctx;
        begin
            next_ctx = current_ctx;
            next_ctx.sq_consumer = sq_ci;
            next_ctx.rq_consumer = rq_ci;
            next_ctx.error_state = 1'b1;
            next_ctx.error_code = request_error_code;

            if (reason == QP_CLEAN_REASON_DESTROY) begin
                next_ctx.valid = 1'b0;
                next_ctx.state = QP_STATE_RESET;
                next_ctx.owner_func = '0;
                next_ctx.sq_producer = '0;
                next_ctx.sq_consumer = '0;
                next_ctx.rq_producer = '0;
                next_ctx.rq_consumer = '0;
            end else if (reason == QP_CLEAN_REASON_ERROR) begin
                next_ctx.valid = 1'b1;
                next_ctx.state = QP_STATE_ERR;
            end

            return next_ctx;
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= QP_CLEAN_STATE_IDLE;
            reason_reg <= QP_CLEAN_REASON_NONE;
            error_reg <= QP_CLEAN_ERR_NONE;
            qpn_reg <= '0;
            function_id_reg <= '0;
            admin_bypass_reg <= 1'b0;
            sequence_reg <= 16'h0000;
            request_error_code_reg <= 16'h0000;
            qp_ctx_reg <= '0;
            update_ctx_reg <= '0;
            flush_sq_index_reg <= '0;
            flush_rq_index_reg <= '0;
            read_issued_reg <= 1'b0;
            write_issued_reg <= 1'b0;
            block_issued_reg <= 1'b0;
            flush_issued_reg <= 1'b0;
            timeout_counter_reg <= 32'h0000_0000;
            cleanup_done_valid <= 1'b0;
        end else begin
            if (done_fire) begin
                cleanup_done_valid <= 1'b0;
                state_reg <= QP_CLEAN_STATE_IDLE;
                reason_reg <= QP_CLEAN_REASON_NONE;
                error_reg <= QP_CLEAN_ERR_NONE;
            end

            unique case (state_reg)
                QP_CLEAN_STATE_IDLE: begin
                    read_issued_reg <= 1'b0;
                    write_issued_reg <= 1'b0;
                    block_issued_reg <= 1'b0;
                    flush_issued_reg <= 1'b0;
                    timeout_counter_reg <= 32'h0000_0000;

                    if (destroy_fire) begin
                        qpn_reg <= destroy_qp_qpn;
                        function_id_reg <= destroy_qp_function_id;
                        admin_bypass_reg <= destroy_qp_admin_bypass;
                        sequence_reg <= destroy_qp_sequence;
                        request_error_code_reg <= 16'h0000;
                        reason_reg <= QP_CLEAN_REASON_DESTROY;
                        error_reg <= QP_CLEAN_ERR_NONE;
                        state_reg <= QP_CLEAN_STATE_LOCK_QP;
                    end else if (error_fire) begin
                        qpn_reg <= error_qp_qpn;
                        function_id_reg <= error_qp_function_id;
                        admin_bypass_reg <= error_qp_admin_bypass;
                        sequence_reg <= error_qp_sequence;
                        request_error_code_reg <= error_qp_error_code;
                        reason_reg <= QP_CLEAN_REASON_ERROR;
                        error_reg <= QP_CLEAN_ERR_NONE;
                        state_reg <= QP_CLEAN_STATE_LOCK_QP;
                    end
                end

                QP_CLEAN_STATE_LOCK_QP: begin
                    if (read_fire) begin
                        read_issued_reg <= 1'b1;
                    end

                    if (read_rsp_fire) begin
                        read_issued_reg <= 1'b0;
                        qp_ctx_reg <= context_read_data;

                        if (!context_read_hit || (context_read_status != QP_TABLE_STATUS_OK)) begin
                            error_reg <= (reason_reg == QP_CLEAN_REASON_DESTROY &&
                                          context_read_status == QP_TABLE_STATUS_MISS) ?
                                         QP_CLEAN_ERR_ALREADY_DESTROYED :
                                         table_status_to_cleanup_error(context_read_status);
                            state_reg <= QP_CLEAN_STATE_ERROR;
                        end else if ((reason_reg == QP_CLEAN_REASON_ERROR) &&
                                     (context_read_data.state == QP_STATE_ERR)) begin
                            error_reg <= QP_CLEAN_ERR_ALREADY_ERR;
                            state_reg <= QP_CLEAN_STATE_ERROR;
                        end else begin
                            flush_sq_index_reg <= context_read_data.sq_consumer;
                            flush_rq_index_reg <= context_read_data.rq_consumer;
                            state_reg <= QP_CLEAN_STATE_BLOCK_DB;
                        end
                    end
                end

                QP_CLEAN_STATE_BLOCK_DB: begin
                    if (block_fire) begin
                        block_issued_reg <= 1'b1;
                        timeout_counter_reg <= 32'h0000_0000;
                        state_reg <= QP_CLEAN_STATE_QUIESCE;
                    end else if (timeout_expired) begin
                        error_reg <= QP_CLEAN_ERR_TIMEOUT;
                        state_reg <= QP_CLEAN_STATE_ERROR;
                    end else begin
                        timeout_counter_reg <= timeout_counter_reg + 1'b1;
                    end
                end

                QP_CLEAN_STATE_QUIESCE: begin
                    if (all_inflight_drained) begin
                        timeout_counter_reg <= 32'h0000_0000;
                        state_reg <= QP_CLEAN_STATE_FLUSH_SQ;
                    end else if (timeout_expired) begin
                        error_reg <= QP_CLEAN_ERR_TIMEOUT;
                        state_reg <= QP_CLEAN_STATE_ERROR;
                    end else begin
                        timeout_counter_reg <= timeout_counter_reg + 1'b1;
                    end
                end

                QP_CLEAN_STATE_FLUSH_SQ: begin
                    if (sq_flush_done) begin
                        flush_issued_reg <= 1'b0;
                        timeout_counter_reg <= 32'h0000_0000;
                        state_reg <= QP_CLEAN_STATE_FLUSH_RQ;
                    end else if (flush_fire) begin
                        flush_issued_reg <= 1'b0;
                        flush_sq_index_reg <= next_sq_flush_index;
                        timeout_counter_reg <= 32'h0000_0000;
                    end else if (flush_completion_valid && timeout_expired) begin
                        error_reg <= QP_CLEAN_ERR_BACKPRESSURE;
                        state_reg <= QP_CLEAN_STATE_ERROR;
                    end else if (flush_completion_valid) begin
                        timeout_counter_reg <= timeout_counter_reg + 1'b1;
                    end
                end

                QP_CLEAN_STATE_FLUSH_RQ: begin
                    if (rq_flush_done) begin
                        update_ctx_reg <= build_update_context(qp_ctx_reg,
                                                               reason_reg,
                                                               request_error_code_reg,
                                                               flush_sq_index_reg,
                                                               flush_rq_index_reg);
                        flush_issued_reg <= 1'b0;
                        timeout_counter_reg <= 32'h0000_0000;
                        state_reg <= QP_CLEAN_STATE_UPDATE_CTX;
                    end else if (flush_fire) begin
                        flush_issued_reg <= 1'b0;
                        flush_rq_index_reg <= next_rq_flush_index;
                        timeout_counter_reg <= 32'h0000_0000;
                    end else if (flush_completion_valid && timeout_expired) begin
                        error_reg <= QP_CLEAN_ERR_BACKPRESSURE;
                        state_reg <= QP_CLEAN_STATE_ERROR;
                    end else if (flush_completion_valid) begin
                        timeout_counter_reg <= timeout_counter_reg + 1'b1;
                    end
                end

                QP_CLEAN_STATE_UPDATE_CTX: begin
                    if (write_fire) begin
                        write_issued_reg <= 1'b1;
                    end

                    if (write_rsp_fire) begin
                        write_issued_reg <= 1'b0;
                        if (context_write_status == QP_TABLE_STATUS_OK) begin
                            error_reg <= QP_CLEAN_ERR_NONE;
                            cleanup_done_valid <= 1'b1;
                            state_reg <= QP_CLEAN_STATE_DONE;
                        end else begin
                            error_reg <= table_status_to_cleanup_error(context_write_status);
                            state_reg <= QP_CLEAN_STATE_ERROR;
                        end
                    end
                end

                QP_CLEAN_STATE_DONE: begin
                    // 等待 cleanup_done_ready。
                end

                QP_CLEAN_STATE_ERROR: begin
                    if (!cleanup_done_valid) begin
                        cleanup_done_valid <= 1'b1;
                    end
                end

                default: begin
                    error_reg <= QP_CLEAN_ERR_TABLE_ERROR;
                    state_reg <= QP_CLEAN_STATE_ERROR;
                end
            endcase
        end
    end

endmodule : qp_cleanup_manager
