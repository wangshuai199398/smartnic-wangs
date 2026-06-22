`timescale 1ns/1ps

module rc_send_engine
    import smartnic_pkg::*;
#(
    parameter int OUTSTANDING_DEPTH = RC_SEND_OUTSTANDING_DEPTH,
    parameter int OUTSTANDING_IDX_W = (OUTSTANDING_DEPTH <= 1) ? 1 : $clog2(OUTSTANDING_DEPTH)
) (
    input  logic                    clk,
    input  logic                    rst_n,

    // RC send context 配置。后续会由 QP context table / lifecycle manager 驱动。
    input  logic                    cfg_valid,
    output logic                    cfg_ready,
    input  logic [QP_ID_W-1:0]      cfg_qpn,
    input  logic [VF_ID_W-1:0]      cfg_owner_function,
    input  logic [PD_ID_W-1:0]      cfg_pd_id,
    input  logic [PSN_W-1:0]        cfg_initial_psn,
    input  logic [RC_SEND_RETRY_COUNT_W-1:0] cfg_retry_limit,
    input  logic [RC_SEND_RETRY_TIMER_W-1:0] cfg_retry_timeout,

    // 来自 SQ/DMA/transport dispatch 的 TX 请求。
    input  logic                    tx_req_valid,
    output logic                    tx_req_ready,
    input  transport_tx_req_t       tx_req,

    // 首次发包输出，后续接 packet builder。
    output logic                    packet_valid,
    input  logic                    packet_ready,
    output transport_rc_packet_t    packet,

    // ACK/NAK hint 输入。9.1 只做 send-side ACK 清理和 retry hint，不实现接收侧 PSN 校验。
    input  logic                    ack_valid,
    output logic                    ack_ready,
    input  transport_ack_event_t    ack_event,

    // retry timer tick。每个 tick 递增 outstanding entry 的等待计数。
    input  logic                    timer_tick,

    // retry 重新发包输出。
    output logic                    retry_valid,
    input  logic                    retry_ready,
    output transport_rc_packet_t    retry_packet,

    // retry exhausted 后请求 QP 进入 error cleanup。
    output logic                    qp_error_req_valid,
    input  logic                    qp_error_req_ready,
    output logic [QP_ID_W-1:0]      qp_error_qpn,
    output logic [VF_ID_W-1:0]      qp_error_owner_function,
    output logic [15:0]             qp_error_code,
    output logic [15:0]             qp_error_desc_id,

    output logic [PSN_W-1:0]        next_psn,
    output logic [3:0]              outstanding_count,
    output rc_send_status_e         debug_status
);

    typedef struct packed {
        logic                     valid;
        transport_rc_packet_t     pkt;
        logic [RC_SEND_RETRY_TIMER_W-1:0] timer;
        logic [RC_SEND_RETRY_COUNT_W-1:0] retries_left;
    } outstanding_entry_t;

    outstanding_entry_t outstanding [OUTSTANDING_DEPTH];

    logic configured_q;
    logic [QP_ID_W-1:0] cfg_qpn_q;
    logic [VF_ID_W-1:0] cfg_owner_q;
    logic [PD_ID_W-1:0] cfg_pd_q;
    logic [PSN_W-1:0] next_psn_q;
    logic [RC_SEND_RETRY_COUNT_W-1:0] retry_limit_q;
    logic [RC_SEND_RETRY_TIMER_W-1:0] retry_timeout_q;

    transport_rc_packet_t packet_q;
    logic packet_valid_q;
    transport_rc_packet_t retry_packet_q;
    logic retry_valid_q;
    logic qp_error_valid_q;
    logic [QP_ID_W-1:0] qp_error_qpn_q;
    logic [VF_ID_W-1:0] qp_error_owner_q;
    logic [15:0] qp_error_code_q;
    logic [15:0] qp_error_desc_id_q;
    rc_send_status_e debug_status_q;

    logic [OUTSTANDING_IDX_W-1:0] free_idx;
    logic free_found;
    logic [OUTSTANDING_IDX_W-1:0] retry_idx;
    logic retry_found;
    logic [3:0] outstanding_count_c;
    logic tx_accept;
    logic ack_accept;
    logic ack_matches;

    assign cfg_ready = 1'b1;
    assign tx_req_ready = configured_q && free_found && !packet_valid_q;
    assign packet_valid = packet_valid_q;
    assign packet = packet_q;
    assign ack_ready = 1'b1;
    assign retry_valid = retry_valid_q;
    assign retry_packet = retry_packet_q;
    assign qp_error_req_valid = qp_error_valid_q;
    assign qp_error_qpn = qp_error_qpn_q;
    assign qp_error_owner_function = qp_error_owner_q;
    assign qp_error_code = qp_error_code_q;
    assign qp_error_desc_id = qp_error_desc_id_q;
    assign next_psn = next_psn_q;
    assign outstanding_count = outstanding_count_c;
    assign debug_status = debug_status_q;
    assign tx_accept = tx_req_valid && tx_req_ready;
    assign ack_accept = ack_valid && ack_ready;

    always_comb begin
        free_idx = '0;
        free_found = 1'b0;
        retry_idx = '0;
        retry_found = 1'b0;
        outstanding_count_c = 4'd0;
        ack_matches = 1'b0;

        for (int i = 0; i < OUTSTANDING_DEPTH; i++) begin
            if (!outstanding[i].valid && !free_found) begin
                free_found = 1'b1;
                free_idx = i;
            end
            if (outstanding[i].valid) begin
                outstanding_count_c = outstanding_count_c + 4'd1;
                if ((outstanding[i].timer >= retry_timeout_q) && !retry_found) begin
                    retry_found = 1'b1;
                    retry_idx = i;
                end
                if (ack_accept &&
                    (ack_event.qpn == outstanding[i].pkt.qpn) &&
                    (ack_event.owner_function == outstanding[i].pkt.owner_function) &&
                    (ack_event.ack_psn >= outstanding[i].pkt.psn)) begin
                    ack_matches = 1'b1;
                end
            end
        end
    end

    function automatic transport_rc_packet_t make_packet(
        input transport_tx_req_t req,
        input logic [PSN_W-1:0] psn,
        input logic is_retry,
        input logic [RC_SEND_RETRY_COUNT_W-1:0] retries_left
    );
        transport_rc_packet_t p;
        p = '0;
        p.desc_id = req.desc_id;
        p.qpn = req.qpn;
        p.cqn = req.cqn;
        p.owner_function = req.owner_function;
        p.pd_id = req.pd_id;
        p.opcode = req.opcode;
        p.status = RC_SEND_STATUS_OK;
        p.error_code = 16'h0000;
        p.wr_id = req.wr_id;
        p.psn = psn;
        p.is_retry = is_retry;
        p.retry_count = retries_left;
        p.build_req = req.build_req;
        p.build_req.desc_id = req.desc_id;
        p.build_req.qpn = req.qpn;
        p.build_req.cqn = req.cqn;
        p.build_req.owner_function = req.owner_function;
        p.build_req.pd_id = req.pd_id;
        p.build_req.opcode = req.opcode;
        p.build_req.psn = psn;
        return p;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            configured_q <= 1'b0;
            cfg_qpn_q <= '0;
            cfg_owner_q <= '0;
            cfg_pd_q <= '0;
            next_psn_q <= '0;
            retry_limit_q <= '0;
            retry_timeout_q <= 16'd16;
            packet_q <= '0;
            packet_valid_q <= 1'b0;
            retry_packet_q <= '0;
            retry_valid_q <= 1'b0;
            qp_error_valid_q <= 1'b0;
            qp_error_qpn_q <= '0;
            qp_error_owner_q <= '0;
            qp_error_code_q <= 16'h0000;
            qp_error_desc_id_q <= 16'h0000;
            debug_status_q <= RC_SEND_STATUS_NOT_CONFIGURED;
            for (int i = 0; i < OUTSTANDING_DEPTH; i++) begin
                outstanding[i] <= '0;
            end
        end else begin
            if (cfg_valid && cfg_ready) begin
                configured_q <= 1'b1;
                cfg_qpn_q <= cfg_qpn;
                cfg_owner_q <= cfg_owner_function;
                cfg_pd_q <= cfg_pd_id;
                next_psn_q <= cfg_initial_psn;
                retry_limit_q <= cfg_retry_limit;
                retry_timeout_q <= (cfg_retry_timeout == '0) ? 16'd16 : cfg_retry_timeout;
                debug_status_q <= RC_SEND_STATUS_OK;
                for (int i = 0; i < OUTSTANDING_DEPTH; i++) begin
                    outstanding[i] <= '0;
                end
            end

            if (packet_valid_q && packet_ready) begin
                packet_valid_q <= 1'b0;
            end
            if (retry_valid_q && retry_ready) begin
                retry_valid_q <= 1'b0;
            end
            if (qp_error_valid_q && qp_error_req_ready) begin
                qp_error_valid_q <= 1'b0;
            end

            if (timer_tick) begin
                for (int i = 0; i < OUTSTANDING_DEPTH; i++) begin
                    if (outstanding[i].valid && (outstanding[i].timer != {RC_SEND_RETRY_TIMER_W{1'b1}})) begin
                        outstanding[i].timer <= outstanding[i].timer + 1'b1;
                    end
                end
            end

            if (ack_accept) begin
                for (int i = 0; i < OUTSTANDING_DEPTH; i++) begin
                    if (outstanding[i].valid &&
                        (ack_event.qpn == outstanding[i].pkt.qpn) &&
                        (ack_event.owner_function == outstanding[i].pkt.owner_function) &&
                        (ack_event.ack_psn >= outstanding[i].pkt.psn)) begin
                        outstanding[i].valid <= 1'b0;
                        outstanding[i].timer <= '0;
                    end
                end
                debug_status_q <= ack_matches ? RC_SEND_STATUS_OK : RC_SEND_STATUS_ACK_MISS;
            end

            if (tx_accept) begin
                transport_rc_packet_t new_packet;
                new_packet = make_packet(tx_req, next_psn_q, 1'b0, retry_limit_q);
                packet_q <= new_packet;
                packet_valid_q <= 1'b1;
                outstanding[free_idx].valid <= 1'b1;
                outstanding[free_idx].pkt <= new_packet;
                outstanding[free_idx].timer <= '0;
                outstanding[free_idx].retries_left <= retry_limit_q;
                next_psn_q <= next_psn_q + 1'b1;
                debug_status_q <= RC_SEND_STATUS_OK;
            end else if (tx_req_valid && !tx_req_ready && configured_q && !free_found) begin
                debug_status_q <= RC_SEND_STATUS_WINDOW_FULL;
            end

            if (configured_q && retry_found && !retry_valid_q && !qp_error_valid_q) begin
                if (outstanding[retry_idx].retries_left != '0) begin
                    transport_rc_packet_t retry_pkt;
                    retry_pkt = outstanding[retry_idx].pkt;
                    retry_pkt.is_retry = 1'b1;
                    retry_pkt.retry_count = outstanding[retry_idx].retries_left - 1'b1;
                    retry_packet_q <= retry_pkt;
                    retry_valid_q <= 1'b1;
                    outstanding[retry_idx].timer <= '0;
                    outstanding[retry_idx].retries_left <= outstanding[retry_idx].retries_left - 1'b1;
                    outstanding[retry_idx].pkt.retry_count <= outstanding[retry_idx].retries_left - 1'b1;
                    debug_status_q <= RC_SEND_STATUS_OK;
                end else begin
                    qp_error_qpn_q <= outstanding[retry_idx].pkt.qpn;
                    qp_error_owner_q <= outstanding[retry_idx].pkt.owner_function;
                    qp_error_code_q <= {11'd0, RC_SEND_STATUS_RETRY_EXHAUSTED};
                    qp_error_desc_id_q <= outstanding[retry_idx].pkt.desc_id;
                    qp_error_valid_q <= 1'b1;
                    outstanding[retry_idx].valid <= 1'b0;
                    debug_status_q <= RC_SEND_STATUS_RETRY_EXHAUSTED;
                end
            end
        end
    end

endmodule
