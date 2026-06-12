// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// RQ engine 最小实现。
//
// 本模块消费入站 Send payload，为目标 QP 查找 Recv WQE，并把 payload
// 分发给后续 DMA write 路径。当前阶段只定义接口和最小状态机，不实现
// 真实 DMA 写入、MR/lkey 校验或 CQE 写回。

`timescale 1ns/1ps

import smartnic_pkg::*;

module rq_engine (
    input  logic                         clk,                    // RQ engine 时钟。
    input  logic                         rst_n,                  // 低有效复位。

    // ------------------------------------------------------------------
    // Inbound Send packet metadata from transport RX
    // ------------------------------------------------------------------
    input  logic                         rq_engine_enable,       // RQ engine 使能。
    input  logic                         inbound_send_valid,     // 入站 Send payload 有效。
    output logic                         inbound_send_ready,     // 本模块可接收入站 Send。
    input  logic [QP_ID_W-1:0]           inbound_qpn,            // 入站包目标 QPN。
    input  logic [VF_ID_W-1:0]           inbound_function_id,    // 入站包所属 function。
    input  logic [DMA_LEN_W-1:0]         inbound_payload_len,    // 入站 payload 字节数。
    input  logic                         inbound_has_imm,        // 是否携带 immediate data。
    input  logic [31:0]                  inbound_imm_data,       // immediate data。
    input  logic                         inbound_solicited,      // solicited event 标志。
    input  logic [63:0]                  inbound_packet_metadata,// 入站包元数据占位，后续承载 PSN/opcode 等。

    // ------------------------------------------------------------------
    // QP context read interface
    // ------------------------------------------------------------------
    output logic                         qp_read_valid,          // QP context 读请求有效。
    input  logic                         qp_read_ready,          // QP context table 可接收读请求。
    output logic [QP_ID_W-1:0]           qp_read_qpn,            // 要读取的 QPN。
    output logic [VF_ID_W-1:0]           qp_read_function_id,    // 发起读取的 function。
    output logic                         qp_read_pf_bypass,      // RQ fast path 不使用 PF bypass。
    input  logic                         qp_read_rsp_valid,      // QP context table 读响应有效。
    output logic                         qp_read_rsp_ready,      // 本模块可接收读响应。
    input  logic                         qp_read_hit,            // QP context 读命中。
    input  qp_table_status_e             qp_read_status,         // QP context 读状态。
    input  qp_context_t                  qp_read_data,           // QP context 数据。

    // ------------------------------------------------------------------
    // Recv WQE fetch request/response
    // ------------------------------------------------------------------
    output logic                         recv_wqe_fetch_req_valid,// Recv WQE fetch 请求有效。
    input  logic                         recv_wqe_fetch_req_ready,// 下游 fetch 单元可接收请求。
    output logic [ADDR_W-1:0]            recv_wqe_fetch_addr,     // 要读取的 Recv WQE 主机地址。
    output logic [QP_ID_W-1:0]           recv_wqe_fetch_qpn,      // fetch 所属 QPN。
    output logic [VF_ID_W-1:0]           recv_wqe_fetch_owner_function,// fetch 所属 function。
    output logic [QUEUE_IDX_W-1:0]       recv_wqe_fetch_rq_ci,    // 被 fetch 的 RQ consumer index。
    output logic [15:0]                  recv_wqe_fetch_size,     // WQE 大小，当前固定为 WQE_BYTES。
    input  logic                         recv_wqe_fetch_rsp_valid,// Recv WQE fetch 响应有效。
    output logic                         recv_wqe_fetch_rsp_ready,// 本模块可接收 fetch 响应。
    input  wqe_t                         recv_wqe_fetch_rsp_wqe,  // fetch 返回的 Recv WQE。
    input  logic                         recv_wqe_fetch_rsp_error,// fetch 返回错误。

    // ------------------------------------------------------------------
    // DMA write dispatch
    // ------------------------------------------------------------------
    output logic                         dma_write_valid,         // DMA write 请求有效。
    input  logic                         dma_write_ready,         // DMA write 下游 ready。
    output rq_dma_write_req_t            dma_write_req,           // DMA write 请求内容。
    input  logic                         dma_write_rsp_valid,     // DMA write 响应有效。
    output logic                         dma_write_rsp_ready,     // 本模块可接收 DMA write 响应。
    input  logic                         dma_write_rsp_error,     // DMA write 响应错误。

    // ------------------------------------------------------------------
    // RQ consumer index update and completion/error outputs
    // ------------------------------------------------------------------
    output logic                         rq_ci_update_valid,      // RQ consumer index 更新有效。
    input  logic                         rq_ci_update_ready,      // QP context manager 可接收 CI 更新。
    output logic [QP_ID_W-1:0]           rq_ci_update_qpn,        // 要更新 CI 的 QPN。
    output logic [VF_ID_W-1:0]           rq_ci_update_function_id,// 更新所属 function。
    output logic [QUEUE_IDX_W-1:0]       rq_ci_update_new_ci,     // 新的 RQ consumer index。
    output logic                         completion_req_valid,    // receive completion 请求有效。
    input  logic                         completion_req_ready,    // completion path 可接收请求。
    output rq_completion_req_t           completion_req,          // receive completion 请求。
    output logic                         rnr_error_valid,         // RNR/no receive buffer 指示。
    input  logic                         rnr_error_ready,         // 上游/transport 可接收 RNR 指示。
    output logic [QP_ID_W-1:0]           rnr_error_qpn,           // RNR 对应 QPN。

    // ------------------------------------------------------------------
    // Debug/status
    // ------------------------------------------------------------------
    output rq_engine_state_e             debug_state,             // 当前 RQ engine 状态。
    output rq_engine_error_e             debug_error_code         // 最近一次错误码。
);

    rq_engine_state_e state_reg;
    logic [QP_ID_W-1:0] active_qpn_reg;
    logic [VF_ID_W-1:0] active_func_reg;
    logic [DMA_LEN_W-1:0] payload_len_reg;
    logic has_imm_reg;
    logic [31:0] imm_data_reg;
    logic solicited_reg;
    logic [63:0] packet_metadata_reg;
    qp_context_t qp_ctx_reg;
    wqe_t recv_wqe_reg;
    rq_engine_error_e error_reg;
    logic fetch_req_issued_reg;
    logic dma_write_issued_reg;
    logic dma_write_done_reg;
    logic ci_update_issued_reg;
    logic completion_issued_reg;
    logic rnr_issued_reg;

    logic inbound_fire;
    logic qp_read_fire;
    logic qp_read_rsp_fire;
    logic fetch_req_fire;
    logic fetch_rsp_fire;
    logic dma_write_fire;
    logic dma_write_rsp_fire;
    logic ci_update_fire;
    logic completion_fire;
    logic rnr_fire;
    logic rq_empty;
    logic queue_index_invalid;
    logic [QUEUE_IDX_W-1:0] next_rq_ci;
    logic state_allows_receive;
    rq_dma_write_req_t dma_write_req_next;
    rq_completion_req_t completion_req_next;

    assign debug_state = state_reg;
    assign debug_error_code = error_reg;
    assign inbound_send_ready = (state_reg == RQ_ENG_STATE_IDLE) && rq_engine_enable;
    assign inbound_fire = inbound_send_valid && inbound_send_ready;

    assign qp_read_valid = (state_reg == RQ_ENG_STATE_LOOKUP_QP);
    assign qp_read_qpn = active_qpn_reg;
    assign qp_read_function_id = active_func_reg;
    assign qp_read_pf_bypass = 1'b0;
    assign qp_read_rsp_ready = (state_reg == RQ_ENG_STATE_LOOKUP_QP);
    assign qp_read_fire = qp_read_valid && qp_read_ready;
    assign qp_read_rsp_fire = qp_read_rsp_valid && qp_read_rsp_ready;

    assign state_allows_receive = (qp_ctx_reg.state == QP_STATE_RTR) ||
                                  (qp_ctx_reg.state == QP_STATE_RTS) ||
                                  (qp_ctx_reg.state == QP_STATE_SQD); // TODO: 后续细化 SQD drain 与接收并行语义。
    assign rq_empty = (qp_ctx_reg.rq_consumer == qp_ctx_reg.rq_producer);
    assign queue_index_invalid = (qp_ctx_reg.rq_depth == '0);
    assign next_rq_ci = (qp_ctx_reg.rq_consumer == (qp_ctx_reg.rq_depth - 1'b1)) ?
                        '0 : (qp_ctx_reg.rq_consumer + 1'b1);

    assign recv_wqe_fetch_req_valid = (state_reg == RQ_ENG_STATE_FETCH_RECV_WQE) &&
                                      !fetch_req_issued_reg;
    assign recv_wqe_fetch_addr = qp_ctx_reg.rq_base +
                                 (ADDR_W'(qp_ctx_reg.rq_consumer) * ADDR_W'(WQE_BYTES));
    assign recv_wqe_fetch_qpn = active_qpn_reg;
    assign recv_wqe_fetch_owner_function = active_func_reg;
    assign recv_wqe_fetch_rq_ci = qp_ctx_reg.rq_consumer;
    assign recv_wqe_fetch_size = 16'(WQE_BYTES);
    assign recv_wqe_fetch_rsp_ready = (state_reg == RQ_ENG_STATE_FETCH_RECV_WQE);
    assign fetch_req_fire = recv_wqe_fetch_req_valid && recv_wqe_fetch_req_ready;
    assign fetch_rsp_fire = recv_wqe_fetch_rsp_valid && recv_wqe_fetch_rsp_ready;

    assign dma_write_req_next.owner_func = active_func_reg;
    assign dma_write_req_next.qpn = active_qpn_reg;
    assign dma_write_req_next.pd_id = qp_ctx_reg.pd_id;
    assign dma_write_req_next.wr_id = recv_wqe_reg.wr_id;
    assign dma_write_req_next.dst_addr = recv_wqe_reg.local_va;
    assign dma_write_req_next.lkey = recv_wqe_reg.lkey;
    assign dma_write_req_next.length = payload_len_reg;
    assign dma_write_req_next.flags = recv_wqe_reg.flags;

    assign dma_write_valid = (state_reg == RQ_ENG_STATE_DISPATCH_DMA_WRITE) &&
                             !dma_write_issued_reg;
    assign dma_write_req = dma_write_req_next;
    assign dma_write_fire = dma_write_valid && dma_write_ready;
    assign dma_write_rsp_ready = (state_reg == RQ_ENG_STATE_DISPATCH_DMA_WRITE);
    assign dma_write_rsp_fire = dma_write_rsp_valid && dma_write_rsp_ready;

    assign rq_ci_update_valid = (state_reg == RQ_ENG_STATE_UPDATE_CI) &&
                                !ci_update_issued_reg;
    assign rq_ci_update_qpn = active_qpn_reg;
    assign rq_ci_update_function_id = active_func_reg;
    assign rq_ci_update_new_ci = next_rq_ci;
    assign ci_update_fire = rq_ci_update_valid && rq_ci_update_ready;

    assign completion_req_next.owner_func = active_func_reg;
    assign completion_req_next.qpn = active_qpn_reg;
    assign completion_req_next.cqn = qp_ctx_reg.recv_cqn;
    assign completion_req_next.wr_id = recv_wqe_reg.wr_id;
    assign completion_req_next.status = (state_reg == RQ_ENG_STATE_COMPLETE) ? CMPL_SUCCESS :
                                                                               error_to_completion_status(error_reg);
    assign completion_req_next.byte_count = payload_len_reg;
    assign completion_req_next.recv_with_imm = has_imm_reg;
    assign completion_req_next.has_imm = has_imm_reg;
    assign completion_req_next.imm_data = imm_data_reg;
    assign completion_req_next.solicited = solicited_reg;
    assign completion_req_next.error_code = error_reg;

    assign completion_req_valid = ((state_reg == RQ_ENG_STATE_COMPLETE) ||
                                   ((state_reg == RQ_ENG_STATE_ERROR) &&
                                    (error_reg != RQ_ENG_ERR_RNR))) &&
                                  !completion_issued_reg;
    assign completion_req = completion_req_next;
    assign completion_fire = completion_req_valid && completion_req_ready;

    assign rnr_error_valid = (state_reg == RQ_ENG_STATE_ERROR) &&
                             (error_reg == RQ_ENG_ERR_RNR) &&
                             !rnr_issued_reg;
    assign rnr_error_qpn = active_qpn_reg;
    assign rnr_fire = rnr_error_valid && rnr_error_ready;

    function automatic rq_engine_error_e lookup_status_to_error(input qp_table_status_e status);
        begin
            unique case (status)
                QP_TABLE_STATUS_MISS:       return RQ_ENG_ERR_LOOKUP_MISS;
                QP_TABLE_STATUS_PERMISSION: return RQ_ENG_ERR_PERMISSION;
                default:                    return RQ_ENG_ERR_LOOKUP_MISS;
            endcase
        end
    endfunction

    function automatic cmpl_status_e error_to_completion_status(input rq_engine_error_e error_code);
        begin
            unique case (error_code)
                RQ_ENG_ERR_LOCAL_LEN: return CMPL_LOC_LEN_ERR;
                RQ_ENG_ERR_FETCH:     return CMPL_DMA_ERR;
                RQ_ENG_ERR_DMA:       return CMPL_DMA_ERR;
                RQ_ENG_ERR_RNR:       return CMPL_RNR_RETRY_EXC_ERR;
                default:              return CMPL_LOC_QP_OP_ERR;
            endcase
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= RQ_ENG_STATE_IDLE;
            active_qpn_reg <= '0;
            active_func_reg <= '0;
            payload_len_reg <= '0;
            has_imm_reg <= 1'b0;
            imm_data_reg <= 32'h0;
            solicited_reg <= 1'b0;
            packet_metadata_reg <= 64'h0;
            qp_ctx_reg <= '0;
            recv_wqe_reg <= '0;
            error_reg <= RQ_ENG_ERR_NONE;
            fetch_req_issued_reg <= 1'b0;
            dma_write_issued_reg <= 1'b0;
            dma_write_done_reg <= 1'b0;
            ci_update_issued_reg <= 1'b0;
            completion_issued_reg <= 1'b0;
            rnr_issued_reg <= 1'b0;
        end else begin
            unique case (state_reg)
                RQ_ENG_STATE_IDLE: begin
                    error_reg <= RQ_ENG_ERR_NONE;
                    fetch_req_issued_reg <= 1'b0;
                    dma_write_issued_reg <= 1'b0;
                    dma_write_done_reg <= 1'b0;
                    ci_update_issued_reg <= 1'b0;
                    completion_issued_reg <= 1'b0;
                    rnr_issued_reg <= 1'b0;

                    if (inbound_send_valid && !rq_engine_enable) begin
                        active_qpn_reg <= inbound_qpn;
                        active_func_reg <= inbound_function_id;
                        error_reg <= RQ_ENG_ERR_DISABLED;
                        state_reg <= RQ_ENG_STATE_ERROR;
                    end else if (inbound_fire) begin
                        active_qpn_reg <= inbound_qpn;
                        active_func_reg <= inbound_function_id;
                        payload_len_reg <= inbound_payload_len;
                        has_imm_reg <= inbound_has_imm;
                        imm_data_reg <= inbound_imm_data;
                        solicited_reg <= inbound_solicited;
                        packet_metadata_reg <= inbound_packet_metadata;
                        state_reg <= RQ_ENG_STATE_LOOKUP_QP;
                    end
                end

                RQ_ENG_STATE_LOOKUP_QP: begin
                    if (qp_read_rsp_fire) begin
                        if (!qp_read_hit || (qp_read_status != QP_TABLE_STATUS_OK)) begin
                            error_reg <= lookup_status_to_error(qp_read_status);
                            state_reg <= RQ_ENG_STATE_ERROR;
                        end else begin
                            qp_ctx_reg <= qp_read_data;
                            state_reg <= RQ_ENG_STATE_CHECK_STATE;
                        end
                    end else if (qp_read_fire) begin
                        // 等待 QP context table 返回 read response。
                    end
                end

                RQ_ENG_STATE_CHECK_STATE: begin
                    if (!state_allows_receive) begin
                        error_reg <= RQ_ENG_ERR_BAD_STATE;
                        state_reg <= RQ_ENG_STATE_ERROR;
                    end else begin
                        state_reg <= RQ_ENG_STATE_CHECK_RQ_AVAILABLE;
                    end
                end

                RQ_ENG_STATE_CHECK_RQ_AVAILABLE: begin
                    if (queue_index_invalid) begin
                        error_reg <= RQ_ENG_ERR_QUEUE_INDEX;
                        state_reg <= RQ_ENG_STATE_ERROR;
                    end else if (rq_empty) begin
                        error_reg <= RQ_ENG_ERR_RNR;
                        state_reg <= RQ_ENG_STATE_ERROR;
                    end else begin
                        fetch_req_issued_reg <= 1'b0;
                        state_reg <= RQ_ENG_STATE_FETCH_RECV_WQE;
                    end
                end

                RQ_ENG_STATE_FETCH_RECV_WQE: begin
                    if (fetch_req_fire) begin
                        fetch_req_issued_reg <= 1'b1;
                    end

                    if (fetch_rsp_fire) begin
                        fetch_req_issued_reg <= 1'b0;
                        if (recv_wqe_fetch_rsp_error) begin
                            error_reg <= RQ_ENG_ERR_FETCH;
                            state_reg <= RQ_ENG_STATE_ERROR;
                        end else begin
                            recv_wqe_reg <= recv_wqe_fetch_rsp_wqe;
                            state_reg <= RQ_ENG_STATE_DECODE_RECV_WQE;
                        end
                    end
                end

                RQ_ENG_STATE_DECODE_RECV_WQE: begin
                    if (payload_len_reg > recv_wqe_reg.length) begin
                        error_reg <= RQ_ENG_ERR_LOCAL_LEN;
                        state_reg <= RQ_ENG_STATE_ERROR;
                    end else begin
                        dma_write_issued_reg <= 1'b0;
                        dma_write_done_reg <= 1'b0;
                        state_reg <= RQ_ENG_STATE_DISPATCH_DMA_WRITE;
                    end
                end

                RQ_ENG_STATE_DISPATCH_DMA_WRITE: begin
                    if (dma_write_fire) begin
                        dma_write_issued_reg <= 1'b1;
                    end

                    if (dma_write_rsp_fire) begin
                        dma_write_done_reg <= 1'b1;
                        if (dma_write_rsp_error) begin
                            error_reg <= RQ_ENG_ERR_DMA;
                            state_reg <= RQ_ENG_STATE_ERROR;
                        end else begin
                            state_reg <= RQ_ENG_STATE_UPDATE_CI;
                        end
                    end
                end

                RQ_ENG_STATE_UPDATE_CI: begin
                    if (ci_update_fire) begin
                        ci_update_issued_reg <= 1'b1;
                        state_reg <= RQ_ENG_STATE_COMPLETE;
                    end
                end

                RQ_ENG_STATE_COMPLETE: begin
                    if (completion_fire) begin
                        completion_issued_reg <= 1'b1;
                        state_reg <= RQ_ENG_STATE_IDLE;
                    end
                end

                RQ_ENG_STATE_ERROR: begin
                    if (error_reg == RQ_ENG_ERR_RNR) begin
                        if (rnr_fire) begin
                            rnr_issued_reg <= 1'b1;
                            state_reg <= RQ_ENG_STATE_IDLE;
                        end
                    end else if (completion_fire) begin
                        completion_issued_reg <= 1'b1;
                        state_reg <= RQ_ENG_STATE_IDLE;
                    end
                end

                default: begin
                    error_reg <= RQ_ENG_ERR_BAD_STATE;
                    state_reg <= RQ_ENG_STATE_ERROR;
                end
            endcase

            if (state_reg != RQ_ENG_STATE_UPDATE_CI) begin
                ci_update_issued_reg <= 1'b0;
            end

            if ((state_reg != RQ_ENG_STATE_COMPLETE) &&
                (state_reg != RQ_ENG_STATE_ERROR)) begin
                completion_issued_reg <= 1'b0;
                rnr_issued_reg <= 1'b0;
            end
        end
    end

    logic [63:0] unused_packet_metadata;
    assign unused_packet_metadata = packet_metadata_reg;
    logic unused_dma_write_done;
    assign unused_dma_write_done = dma_write_done_reg;

endmodule : rq_engine
