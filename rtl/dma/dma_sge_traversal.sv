// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// DMA SGE traversal 最小实现。
//
// 本模块接收 dma_wqe_sge_fetcher 输出的 SGE stream，把每个 SGE 规范化成
// 后续 MR lookup / DMA split 可以使用的 dma_segment_t。当前阶段只做：
// - SGE index 顺序检查；
// - total-length accounting；
// - byte_offset 计算；
// - zero-overlap validation。
//
// 本阶段不做 MR lookup、access permission、PD check、PMTU/4KB split 或真实 DMA。

`timescale 1ns/1ps

import smartnic_pkg::*;

module dma_sge_traversal (
    input  logic                         clk,                         // traversal 时钟。
    input  logic                         rst_n,                       // 低有效复位。

    // ------------------------------------------------------------------
    // SGE stream input
    // ------------------------------------------------------------------
    input  logic                         sge_stream_valid,            // 输入 SGE 有效。
    output logic                         sge_stream_ready,            // traversal 可接收当前 SGE。
    input  logic [15:0]                  sge_stream_desc_id,          // 来源 descriptor ID。
    input  logic [QP_ID_W-1:0]           sge_stream_qpn,              // 当前 WR 所属 QPN。
    input  logic [VF_ID_W-1:0]           sge_stream_owner_function,   // 当前 WR 所属 PF/VF function。
    input  logic [PD_ID_W-1:0]           sge_stream_pd_id,            // 当前 QP/MR 所属 PD。
    input  mr_operation_e                sge_stream_operation,        // 后续 MR checker 使用的操作类型。
    input  logic [DMA_SGE_COUNT_W-1:0]   sge_stream_index,            // 当前 SGE index，合法范围 0..255。
    input  logic [ADDR_W-1:0]            sge_stream_addr,             // 当前 SGE 虚拟地址。
    input  logic [DMA_LEN_W-1:0]         sge_stream_length,           // 当前 SGE 长度。
    input  logic [KEY_W-1:0]             sge_stream_lkey,             // 当前 SGE lkey。
    input  logic [15:0]                  sge_stream_flags,            // 当前 SGE flags。
    input  logic                         sge_stream_last,             // 当前 SGE 是否为 list 最后一项。
    input  logic [DMA_LEN_W-1:0]         expected_total_len,          // WR 期望搬运的总字节数。

    // Inline data 不走 SGE/MR lookup。本阶段只提供旁路语义检查接口，
    // 真正 payload 搬运留给后续 transport / DMA 数据路径。
    input  logic                         inline_data_present,         // WQE 是否携带 inline payload。
    input  logic [DMA_LEN_W-1:0]         inline_data_len,             // inline payload 长度。

    // ------------------------------------------------------------------
    // Normalized DMA segment output
    // ------------------------------------------------------------------
    output logic                         dma_segment_valid,           // 输出 segment 有效。
    input  logic                         dma_segment_ready,           // 下游可接收 segment。
    output logic [15:0]                  dma_segment_desc_id,         // 来源 descriptor ID。
    output logic [QP_ID_W-1:0]           dma_segment_qpn,             // segment 所属 QPN。
    output logic [VF_ID_W-1:0]           dma_segment_owner_function,  // segment 所属 PF/VF function。
    output logic [PD_ID_W-1:0]           dma_segment_pd_id,           // segment 所属 PD。
    output mr_operation_e                dma_segment_operation,       // segment 操作类型。
    output logic [DMA_SGE_COUNT_W-1:0]   dma_segment_index,           // segment 对应 SGE index。
    output logic [ADDR_W-1:0]            dma_segment_va,              // segment 虚拟地址。
    output logic [DMA_LEN_W-1:0]         dma_segment_len,             // segment 长度。
    output logic [KEY_W-1:0]             dma_segment_lkey,            // segment lkey。
    output logic [15:0]                  dma_segment_flags,           // segment flags。
    output logic [DMA_BYTE_OFFSET_W-1:0] dma_segment_byte_offset,     // WR 内字节偏移。
    output logic                         dma_segment_is_last,         // segment 是否为 WR 最后一段。
    output sge_traversal_error_e         traversal_error_code,        // 当前错误码；无错误为 NONE。

    // ------------------------------------------------------------------
    // Error / done status
    // ------------------------------------------------------------------
    output logic                         traversal_error_valid,       // traversal error 有效。
    input  logic                         traversal_error_ready,       // 下游已接收 error。
    output logic                         traversal_done_valid,        // 当前 SGE list 或 inline payload 校验完成。
    input  logic                         traversal_done_ready,        // 下游已接收 done。
    output sge_traversal_state_e         debug_state                  // 调试观察 FSM 状态。
);

    sge_traversal_state_e state_reg;

    logic [15:0] latched_desc_id_reg;
    logic [QP_ID_W-1:0] latched_qpn_reg;
    logic [VF_ID_W-1:0] latched_owner_reg;
    logic [PD_ID_W-1:0] latched_pd_id_reg;
    mr_operation_e latched_operation_reg;
    logic [DMA_SGE_COUNT_W-1:0] latched_index_reg;
    logic [ADDR_W-1:0] latched_addr_reg;
    logic [DMA_LEN_W-1:0] latched_len_reg;
    logic [KEY_W-1:0] latched_lkey_reg;
    logic [15:0] latched_flags_reg;
    logic latched_last_reg;
    logic [DMA_LEN_W-1:0] expected_total_reg;

    logic [DMA_TOTAL_LEN_W-1:0] total_len_reg;
    logic [DMA_TOTAL_LEN_W-1:0] next_total_len;
    logic [DMA_SGE_COUNT_W-1:0] expected_index_reg;
    logic [DMA_BYTE_OFFSET_W-1:0] byte_offset_reg;
    logic [31:0] timeout_counter_reg;
    logic active_list_reg;

    logic seen_valid [MAX_SGE];
    logic [ADDR_W-1:0] seen_base [MAX_SGE];
    logic [ADDR_W-1:0] seen_end [MAX_SGE];

    logic [ADDR_W-1:0] latched_end_addr;
    logic addr_overflow;
    logic total_overflow;
    logic overlap_found;
    logic index_range_error;
    logic index_order_error;
    sge_traversal_error_e error_code_reg;

    assign debug_state = state_reg;

    assign sge_stream_ready = (state_reg == SGE_TRAV_STATE_IDLE) &&
                              !inline_data_present &&
                              !traversal_done_valid &&
                              !traversal_error_valid;

    assign dma_segment_valid = (state_reg == SGE_TRAV_STATE_EMIT_SEGMENT);
    assign dma_segment_desc_id = latched_desc_id_reg;
    assign dma_segment_qpn = latched_qpn_reg;
    assign dma_segment_owner_function = latched_owner_reg;
    assign dma_segment_pd_id = latched_pd_id_reg;
    assign dma_segment_operation = latched_operation_reg;
    assign dma_segment_index = latched_index_reg;
    assign dma_segment_va = latched_addr_reg;
    assign dma_segment_len = latched_len_reg;
    assign dma_segment_lkey = latched_lkey_reg;
    assign dma_segment_flags = latched_flags_reg;
    assign dma_segment_byte_offset = byte_offset_reg;
    assign dma_segment_is_last = latched_last_reg;
    assign traversal_error_code = error_code_reg;

    assign latched_end_addr = latched_addr_reg + ADDR_W'(latched_len_reg);
    assign addr_overflow = (latched_end_addr < latched_addr_reg);
    assign next_total_len = total_len_reg + DMA_TOTAL_LEN_W'(latched_len_reg);
    assign total_overflow = next_total_len[DMA_TOTAL_LEN_W-1];
    assign index_range_error = (latched_index_reg >= DMA_SGE_COUNT_W'(MAX_SGE));
    assign index_order_error = (latched_index_reg != expected_index_reg);

    always_comb begin
        overlap_found = 1'b0;
        for (int i = 0; i < MAX_SGE; i++) begin
            if (seen_valid[i]) begin
                if (!((latched_end_addr <= seen_base[i]) ||
                      (seen_end[i] <= latched_addr_reg))) begin
                    overlap_found = 1'b1;
                end
            end
        end
    end

    task automatic clear_seen_ranges;
        for (int i = 0; i < MAX_SGE; i++) begin
            seen_valid[i] <= 1'b0;
            seen_base[i] <= '0;
            seen_end[i] <= '0;
        end
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= SGE_TRAV_STATE_IDLE;
            latched_desc_id_reg <= '0;
            latched_qpn_reg <= '0;
            latched_owner_reg <= '0;
            latched_pd_id_reg <= '0;
            latched_operation_reg <= MR_OP_LOCAL_DMA_READ;
            latched_index_reg <= '0;
            latched_addr_reg <= '0;
            latched_len_reg <= '0;
            latched_lkey_reg <= '0;
            latched_flags_reg <= '0;
            latched_last_reg <= 1'b0;
            expected_total_reg <= '0;
            total_len_reg <= '0;
            expected_index_reg <= '0;
            byte_offset_reg <= '0;
            timeout_counter_reg <= '0;
            active_list_reg <= 1'b0;
            error_code_reg <= SGE_TRAV_ERR_NONE;
            traversal_error_valid <= 1'b0;
            traversal_done_valid <= 1'b0;
            clear_seen_ranges();
        end else begin
            unique case (state_reg)
                SGE_TRAV_STATE_IDLE: begin
                    error_code_reg <= SGE_TRAV_ERR_NONE;
                    if (traversal_done_valid && traversal_done_ready) begin
                        traversal_done_valid <= 1'b0;
                    end
                    if (traversal_error_valid && traversal_error_ready) begin
                        traversal_error_valid <= 1'b0;
                    end

                    if (!traversal_done_valid && !traversal_error_valid && inline_data_present) begin
                        clear_seen_ranges();
                        active_list_reg <= 1'b0;
                        total_len_reg <= '0;
                        expected_index_reg <= '0;
                        timeout_counter_reg <= '0;
                        if ((expected_total_len == '0) || (inline_data_len != expected_total_len)) begin
                            error_code_reg <= SGE_TRAV_ERR_EXPECTED_LEN;
                            traversal_error_valid <= 1'b1;
                            state_reg <= SGE_TRAV_STATE_ERROR;
                        end else begin
                            traversal_done_valid <= 1'b1;
                            state_reg <= SGE_TRAV_STATE_DONE;
                        end
                    end else if (sge_stream_valid && sge_stream_ready) begin
                        latched_desc_id_reg <= sge_stream_desc_id;
                        latched_qpn_reg <= sge_stream_qpn;
                        latched_owner_reg <= sge_stream_owner_function;
                        latched_pd_id_reg <= sge_stream_pd_id;
                        latched_operation_reg <= sge_stream_operation;
                        latched_index_reg <= sge_stream_index;
                        latched_addr_reg <= sge_stream_addr;
                        latched_len_reg <= sge_stream_length;
                        latched_lkey_reg <= sge_stream_lkey;
                        latched_flags_reg <= sge_stream_flags;
                        latched_last_reg <= sge_stream_last;
                        expected_total_reg <= expected_total_len;
                        byte_offset_reg <= DMA_BYTE_OFFSET_W'(total_len_reg);
                        timeout_counter_reg <= '0;
                        state_reg <= SGE_TRAV_STATE_ACCEPT_SGE;
                    end else if (active_list_reg) begin
                        timeout_counter_reg <= timeout_counter_reg + 32'd1;
                        if (timeout_counter_reg >= 32'(SGE_TRAVERSAL_TIMEOUT_CYCLES)) begin
                            error_code_reg <= SGE_TRAV_ERR_MISSING_LAST;
                            traversal_error_valid <= 1'b1;
                            active_list_reg <= 1'b0;
                            clear_seen_ranges();
                            state_reg <= SGE_TRAV_STATE_ERROR;
                        end
                    end
                end

                SGE_TRAV_STATE_ACCEPT_SGE: begin
                    state_reg <= SGE_TRAV_STATE_CHECK_ZERO_LEN;
                end

                SGE_TRAV_STATE_CHECK_ZERO_LEN: begin
                    if ((expected_total_reg == '0) || (latched_len_reg == '0)) begin
                        error_code_reg <= (expected_total_reg == '0) ?
                                          SGE_TRAV_ERR_EXPECTED_LEN :
                                          SGE_TRAV_ERR_ZERO_LENGTH;
                        traversal_error_valid <= 1'b1;
                        active_list_reg <= 1'b0;
                        clear_seen_ranges();
                        state_reg <= SGE_TRAV_STATE_ERROR;
                    end else begin
                        state_reg <= SGE_TRAV_STATE_CHECK_ADDR;
                    end
                end

                SGE_TRAV_STATE_CHECK_ADDR: begin
                    if (addr_overflow) begin
                        error_code_reg <= SGE_TRAV_ERR_ADDR_OVERFLOW;
                        traversal_error_valid <= 1'b1;
                        active_list_reg <= 1'b0;
                        clear_seen_ranges();
                        state_reg <= SGE_TRAV_STATE_ERROR;
                    end else begin
                        state_reg <= SGE_TRAV_STATE_CHECK_INDEX;
                    end
                end

                SGE_TRAV_STATE_CHECK_INDEX: begin
                    if (index_range_error) begin
                        error_code_reg <= SGE_TRAV_ERR_INDEX_RANGE;
                        traversal_error_valid <= 1'b1;
                        active_list_reg <= 1'b0;
                        clear_seen_ranges();
                        state_reg <= SGE_TRAV_STATE_ERROR;
                    end else if (index_order_error) begin
                        error_code_reg <= SGE_TRAV_ERR_INDEX_ORDER;
                        traversal_error_valid <= 1'b1;
                        active_list_reg <= 1'b0;
                        clear_seen_ranges();
                        state_reg <= SGE_TRAV_STATE_ERROR;
                    end else begin
                        state_reg <= SGE_TRAV_STATE_CHECK_OVERLAP;
                    end
                end

                SGE_TRAV_STATE_CHECK_OVERLAP: begin
                    if (overlap_found) begin
                        error_code_reg <= SGE_TRAV_ERR_OVERLAP;
                        traversal_error_valid <= 1'b1;
                        active_list_reg <= 1'b0;
                        clear_seen_ranges();
                        state_reg <= SGE_TRAV_STATE_ERROR;
                    end else if (total_overflow) begin
                        error_code_reg <= SGE_TRAV_ERR_TOTAL_OVERFLOW;
                        traversal_error_valid <= 1'b1;
                        active_list_reg <= 1'b0;
                        clear_seen_ranges();
                        state_reg <= SGE_TRAV_STATE_ERROR;
                    end else if (next_total_len > DMA_TOTAL_LEN_W'(expected_total_reg)) begin
                        error_code_reg <= SGE_TRAV_ERR_LENGTH_OVERRUN;
                        traversal_error_valid <= 1'b1;
                        active_list_reg <= 1'b0;
                        clear_seen_ranges();
                        state_reg <= SGE_TRAV_STATE_ERROR;
                    end else begin
                        state_reg <= SGE_TRAV_STATE_EMIT_SEGMENT;
                    end
                end

                SGE_TRAV_STATE_EMIT_SEGMENT: begin
                    if (dma_segment_ready) begin
                        state_reg <= SGE_TRAV_STATE_UPDATE_ACCOUNT;
                    end
                end

                SGE_TRAV_STATE_UPDATE_ACCOUNT: begin
                    if (total_overflow) begin
                        error_code_reg <= SGE_TRAV_ERR_TOTAL_OVERFLOW;
                        traversal_error_valid <= 1'b1;
                        active_list_reg <= 1'b0;
                        clear_seen_ranges();
                        state_reg <= SGE_TRAV_STATE_ERROR;
                    end else if (next_total_len > DMA_TOTAL_LEN_W'(expected_total_reg)) begin
                        error_code_reg <= SGE_TRAV_ERR_LENGTH_OVERRUN;
                        traversal_error_valid <= 1'b1;
                        active_list_reg <= 1'b0;
                        clear_seen_ranges();
                        state_reg <= SGE_TRAV_STATE_ERROR;
                    end else begin
                        seen_valid[latched_index_reg] <= 1'b1;
                        seen_base[latched_index_reg] <= latched_addr_reg;
                        seen_end[latched_index_reg] <= latched_end_addr;
                        total_len_reg <= next_total_len;
                        expected_index_reg <= latched_index_reg + DMA_SGE_COUNT_W'(1);
                        active_list_reg <= !latched_last_reg;
                        if (latched_last_reg) begin
                            state_reg <= SGE_TRAV_STATE_CHECK_TOTAL;
                        end else begin
                            state_reg <= SGE_TRAV_STATE_IDLE;
                        end
                    end
                end

                SGE_TRAV_STATE_CHECK_TOTAL: begin
                    if (total_len_reg < DMA_TOTAL_LEN_W'(expected_total_reg)) begin
                        error_code_reg <= SGE_TRAV_ERR_LENGTH_UNDERRUN;
                        traversal_error_valid <= 1'b1;
                        clear_seen_ranges();
                        state_reg <= SGE_TRAV_STATE_ERROR;
                    end else begin
                        traversal_done_valid <= 1'b1;
                        clear_seen_ranges();
                        total_len_reg <= '0;
                        expected_index_reg <= '0;
                        timeout_counter_reg <= '0;
                        state_reg <= SGE_TRAV_STATE_DONE;
                    end
                end

                SGE_TRAV_STATE_DONE: begin
                    if (traversal_done_ready) begin
                        traversal_done_valid <= 1'b0;
                        state_reg <= SGE_TRAV_STATE_IDLE;
                    end
                end

                SGE_TRAV_STATE_ERROR: begin
                    if (traversal_error_ready) begin
                        traversal_error_valid <= 1'b0;
                        total_len_reg <= '0;
                        expected_index_reg <= '0;
                        timeout_counter_reg <= '0;
                        state_reg <= SGE_TRAV_STATE_IDLE;
                    end
                end

                default: begin
                    error_code_reg <= SGE_TRAV_ERR_NONE;
                    traversal_error_valid <= 1'b0;
                    traversal_done_valid <= 1'b0;
                    total_len_reg <= '0;
                    expected_index_reg <= '0;
                    timeout_counter_reg <= '0;
                    active_list_reg <= 1'b0;
                    clear_seen_ranges();
                    state_reg <= SGE_TRAV_STATE_IDLE;
                end
            endcase
        end
    end

endmodule
