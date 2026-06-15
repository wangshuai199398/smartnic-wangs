// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// DMA WQE/SGE fetcher 最小实现。
//
// 本模块把 SQ/RQ engine 给出的 queue base/index/stride 转成 WQE host read，
// 并提供 extended SGE list 的逐项 fetch 框架。当前阶段不做 MR 权限检查、
// SGE 总长度统计、zero-overlap 校验、PMTU/4KB 分段或真实 PCIe read。

`timescale 1ns/1ps

import smartnic_pkg::*;

module dma_wqe_sge_fetcher (
    input  logic                         clk,                         // fetcher 时钟。
    input  logic                         rst_n,                       // 低有效复位。

    // ------------------------------------------------------------------
    // WQE fetch request
    // ------------------------------------------------------------------
    input  logic                         wqe_fetch_req_valid,         // WQE fetch 请求有效。
    output logic                         wqe_fetch_req_ready,         // fetcher 可接收 WQE fetch 请求。
    input  logic [QP_ID_W-1:0]           wqe_fetch_qpn,               // 目标 QPN。
    input  logic [VF_ID_W-1:0]           wqe_fetch_owner_function,    // WQE 所属 function。
    input  queue_type_e                  wqe_fetch_queue_type,        // SQ 或 RQ。
    input  logic [ADDR_W-1:0]            wqe_fetch_base_addr,         // SQ/RQ WQE ring base 地址。
    input  logic [QUEUE_IDX_W-1:0]       wqe_fetch_index,             // 要读取的 WQE index。
    input  logic [15:0]                  wqe_fetch_stride,            // WQE stride，通常为 64 bytes。
    input  logic [15:0]                  wqe_fetch_desc_id,           // 关联 descriptor ID。
    input  logic [PD_ID_W-1:0]           wqe_fetch_pd_id,             // QP 的 PD。

    // ------------------------------------------------------------------
    // WQE fetch response
    // ------------------------------------------------------------------
    output logic                         wqe_fetch_resp_valid,        // WQE fetch 响应有效。
    input  logic                         wqe_fetch_resp_ready,        // 下游可接收 WQE 响应。
    output wqe_fetch_status_e            wqe_fetch_status,            // WQE fetch 状态。
    output wqe_fetch_error_e             wqe_fetch_error_code,        // WQE fetch 错误码。
    output logic [15:0]                  wqe_fetch_resp_desc_id,      // 回传 descriptor ID。
    output logic [QP_ID_W-1:0]           wqe_fetch_resp_qpn,          // 回传 QPN。
    output logic [VF_ID_W-1:0]           wqe_fetch_resp_owner_function,// 回传 function。
    output wqe_opcode_e                  wqe_opcode,                  // 解码出的 WQE opcode。
    output logic [WR_ID_W-1:0]           wqe_wr_id,                   // 解码出的 WR ID。
    output logic                         wqe_inline_present,          // WQE 是否携带 inline payload。
    output logic [15:0]                  wqe_inline_len,              // inline payload 长度。
    output inline_data_t                 wqe_inline_data,             // inline payload 数据窗口。
    output logic [DMA_SGE_COUNT_W-1:0]   wqe_sge_count,               // WQE SGE 总数。
    output logic [WQE_INLINE_SGE_COUNT*SGE_W-1:0] wqe_inline_sge_entries, // WQE 内 inline SGE。
    output logic [ADDR_W-1:0]            wqe_extended_sge_list_addr,  // extended SGE list 地址。

    // ------------------------------------------------------------------
    // SGE fetch request
    // ------------------------------------------------------------------
    input  logic                         sge_fetch_req_valid,         // SGE fetch 请求有效。
    output logic                         sge_fetch_req_ready,         // fetcher 可接收 SGE fetch 请求。
    input  logic [15:0]                  sge_fetch_desc_id,           // 关联 descriptor ID。
    input  logic [QP_ID_W-1:0]           sge_fetch_qpn,               // 目标 QPN。
    input  logic [VF_ID_W-1:0]           sge_fetch_owner_function,    // 所属 function。
    input  logic [PD_ID_W-1:0]           sge_fetch_pd_id,             // QP 的 PD。
    input  logic [ADDR_W-1:0]            sge_fetch_list_base_addr,    // extended SGE list base 地址。
    input  logic [DMA_SGE_COUNT_W-1:0]   sge_fetch_count,             // 要 fetch 的 SGE 数量，1..256。
    input  logic [DMA_SGE_COUNT_W-1:0]   sge_fetch_start_index,       // 起始 SGE index。

    // ------------------------------------------------------------------
    // SGE fetch response
    // ------------------------------------------------------------------
    output logic                         sge_fetch_resp_valid,        // 当前 SGE 响应/完成响应有效。
    input  logic                         sge_fetch_resp_ready,        // 下游可接收 SGE 响应。
    output sge_fetch_status_e            sge_fetch_status,            // SGE fetch 状态。
    output sge_fetch_error_e             sge_fetch_error_code,        // SGE fetch 错误码。
    output logic [15:0]                  sge_fetch_resp_desc_id,      // 回传 descriptor ID。
    output logic [QP_ID_W-1:0]           sge_fetch_resp_qpn,          // 回传 QPN。
    output logic [VF_ID_W-1:0]           sge_fetch_resp_owner_function,// 回传 function。
    output logic                         sge_entry_valid,             // 当前响应携带一个 SGE entry。
    output logic [DMA_SGE_COUNT_W-1:0]   sge_entry_index,             // 当前 SGE index。
    output logic [ADDR_W-1:0]            sge_entry_addr,              // SGE 地址。
    output logic [DMA_LEN_W-1:0]         sge_entry_length,            // SGE 长度。
    output logic [KEY_W-1:0]             sge_entry_lkey,              // SGE lkey。
    output logic [15:0]                  sge_entry_flags,             // SGE flags。
    output logic                         sge_list_done,               // SGE list 已全部输出。

    // ------------------------------------------------------------------
    // Shared host read request/response
    // ------------------------------------------------------------------
    output logic                         host_read_req_valid,         // host read 请求有效。
    input  logic                         host_read_req_ready,         // host read 下游 ready。
    output logic [ADDR_W-1:0]            host_read_req_addr,          // host read 地址。
    output logic [15:0]                  host_read_req_len,           // host read 长度。
    output logic [DMA_HOST_READ_TAG_W-1:0] host_read_req_tag,         // host read tag，bit15 区分 WQE/SGE。
    output logic [VF_ID_W-1:0]           host_read_req_owner_function,// host read 所属 function。
    input  logic                         host_read_resp_valid,        // host read 响应有效。
    input  logic [WQE_W-1:0]             host_read_resp_data,         // host read 返回数据，WQE/SGE 复用此宽度。
    input  logic [DMA_HOST_READ_TAG_W-1:0] host_read_resp_tag,        // host read 返回 tag。
    input  logic                         host_read_resp_error,        // host read 错误。

    output wqe_fetch_state_e             debug_wqe_state,            // WQE fetch FSM 状态。
    output sge_fetch_state_e             debug_sge_state             // SGE fetch FSM 状态。
);

    localparam logic [DMA_HOST_READ_TAG_W-1:0] WQE_TAG_PREFIX = 16'h8000;
    localparam logic [DMA_HOST_READ_TAG_W-1:0] SGE_TAG_PREFIX = 16'h0000;

    wqe_fetch_state_e wqe_state_reg;
    sge_fetch_state_e sge_state_reg;

    logic [QP_ID_W-1:0] wqe_qpn_reg;
    logic [VF_ID_W-1:0] wqe_owner_reg;
    queue_type_e wqe_queue_type_reg;
    logic [ADDR_W-1:0] wqe_base_reg;
    logic [QUEUE_IDX_W-1:0] wqe_index_reg;
    logic [15:0] wqe_stride_reg;
    logic [15:0] wqe_desc_id_reg;
    logic [PD_ID_W-1:0] wqe_pd_id_reg;
    logic [ADDR_W-1:0] wqe_addr_reg;
    send_wqe_t wqe_reg;
    wqe_fetch_error_e wqe_error_reg;

    logic [15:0] sge_desc_id_reg;
    logic [QP_ID_W-1:0] sge_qpn_reg;
    logic [VF_ID_W-1:0] sge_owner_reg;
    logic [PD_ID_W-1:0] sge_pd_id_reg;
    logic [ADDR_W-1:0] sge_base_reg;
    logic [DMA_SGE_COUNT_W-1:0] sge_count_reg;
    logic [DMA_SGE_COUNT_W-1:0] sge_start_index_reg;
    logic [DMA_SGE_COUNT_W-1:0] sge_current_index_reg;
    logic [DMA_SGE_COUNT_W-1:0] sge_emitted_count_reg;
    logic [ADDR_W-1:0] sge_addr_reg;
    sge_t sge_reg;
    sge_fetch_error_e sge_error_reg;

    logic [ADDR_W-1:0] wqe_offset;
    logic [ADDR_W-1:0] wqe_addr_calc;
    logic wqe_addr_overflow;
    logic wqe_resp_fire;
    logic wqe_host_req_fire;
    logic wqe_opcode_supported;
    logic wqe_malformed;

    logic [ADDR_W-1:0] sge_offset;
    logic [ADDR_W-1:0] sge_addr_calc;
    logic sge_addr_overflow;
    logic sge_host_resp_fire;
    logic sge_emit_fire;
    logic sge_host_req_fire;
    logic sge_done_fire;
    inline_data_t inline_data_reg;

    sge_t inline_sge0;
    sge_t inline_sge1;

    assign debug_wqe_state = wqe_state_reg;
    assign debug_sge_state = sge_state_reg;

    assign wqe_fetch_req_ready = (wqe_state_reg == WQE_FETCH_STATE_IDLE);
    assign sge_fetch_req_ready = (sge_state_reg == SGE_FETCH_STATE_IDLE);

    assign wqe_offset = ADDR_W'(wqe_index_reg) * ADDR_W'(wqe_stride_reg);
    assign wqe_addr_calc = wqe_base_reg + wqe_offset;
    assign wqe_addr_overflow = (wqe_addr_calc < wqe_base_reg);

    assign sge_offset = ADDR_W'(sge_current_index_reg) * ADDR_W'(SGE_BYTES);
    assign sge_addr_calc = sge_base_reg + sge_offset;
    assign sge_addr_overflow = (sge_addr_calc < sge_base_reg);

    assign host_read_req_valid = (wqe_state_reg == WQE_FETCH_STATE_ISSUE_READ) ||
                                 ((wqe_state_reg != WQE_FETCH_STATE_ISSUE_READ) &&
                                  (sge_state_reg == SGE_FETCH_STATE_ISSUE_READ));
    assign host_read_req_addr = (wqe_state_reg == WQE_FETCH_STATE_ISSUE_READ) ?
                                wqe_addr_reg : sge_addr_reg;
    assign host_read_req_len = (wqe_state_reg == WQE_FETCH_STATE_ISSUE_READ) ?
                               16'(WQE_BYTES) : 16'(SGE_BYTES);
    assign host_read_req_tag = (wqe_state_reg == WQE_FETCH_STATE_ISSUE_READ) ?
                               (WQE_TAG_PREFIX | {1'b0, wqe_desc_id_reg[14:0]}) :
                               (SGE_TAG_PREFIX | {1'b0, sge_desc_id_reg[14:0]});
    assign host_read_req_owner_function = (wqe_state_reg == WQE_FETCH_STATE_ISSUE_READ) ?
                                          wqe_owner_reg : sge_owner_reg;
    assign wqe_host_req_fire = (wqe_state_reg == WQE_FETCH_STATE_ISSUE_READ) &&
                               host_read_req_valid &&
                               host_read_req_ready;
    assign sge_host_req_fire = (wqe_state_reg != WQE_FETCH_STATE_ISSUE_READ) &&
                               (sge_state_reg == SGE_FETCH_STATE_ISSUE_READ) &&
                               host_read_req_valid &&
                               host_read_req_ready;

    assign wqe_resp_fire = host_read_resp_valid &&
                           (wqe_state_reg == WQE_FETCH_STATE_WAIT_RESP) &&
                           (host_read_resp_tag[15] == 1'b1);
    assign sge_host_resp_fire = host_read_resp_valid &&
                                (sge_state_reg == SGE_FETCH_STATE_WAIT_RESP) &&
                                (host_read_resp_tag[15] == 1'b0);

    assign wqe_fetch_resp_valid = (wqe_state_reg == WQE_FETCH_STATE_RESPOND) ||
                                  (wqe_state_reg == WQE_FETCH_STATE_ERROR);
    assign wqe_fetch_status = (wqe_state_reg == WQE_FETCH_STATE_RESPOND) ?
                              WQE_FETCH_STATUS_OK : WQE_FETCH_STATUS_ERROR;
    assign wqe_fetch_error_code = wqe_error_reg;
    assign wqe_fetch_resp_desc_id = wqe_desc_id_reg;
    assign wqe_fetch_resp_qpn = wqe_qpn_reg;
    assign wqe_fetch_resp_owner_function = wqe_owner_reg;
    assign wqe_opcode = wqe_reg.opcode;
    assign wqe_wr_id = wqe_reg.wr_id;
    assign wqe_inline_present = wqe_reg.inline_present;
    assign wqe_inline_len = wqe_reg.inline_len;
    assign wqe_inline_data = inline_data_reg;
    assign wqe_sge_count = wqe_reg.sge_count;
    assign wqe_extended_sge_list_addr = wqe_reg.extended_sge_list_addr;

    assign inline_sge0.addr = wqe_reg.local_va;
    assign inline_sge0.length = wqe_reg.length;
    assign inline_sge0.lkey = wqe_reg.lkey;
    assign inline_sge0.flags = 16'h0001;
    assign inline_sge0.reserved = '0;

    assign inline_sge1.addr = wqe_reg.local_va + ADDR_W'(wqe_reg.length);
    assign inline_sge1.length = '0;
    assign inline_sge1.lkey = wqe_reg.lkey;
    assign inline_sge1.flags = 16'h0000;
    assign inline_sge1.reserved = '0;

    assign wqe_inline_sge_entries = {inline_sge0, inline_sge1};

    always_comb begin
        unique case (wqe_reg.opcode)
            RDMA_OP_SEND,
            RDMA_OP_SEND_WITH_IMM,
            RDMA_OP_RDMA_WRITE,
            RDMA_OP_RDMA_WRITE_WITH_IMM,
            RDMA_OP_RDMA_READ,
            RDMA_OP_LOCAL_INV,
            RDMA_OP_NOP: wqe_opcode_supported = 1'b1;
            default:     wqe_opcode_supported = 1'b0;
        endcase
    end

    assign wqe_malformed = (wqe_reg.inline_sge_count > 2'(WQE_INLINE_SGE_COUNT)) ||
                           (wqe_reg.inline_present &&
                            (wqe_reg.inline_len > 16'(INLINE_DATA_BYTES))) ||
                           (wqe_reg.sge_count > DMA_SGE_COUNT_W'(MAX_SGE));

    assign sge_fetch_resp_valid = (sge_state_reg == SGE_FETCH_STATE_EMIT) ||
                                  (sge_state_reg == SGE_FETCH_STATE_DONE) ||
                                  (sge_state_reg == SGE_FETCH_STATE_ERROR);
    assign sge_fetch_status = (sge_state_reg == SGE_FETCH_STATE_ERROR) ?
                              SGE_FETCH_STATUS_ERROR : SGE_FETCH_STATUS_OK;
    assign sge_fetch_error_code = sge_error_reg;
    assign sge_fetch_resp_desc_id = sge_desc_id_reg;
    assign sge_fetch_resp_qpn = sge_qpn_reg;
    assign sge_fetch_resp_owner_function = sge_owner_reg;
    assign sge_entry_valid = (sge_state_reg == SGE_FETCH_STATE_EMIT);
    assign sge_entry_index = sge_current_index_reg;
    assign sge_entry_addr = sge_reg.addr;
    assign sge_entry_length = sge_reg.length;
    assign sge_entry_lkey = sge_reg.lkey;
    assign sge_entry_flags = sge_reg.flags;
    assign sge_list_done = (sge_state_reg == SGE_FETCH_STATE_DONE);
    assign sge_emit_fire = sge_fetch_resp_valid &&
                           sge_fetch_resp_ready &&
                           (sge_state_reg == SGE_FETCH_STATE_EMIT);
    assign sge_done_fire = sge_fetch_resp_valid &&
                           sge_fetch_resp_ready &&
                           ((sge_state_reg == SGE_FETCH_STATE_DONE) ||
                            (sge_state_reg == SGE_FETCH_STATE_ERROR));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wqe_state_reg <= WQE_FETCH_STATE_IDLE;
            wqe_qpn_reg <= '0;
            wqe_owner_reg <= '0;
            wqe_queue_type_reg <= QUEUE_TYPE_SQ;
            wqe_base_reg <= '0;
            wqe_index_reg <= '0;
            wqe_stride_reg <= '0;
            wqe_desc_id_reg <= '0;
            wqe_pd_id_reg <= '0;
            wqe_addr_reg <= '0;
            wqe_reg <= '0;
            inline_data_reg <= '0;
            wqe_error_reg <= WQE_FETCH_ERR_NONE;
        end else begin
            unique case (wqe_state_reg)
                WQE_FETCH_STATE_IDLE: begin
                    wqe_error_reg <= WQE_FETCH_ERR_NONE;
                    if (wqe_fetch_req_valid && wqe_fetch_req_ready) begin
                        wqe_qpn_reg <= wqe_fetch_qpn;
                        wqe_owner_reg <= wqe_fetch_owner_function;
                        wqe_queue_type_reg <= wqe_fetch_queue_type;
                        wqe_base_reg <= wqe_fetch_base_addr;
                        wqe_index_reg <= wqe_fetch_index;
                        wqe_stride_reg <= wqe_fetch_stride;
                        wqe_desc_id_reg <= wqe_fetch_desc_id;
                        wqe_pd_id_reg <= wqe_fetch_pd_id;
                        wqe_state_reg <= WQE_FETCH_STATE_CALC_ADDR;
                    end
                end

                WQE_FETCH_STATE_CALC_ADDR: begin
                    if (wqe_stride_reg == '0) begin
                        wqe_error_reg <= WQE_FETCH_ERR_STRIDE_ZERO;
                        wqe_state_reg <= WQE_FETCH_STATE_ERROR;
                    end else if (wqe_addr_overflow) begin
                        wqe_error_reg <= WQE_FETCH_ERR_ADDR_OVERFLOW;
                        wqe_state_reg <= WQE_FETCH_STATE_ERROR;
                    end else begin
                        wqe_addr_reg <= wqe_addr_calc;
                        wqe_state_reg <= WQE_FETCH_STATE_ISSUE_READ;
                    end
                end

                WQE_FETCH_STATE_ISSUE_READ: begin
                    if (wqe_host_req_fire) begin
                        wqe_state_reg <= WQE_FETCH_STATE_WAIT_RESP;
                    end
                end

                WQE_FETCH_STATE_WAIT_RESP: begin
                    if (wqe_resp_fire) begin
                        if (host_read_resp_error) begin
                            wqe_error_reg <= WQE_FETCH_ERR_HOST_READ;
                            wqe_state_reg <= WQE_FETCH_STATE_ERROR;
                        end else begin
                            wqe_reg <= send_wqe_t'(host_read_resp_data);
                            inline_data_reg.data <= host_read_resp_data[INLINE_DATA_W-1:0];
                            wqe_state_reg <= WQE_FETCH_STATE_DECODE;
                        end
                    end
                end

                WQE_FETCH_STATE_DECODE: begin
                    if (!wqe_opcode_supported) begin
                        wqe_error_reg <= WQE_FETCH_ERR_OPCODE;
                        wqe_state_reg <= WQE_FETCH_STATE_ERROR;
                    end else if (wqe_malformed) begin
                        wqe_error_reg <= WQE_FETCH_ERR_MALFORMED;
                        wqe_state_reg <= WQE_FETCH_STATE_ERROR;
                    end else begin
                        wqe_state_reg <= WQE_FETCH_STATE_RESPOND;
                    end
                end

                WQE_FETCH_STATE_RESPOND,
                WQE_FETCH_STATE_ERROR: begin
                    if (wqe_fetch_resp_ready) begin
                        wqe_state_reg <= WQE_FETCH_STATE_IDLE;
                    end
                end

                default: begin
                    wqe_state_reg <= WQE_FETCH_STATE_IDLE;
                end
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sge_state_reg <= SGE_FETCH_STATE_IDLE;
            sge_desc_id_reg <= '0;
            sge_qpn_reg <= '0;
            sge_owner_reg <= '0;
            sge_pd_id_reg <= '0;
            sge_base_reg <= '0;
            sge_count_reg <= '0;
            sge_start_index_reg <= '0;
            sge_current_index_reg <= '0;
            sge_emitted_count_reg <= '0;
            sge_addr_reg <= '0;
            sge_reg <= '0;
            sge_error_reg <= SGE_FETCH_ERR_NONE;
        end else begin
            unique case (sge_state_reg)
                SGE_FETCH_STATE_IDLE: begin
                    sge_error_reg <= SGE_FETCH_ERR_NONE;
                    if (sge_fetch_req_valid && sge_fetch_req_ready) begin
                        sge_desc_id_reg <= sge_fetch_desc_id;
                        sge_qpn_reg <= sge_fetch_qpn;
                        sge_owner_reg <= sge_fetch_owner_function;
                        sge_pd_id_reg <= sge_fetch_pd_id;
                        sge_base_reg <= sge_fetch_list_base_addr;
                        sge_count_reg <= sge_fetch_count;
                        sge_start_index_reg <= sge_fetch_start_index;
                        sge_current_index_reg <= sge_fetch_start_index;
                        sge_emitted_count_reg <= '0;
                        sge_state_reg <= SGE_FETCH_STATE_VALIDATE;
                    end
                end

                SGE_FETCH_STATE_VALIDATE: begin
                    if (sge_count_reg == '0) begin
                        sge_error_reg <= SGE_FETCH_ERR_COUNT_ZERO;
                        sge_state_reg <= SGE_FETCH_STATE_ERROR;
                    end else if (sge_count_reg > DMA_SGE_COUNT_W'(MAX_SGE)) begin
                        sge_error_reg <= SGE_FETCH_ERR_TOO_MANY;
                        sge_state_reg <= SGE_FETCH_STATE_ERROR;
                    end else begin
                        sge_state_reg <= SGE_FETCH_STATE_CALC_ADDR;
                    end
                end

                SGE_FETCH_STATE_CALC_ADDR: begin
                    if (sge_addr_overflow) begin
                        sge_error_reg <= SGE_FETCH_ERR_ADDR_OVERFLOW;
                        sge_state_reg <= SGE_FETCH_STATE_ERROR;
                    end else begin
                        sge_addr_reg <= sge_addr_calc;
                        sge_state_reg <= SGE_FETCH_STATE_ISSUE_READ;
                    end
                end

                SGE_FETCH_STATE_ISSUE_READ: begin
                    if (sge_host_req_fire) begin
                        sge_state_reg <= SGE_FETCH_STATE_WAIT_RESP;
                    end
                end

                SGE_FETCH_STATE_WAIT_RESP: begin
                    if (sge_host_resp_fire) begin
                        if (host_read_resp_error) begin
                            sge_error_reg <= SGE_FETCH_ERR_HOST_READ;
                            sge_state_reg <= SGE_FETCH_STATE_ERROR;
                        end else begin
                            sge_reg <= sge_t'(host_read_resp_data[SGE_W-1:0]);
                            sge_state_reg <= SGE_FETCH_STATE_DECODE;
                        end
                    end
                end

                SGE_FETCH_STATE_DECODE: begin
                    sge_state_reg <= SGE_FETCH_STATE_EMIT;
                end

                SGE_FETCH_STATE_EMIT: begin
                    if (sge_emit_fire) begin
                        sge_emitted_count_reg <= sge_emitted_count_reg + 1'b1;
                        if ((sge_emitted_count_reg + 1'b1) >= sge_count_reg) begin
                            sge_state_reg <= SGE_FETCH_STATE_DONE;
                        end else begin
                            sge_state_reg <= SGE_FETCH_STATE_NEXT;
                        end
                    end
                end

                SGE_FETCH_STATE_NEXT: begin
                    sge_current_index_reg <= sge_current_index_reg + 1'b1;
                    sge_state_reg <= SGE_FETCH_STATE_CALC_ADDR;
                end

                SGE_FETCH_STATE_DONE,
                SGE_FETCH_STATE_ERROR: begin
                    if (sge_done_fire) begin
                        sge_state_reg <= SGE_FETCH_STATE_IDLE;
                    end
                end

                default: begin
                    sge_state_reg <= SGE_FETCH_STATE_IDLE;
                end
            endcase
        end
    end

    logic unused_queue_type;
    logic unused_pd;
    assign unused_queue_type = ^wqe_queue_type_reg;
    assign unused_pd = ^wqe_pd_id_reg ^ ^sge_pd_id_reg ^ ^sge_start_index_reg;

endmodule : dma_wqe_sge_fetcher
