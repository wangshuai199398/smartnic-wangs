`timescale 1ns/1ps

module ud_rx_engine
    import smartnic_pkg::*;
(
    input  logic                         clk,
    input  logic                         rst_n,

    // 来自 packet parser / payload extractor 的 UD packet metadata 和 payload。
    input  logic                         rx_meta_valid,
    output logic                         rx_meta_ready,
    input  packet_meta_t                 rx_meta,
    input  logic                         rx_payload_valid,
    output logic                         rx_payload_ready,
    input  packet_payload_stream_t       rx_payload,

    // 目标 QP lookup，用于校验 UD 类型、状态、owner/PD 和 Q_Key。
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

    // RQ stub。9.6 只消费一个已投递的 Recv WQE 描述，不实现完整 RQ engine。
    input  logic                         rq_wqe_available,
    input  logic [WR_ID_W-1:0]           rq_wqe_wr_id,
    input  logic [CQ_ID_W-1:0]           rq_wqe_cqn,
    input  logic [ADDR_W-1:0]            rq_wqe_buffer_addr,
    input  logic [KEY_W-1:0]             rq_wqe_lkey,
    input  logic [DMA_LEN_W-1:0]         rq_wqe_buffer_len,
    output logic                         rq_consume_valid,
    input  logic                         rq_consume_ready,
    output logic [QP_ID_W-1:0]           rq_consume_qpn,
    output logic [VF_ID_W-1:0]           rq_consume_owner_function,
    output logic [QP_ID_W-1:0]           rq_consume_source_qpn,

    // Receive buffer write stub。真实 MR/DMA path 由 7.x 和后续 top 集成连接。
    output logic                         dma_write_valid,
    input  logic                         dma_write_ready,
    output rq_dma_write_req_t            dma_write_req,
    output logic [511:0]                 dma_write_payload_data,
    output logic [15:0]                  dma_write_payload_len,
    input  logic                         dma_write_done_valid,
    output logic                         dma_write_done_ready,
    input  logic                         dma_write_error,

    // 带 source QPN 的 receive completion seed。
    output logic                         completion_valid,
    input  logic                         completion_ready,
    output ud_rx_completion_t            completion,

    // Drop/error 可观测路径和 failure counters。
    output logic                         drop_valid,
    input  logic                         drop_ready,
    output ud_rx_status_e                drop_status,
    output logic [QP_ID_W-1:0]           drop_qpn,
    output logic [QP_ID_W-1:0]           drop_source_qpn,
    output logic [15:0]                  drop_error_code,
    output ud_rx_counters_t              counters,

    output ud_rx_status_e                debug_status
);

    typedef enum logic [3:0] {
        UD_RX_STATE_IDLE        = 4'd0,
        UD_RX_STATE_PRECHECK    = 4'd1,
        UD_RX_STATE_LOOKUP_QP   = 4'd2,
        UD_RX_STATE_CHECK_QP    = 4'd3,
        UD_RX_STATE_CHECK_RQ    = 4'd4,
        UD_RX_STATE_DMA_WRITE   = 4'd5,
        UD_RX_STATE_WAIT_DMA    = 4'd6,
        UD_RX_STATE_CONSUME_RQ  = 4'd7,
        UD_RX_STATE_COMPLETION  = 4'd8,
        UD_RX_STATE_DROP        = 4'd9
    } ud_rx_state_e;

    ud_rx_state_e state_q;
    packet_meta_t meta_q;
    packet_payload_stream_t payload_q;
    qp_context_t qp_ctx_q;
    ud_rx_status_e status_q;
    logic [15:0] error_code_q;
    ud_rx_counters_t counters_q;
    ud_rx_completion_t completion_q;
    rq_dma_write_req_t dma_req_q;

    logic rx_fire;
    logic qp_read_fire;
    logic qp_rsp_fire;
    logic dma_write_fire;
    logic dma_done_fire;
    logic rq_consume_fire;
    logic completion_fire;
    logic drop_fire;
    logic state_allows_receive;
    logic precheck_ok;

    assign counters = counters_q;
    assign debug_status = status_q;

    assign rx_meta_ready = (state_q == UD_RX_STATE_IDLE) && rx_payload_valid;
    assign rx_payload_ready = (state_q == UD_RX_STATE_IDLE) && rx_meta_valid;
    assign rx_fire = rx_meta_valid && rx_meta_ready && rx_payload_valid && rx_payload_ready;

    assign qp_read_valid = (state_q == UD_RX_STATE_LOOKUP_QP);
    assign qp_read_qpn = meta_q.dest_qpn;
    assign qp_read_function_id = meta_q.owner_function;
    assign qp_read_pf_bypass = 1'b0;
    assign qp_read_fire = qp_read_valid && qp_read_ready;
    assign qp_read_rsp_ready = (state_q == UD_RX_STATE_LOOKUP_QP);
    assign qp_rsp_fire = qp_read_rsp_valid && qp_read_rsp_ready;

    assign state_allows_receive = (qp_ctx_q.state == QP_STATE_RTR) ||
                                  (qp_ctx_q.state == QP_STATE_RTS) ||
                                  (qp_ctx_q.state == QP_STATE_SQD);

    assign dma_write_valid = (state_q == UD_RX_STATE_DMA_WRITE);
    assign dma_write_req = dma_req_q;
    assign dma_write_payload_data = payload_q.data;
    assign dma_write_payload_len = payload_q.valid_bytes;
    assign dma_write_fire = dma_write_valid && dma_write_ready;
    assign dma_write_done_ready = (state_q == UD_RX_STATE_WAIT_DMA);
    assign dma_done_fire = dma_write_done_valid && dma_write_done_ready;

    assign rq_consume_valid = (state_q == UD_RX_STATE_CONSUME_RQ);
    assign rq_consume_qpn = meta_q.dest_qpn;
    assign rq_consume_owner_function = meta_q.owner_function;
    assign rq_consume_source_qpn = meta_q.src_qpn;
    assign rq_consume_fire = rq_consume_valid && rq_consume_ready;

    assign completion_valid = (state_q == UD_RX_STATE_COMPLETION);
    assign completion = completion_q;
    assign completion_fire = completion_valid && completion_ready;

    assign drop_valid = (state_q == UD_RX_STATE_DROP);
    assign drop_status = status_q;
    assign drop_qpn = meta_q.dest_qpn;
    assign drop_source_qpn = meta_q.src_qpn;
    assign drop_error_code = error_code_q;
    assign drop_fire = drop_valid && drop_ready;

    always_comb begin
        precheck_ok = 1'b1;
        if ((meta_q.status != PKT_PARSE_STATUS_OK) ||
            (payload_q.status != PKT_PAYLOAD_OK) ||
            (meta_q.opcode != ROCE_OPCODE_UD_SEND_ONLY)) begin
            precheck_ok = 1'b0;
        end
    end

    function automatic ud_rx_completion_t make_completion(
        input packet_meta_t meta,
        input packet_payload_stream_t payload
    );
        ud_rx_completion_t c;
        c = '0;
        c.event.event_type = CMPL_EVENT_RQ;
        c.event.qpn = meta.dest_qpn;
        c.event.cqn = rq_wqe_cqn;
        c.event.owner_function = meta.owner_function;
        c.event.wr_id = rq_wqe_wr_id;
        c.event.opcode = RDMA_OP_SEND;
        c.event.status = CMPL_SUCCESS;
        c.event.byte_len = payload.valid_bytes;
        c.event.imm_data = meta.imm_data;
        c.event.has_imm = meta.has_imm;
        c.event.solicited = 1'b0;
        c.event.vendor_error = {8'd0, meta.src_qpn};
        c.event.source_engine = CMPL_SRC_TRANSPORT;
        c.source_qpn = meta.src_qpn;
        return c;
    endfunction

    function automatic rq_dma_write_req_t make_dma_req(input packet_meta_t meta);
        rq_dma_write_req_t req;
        req = '0;
        req.owner_func = meta.owner_function;
        req.qpn = meta.dest_qpn;
        req.pd_id = qp_ctx_q.pd_id;
        req.wr_id = rq_wqe_wr_id;
        req.dst_addr = rq_wqe_buffer_addr;
        req.lkey = rq_wqe_lkey;
        req.length = meta.payload_len;
        req.flags = 8'd0;
        return req;
    endfunction

    task automatic set_drop(input ud_rx_status_e status, input logic [15:0] code);
        begin
            status_q <= status;
            error_code_q <= code;
            state_q <= UD_RX_STATE_DROP;
            unique case (status)
                UD_RX_STATUS_INVALID_DETH:   counters_q.invalid_deth <= counters_q.invalid_deth + 32'd1;
                UD_RX_STATUS_QKEY_MISMATCH:  counters_q.qkey_mismatch <= counters_q.qkey_mismatch + 32'd1;
                UD_RX_STATUS_MISSING_RQ_WQE: counters_q.missing_rq_wqe <= counters_q.missing_rq_wqe + 32'd1;
                UD_RX_STATUS_MALFORMED:      counters_q.malformed <= counters_q.malformed + 32'd1;
                default: begin
                    counters_q.malformed <= counters_q.malformed + 32'd1;
                end
            endcase
        end
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= UD_RX_STATE_IDLE;
            meta_q <= '0;
            payload_q <= '0;
            qp_ctx_q <= '0;
            status_q <= UD_RX_STATUS_OK;
            error_code_q <= 16'd0;
            counters_q <= '0;
            completion_q <= '0;
            dma_req_q <= '0;
        end else begin
            unique case (state_q)
                UD_RX_STATE_IDLE: begin
                    status_q <= UD_RX_STATUS_OK;
                    error_code_q <= 16'd0;
                    if (rx_fire) begin
                        meta_q <= rx_meta;
                        payload_q <= rx_payload;
                        state_q <= UD_RX_STATE_PRECHECK;
                    end
                end

                UD_RX_STATE_PRECHECK: begin
                    if (!precheck_ok) begin
                        set_drop(UD_RX_STATUS_MALFORMED, {11'd0, UD_RX_STATUS_MALFORMED});
                    end else if (!meta_q.has_deth || (meta_q.qkey == '0) || (meta_q.src_qpn == '0)) begin
                        set_drop(UD_RX_STATUS_INVALID_DETH, {11'd0, UD_RX_STATUS_INVALID_DETH});
                    end else begin
                        state_q <= UD_RX_STATE_LOOKUP_QP;
                    end
                end

                UD_RX_STATE_LOOKUP_QP: begin
                    if (qp_rsp_fire) begin
                        if (!qp_read_hit || (qp_read_status != QP_TABLE_STATUS_OK)) begin
                            set_drop(UD_RX_STATUS_QP_ERROR, {11'd0, UD_RX_STATUS_QP_ERROR});
                        end else begin
                            qp_ctx_q <= qp_read_data;
                            state_q <= UD_RX_STATE_CHECK_QP;
                        end
                    end else if (qp_read_fire) begin
                        // 等待 QP table 返回目标 UD QP context。
                    end
                end

                UD_RX_STATE_CHECK_QP: begin
                    if ((qp_ctx_q.qp_type != QP_TYPE_UD) ||
                        !state_allows_receive ||
                        (qp_ctx_q.owner_func != meta_q.owner_function)) begin
                        set_drop(UD_RX_STATUS_QP_ERROR, {11'd0, UD_RX_STATUS_QP_ERROR});
                    end else if (qp_ctx_q.qkey != meta_q.qkey) begin
                        set_drop(UD_RX_STATUS_QKEY_MISMATCH, {11'd0, UD_RX_STATUS_QKEY_MISMATCH});
                    end else begin
                        state_q <= UD_RX_STATE_CHECK_RQ;
                    end
                end

                UD_RX_STATE_CHECK_RQ: begin
                    if (!rq_wqe_available) begin
                        set_drop(UD_RX_STATUS_MISSING_RQ_WQE, {11'd0, UD_RX_STATUS_MISSING_RQ_WQE});
                    end else if (payload_q.valid_bytes > rq_wqe_buffer_len) begin
                        set_drop(UD_RX_STATUS_MALFORMED, 16'h0007);
                    end else begin
                        dma_req_q <= make_dma_req(meta_q);
                        state_q <= UD_RX_STATE_DMA_WRITE;
                    end
                end

                UD_RX_STATE_DMA_WRITE: begin
                    if (dma_write_fire) begin
                        state_q <= UD_RX_STATE_WAIT_DMA;
                    end
                end

                UD_RX_STATE_WAIT_DMA: begin
                    if (dma_done_fire) begin
                        if (dma_write_error) begin
                            set_drop(UD_RX_STATUS_DMA_ERROR, {11'd0, UD_RX_STATUS_DMA_ERROR});
                        end else begin
                            completion_q <= make_completion(meta_q, payload_q);
                            state_q <= UD_RX_STATE_CONSUME_RQ;
                        end
                    end
                end

                UD_RX_STATE_CONSUME_RQ: begin
                    if (rq_consume_fire) begin
                        state_q <= UD_RX_STATE_COMPLETION;
                    end
                end

                UD_RX_STATE_COMPLETION: begin
                    if (completion_fire) begin
                        state_q <= UD_RX_STATE_IDLE;
                    end
                end

                UD_RX_STATE_DROP: begin
                    if (drop_fire) begin
                        state_q <= UD_RX_STATE_IDLE;
                    end
                end

                default: begin
                    set_drop(UD_RX_STATUS_MALFORMED, 16'hffff);
                end
            endcase
        end
    end

endmodule
