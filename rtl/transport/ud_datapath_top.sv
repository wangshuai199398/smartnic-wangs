// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// 11.6 UD transmit/receive top-level integration.
//
// 该模块把已有 AH table、UD TX engine 和 UD RX engine 组合成一条最小
// UD 数据通路。真实 SQ WQE fetch、SGE/MR pipeline、PCIe DMA 和 CQ notify
// 仍由后续 top-level 闭环替换当前 hook/stub。

`timescale 1ns/1ps

module ud_datapath_top
    import smartnic_pkg::*;
(
    input  logic                         clk,
    input  logic                         rst_n,

    // AH table create hook。CSR/driver 路径后续可替换该测试入口。
    input  logic                         ah_create_valid,
    output logic                         ah_create_ready,
    input  ah_entry_t                    ah_create_entry,
    output logic                         ah_create_rsp_valid,
    input  logic                         ah_create_rsp_ready,
    output ah_table_status_e             ah_create_status,

    // UD Send WR hook，代表 QP SQ 解码后的最小 UD SEND。
    input  logic                         tx_req_valid,
    output logic                         tx_req_ready,
    input  logic [15:0]                  tx_desc_id,
    input  logic [QP_ID_W-1:0]           tx_qpn,
    input  logic [CQ_ID_W-1:0]           tx_cqn,
    input  logic [VF_ID_W-1:0]           tx_owner_function,
    input  logic [PD_ID_W-1:0]           tx_pd_id,
    input  logic [WR_ID_W-1:0]           tx_wr_id,
    input  logic [AH_ID_W-1:0]           tx_ah_id,
    input  logic [QP_ID_W-1:0]           tx_dest_qpn,
    input  logic [QKEY_W-1:0]            tx_qkey,
    input  logic [PSN_W-1:0]             tx_psn,
    input  logic [ADDR_W-1:0]            tx_local_va,
    input  logic [KEY_W-1:0]             tx_lkey,
    input  logic [511:0]                 tx_payload_data,
    input  logic [15:0]                  tx_payload_len,
    input  logic                         tx_solicited,
    input  logic                         tx_completion_required,

    // UD RX path from packet parser/payload extractor.
    input  logic                         rx_meta_valid,
    output logic                         rx_meta_ready,
    input  packet_meta_t                 rx_meta,
    input  logic                         rx_payload_valid,
    output logic                         rx_payload_ready,
    input  packet_payload_stream_t       rx_payload,

    // QP manager read interface used by UD receive target-QP lookup.
    output logic                         qp_read_valid,
    input  logic                         qp_read_ready,
    output logic [QP_ID_W-1:0]           qp_read_qpn,
    output logic [VF_ID_W-1:0]           qp_read_function_id,
    output logic                         qp_read_pf_bypass,
    input  logic                         qp_read_rsp_valid,
    output logic                         qp_read_rsp_ready,
    input  logic                         qp_read_hit,
    input  qp_table_status_e             qp_read_status,
    input  qp_context_t                  qp_read_data,

    // Minimal RQ WQE hook for UD receive.
    input  logic                         rx_rq_wqe_available,
    input  logic [WR_ID_W-1:0]           rx_rq_wqe_wr_id,
    input  logic [CQ_ID_W-1:0]           rx_rq_wqe_cqn,
    input  logic [ADDR_W-1:0]            rx_rq_wqe_buffer_addr,
    input  logic [KEY_W-1:0]             rx_rq_wqe_lkey,
    input  logic [DMA_LEN_W-1:0]         rx_rq_wqe_buffer_len,
    output logic                         rx_rq_consume_valid,
    input  logic                         rx_rq_consume_ready,
    output logic [QP_ID_W-1:0]           rx_rq_consume_qpn,
    output logic [VF_ID_W-1:0]           rx_rq_consume_owner_function,
    output logic [QP_ID_W-1:0]           rx_rq_consume_source_qpn,

    // TX DMA read hook and RX DMA write hook.
    output logic                         tx_dma_read_valid,
    input  logic                         tx_dma_read_ready,
    output logic [QP_ID_W-1:0]           tx_dma_read_qpn,
    output logic [ADDR_W-1:0]            tx_dma_read_local_va,
    output logic [KEY_W-1:0]             tx_dma_read_lkey,
    output logic [15:0]                  tx_dma_read_len,
    output logic                         rx_dma_write_valid,
    input  logic                         rx_dma_write_ready,
    output rq_dma_write_req_t            rx_dma_write_req,
    output logic [511:0]                 rx_dma_write_payload_data,
    output logic [15:0]                  rx_dma_write_payload_len,
    input  logic                         rx_dma_write_done_valid,
    output logic                         rx_dma_write_done_ready,
    input  logic                         rx_dma_write_error,

    // Packet builder and completion engine.
    output logic                         packet_valid,
    input  logic                         packet_ready,
    output packet_build_req_t            packet_req,
    output logic                         completion_valid,
    input  logic                         completion_ready,
    output completion_event_t            completion_event,

    // Error/drop observability.
    output logic                         drop_valid,
    input  logic                         drop_ready,
    output ud_rx_status_e                drop_status,
    output logic [QP_ID_W-1:0]           drop_qpn,
    output logic [QP_ID_W-1:0]           drop_source_qpn,
    output logic [15:0]                  drop_error_code,
    output ud_rx_counters_t              rx_counters,
    output logic [31:0]                  ah_lookup_fail_count,
    output ud_tx_status_e                debug_tx_status,
    output ud_rx_status_e                debug_rx_status,
    output logic [2:0]                   debug_tx_state
);

    typedef enum logic [2:0] {
        UD_TOP_TX_IDLE     = 3'd0,
        UD_TOP_TX_DMA_READ = 3'd1,
        UD_TOP_TX_SEND     = 3'd2
    } ud_top_tx_state_e;

    ud_top_tx_state_e tx_state_q;
    ud_tx_req_t tx_req_q;
    logic [ADDR_W-1:0] tx_local_va_q;
    logic [KEY_W-1:0] tx_lkey_q;
    logic tx_req_fire;
    logic tx_dma_fire;
    logic tx_engine_valid;
    logic tx_engine_ready;
    completion_event_t tx_completion_event;
    logic tx_completion_valid;
    logic tx_completion_ready;
    completion_event_t rx_completion_event;
    ud_rx_completion_t rx_completion;
    logic rx_completion_valid;
    logic rx_completion_ready;
    logic tx_wqe_error_valid;
    ud_tx_status_e tx_wqe_error_status;
    logic [15:0] tx_wqe_error_code;

    logic ah_lookup_valid;
    logic ah_lookup_ready;
    logic [AH_ID_W-1:0] ah_lookup_id;
    logic [VF_ID_W-1:0] ah_lookup_owner_function;
    logic [PD_ID_W-1:0] ah_lookup_pd_id;
    logic ah_lookup_rsp_valid;
    logic ah_lookup_rsp_ready;
    logic ah_lookup_hit;
    ah_entry_t ah_lookup_entry;
    ah_table_status_e ah_lookup_status;
    logic [15:0] ah_lookup_error_code;

    assign debug_tx_state = tx_state_q;
    assign tx_req_ready = (tx_state_q == UD_TOP_TX_IDLE);
    assign tx_req_fire = tx_req_valid && tx_req_ready;
    assign tx_dma_read_valid = (tx_state_q == UD_TOP_TX_DMA_READ);
    assign tx_dma_read_qpn = tx_req_q.qpn;
    assign tx_dma_read_local_va = tx_local_va_q;
    assign tx_dma_read_lkey = tx_lkey_q;
    assign tx_dma_read_len = tx_req_q.payload_len;
    assign tx_dma_fire = tx_dma_read_valid && tx_dma_read_ready;
    assign tx_engine_valid = (tx_state_q == UD_TOP_TX_SEND);

    assign rx_completion_event = rx_completion.event;
    assign completion_valid = tx_completion_valid || rx_completion_valid;
    assign completion_event = tx_completion_valid ? tx_completion_event : rx_completion_event;
    assign tx_completion_ready = completion_ready;
    assign rx_completion_ready = !tx_completion_valid && completion_ready;

    ah_table u_ah_table (
        .clk(clk),
        .rst_n(rst_n),
        .create_valid(ah_create_valid),
        .create_ready(ah_create_ready),
        .create_entry(ah_create_entry),
        .create_rsp_valid(ah_create_rsp_valid),
        .create_rsp_ready(ah_create_rsp_ready),
        .create_status(ah_create_status),
        .update_valid(1'b0),
        .update_entry('0),
        .update_ah_id('0),
        .update_owner_function('0),
        .update_pd_id('0),
        .update_rsp_ready(1'b1),
        .lookup_valid(ah_lookup_valid),
        .lookup_ready(ah_lookup_ready),
        .lookup_ah_id(ah_lookup_id),
        .lookup_owner_function(ah_lookup_owner_function),
        .lookup_pd_id(ah_lookup_pd_id),
        .lookup_rsp_valid(ah_lookup_rsp_valid),
        .lookup_rsp_ready(ah_lookup_rsp_ready),
        .lookup_hit(ah_lookup_hit),
        .lookup_entry(ah_lookup_entry),
        .lookup_status(ah_lookup_status),
        .lookup_error_code(ah_lookup_error_code),
        .delete_valid(1'b0),
        .delete_ah_id('0),
        .delete_owner_function('0),
        .delete_pd_id('0),
        .delete_rsp_ready(1'b1)
    );

    ud_tx_engine u_ud_tx_engine (
        .clk(clk),
        .rst_n(rst_n),
        .ud_req_valid(tx_engine_valid),
        .ud_req_ready(tx_engine_ready),
        .ud_req(tx_req_q),
        .ah_lookup_valid(ah_lookup_valid),
        .ah_lookup_ready(ah_lookup_ready),
        .ah_lookup_id(ah_lookup_id),
        .ah_lookup_owner_function(ah_lookup_owner_function),
        .ah_lookup_pd_id(ah_lookup_pd_id),
        .ah_lookup_resp_valid(ah_lookup_rsp_valid),
        .ah_lookup_resp_ready(ah_lookup_rsp_ready),
        .ah_lookup_hit(ah_lookup_hit),
        .ah_lookup_entry(ah_lookup_entry),
        .ah_lookup_error_code(ah_lookup_error_code),
        .packet_valid(packet_valid),
        .packet_ready(packet_ready),
        .packet_req(packet_req),
        .completion_valid(tx_completion_valid),
        .completion_ready(tx_completion_ready),
        .completion_event(tx_completion_event),
        .wqe_error_valid(tx_wqe_error_valid),
        .wqe_error_ready(1'b1),
        .wqe_error_qpn(),
        .wqe_error_cqn(),
        .wqe_error_owner_function(),
        .wqe_error_wr_id(),
        .wqe_error_opcode(),
        .wqe_error_completion_status(),
        .wqe_error_status(tx_wqe_error_status),
        .wqe_error_code(tx_wqe_error_code),
        .debug_status(debug_tx_status)
    );

    ud_rx_engine u_ud_rx_engine (
        .clk(clk),
        .rst_n(rst_n),
        .rx_meta_valid(rx_meta_valid),
        .rx_meta_ready(rx_meta_ready),
        .rx_meta(rx_meta),
        .rx_payload_valid(rx_payload_valid),
        .rx_payload_ready(rx_payload_ready),
        .rx_payload(rx_payload),
        .qp_read_valid(qp_read_valid),
        .qp_read_ready(qp_read_ready),
        .qp_read_qpn(qp_read_qpn),
        .qp_read_function_id(qp_read_function_id),
        .qp_read_pf_bypass(qp_read_pf_bypass),
        .qp_read_rsp_valid(qp_read_rsp_valid),
        .qp_read_rsp_ready(qp_read_rsp_ready),
        .qp_read_hit(qp_read_hit),
        .qp_read_status(qp_read_status),
        .qp_read_data(qp_read_data),
        .rq_wqe_available(rx_rq_wqe_available),
        .rq_wqe_wr_id(rx_rq_wqe_wr_id),
        .rq_wqe_cqn(rx_rq_wqe_cqn),
        .rq_wqe_buffer_addr(rx_rq_wqe_buffer_addr),
        .rq_wqe_lkey(rx_rq_wqe_lkey),
        .rq_wqe_buffer_len(rx_rq_wqe_buffer_len),
        .rq_consume_valid(rx_rq_consume_valid),
        .rq_consume_ready(rx_rq_consume_ready),
        .rq_consume_qpn(rx_rq_consume_qpn),
        .rq_consume_owner_function(rx_rq_consume_owner_function),
        .rq_consume_source_qpn(rx_rq_consume_source_qpn),
        .dma_write_valid(rx_dma_write_valid),
        .dma_write_ready(rx_dma_write_ready),
        .dma_write_req(rx_dma_write_req),
        .dma_write_payload_data(rx_dma_write_payload_data),
        .dma_write_payload_len(rx_dma_write_payload_len),
        .dma_write_done_valid(rx_dma_write_done_valid),
        .dma_write_done_ready(rx_dma_write_done_ready),
        .dma_write_error(rx_dma_write_error),
        .completion_valid(rx_completion_valid),
        .completion_ready(rx_completion_ready),
        .completion(rx_completion),
        .drop_valid(drop_valid),
        .drop_ready(drop_ready),
        .drop_status(drop_status),
        .drop_qpn(drop_qpn),
        .drop_source_qpn(drop_source_qpn),
        .drop_error_code(drop_error_code),
        .counters(rx_counters),
        .debug_status(debug_rx_status)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state_q <= UD_TOP_TX_IDLE;
            tx_req_q <= '0;
            tx_local_va_q <= '0;
            tx_lkey_q <= '0;
            ah_lookup_fail_count <= 32'd0;
        end else begin
            if (tx_wqe_error_valid &&
                ((tx_wqe_error_status == UD_TX_STATUS_AH_MISS) ||
                 (tx_wqe_error_status == UD_TX_STATUS_AH_PERMISSION) ||
                 (tx_wqe_error_status == UD_TX_STATUS_MISSING_QKEY))) begin
                ah_lookup_fail_count <= ah_lookup_fail_count + 32'd1;
            end

            unique case (tx_state_q)
                UD_TOP_TX_IDLE: begin
                    if (tx_req_fire) begin
                        tx_req_q.desc_id <= tx_desc_id;
                        tx_req_q.qpn <= tx_qpn;
                        tx_req_q.cqn <= tx_cqn;
                        tx_req_q.owner_function <= tx_owner_function;
                        tx_req_q.pd_id <= tx_pd_id;
                        tx_req_q.wr_id <= tx_wr_id;
                        tx_req_q.qp_type <= QP_TYPE_UD;
                        tx_req_q.opcode <= RDMA_OP_SEND;
                        tx_req_q.ah_id <= tx_ah_id;
                        tx_req_q.dest_qpn <= tx_dest_qpn;
                        tx_req_q.qkey <= tx_qkey;
                        tx_req_q.psn <= tx_psn;
                        tx_req_q.payload_data <= tx_payload_data;
                        tx_req_q.payload_len <= tx_payload_len;
                        tx_req_q.solicited <= tx_solicited;
                        tx_req_q.completion_required <= tx_completion_required;
                        tx_local_va_q <= tx_local_va;
                        tx_lkey_q <= tx_lkey;
                        tx_state_q <= UD_TOP_TX_DMA_READ;
                    end
                end

                UD_TOP_TX_DMA_READ: begin
                    if (tx_dma_fire) begin
                        // TODO: 接入 7.x MR/DMA pipeline 后，用 DMA read response 填充 payload_data。
                        tx_state_q <= UD_TOP_TX_SEND;
                    end
                end

                UD_TOP_TX_SEND: begin
                    if (tx_engine_valid && tx_engine_ready) begin
                        tx_state_q <= UD_TOP_TX_IDLE;
                    end
                end

                default: begin
                    tx_state_q <= UD_TOP_TX_IDLE;
                end
            endcase
        end
    end

endmodule : ud_datapath_top
