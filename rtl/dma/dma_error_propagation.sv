// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// DMA error propagation 最小实现。
//
// 本模块把 DMA 子模块上报的错误统一转换为 completion error event，并在
// fatal 错误时额外发出 QP error request。当前阶段只做错误汇聚、状态映射
// 和 ready/valid 保持，不实现 retry engine、remote error packet 或 async event。

`timescale 1ns/1ps

import smartnic_pkg::*;

module dma_error_propagation (
    input  logic                         clk,                         // 时钟。
    input  logic                         rst_n,                       // 低有效复位。

    // ------------------------------------------------------------------
    // Vectorized DMA error inputs, one lane per error source
    // ------------------------------------------------------------------
    input  logic [MAX_DMA_ERROR_SOURCES-1:0] error_valid,             // 每个 error lane 的 valid。
    output logic [MAX_DMA_ERROR_SOURCES-1:0] error_ready,             // 被选中并锁存时拉高 ready。
    input  logic [MAX_DMA_ERROR_SOURCES*DMA_ERROR_SOURCE_ID_W-1:0] error_source_id, // 报错来源 ID。
    input  logic [MAX_DMA_ERROR_SOURCES*16-1:0] error_desc_id,        // descriptor ID。
    input  logic [MAX_DMA_ERROR_SOURCES*QP_ID_W-1:0] error_qpn,       // QPN。
    input  logic [MAX_DMA_ERROR_SOURCES*CQ_ID_W-1:0] error_cqn,       // CQN。
    input  logic [MAX_DMA_ERROR_SOURCES*VF_ID_W-1:0] error_owner_function, // owner PF/VF function。
    input  logic [MAX_DMA_ERROR_SOURCES*PD_ID_W-1:0] error_pd_id,     // PD ID。
    input  logic [MAX_DMA_ERROR_SOURCES*4-1:0] error_operation,       // mr_operation_e packed。
    input  logic [MAX_DMA_ERROR_SOURCES*3-1:0] error_direction,       // dma_direction_e packed。
    input  logic [MAX_DMA_ERROR_SOURCES*DMA_SGE_COUNT_W-1:0] error_segment_index, // segment index。
    input  logic [MAX_DMA_ERROR_SOURCES*DMA_BYTE_OFFSET_W-1:0] error_byte_offset, // WR byte offset。
    input  logic [MAX_DMA_ERROR_SOURCES*16-1:0] error_dma_code,       // dma_error_code_e packed。
    input  logic [MAX_DMA_ERROR_SOURCES*8-1:0] error_original_status, // cmpl_status_e packed。
    input  logic [MAX_DMA_ERROR_SOURCES-1:0] error_fatal,             // fatal 错误标志。
    input  logic [MAX_DMA_ERROR_SOURCES-1:0] error_retryable,         // retryable 提示，当前阶段仅保留语义。
    input  logic [MAX_DMA_ERROR_SOURCES*WR_ID_W-1:0] error_wr_id,     // WR ID。
    input  logic [MAX_DMA_ERROR_SOURCES*8-1:0] error_opcode,          // rdma_opcode_e packed。
    input  logic [MAX_DMA_ERROR_SOURCES*DMA_LEN_W-1:0] error_byte_len,// byte_len。
    input  logic [MAX_DMA_ERROR_SOURCES-1:0] error_solicited,         // solicited completion 标志。

    // ------------------------------------------------------------------
    // Completion error event output
    // ------------------------------------------------------------------
    output logic                         completion_error_valid,      // completion error event valid。
    input  logic                         completion_error_ready,      // completion_engine 接受 event。
    output completion_event_type_e       completion_event_type,       // 固定为 CMPL_EVENT_ERROR。
    output logic [QP_ID_W-1:0]           completion_qpn,              // completion QPN。
    output logic [CQ_ID_W-1:0]           completion_cqn,              // completion CQN。
    output logic [VF_ID_W-1:0]           completion_owner_function,   // completion owner function。
    output logic [WR_ID_W-1:0]           completion_wr_id,            // completion WR ID。
    output rdma_opcode_e                 completion_opcode,           // completion opcode。
    output cmpl_status_e                 completion_status,           // 映射后的 completion status。
    output logic [31:0]                  completion_vendor_error,     // vendor/syndrome debug code。
    output logic [DMA_LEN_W-1:0]         completion_byte_len,         // byte_len。
    output logic                         completion_solicited,        // solicited 标志。
    output logic [15:0]                  completion_desc_id,          // debug: descriptor ID。
    output dma_error_source_e            completion_source_id,        // debug: error source。

    // ------------------------------------------------------------------
    // Fatal error -> QP cleanup/error request
    // ------------------------------------------------------------------
    output logic                         qp_error_req_valid,          // fatal 错误触发 QP error 请求。
    input  logic                         qp_error_req_ready,          // QP cleanup/lifecycle 接受请求。
    output logic [QP_ID_W-1:0]           qp_error_qpn,                // 需要进入 error 的 QPN。
    output logic [VF_ID_W-1:0]           qp_error_owner_function,     // QP owner function。
    output dma_error_code_e              qp_error_code,               // 原始 DMA error code。
    output logic [15:0]                  qp_error_desc_id,            // descriptor ID。
    output dma_error_source_e            qp_error_source_id,          // fatal error 来源。

    output logic                         retry_hint_valid,            // retryable 错误提示，后续 retry engine 使用。
    output logic [15:0]                  retry_hint_desc_id,          // retryable descriptor ID。
    output dma_error_source_e            retry_hint_source_id,        // retryable 来源。

    output dma_error_propagation_state_e debug_state,                 // 调试：当前 FSM 状态。
    output logic [DMA_ERROR_SOURCE_ID_W-1:0] debug_selected_lane,      // 调试：被选中 lane。
    output dma_error_code_e              debug_last_error_code        // 调试：最近锁存的 DMA error code。
);

    dma_error_propagation_state_e state_reg;
    dma_error_event_t captured_event_reg;
    cmpl_status_e mapped_status_reg;
    logic [DMA_ERROR_SOURCE_ID_W-1:0] selected_lane_reg;
    logic [DMA_ERROR_SOURCE_ID_W-1:0] selected_lane_comb;
    logic selected_valid_comb;

    assign debug_state = state_reg;
    assign debug_selected_lane = selected_lane_reg;
    assign debug_last_error_code = captured_event_reg.dma_error_code;

    assign completion_error_valid = (state_reg == DMA_ERR_PROP_STATE_EMIT_CMPL);
    assign completion_event_type = CMPL_EVENT_ERROR;
    assign completion_qpn = captured_event_reg.qpn;
    assign completion_cqn = captured_event_reg.cqn;
    assign completion_owner_function = captured_event_reg.owner_function;
    assign completion_wr_id = captured_event_reg.wr_id;
    assign completion_opcode = captured_event_reg.opcode;
    assign completion_status = mapped_status_reg;
    assign completion_vendor_error = {
        8'hd9,
        4'h0,
        captured_event_reg.source_id,
        captured_event_reg.dma_error_code
    };
    assign completion_byte_len = captured_event_reg.byte_len;
    assign completion_solicited = captured_event_reg.solicited;
    assign completion_desc_id = captured_event_reg.desc_id;
    assign completion_source_id = captured_event_reg.source_id;

    assign qp_error_req_valid = (state_reg == DMA_ERR_PROP_STATE_EMIT_QP_ERR);
    assign qp_error_qpn = captured_event_reg.qpn;
    assign qp_error_owner_function = captured_event_reg.owner_function;
    assign qp_error_code = captured_event_reg.dma_error_code;
    assign qp_error_desc_id = captured_event_reg.desc_id;
    assign qp_error_source_id = captured_event_reg.source_id;

    assign retry_hint_valid = (state_reg == DMA_ERR_PROP_STATE_EMIT_CMPL) && captured_event_reg.retryable;
    assign retry_hint_desc_id = captured_event_reg.desc_id;
    assign retry_hint_source_id = captured_event_reg.source_id;

    always_comb begin
        error_ready = '0;
        if ((state_reg == DMA_ERR_PROP_STATE_SELECT) && selected_valid_comb) begin
            error_ready[selected_lane_comb] = 1'b1;
        end
    end

    function automatic dma_error_source_e source_at(input int idx);
        return dma_error_source_e'(error_source_id[idx*DMA_ERROR_SOURCE_ID_W +: DMA_ERROR_SOURCE_ID_W]);
    endfunction

    function automatic logic [15:0] desc_at(input int idx);
        return error_desc_id[idx*16 +: 16];
    endfunction

    function automatic logic [QP_ID_W-1:0] qpn_at(input int idx);
        return error_qpn[idx*QP_ID_W +: QP_ID_W];
    endfunction

    function automatic logic [CQ_ID_W-1:0] cqn_at(input int idx);
        return error_cqn[idx*CQ_ID_W +: CQ_ID_W];
    endfunction

    function automatic logic [VF_ID_W-1:0] owner_at(input int idx);
        return error_owner_function[idx*VF_ID_W +: VF_ID_W];
    endfunction

    function automatic logic [PD_ID_W-1:0] pd_at(input int idx);
        return error_pd_id[idx*PD_ID_W +: PD_ID_W];
    endfunction

    function automatic mr_operation_e operation_at(input int idx);
        return mr_operation_e'(error_operation[idx*4 +: 4]);
    endfunction

    function automatic dma_direction_e direction_at(input int idx);
        return dma_direction_e'(error_direction[idx*3 +: 3]);
    endfunction

    function automatic logic [DMA_SGE_COUNT_W-1:0] segment_at(input int idx);
        return error_segment_index[idx*DMA_SGE_COUNT_W +: DMA_SGE_COUNT_W];
    endfunction

    function automatic logic [DMA_BYTE_OFFSET_W-1:0] byte_offset_at(input int idx);
        return error_byte_offset[idx*DMA_BYTE_OFFSET_W +: DMA_BYTE_OFFSET_W];
    endfunction

    function automatic dma_error_code_e code_at(input int idx);
        return dma_error_code_e'(error_dma_code[idx*16 +: 16]);
    endfunction

    function automatic cmpl_status_e original_status_at(input int idx);
        return cmpl_status_e'(error_original_status[idx*8 +: 8]);
    endfunction

    function automatic logic [WR_ID_W-1:0] wr_id_at(input int idx);
        return error_wr_id[idx*WR_ID_W +: WR_ID_W];
    endfunction

    function automatic rdma_opcode_e opcode_at(input int idx);
        return rdma_opcode_e'(error_opcode[idx*8 +: 8]);
    endfunction

    function automatic logic [DMA_LEN_W-1:0] byte_len_at(input int idx);
        return error_byte_len[idx*DMA_LEN_W +: DMA_LEN_W];
    endfunction

    function automatic logic is_remote_operation(input mr_operation_e operation);
        return (operation == MR_OP_REMOTE_RDMA_READ) ||
               (operation == MR_OP_REMOTE_RDMA_WRITE) ||
               (operation == MR_OP_REMOTE_ATOMIC);
    endfunction

    function automatic logic source_is_mr_or_protection(input dma_error_source_e source);
        return source == DMA_ERR_SRC_MR_INTEGRATION;
    endfunction

    function automatic logic source_is_host(input dma_error_source_e source);
        return (source == DMA_ERR_SRC_HOST_READ) || (source == DMA_ERR_SRC_HOST_WRITE);
    endfunction

    function automatic logic source_is_fetch(input dma_error_source_e source);
        return (source == DMA_ERR_SRC_WQE_FETCH) || (source == DMA_ERR_SRC_SGE_FETCH);
    endfunction

    function automatic logic source_is_traversal_or_split(input dma_error_source_e source);
        return (source == DMA_ERR_SRC_SGE_TRAVERSAL) || (source == DMA_ERR_SRC_SEGMENT_SPLIT);
    endfunction

    function automatic logic source_is_arb_or_dispatch(input dma_error_source_e source);
        return (source == DMA_ERR_SRC_ARBITER) || (source == DMA_ERR_SRC_DISPATCHER);
    endfunction

    function automatic cmpl_status_e map_dma_error_to_completion(
        input dma_error_code_e code,
        input mr_operation_e operation,
        input cmpl_status_e original_status
    );
        begin
            unique case (code)
                DMA_ERR_NONE: begin
                    map_dma_error_to_completion = (original_status == CMPL_SUCCESS) ?
                                                  CMPL_GENERAL_ERR :
                                                  original_status;
                end
                DMA_ERR_MR_LOOKUP_MISS,
                DMA_ERR_PD_MISMATCH,
                DMA_ERR_SGE_OVERLAP: begin
                    map_dma_error_to_completion = CMPL_LOC_PROT_ERR;
                end
                DMA_ERR_KEY_DIRECTION,
                DMA_ERR_ACCESS_DENIED: begin
                    map_dma_error_to_completion = is_remote_operation(operation) ?
                                                  CMPL_REM_ACCESS_ERR :
                                                  CMPL_LOC_PROT_ERR;
                end
                DMA_ERR_BOUNDS,
                DMA_ERR_SGE_LENGTH: begin
                    map_dma_error_to_completion = CMPL_LOC_LEN_ERR;
                end
                DMA_ERR_WQE_FETCH,
                DMA_ERR_SGE_FETCH,
                DMA_ERR_UNSUPPORTED_OPCODE,
                DMA_ERR_ARB_MALFORMED: begin
                    map_dma_error_to_completion = CMPL_LOC_QP_OP_ERR;
                end
                DMA_ERR_PCIE_READ,
                DMA_ERR_PCIE_WRITE: begin
                    map_dma_error_to_completion = CMPL_DMA_ERR;
                end
                DMA_ERR_CQ_OVERFLOW: begin
                    map_dma_error_to_completion = CMPL_CQ_OVERFLOW_ERR;
                end
                DMA_ERR_TIMEOUT: begin
                    map_dma_error_to_completion = CMPL_GENERAL_ERR;
                end
                default: begin
                    map_dma_error_to_completion = CMPL_GENERAL_ERR;
                end
            endcase
        end
    endfunction

    always_comb begin
        selected_valid_comb = 1'b0;
        selected_lane_comb = '0;

        // fatal 错误最高优先级，先选低 lane index，保证行为稳定。
        for (int i = 0; i < MAX_DMA_ERROR_SOURCES; i++) begin
            if (!selected_valid_comb && error_valid[i] && error_fatal[i]) begin
                selected_lane_comb = DMA_ERROR_SOURCE_ID_W'(i);
                selected_valid_comb = 1'b1;
            end
        end

        // 保护类错误优先于普通 host/fetch/split/arbiter 错误。
        for (int i = 0; i < MAX_DMA_ERROR_SOURCES; i++) begin
            if (!selected_valid_comb && error_valid[i] && source_is_mr_or_protection(source_at(i))) begin
                selected_lane_comb = DMA_ERROR_SOURCE_ID_W'(i);
                selected_valid_comb = 1'b1;
            end
        end

        for (int i = 0; i < MAX_DMA_ERROR_SOURCES; i++) begin
            if (!selected_valid_comb && error_valid[i] && source_is_host(source_at(i))) begin
                selected_lane_comb = DMA_ERROR_SOURCE_ID_W'(i);
                selected_valid_comb = 1'b1;
            end
        end

        for (int i = 0; i < MAX_DMA_ERROR_SOURCES; i++) begin
            if (!selected_valid_comb && error_valid[i] && source_is_fetch(source_at(i))) begin
                selected_lane_comb = DMA_ERROR_SOURCE_ID_W'(i);
                selected_valid_comb = 1'b1;
            end
        end

        for (int i = 0; i < MAX_DMA_ERROR_SOURCES; i++) begin
            if (!selected_valid_comb && error_valid[i] && source_is_traversal_or_split(source_at(i))) begin
                selected_lane_comb = DMA_ERROR_SOURCE_ID_W'(i);
                selected_valid_comb = 1'b1;
            end
        end

        for (int i = 0; i < MAX_DMA_ERROR_SOURCES; i++) begin
            if (!selected_valid_comb && error_valid[i] && source_is_arb_or_dispatch(source_at(i))) begin
                selected_lane_comb = DMA_ERROR_SOURCE_ID_W'(i);
                selected_valid_comb = 1'b1;
            end
        end

        // 未分类但 valid 的 lane 仍然不能丢，最后兜底选择。
        for (int i = 0; i < MAX_DMA_ERROR_SOURCES; i++) begin
            if (!selected_valid_comb && error_valid[i]) begin
                selected_lane_comb = DMA_ERROR_SOURCE_ID_W'(i);
                selected_valid_comb = 1'b1;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= DMA_ERR_PROP_STATE_IDLE;
            captured_event_reg <= '0;
            mapped_status_reg <= CMPL_SUCCESS;
            selected_lane_reg <= '0;
        end else begin
            unique case (state_reg)
                DMA_ERR_PROP_STATE_IDLE: begin
                    if (|error_valid) begin
                        state_reg <= DMA_ERR_PROP_STATE_SELECT;
                    end
                end

                DMA_ERR_PROP_STATE_SELECT: begin
                    if (selected_valid_comb) begin
                        selected_lane_reg <= selected_lane_comb;
                        captured_event_reg.source_id <= source_at(selected_lane_comb);
                        captured_event_reg.desc_id <= desc_at(selected_lane_comb);
                        captured_event_reg.qpn <= qpn_at(selected_lane_comb);
                        captured_event_reg.cqn <= cqn_at(selected_lane_comb);
                        captured_event_reg.owner_function <= owner_at(selected_lane_comb);
                        captured_event_reg.pd_id <= pd_at(selected_lane_comb);
                        captured_event_reg.operation <= operation_at(selected_lane_comb);
                        captured_event_reg.direction <= direction_at(selected_lane_comb);
                        captured_event_reg.segment_index <= segment_at(selected_lane_comb);
                        captured_event_reg.byte_offset <= byte_offset_at(selected_lane_comb);
                        captured_event_reg.dma_error_code <= code_at(selected_lane_comb);
                        captured_event_reg.original_status <= original_status_at(selected_lane_comb);
                        captured_event_reg.fatal <= error_fatal[selected_lane_comb];
                        captured_event_reg.retryable <= error_retryable[selected_lane_comb];
                        captured_event_reg.wr_id <= wr_id_at(selected_lane_comb);
                        captured_event_reg.opcode <= opcode_at(selected_lane_comb);
                        captured_event_reg.byte_len <= byte_len_at(selected_lane_comb);
                        captured_event_reg.solicited <= error_solicited[selected_lane_comb];
                        state_reg <= DMA_ERR_PROP_STATE_CAPTURE;
                    end else begin
                        state_reg <= DMA_ERR_PROP_STATE_IDLE;
                    end
                end

                DMA_ERR_PROP_STATE_CAPTURE: begin
                    state_reg <= DMA_ERR_PROP_STATE_MAP_STATUS;
                end

                DMA_ERR_PROP_STATE_MAP_STATUS: begin
                    mapped_status_reg <= map_dma_error_to_completion(
                        captured_event_reg.dma_error_code,
                        captured_event_reg.operation,
                        captured_event_reg.original_status
                    );
                    state_reg <= DMA_ERR_PROP_STATE_EMIT_CMPL;
                end

                DMA_ERR_PROP_STATE_EMIT_CMPL: begin
                    if (completion_error_ready) begin
                        if (captured_event_reg.fatal) begin
                            state_reg <= DMA_ERR_PROP_STATE_EMIT_QP_ERR;
                        end else begin
                            state_reg <= DMA_ERR_PROP_STATE_DONE;
                        end
                    end
                end

                DMA_ERR_PROP_STATE_EMIT_QP_ERR: begin
                    if (qp_error_req_ready) begin
                        state_reg <= DMA_ERR_PROP_STATE_DONE;
                    end
                end

                DMA_ERR_PROP_STATE_DONE: begin
                    state_reg <= DMA_ERR_PROP_STATE_IDLE;
                end

                default: begin
                    state_reg <= DMA_ERR_PROP_STATE_ERROR;
                end
            endcase
        end
    end

endmodule
