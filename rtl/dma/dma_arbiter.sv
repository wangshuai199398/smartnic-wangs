// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// DMA arbitration 最小实现。
//
// 本模块在多个 active QP/source 的 DMA 请求之间选择一个 grant。当前阶段只
// 实现请求仲裁和公平性状态，不执行真实 host read/write/fetch，也不做错误完成传播。

`timescale 1ns/1ps

import smartnic_pkg::*;

module dma_arbiter (
    input  logic                         clk,                         // arbiter 时钟。
    input  logic                         rst_n,                       // 低有效复位。

    input  dma_arb_policy_e              arb_policy,                  // 当前仲裁策略。
    input  logic [DMA_ARB_WAIT_COUNTER_W-1:0] starvation_threshold,    // starvation guard 阈值，0 使用默认值。

    // ------------------------------------------------------------------
    // Vectorized request inputs, one lane per DMA source
    // ------------------------------------------------------------------
    input  logic [MAX_DMA_ARB_SOURCES-1:0] req_valid,                 // 每个 source 请求有效。
    output logic [MAX_DMA_ARB_SOURCES-1:0] req_ready,                 // 仅被 grant 且 accepted 的 source ready。
    input  logic [MAX_DMA_ARB_SOURCES*DMA_ARB_SOURCE_ID_W-1:0] req_source_id, // source ID。
    input  logic [MAX_DMA_ARB_SOURCES*QP_ID_W-1:0] req_qpn,           // QPN。
    input  logic [MAX_DMA_ARB_SOURCES*VF_ID_W-1:0] req_owner_function,// owner function。
    input  logic [MAX_DMA_ARB_SOURCES*16-1:0] req_desc_id,            // descriptor ID。
    input  logic [MAX_DMA_ARB_SOURCES*4-1:0] req_operation,           // mr_operation_e packed。
    input  logic [MAX_DMA_ARB_SOURCES*3-1:0] req_direction,           // dma_direction_e packed。
    input  logic [MAX_DMA_ARB_SOURCES*DMA_LEN_W-1:0] req_len,         // 请求长度。
    input  logic [MAX_DMA_ARB_SOURCES*DMA_ARB_PRIORITY_W-1:0] req_priority, // source priority。
    input  logic [MAX_DMA_ARB_SOURCES*DMA_ARB_WEIGHT_W-1:0] req_weight, // WRR weight，0 表示 disabled。
    input  logic [MAX_DMA_ARB_SOURCES*DMA_ARB_PAYLOAD_W-1:0] req_payload, // 透传 metadata/payload。

    // ------------------------------------------------------------------
    // Grant output
    // ------------------------------------------------------------------
    output logic                         grant_valid,                 // grant 有效。
    input  logic                         grant_ready,                 // 下游接受 grant。
    output logic [DMA_ARB_SOURCE_ID_W-1:0] grant_source_id,           // grant source ID。
    output logic [QP_ID_W-1:0]           grant_qpn,                   // grant QPN。
    output logic [VF_ID_W-1:0]           grant_owner_function,        // grant owner function。
    output logic [15:0]                  grant_desc_id,               // grant descriptor ID。
    output mr_operation_e                grant_operation,             // grant operation。
    output dma_direction_e               grant_direction,             // grant direction。
    output logic [DMA_LEN_W-1:0]         grant_len,                   // grant length。
    output logic [DMA_ARB_PAYLOAD_W-1:0] grant_payload,               // grant payload/metadata。
    output dma_arb_policy_e              grant_policy_used,           // grant 使用的 policy。

    output logic [MAX_DMA_ARB_SOURCES-1:0] starvation_detected,       // 每个 source 的 starvation 状态。
    output logic [DMA_ARB_SOURCE_ID_W-1:0] starvation_source_id,       // 第一个 starvation source。
    output dma_arb_error_e               arb_error_code,              // 仲裁错误码。
    output dma_arb_state_e               debug_state,                 // 调试观察 FSM 状态。
    output logic [DMA_ARB_SOURCE_ID_W-1:0] debug_last_grant_source     // 最近一次被接受的 source。
);

    dma_arb_state_e state_reg;
    dma_arb_policy_e policy_used_reg;
    dma_arb_error_e error_code_reg;

    logic [DMA_ARB_SOURCE_ID_W-1:0] selected_idx_reg;
    logic [DMA_ARB_SOURCE_ID_W-1:0] selected_idx_comb;
    logic selected_valid_comb;
    logic [DMA_ARB_SOURCE_ID_W-1:0] last_grant_source_reg;
    logic [DMA_ARB_SOURCE_ID_W-1:0] wrr_current_source_reg;
    logic [DMA_ARB_WEIGHT_W-1:0] wrr_service_count_reg;
    logic [DMA_ARB_WAIT_COUNTER_W-1:0] wait_counter_reg [MAX_DMA_ARB_SOURCES];
    logic [DMA_ARB_SOURCE_ID_W-1:0] wrr_next_source_comb;
    logic wrr_next_source_valid_comb;

    logic [DMA_ARB_WAIT_COUNTER_W-1:0] effective_starvation_threshold;
    logic any_req_valid;
    logic grant_fire;
    logic [MAX_DMA_ARB_SOURCES-1:0] selected_onehot;

    assign debug_state = state_reg;
    assign debug_last_grant_source = last_grant_source_reg;
    assign arb_error_code = error_code_reg;
    assign effective_starvation_threshold = (starvation_threshold == '0) ?
                                            DMA_ARB_DEFAULT_STARVATION_THRESHOLD :
                                            starvation_threshold;
    assign any_req_valid = |req_valid;
    assign grant_fire = grant_valid && grant_ready;

    always_comb begin
        selected_onehot = '0;
        if (int'(selected_idx_reg) < MAX_DMA_ARB_SOURCES) begin
            selected_onehot[selected_idx_reg] = 1'b1;
        end
    end

    assign req_ready = grant_fire ? selected_onehot : '0;

    function automatic logic [DMA_ARB_SOURCE_ID_W-1:0] src_id_at(input int idx);
        return req_source_id[idx*DMA_ARB_SOURCE_ID_W +: DMA_ARB_SOURCE_ID_W];
    endfunction

    function automatic logic [QP_ID_W-1:0] qpn_at(input int idx);
        return req_qpn[idx*QP_ID_W +: QP_ID_W];
    endfunction

    function automatic logic [VF_ID_W-1:0] owner_at(input int idx);
        return req_owner_function[idx*VF_ID_W +: VF_ID_W];
    endfunction

    function automatic logic [15:0] desc_at(input int idx);
        return req_desc_id[idx*16 +: 16];
    endfunction

    function automatic mr_operation_e operation_at(input int idx);
        return mr_operation_e'(req_operation[idx*4 +: 4]);
    endfunction

    function automatic dma_direction_e direction_at(input int idx);
        return dma_direction_e'(req_direction[idx*3 +: 3]);
    endfunction

    function automatic logic [DMA_LEN_W-1:0] len_at(input int idx);
        return req_len[idx*DMA_LEN_W +: DMA_LEN_W];
    endfunction

    function automatic logic [DMA_ARB_PRIORITY_W-1:0] priority_at(input int idx);
        return req_priority[idx*DMA_ARB_PRIORITY_W +: DMA_ARB_PRIORITY_W];
    endfunction

    function automatic logic [DMA_ARB_WEIGHT_W-1:0] weight_at(input int idx);
        return req_weight[idx*DMA_ARB_WEIGHT_W +: DMA_ARB_WEIGHT_W];
    endfunction

    function automatic logic [DMA_ARB_PAYLOAD_W-1:0] payload_at(input int idx);
        return req_payload[idx*DMA_ARB_PAYLOAD_W +: DMA_ARB_PAYLOAD_W];
    endfunction

    function automatic int rr_index(input int base, input int step);
        int value;
        begin
            value = base + step;
            while (value >= MAX_DMA_ARB_SOURCES) begin
                value = value - MAX_DMA_ARB_SOURCES;
            end
            return value;
        end
    endfunction

    function automatic logic source_enabled(input int idx);
        return req_valid[idx] && (weight_at(idx) != '0);
    endfunction

    always_comb begin
        starvation_detected = '0;
        starvation_source_id = '0;
        for (int i = 0; i < MAX_DMA_ARB_SOURCES; i++) begin
            if (req_valid[i] && (wait_counter_reg[i] >= effective_starvation_threshold)) begin
                if (starvation_detected == '0) begin
                    starvation_source_id = DMA_ARB_SOURCE_ID_W'(i);
                end
                starvation_detected[i] = 1'b1;
            end
        end
    end

    always_comb begin
        wrr_next_source_comb = selected_idx_reg;
        wrr_next_source_valid_comb = 1'b0;
        for (int step = 1; step <= MAX_DMA_ARB_SOURCES; step++) begin
            int idx;
            idx = rr_index(selected_idx_reg, step);
            if (!wrr_next_source_valid_comb && source_enabled(idx)) begin
                wrr_next_source_comb = DMA_ARB_SOURCE_ID_W'(idx);
                wrr_next_source_valid_comb = 1'b1;
            end
        end
    end

    always_comb begin
        selected_valid_comb = 1'b0;
        selected_idx_comb = '0;

        unique case (arb_policy)
            DMA_ARB_POLICY_FIXED_PRIORITY: begin
                // CQE write > RQ/RDMA read response write > SQ/RDMA write read > fetch。
                if (req_valid[DMA_SRC_CQE_WRITE]) begin
                    selected_idx_comb = DMA_SRC_CQE_WRITE;
                    selected_valid_comb = 1'b1;
                end else if (req_valid[DMA_SRC_RQ_HOST_WRITE]) begin
                    selected_idx_comb = DMA_SRC_RQ_HOST_WRITE;
                    selected_valid_comb = 1'b1;
                end else if (req_valid[DMA_SRC_RDMA_READ_RESP_WRITE]) begin
                    selected_idx_comb = DMA_SRC_RDMA_READ_RESP_WRITE;
                    selected_valid_comb = 1'b1;
                end else if (req_valid[DMA_SRC_SQ_HOST_READ]) begin
                    selected_idx_comb = DMA_SRC_SQ_HOST_READ;
                    selected_valid_comb = 1'b1;
                end else if (req_valid[DMA_SRC_RDMA_WRITE_HOST_READ]) begin
                    selected_idx_comb = DMA_SRC_RDMA_WRITE_HOST_READ;
                    selected_valid_comb = 1'b1;
                end else if (req_valid[DMA_SRC_WQE_FETCH]) begin
                    selected_idx_comb = DMA_SRC_WQE_FETCH;
                    selected_valid_comb = 1'b1;
                end else if (req_valid[DMA_SRC_SGE_FETCH]) begin
                    selected_idx_comb = DMA_SRC_SGE_FETCH;
                    selected_valid_comb = 1'b1;
                end
            end

            DMA_ARB_POLICY_ROUND_ROBIN: begin
                for (int step = 1; step <= MAX_DMA_ARB_SOURCES; step++) begin
                    int idx;
                    idx = rr_index(last_grant_source_reg, step);
                    if (!selected_valid_comb && req_valid[idx]) begin
                        selected_idx_comb = DMA_ARB_SOURCE_ID_W'(idx);
                        selected_valid_comb = 1'b1;
                    end
                end
            end

            DMA_ARB_POLICY_WEIGHTED_RR: begin
                if (source_enabled(wrr_current_source_reg) &&
                    (wrr_service_count_reg < weight_at(wrr_current_source_reg))) begin
                    selected_idx_comb = wrr_current_source_reg;
                    selected_valid_comb = 1'b1;
                end else begin
                    for (int step = 1; step <= MAX_DMA_ARB_SOURCES; step++) begin
                        int idx;
                        idx = rr_index(wrr_current_source_reg, step);
                        if (!selected_valid_comb && source_enabled(idx)) begin
                            selected_idx_comb = DMA_ARB_SOURCE_ID_W'(idx);
                            selected_valid_comb = 1'b1;
                        end
                    end
                end
            end

            DMA_ARB_POLICY_STRICT_GUARD: begin
                for (int i = 0; i < MAX_DMA_ARB_SOURCES; i++) begin
                    if (!selected_valid_comb &&
                        req_valid[i] &&
                        (wait_counter_reg[i] >= effective_starvation_threshold)) begin
                        selected_idx_comb = DMA_ARB_SOURCE_ID_W'(i);
                        selected_valid_comb = 1'b1;
                    end
                end
                if (!selected_valid_comb) begin
                    if (req_valid[DMA_SRC_CQE_WRITE]) begin
                        selected_idx_comb = DMA_SRC_CQE_WRITE;
                        selected_valid_comb = 1'b1;
                    end else if (req_valid[DMA_SRC_RQ_HOST_WRITE]) begin
                        selected_idx_comb = DMA_SRC_RQ_HOST_WRITE;
                        selected_valid_comb = 1'b1;
                    end else if (req_valid[DMA_SRC_RDMA_READ_RESP_WRITE]) begin
                        selected_idx_comb = DMA_SRC_RDMA_READ_RESP_WRITE;
                        selected_valid_comb = 1'b1;
                    end else if (req_valid[DMA_SRC_SQ_HOST_READ]) begin
                        selected_idx_comb = DMA_SRC_SQ_HOST_READ;
                        selected_valid_comb = 1'b1;
                    end else if (req_valid[DMA_SRC_RDMA_WRITE_HOST_READ]) begin
                        selected_idx_comb = DMA_SRC_RDMA_WRITE_HOST_READ;
                        selected_valid_comb = 1'b1;
                    end else if (req_valid[DMA_SRC_WQE_FETCH]) begin
                        selected_idx_comb = DMA_SRC_WQE_FETCH;
                        selected_valid_comb = 1'b1;
                    end else if (req_valid[DMA_SRC_SGE_FETCH]) begin
                        selected_idx_comb = DMA_SRC_SGE_FETCH;
                        selected_valid_comb = 1'b1;
                    end
                end
            end

            default: begin
                selected_idx_comb = '0;
                selected_valid_comb = 1'b0;
            end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= DMA_ARB_STATE_IDLE;
            policy_used_reg <= DMA_ARB_POLICY_FIXED_PRIORITY;
            error_code_reg <= DMA_ARB_ERR_NONE;
            selected_idx_reg <= '0;
            last_grant_source_reg <= DMA_SRC_SGE_FETCH;
            wrr_current_source_reg <= DMA_SRC_SQ_HOST_READ;
            wrr_service_count_reg <= '0;
            grant_valid <= 1'b0;
            grant_source_id <= '0;
            grant_qpn <= '0;
            grant_owner_function <= '0;
            grant_desc_id <= '0;
            grant_operation <= MR_OP_LOCAL_DMA_READ;
            grant_direction <= DMA_DIR_HOST_READ;
            grant_len <= '0;
            grant_payload <= '0;
            grant_policy_used <= DMA_ARB_POLICY_FIXED_PRIORITY;
            for (int i = 0; i < MAX_DMA_ARB_SOURCES; i++) begin
                wait_counter_reg[i] <= '0;
            end
        end else begin
            unique case (state_reg)
                DMA_ARB_STATE_IDLE: begin
                    error_code_reg <= DMA_ARB_ERR_NONE;
                    if (!grant_valid && any_req_valid) begin
                        state_reg <= DMA_ARB_STATE_COLLECT;
                    end
                end

                DMA_ARB_STATE_COLLECT: begin
                    state_reg <= DMA_ARB_STATE_SELECT_POLICY;
                end

                DMA_ARB_STATE_SELECT_POLICY: begin
                    policy_used_reg <= arb_policy;
                    if ((arb_policy != DMA_ARB_POLICY_FIXED_PRIORITY) &&
                        (arb_policy != DMA_ARB_POLICY_ROUND_ROBIN) &&
                        (arb_policy != DMA_ARB_POLICY_WEIGHTED_RR) &&
                        (arb_policy != DMA_ARB_POLICY_STRICT_GUARD)) begin
                        error_code_reg <= DMA_ARB_ERR_INVALID_POLICY;
                        state_reg <= DMA_ARB_STATE_ERROR;
                    end else begin
                        state_reg <= DMA_ARB_STATE_SELECT_SOURCE;
                    end
                end

                DMA_ARB_STATE_SELECT_SOURCE: begin
                    if (!selected_valid_comb) begin
                        error_code_reg <= DMA_ARB_ERR_NO_VALID;
                        state_reg <= DMA_ARB_STATE_ERROR;
                    end else if (int'(selected_idx_comb) >= MAX_DMA_ARB_SOURCES) begin
                        error_code_reg <= DMA_ARB_ERR_INVALID_SOURCE;
                        state_reg <= DMA_ARB_STATE_ERROR;
                    end else begin
                        selected_idx_reg <= selected_idx_comb;
                        grant_source_id <= src_id_at(selected_idx_comb);
                        grant_qpn <= qpn_at(selected_idx_comb);
                        grant_owner_function <= owner_at(selected_idx_comb);
                        grant_desc_id <= desc_at(selected_idx_comb);
                        grant_operation <= operation_at(selected_idx_comb);
                        grant_direction <= direction_at(selected_idx_comb);
                        grant_len <= len_at(selected_idx_comb);
                        grant_payload <= payload_at(selected_idx_comb);
                        grant_policy_used <= policy_used_reg;
                        grant_valid <= 1'b1;
                        state_reg <= DMA_ARB_STATE_HOLD_GRANT;
                    end
                end

                DMA_ARB_STATE_HOLD_GRANT: begin
                    if (grant_fire) begin
                        grant_valid <= 1'b0;
                        state_reg <= DMA_ARB_STATE_UPDATE_FAIRNESS;
                    end
                end

                DMA_ARB_STATE_UPDATE_FAIRNESS: begin
                    last_grant_source_reg <= selected_idx_reg;
                    for (int i = 0; i < MAX_DMA_ARB_SOURCES; i++) begin
                        if (DMA_ARB_SOURCE_ID_W'(i) == selected_idx_reg) begin
                            wait_counter_reg[i] <= '0;
                        end else if (req_valid[i] && (wait_counter_reg[i] != {DMA_ARB_WAIT_COUNTER_W{1'b1}})) begin
                            wait_counter_reg[i] <= wait_counter_reg[i] + 1'b1;
                        end else if (!req_valid[i]) begin
                            wait_counter_reg[i] <= '0;
                        end
                    end

                    if (policy_used_reg == DMA_ARB_POLICY_WEIGHTED_RR) begin
                        if (selected_idx_reg == wrr_current_source_reg) begin
                            if ((wrr_service_count_reg + 1'b1) >= weight_at(selected_idx_reg)) begin
                                wrr_service_count_reg <= '0;
                                if (wrr_next_source_valid_comb) begin
                                    wrr_current_source_reg <= wrr_next_source_comb;
                                end else begin
                                    wrr_current_source_reg <= selected_idx_reg;
                                end
                            end else begin
                                wrr_service_count_reg <= wrr_service_count_reg + 1'b1;
                            end
                        end else begin
                            wrr_current_source_reg <= selected_idx_reg;
                            wrr_service_count_reg <= 8'd1;
                        end
                    end

                    state_reg <= DMA_ARB_STATE_DONE;
                end

                DMA_ARB_STATE_DONE: begin
                    state_reg <= DMA_ARB_STATE_IDLE;
                end

                DMA_ARB_STATE_ERROR: begin
                    grant_valid <= 1'b0;
                    state_reg <= DMA_ARB_STATE_IDLE;
                end

                default: begin
                    state_reg <= DMA_ARB_STATE_IDLE;
                    grant_valid <= 1'b0;
                    error_code_reg <= DMA_ARB_ERR_NONE;
                end
            endcase
        end
    end

    logic unused_priority;
    assign unused_priority = ^req_priority;

endmodule : dma_arbiter
