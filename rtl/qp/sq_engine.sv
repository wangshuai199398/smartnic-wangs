// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// SQ engine 最小实现。
//
// 本模块连接 Doorbell/scheduler、QP context table、WQE fetch 接口和后续
// DMA/transport/completion 路径。当前阶段只实现状态机、QP state 检查、
// WQE fetch 请求、opcode decode 和 dispatch 框架，不实现真实 DMA 搬运或
// RoCEv2 packet 生成。

`timescale 1ns/1ps

import smartnic_pkg::*;

module sq_engine (
    input  logic                         clk,                    // SQ engine 时钟。
    input  logic                         rst_n,                  // 低有效复位。

    // ------------------------------------------------------------------
    // Scheduler / SQ Doorbell input
    // ------------------------------------------------------------------
    input  logic                         sq_engine_enable,       // SQ engine 使能。
    input  logic                         sq_req_valid,           // 有 QP 需要处理 SQ。
    output logic                         sq_req_ready,           // 本模块可接收 SQ 请求。
    input  logic [QP_ID_W-1:0]           sq_req_qpn,             // 目标 QPN。
    input  logic [VF_ID_W-1:0]           sq_req_function_id,     // 请求所属 PF/VF function。

    // ------------------------------------------------------------------
    // QP context read interface
    // ------------------------------------------------------------------
    output logic                         qp_read_valid,          // QP context 读请求有效。
    input  logic                         qp_read_ready,          // QP context table 可接收读请求。
    output logic [QP_ID_W-1:0]           qp_read_qpn,            // 要读取的 QPN。
    output logic [VF_ID_W-1:0]           qp_read_function_id,    // 发起读取的 function。
    output logic                         qp_read_pf_bypass,      // SQ fast path 不使用 PF bypass。
    input  logic                         qp_read_rsp_valid,      // QP context table 读响应有效。
    output logic                         qp_read_rsp_ready,      // 本模块可接收读响应。
    input  logic                         qp_read_hit,            // QP context 读命中。
    input  qp_table_status_e             qp_read_status,         // QP context 读状态。
    input  qp_context_t                  qp_read_data,           // QP context 数据。

    // ------------------------------------------------------------------
    // WQE fetch request/response
    // ------------------------------------------------------------------
    output logic                         wqe_fetch_req_valid,    // WQE fetch 请求有效。
    input  logic                         wqe_fetch_req_ready,    // 下游 fetch 单元可接收请求。
    output logic [ADDR_W-1:0]            wqe_fetch_addr,         // 要读取的 WQE 主机地址。
    output logic [QP_ID_W-1:0]           wqe_fetch_qpn,          // fetch 所属 QPN。
    output logic [VF_ID_W-1:0]           wqe_fetch_owner_function,// fetch 所属 PF/VF function。
    output logic [QUEUE_IDX_W-1:0]       wqe_fetch_sq_ci,        // 被 fetch 的 SQ consumer index。
    output logic [15:0]                  wqe_fetch_size,         // WQE 大小，当前固定为 WQE_BYTES。
    input  logic                         wqe_fetch_rsp_valid,    // WQE fetch 响应有效。
    output logic                         wqe_fetch_rsp_ready,    // 本模块可接收 WQE fetch 响应。
    input  wqe_t                         wqe_fetch_rsp_wqe,      // fetch 返回的 packed WQE。
    input  logic                         wqe_fetch_rsp_error,    // fetch 返回错误。

    // ------------------------------------------------------------------
    // Dispatch outputs
    // ------------------------------------------------------------------
    output logic                         dma_dispatch_valid,     // 分发到 DMA/RDMA read-write 路径。
    input  logic                         dma_dispatch_ready,     // DMA dispatch 下游 ready。
    output sq_dispatch_req_t             dma_dispatch_req,       // DMA dispatch 请求。
    output logic                         transport_dispatch_valid,// 分发到 transport send 路径。
    input  logic                         transport_dispatch_ready,// transport dispatch 下游 ready。
    output sq_dispatch_req_t             transport_dispatch_req, // transport dispatch 请求。
    output logic                         local_inv_valid,        // LOCAL_INVALIDATE 预留接口。
    input  logic                         local_inv_ready,        // local invalidate 下游 ready。
    output sq_dispatch_req_t             local_inv_req,          // local invalidate 请求。

    // ------------------------------------------------------------------
    // Consumer index update and completion/error event
    // ------------------------------------------------------------------
    output logic                         sq_ci_update_valid,     // SQ consumer index 更新有效。
    input  logic                         sq_ci_update_ready,     // QP context manager 可接收 CI 更新。
    output logic [QP_ID_W-1:0]           sq_ci_update_qpn,       // 要更新 CI 的 QPN。
    output logic [VF_ID_W-1:0]           sq_ci_update_function_id,// 更新所属 function。
    output logic [QUEUE_IDX_W-1:0]       sq_ci_update_new_ci,    // 新的 SQ consumer index。
    output logic                         completion_req_valid,   // completion/error 请求有效。
    input  logic                         completion_req_ready,   // completion path 可接收请求。
    output logic [QP_ID_W-1:0]           completion_qpn,         // completion 所属 QPN。
    output logic [CQ_ID_W-1:0]           completion_cqn,         // send CQ 编号。
    output cmpl_status_e                 completion_status,      // completion 状态。
    output sq_engine_error_e             completion_error_code,  // SQ engine 错误码。

    // ------------------------------------------------------------------
    // Debug/status
    // ------------------------------------------------------------------
    output sq_engine_state_e             debug_state,            // 当前 SQ engine 状态。
    output sq_engine_error_e             debug_error_code        // 最近一次错误码。
);

    sq_engine_state_e state_reg;          // 当前 SQ engine 状态。
    logic [QP_ID_W-1:0] active_qpn_reg;   // 当前处理的 QPN。
    logic [VF_ID_W-1:0] active_func_reg;  // 当前处理的 function。
    qp_context_t qp_ctx_reg;              // 当前 QP context 快照。
    wqe_t wqe_reg;                        // 当前 WQE。
    sq_engine_error_e error_reg;          // 当前错误码。
    logic fetch_req_issued_reg;           // FETCH_WQE 状态中请求是否已发出。
    logic dispatch_issued_reg;            // DISPATCH 状态中请求是否已发出。
    logic completion_issued_reg;          // completion/error 请求是否已发出。
    logic ci_update_issued_reg;           // CI update 请求是否已发出。
    logic advance_ci_reg;                 // 当前 WQE 是否需要推进 CI。
    logic generate_success_completion_reg;// 当前 WQE 是否生成成功 completion。

    logic sq_req_fire;
    logic qp_read_fire;
    logic qp_read_rsp_fire;
    logic wqe_fetch_req_fire;
    logic wqe_fetch_rsp_fire;
    logic dma_dispatch_fire;
    logic transport_dispatch_fire;
    logic local_inv_fire;
    logic completion_fire;
    logic ci_update_fire;
    logic [QUEUE_IDX_W-1:0] next_sq_ci;
    logic sq_empty;
    logic queue_index_invalid;
    logic dispatch_needs_dma;
    logic dispatch_needs_transport;
    logic dispatch_needs_local_inv;
    logic dispatch_is_nop;
    logic opcode_supported;
    sq_dispatch_req_t dispatch_req_next;

    assign debug_state = state_reg;
    assign debug_error_code = error_reg;
    assign sq_req_ready = (state_reg == SQ_ENG_STATE_IDLE) && sq_engine_enable;
    assign sq_req_fire = sq_req_valid && sq_req_ready;

    assign qp_read_valid = (state_reg == SQ_ENG_STATE_LOOKUP_QP);
    assign qp_read_qpn = active_qpn_reg;
    assign qp_read_function_id = active_func_reg;
    assign qp_read_pf_bypass = 1'b0;
    assign qp_read_rsp_ready = (state_reg == SQ_ENG_STATE_LOOKUP_QP);
    assign qp_read_fire = qp_read_valid && qp_read_ready;
    assign qp_read_rsp_fire = qp_read_rsp_valid && qp_read_rsp_ready;

    assign sq_empty = (qp_ctx_reg.sq_consumer == qp_ctx_reg.sq_producer);
    assign queue_index_invalid = (qp_ctx_reg.sq_depth == '0);
    assign next_sq_ci = (qp_ctx_reg.sq_consumer == (qp_ctx_reg.sq_depth - 1'b1)) ?
                        '0 : (qp_ctx_reg.sq_consumer + 1'b1);

    assign wqe_fetch_req_valid = (state_reg == SQ_ENG_STATE_FETCH_WQE) && !fetch_req_issued_reg;
    assign wqe_fetch_addr = qp_ctx_reg.sq_base + (ADDR_W'(qp_ctx_reg.sq_consumer) * ADDR_W'(WQE_BYTES));
    assign wqe_fetch_qpn = active_qpn_reg;
    assign wqe_fetch_owner_function = active_func_reg;
    assign wqe_fetch_sq_ci = qp_ctx_reg.sq_consumer;
    assign wqe_fetch_size = 16'(WQE_BYTES);
    assign wqe_fetch_rsp_ready = (state_reg == SQ_ENG_STATE_FETCH_WQE);
    assign wqe_fetch_req_fire = wqe_fetch_req_valid && wqe_fetch_req_ready;
    assign wqe_fetch_rsp_fire = wqe_fetch_rsp_valid && wqe_fetch_rsp_ready;

    assign dispatch_needs_dma = (wqe_reg.opcode == RDMA_OP_RDMA_WRITE) ||
                                (wqe_reg.opcode == RDMA_OP_RDMA_WRITE_WITH_IMM) ||
                                (wqe_reg.opcode == RDMA_OP_RDMA_READ);
    assign dispatch_needs_transport = (wqe_reg.opcode == RDMA_OP_SEND) ||
                                      (wqe_reg.opcode == RDMA_OP_SEND_WITH_IMM);
    assign dispatch_needs_local_inv = (wqe_reg.opcode == RDMA_OP_LOCAL_INV);
    assign dispatch_is_nop = (wqe_reg.opcode == RDMA_OP_NOP);
    assign opcode_supported = dispatch_needs_dma ||
                              dispatch_needs_transport ||
                              dispatch_needs_local_inv ||
                              dispatch_is_nop;

    assign dispatch_req_next.owner_func = active_func_reg;
    assign dispatch_req_next.qpn = active_qpn_reg;
    assign dispatch_req_next.opcode = wqe_reg.opcode;
    assign dispatch_req_next.qp_type = qp_ctx_reg.qp_type;
    assign dispatch_req_next.pd_id = qp_ctx_reg.pd_id;
    assign dispatch_req_next.send_cqn = qp_ctx_reg.send_cqn;
    assign dispatch_req_next.sq_consumer = qp_ctx_reg.sq_consumer;
    assign dispatch_req_next.wqe = wqe_reg;

    assign dma_dispatch_valid = (state_reg == SQ_ENG_STATE_DISPATCH) &&
                                dispatch_needs_dma &&
                                !dispatch_issued_reg;
    assign dma_dispatch_req = dispatch_req_next;
    assign dma_dispatch_fire = dma_dispatch_valid && dma_dispatch_ready;

    assign transport_dispatch_valid = (state_reg == SQ_ENG_STATE_DISPATCH) &&
                                      dispatch_needs_transport &&
                                      !dispatch_issued_reg;
    assign transport_dispatch_req = dispatch_req_next;
    assign transport_dispatch_fire = transport_dispatch_valid && transport_dispatch_ready;

    assign local_inv_valid = (state_reg == SQ_ENG_STATE_DISPATCH) &&
                             dispatch_needs_local_inv &&
                             !dispatch_issued_reg;
    assign local_inv_req = dispatch_req_next;
    assign local_inv_fire = local_inv_valid && local_inv_ready;

    assign completion_req_valid = ((state_reg == SQ_ENG_STATE_ERROR) ||
                                   (state_reg == SQ_ENG_STATE_UPDATE_CI &&
                                    generate_success_completion_reg)) &&
                                  !completion_issued_reg;
    assign completion_qpn = active_qpn_reg;
    assign completion_cqn = qp_ctx_reg.send_cqn;
    assign completion_status = (state_reg == SQ_ENG_STATE_ERROR) ? CMPL_LOC_QP_OP_ERR :
                                                              CMPL_SUCCESS;
    assign completion_error_code = error_reg;
    assign completion_fire = completion_req_valid && completion_req_ready;

    assign sq_ci_update_valid = (state_reg == SQ_ENG_STATE_UPDATE_CI) &&
                                advance_ci_reg &&
                                !ci_update_issued_reg;
    assign sq_ci_update_qpn = active_qpn_reg;
    assign sq_ci_update_function_id = active_func_reg;
    assign sq_ci_update_new_ci = next_sq_ci;
    assign ci_update_fire = sq_ci_update_valid && sq_ci_update_ready;

    function automatic sq_engine_error_e lookup_status_to_error(input qp_table_status_e status);
        begin
            unique case (status)
                QP_TABLE_STATUS_MISS:       return SQ_ENG_ERR_LOOKUP_MISS;
                QP_TABLE_STATUS_PERMISSION: return SQ_ENG_ERR_PERMISSION;
                default:                    return SQ_ENG_ERR_LOOKUP_MISS;
            endcase
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= SQ_ENG_STATE_IDLE;
            active_qpn_reg <= '0;
            active_func_reg <= '0;
            qp_ctx_reg <= '0;
            wqe_reg <= '0;
            error_reg <= SQ_ENG_ERR_NONE;
            fetch_req_issued_reg <= 1'b0;
            dispatch_issued_reg <= 1'b0;
            completion_issued_reg <= 1'b0;
            ci_update_issued_reg <= 1'b0;
            advance_ci_reg <= 1'b0;
            generate_success_completion_reg <= 1'b0;
        end else begin
            unique case (state_reg)
                SQ_ENG_STATE_IDLE: begin
                    fetch_req_issued_reg <= 1'b0;
                    dispatch_issued_reg <= 1'b0;
                    completion_issued_reg <= 1'b0;
                    ci_update_issued_reg <= 1'b0;
                    advance_ci_reg <= 1'b0;
                    generate_success_completion_reg <= 1'b0;
                    error_reg <= SQ_ENG_ERR_NONE;

                    if (sq_req_valid && !sq_engine_enable) begin
                        active_qpn_reg <= sq_req_qpn;
                        active_func_reg <= sq_req_function_id;
                        error_reg <= SQ_ENG_ERR_DISABLED;
                        state_reg <= SQ_ENG_STATE_ERROR;
                    end else if (sq_req_fire) begin
                        active_qpn_reg <= sq_req_qpn;
                        active_func_reg <= sq_req_function_id;
                        state_reg <= SQ_ENG_STATE_LOOKUP_QP;
                    end
                end

                SQ_ENG_STATE_LOOKUP_QP: begin
                    if (qp_read_rsp_fire) begin
                        if (!qp_read_hit || (qp_read_status != QP_TABLE_STATUS_OK)) begin
                            error_reg <= lookup_status_to_error(qp_read_status);
                            state_reg <= SQ_ENG_STATE_ERROR;
                        end else begin
                            qp_ctx_reg <= qp_read_data;
                            state_reg <= SQ_ENG_STATE_CHECK_STATE;
                        end
                    end else if (qp_read_fire) begin
                        // 等待 QP context table 返回 read response。
                    end
                end

                SQ_ENG_STATE_CHECK_STATE: begin
                    if (qp_ctx_reg.state != QP_STATE_RTS) begin
                        // SQD 后续会进入 drain 逻辑；当前阶段按不可处理 SQ WQE 报错。
                        error_reg <= SQ_ENG_ERR_BAD_STATE;
                        state_reg <= SQ_ENG_STATE_ERROR;
                    end else if (queue_index_invalid) begin
                        error_reg <= SQ_ENG_ERR_QUEUE_INDEX;
                        state_reg <= SQ_ENG_STATE_ERROR;
                    end else if (sq_empty) begin
                        state_reg <= SQ_ENG_STATE_IDLE;
                    end else begin
                        fetch_req_issued_reg <= 1'b0;
                        state_reg <= SQ_ENG_STATE_FETCH_WQE;
                    end
                end

                SQ_ENG_STATE_FETCH_WQE: begin
                    if (wqe_fetch_req_fire) begin
                        fetch_req_issued_reg <= 1'b1;
                    end

                    if (wqe_fetch_rsp_fire) begin
                        fetch_req_issued_reg <= 1'b0;
                        if (wqe_fetch_rsp_error) begin
                            error_reg <= SQ_ENG_ERR_FETCH;
                            state_reg <= SQ_ENG_STATE_ERROR;
                        end else begin
                            wqe_reg <= wqe_fetch_rsp_wqe;
                            state_reg <= SQ_ENG_STATE_DECODE_WQE;
                        end
                    end
                end

                SQ_ENG_STATE_DECODE_WQE: begin
                    if (!opcode_supported) begin
                        error_reg <= SQ_ENG_ERR_UNSUPPORTED_OPCODE;
                        state_reg <= SQ_ENG_STATE_ERROR;
                    end else begin
                        dispatch_issued_reg <= 1'b0;
                        state_reg <= SQ_ENG_STATE_DISPATCH;
                    end
                end

                SQ_ENG_STATE_DISPATCH: begin
                    if (dispatch_is_nop) begin
                        advance_ci_reg <= 1'b1;
                        generate_success_completion_reg <= 1'b1;
                        state_reg <= SQ_ENG_STATE_UPDATE_CI;
                    end else if (dma_dispatch_fire ||
                                 transport_dispatch_fire ||
                                 local_inv_fire) begin
                        dispatch_issued_reg <= 1'b1;
                        advance_ci_reg <= 1'b1;
                        generate_success_completion_reg <= 1'b0;
                        state_reg <= SQ_ENG_STATE_UPDATE_CI;
                    end
                end

                SQ_ENG_STATE_UPDATE_CI: begin
                    if (!advance_ci_reg) begin
                        state_reg <= SQ_ENG_STATE_IDLE;
                    end else begin
                        if (ci_update_fire) begin
                            ci_update_issued_reg <= 1'b1;
                        end

                        if ((!generate_success_completion_reg || completion_issued_reg) &&
                            ci_update_issued_reg) begin
                            state_reg <= SQ_ENG_STATE_IDLE;
                        end

                        if (completion_fire) begin
                            completion_issued_reg <= 1'b1;
                        end
                    end
                end

                SQ_ENG_STATE_ERROR: begin
                    if (completion_fire) begin
                        completion_issued_reg <= 1'b1;
                        state_reg <= SQ_ENG_STATE_IDLE;
                    end
                end

                default: begin
                    error_reg <= SQ_ENG_ERR_BAD_STATE;
                    state_reg <= SQ_ENG_STATE_ERROR;
                end
            endcase

            if (state_reg != SQ_ENG_STATE_UPDATE_CI) begin
                ci_update_issued_reg <= 1'b0;
            end

            if ((state_reg != SQ_ENG_STATE_UPDATE_CI) &&
                (state_reg != SQ_ENG_STATE_ERROR)) begin
                completion_issued_reg <= 1'b0;
            end
        end
    end

endmodule : sq_engine
