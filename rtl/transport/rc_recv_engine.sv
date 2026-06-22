`timescale 1ns/1ps

module rc_recv_engine
    import smartnic_pkg::*;
(
    input  logic                    clk,
    input  logic                    rst_n,

    // RC receive context 配置。后续会由 QP context table 提供 per-QP rq_psn/RQ state。
    input  logic                    cfg_valid,
    output logic                    cfg_ready,
    input  logic [QP_ID_W-1:0]      cfg_qpn,
    input  logic [VF_ID_W-1:0]      cfg_owner_function,
    input  logic [PD_ID_W-1:0]      cfg_pd_id,
    input  logic [PSN_W-1:0]        cfg_expected_psn,
    input  logic [RC_RECV_ACK_COALESCE_W-1:0] cfg_ack_coalesce_count,
    input  logic [RC_RECV_ACK_TIMER_W-1:0]    cfg_ack_timeout,

    // 来自 payload extractor / transport RX 的入站 metadata。
    input  logic                    rx_meta_valid,
    output logic                    rx_meta_ready,
    input  packet_meta_t            rx_meta,

    // 与 metadata 对应的 payload stream。当前最小版本只消费单 beat payload。
    input  logic                    rx_payload_valid,
    output logic                    rx_payload_ready,
    input  packet_payload_stream_t  rx_payload,

    // RQ 可用性由 RQ engine/QP context 后续提供。Send 系列没有 RQ buffer 时产生 RNR NAK。
    input  logic                    rq_buffer_available,

    // ACK 合并 timer tick。
    input  logic                    timer_tick,

    // 通过 PSN/RQ 检查后才放行给 RQ/DMA/remote op 处理。
    output logic                    accept_valid,
    input  logic                    accept_ready,
    output packet_meta_t            accept_meta,
    output packet_payload_stream_t  accept_payload,

    // ACK/NAK/RNR 事件，后续接 packet builder 或 ACK coalescer。
    output logic                    ack_event_valid,
    input  logic                    ack_event_ready,
    output transport_rx_ack_event_t ack_event,

    // drop/debug 事件，不应产生 DMA 副作用。
    output logic                    drop_valid,
    input  logic                    drop_ready,
    output logic [15:0]             drop_desc_id,
    output logic [QP_ID_W-1:0]      drop_qpn,
    output logic [CQ_ID_W-1:0]      drop_cqn,
    output logic [VF_ID_W-1:0]      drop_owner_function,
    output logic [PD_ID_W-1:0]      drop_pd_id,
    output roce_opcode_e            drop_opcode,
    output rc_recv_status_e         drop_status,
    output logic [15:0]             drop_error_code,

    output logic [PSN_W-1:0]        expected_psn,
    output rc_recv_status_e         debug_status
);

    typedef enum logic [3:0] {
        RC_RECV_STATE_IDLE        = 4'd0,
        RC_RECV_STATE_ACCEPT      = 4'd1,
        RC_RECV_STATE_EMIT_ACK    = 4'd2,
        RC_RECV_STATE_DROP        = 4'd3
    } rc_recv_state_e;

    rc_recv_state_e state_q;
    packet_meta_t meta_q;
    packet_payload_stream_t payload_q;
    transport_rx_ack_event_t ack_q;
    rc_recv_status_e drop_status_q;
    logic [15:0] drop_error_q;

    logic configured_q;
    logic [QP_ID_W-1:0] cfg_qpn_q;
    logic [VF_ID_W-1:0] cfg_owner_q;
    logic [PD_ID_W-1:0] cfg_pd_q;
    logic [PSN_W-1:0] expected_psn_q;
    logic [PSN_W-1:0] last_acked_psn_q;
    logic [RC_RECV_ACK_COALESCE_W-1:0] ack_coalesce_count_q;
    logic [RC_RECV_ACK_TIMER_W-1:0] ack_timeout_q;
    logic [RC_RECV_ACK_COALESCE_W-1:0] pending_ack_count_q;
    logic [RC_RECV_ACK_TIMER_W-1:0] ack_timer_q;
    logic pending_ack_q;
    logic ack_ready_to_flush;

    logic needs_payload;
    logic supported_rc_opcode;
    logic send_needs_rq;
    logic psn_match;
    logic duplicate_psn;
    logic gap_psn;
    logic input_fire;
    logic accept_fire;
    logic ack_fire;
    logic drop_fire;

    assign cfg_ready = 1'b1;
    assign needs_payload = (rx_meta.payload_len != 16'd0);
    assign rx_meta_ready = (state_q == RC_RECV_STATE_IDLE) && configured_q && (!needs_payload || rx_payload_valid);
    assign rx_payload_ready = (state_q == RC_RECV_STATE_IDLE) && configured_q && needs_payload && rx_meta_valid;
    assign input_fire = rx_meta_valid && rx_meta_ready && (!needs_payload || (rx_payload_valid && rx_payload_ready));

    assign accept_valid = (state_q == RC_RECV_STATE_ACCEPT);
    assign accept_meta = meta_q;
    assign accept_payload = payload_q;
    assign ack_event_valid = (state_q == RC_RECV_STATE_EMIT_ACK);
    assign ack_event = ack_q;
    assign drop_valid = (state_q == RC_RECV_STATE_DROP);
    assign drop_desc_id = meta_q.desc_id;
    assign drop_qpn = meta_q.qpn;
    assign drop_cqn = meta_q.cqn;
    assign drop_owner_function = meta_q.owner_function;
    assign drop_pd_id = meta_q.pd_id;
    assign drop_opcode = meta_q.opcode;
    assign drop_status = drop_status_q;
    assign drop_error_code = drop_error_q;
    assign expected_psn = expected_psn_q;
    assign debug_status = drop_status_q;

    assign accept_fire = accept_valid && accept_ready;
    assign ack_fire = ack_event_valid && ack_event_ready;
    assign drop_fire = drop_valid && drop_ready;

    assign psn_match = (rx_meta.psn == expected_psn_q);
    // TODO: 后续替换为 24-bit wraparound aware PSN compare。
    assign duplicate_psn = (rx_meta.psn < expected_psn_q);
    assign gap_psn = (rx_meta.psn > expected_psn_q);

    assign send_needs_rq = (rx_meta.opcode == ROCE_OPCODE_SEND_ONLY) ||
                           (rx_meta.opcode == ROCE_OPCODE_SEND_ONLY_IMM);
    assign supported_rc_opcode = send_needs_rq ||
                                 (rx_meta.opcode == ROCE_OPCODE_RDMA_WRITE_ONLY) ||
                                 (rx_meta.opcode == ROCE_OPCODE_RDMA_READ_REQ);

    assign ack_ready_to_flush = pending_ack_q &&
                                ((ack_coalesce_count_q <= {{(RC_RECV_ACK_COALESCE_W-1){1'b0}}, 1'b1}) ||
                                 (pending_ack_count_q >= ack_coalesce_count_q) ||
                                 ((ack_timeout_q != '0) && (ack_timer_q >= ack_timeout_q)));

    function automatic transport_rx_ack_event_t make_event(
        input packet_meta_t meta,
        input rc_recv_status_e status,
        input logic is_ack,
        input logic is_nak,
        input logic is_rnr,
        input logic duplicate,
        input logic gap,
        input rc_nak_code_e nak_code,
        input logic [PSN_W-1:0] ack_psn,
        input logic [PSN_W-1:0] expected
    );
        transport_rx_ack_event_t e;
        e = '0;
        e.desc_id = meta.desc_id;
        e.qpn = meta.dest_qpn;
        e.cqn = meta.cqn;
        e.owner_function = meta.owner_function;
        e.pd_id = meta.pd_id;
        e.opcode = meta.opcode;
        e.status = status;
        e.error_code = {11'd0, status};
        e.packet_psn = meta.psn;
        e.expected_psn = expected;
        e.ack_psn = ack_psn;
        e.is_ack = is_ack;
        e.is_nak = is_nak;
        e.is_rnr = is_rnr;
        e.duplicate = duplicate;
        e.gap = gap;
        e.nak_code = nak_code;
        // TODO: AETH syndrome/MSN 编码先用可调试 placeholder，后续按 IBTA 完整编码。
        e.aeth = {is_nak, is_rnr, 2'b00, nak_code, ack_psn};
        return e;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= RC_RECV_STATE_IDLE;
            meta_q <= '0;
            payload_q <= '0;
            ack_q <= '0;
            drop_status_q <= RC_RECV_STATUS_NOT_READY;
            drop_error_q <= 16'h0000;
            configured_q <= 1'b0;
            cfg_qpn_q <= '0;
            cfg_owner_q <= '0;
            cfg_pd_q <= '0;
            expected_psn_q <= '0;
            last_acked_psn_q <= '0;
            ack_coalesce_count_q <= {{(RC_RECV_ACK_COALESCE_W-1){1'b0}}, 1'b1};
            ack_timeout_q <= '0;
            pending_ack_count_q <= '0;
            ack_timer_q <= '0;
            pending_ack_q <= 1'b0;
        end else begin
            if (cfg_valid && cfg_ready) begin
                configured_q <= 1'b1;
                cfg_qpn_q <= cfg_qpn;
                cfg_owner_q <= cfg_owner_function;
                cfg_pd_q <= cfg_pd_id;
                expected_psn_q <= cfg_expected_psn;
                last_acked_psn_q <= (cfg_expected_psn == '0) ? '0 : (cfg_expected_psn - 1'b1);
                ack_coalesce_count_q <= (cfg_ack_coalesce_count == '0)
                                      ? {{(RC_RECV_ACK_COALESCE_W-1){1'b0}}, 1'b1}
                                      : cfg_ack_coalesce_count;
                ack_timeout_q <= cfg_ack_timeout;
                pending_ack_count_q <= '0;
                ack_timer_q <= '0;
                pending_ack_q <= 1'b0;
                state_q <= RC_RECV_STATE_IDLE;
                drop_status_q <= RC_RECV_STATUS_OK;
            end

            if (timer_tick && pending_ack_q && (ack_timer_q != {RC_RECV_ACK_TIMER_W{1'b1}})) begin
                ack_timer_q <= ack_timer_q + 1'b1;
            end

            unique case (state_q)
                RC_RECV_STATE_IDLE: begin
                    if (ack_ready_to_flush) begin
                        ack_q <= make_event(meta_q, RC_RECV_STATUS_OK, 1'b1, 1'b0, 1'b0,
                                            1'b0, 1'b0, RC_NAK_NONE, last_acked_psn_q, expected_psn_q);
                        state_q <= RC_RECV_STATE_EMIT_ACK;
                    end else if (input_fire) begin
                        meta_q <= rx_meta;
                        payload_q <= needs_payload ? rx_payload : '0;

                        if (!supported_rc_opcode) begin
                            ack_q <= make_event(rx_meta, RC_RECV_STATUS_BAD_OPCODE, 1'b0, 1'b1, 1'b0,
                                                1'b0, 1'b0, RC_NAK_OPCODE, expected_psn_q, expected_psn_q);
                            drop_status_q <= RC_RECV_STATUS_BAD_OPCODE;
                            drop_error_q <= {11'd0, RC_RECV_STATUS_BAD_OPCODE};
                            state_q <= RC_RECV_STATE_EMIT_ACK;
                        end else if (duplicate_psn) begin
                            ack_q <= make_event(rx_meta, RC_RECV_STATUS_DUPLICATE, 1'b1, 1'b0, 1'b0,
                                                1'b1, 1'b0, RC_NAK_NONE, last_acked_psn_q, expected_psn_q);
                            drop_status_q <= RC_RECV_STATUS_DUPLICATE;
                            drop_error_q <= {11'd0, RC_RECV_STATUS_DUPLICATE};
                            state_q <= RC_RECV_STATE_DROP;
                        end else if (gap_psn) begin
                            ack_q <= make_event(rx_meta, RC_RECV_STATUS_GAP_NAK, 1'b0, 1'b1, 1'b0,
                                                1'b0, 1'b1, RC_NAK_SEQUENCE, expected_psn_q, expected_psn_q);
                            drop_status_q <= RC_RECV_STATUS_GAP_NAK;
                            drop_error_q <= {11'd0, RC_RECV_STATUS_GAP_NAK};
                            state_q <= RC_RECV_STATE_EMIT_ACK;
                        end else if (psn_match && send_needs_rq && !rq_buffer_available) begin
                            ack_q <= make_event(rx_meta, RC_RECV_STATUS_RNR_NAK, 1'b0, 1'b1, 1'b1,
                                                1'b0, 1'b0, RC_NAK_RNR, expected_psn_q, expected_psn_q);
                            drop_status_q <= RC_RECV_STATUS_RNR_NAK;
                            drop_error_q <= {11'd0, RC_RECV_STATUS_RNR_NAK};
                            state_q <= RC_RECV_STATE_EMIT_ACK;
                        end else begin
                            drop_status_q <= RC_RECV_STATUS_OK;
                            drop_error_q <= 16'h0000;
                            state_q <= RC_RECV_STATE_ACCEPT;
                        end
                    end
                end

                RC_RECV_STATE_ACCEPT: begin
                    if (accept_fire) begin
                        last_acked_psn_q <= meta_q.psn;
                        expected_psn_q <= expected_psn_q + 1'b1;
                        pending_ack_q <= 1'b1;
                        pending_ack_count_q <= pending_ack_count_q + 1'b1;
                        if (!pending_ack_q) begin
                            ack_timer_q <= '0;
                        end
                        state_q <= RC_RECV_STATE_IDLE;
                    end
                end

                RC_RECV_STATE_EMIT_ACK: begin
                    if (ack_fire) begin
                        if (ack_q.is_ack && !ack_q.is_nak) begin
                            pending_ack_q <= 1'b0;
                            pending_ack_count_q <= '0;
                            ack_timer_q <= '0;
                        end
                        if ((ack_q.status == RC_RECV_STATUS_BAD_OPCODE) ||
                            (ack_q.status == RC_RECV_STATUS_GAP_NAK) ||
                            (ack_q.status == RC_RECV_STATUS_RNR_NAK)) begin
                            state_q <= RC_RECV_STATE_DROP;
                        end else begin
                            state_q <= RC_RECV_STATE_IDLE;
                        end
                    end
                end

                RC_RECV_STATE_DROP: begin
                    if (drop_fire) begin
                        if (drop_status_q == RC_RECV_STATUS_DUPLICATE) begin
                            state_q <= RC_RECV_STATE_EMIT_ACK;
                        end else begin
                            state_q <= RC_RECV_STATE_IDLE;
                        end
                    end
                end

                default: begin
                    state_q <= RC_RECV_STATE_IDLE;
                end
            endcase
        end
    end

endmodule
