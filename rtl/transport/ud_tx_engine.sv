`timescale 1ns/1ps

module ud_tx_engine
    import smartnic_pkg::*;
(
    input  logic                         clk,
    input  logic                         rst_n,

    // UD transmit request，来自 SQ/WQE 解码后的最小请求。
    input  logic                         ud_req_valid,
    output logic                         ud_req_ready,
    input  ud_tx_req_t                   ud_req,

    // Address Handle lookup。9.7 会补完整 AH table，本阶段使用外部 stub/table 响应。
    output logic                         ah_lookup_valid,
    input  logic                         ah_lookup_ready,
    output logic [AH_ID_W-1:0]           ah_lookup_id,
    output logic [VF_ID_W-1:0]           ah_lookup_owner_function,
    output logic [PD_ID_W-1:0]           ah_lookup_pd_id,
    input  logic                         ah_lookup_resp_valid,
    output logic                         ah_lookup_resp_ready,
    input  logic                         ah_lookup_hit,
    input  ah_entry_t                    ah_lookup_entry,
    input  logic [15:0]                  ah_lookup_error_code,

    // 交给 RoCEv2 packet builder。builder 负责把 DETH 写成 network byte order。
    output logic                         packet_valid,
    input  logic                         packet_ready,
    output packet_build_req_t            packet_req,

    // 本地 send completion。UD 不等待 ACK，也不维护 RC retry/connection state。
    output logic                         completion_valid,
    input  logic                         completion_ready,
    output completion_event_t            completion_event,

    // 本地 WQE 错误路径，用于 invalid AH、缺失 Q_Key、UD 不支持 opcode 等。
    output logic                         wqe_error_valid,
    input  logic                         wqe_error_ready,
    output logic [QP_ID_W-1:0]           wqe_error_qpn,
    output logic [CQ_ID_W-1:0]           wqe_error_cqn,
    output logic [VF_ID_W-1:0]           wqe_error_owner_function,
    output logic [WR_ID_W-1:0]           wqe_error_wr_id,
    output rdma_opcode_e                 wqe_error_opcode,
    output cmpl_status_e                 wqe_error_completion_status,
    output ud_tx_status_e                wqe_error_status,
    output logic [15:0]                  wqe_error_code,

    output ud_tx_status_e                debug_status
);

    typedef enum logic [3:0] {
        UD_TX_STATE_IDLE       = 4'd0,
        UD_TX_STATE_AH_LOOKUP  = 4'd1,
        UD_TX_STATE_WAIT_AH    = 4'd2,
        UD_TX_STATE_PACKET     = 4'd3,
        UD_TX_STATE_COMPLETION = 4'd4,
        UD_TX_STATE_ERROR      = 4'd5
    } ud_tx_state_e;

    ud_tx_state_e      state_q;
    ud_tx_req_t        req_q;
    packet_build_req_t packet_q;
    completion_event_t completion_q;
    ud_tx_status_e     status_q;
    logic [15:0]       error_code_q;

    logic req_fire;
    logic ah_lookup_fire;
    logic ah_resp_fire;
    logic packet_fire;
    logic completion_fire;
    logic error_fire;

    assign ud_req_ready = (state_q == UD_TX_STATE_IDLE);
    assign req_fire = ud_req_valid && ud_req_ready;

    assign ah_lookup_valid = (state_q == UD_TX_STATE_AH_LOOKUP);
    assign ah_lookup_id = req_q.ah_id;
    assign ah_lookup_owner_function = req_q.owner_function;
    assign ah_lookup_pd_id = req_q.pd_id;
    assign ah_lookup_fire = ah_lookup_valid && ah_lookup_ready;

    assign ah_lookup_resp_ready = (state_q == UD_TX_STATE_WAIT_AH);
    assign ah_resp_fire = ah_lookup_resp_valid && ah_lookup_resp_ready;

    assign packet_valid = (state_q == UD_TX_STATE_PACKET);
    assign packet_req = packet_q;
    assign packet_fire = packet_valid && packet_ready;

    assign completion_valid = (state_q == UD_TX_STATE_COMPLETION);
    assign completion_event = completion_q;
    assign completion_fire = completion_valid && completion_ready;

    assign wqe_error_valid = (state_q == UD_TX_STATE_ERROR);
    assign wqe_error_qpn = req_q.qpn;
    assign wqe_error_cqn = req_q.cqn;
    assign wqe_error_owner_function = req_q.owner_function;
    assign wqe_error_wr_id = req_q.wr_id;
    assign wqe_error_opcode = req_q.opcode;
    assign wqe_error_status = status_q;
    assign wqe_error_code = error_code_q;
    assign wqe_error_completion_status =
        (status_q == UD_TX_STATUS_UNSUPPORTED_OP) ? CMPL_LOC_QP_OP_ERR : CMPL_LOC_PROT_ERR;
    assign error_fire = wqe_error_valid && wqe_error_ready;

    assign debug_status = status_q;

    function automatic logic [QKEY_W-1:0] select_qkey(
        input ud_tx_req_t req,
        input ah_entry_t ah
    );
        begin
            select_qkey = (req.qkey != '0) ? req.qkey : ah.qkey;
        end
    endfunction

    function automatic packet_build_req_t make_ud_packet(
        input ud_tx_req_t req,
        input ah_entry_t ah
    );
        packet_build_req_t p;
        p = '0;
        p.desc_id = req.desc_id;
        p.qpn = req.qpn;
        p.cqn = req.cqn;
        p.owner_function = req.owner_function;
        p.pd_id = req.pd_id;
        p.opcode = ROCE_OPCODE_UD_SEND_ONLY;
        p.status = PKT_BUILD_OK;
        p.dst_mac = ah.dst_mac;
        p.dst_ipv4 = ah.dst_ipv4;
        p.udp_src_port = ah.udp_src_port;
        p.udp_dst_port = (ah.udp_dst_port == 16'd0) ? ROCEV2_UDP_PORT : ah.udp_dst_port;
        p.pkey = ah.pkey;
        p.dest_qpn = req.dest_qpn;
        p.src_qpn = req.qpn;
        p.psn = req.psn;
        p.qkey = select_qkey(req, ah);
        p.has_imm = 1'b0;
        p.imm_data = 32'd0;
        p.payload_data = req.payload_data;
        p.payload_len = req.payload_len;
        return p;
    endfunction

    function automatic completion_event_t make_sq_completion(input ud_tx_req_t req);
        completion_event_t c;
        c = '0;
        c.event_type = CMPL_EVENT_SQ;
        c.qpn = req.qpn;
        c.cqn = req.cqn;
        c.owner_function = req.owner_function;
        c.wr_id = req.wr_id;
        c.opcode = RDMA_OP_SEND;
        c.status = CMPL_SUCCESS;
        c.byte_len = req.payload_len;
        c.has_imm = 1'b0;
        c.solicited = req.solicited;
        c.source_engine = CMPL_SRC_TRANSPORT;
        return c;
    endfunction

    function automatic ud_tx_status_e precheck_status(input ud_tx_req_t req);
        begin
            if (req.qp_type != QP_TYPE_UD) begin
                precheck_status = UD_TX_STATUS_BAD_QP_TYPE;
            end else if (req.opcode != RDMA_OP_SEND) begin
                precheck_status = UD_TX_STATUS_UNSUPPORTED_OP;
            end else begin
                precheck_status = UD_TX_STATUS_OK;
            end
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= UD_TX_STATE_IDLE;
            req_q <= '0;
            packet_q <= '0;
            completion_q <= '0;
            status_q <= UD_TX_STATUS_OK;
            error_code_q <= 16'd0;
        end else begin
            unique case (state_q)
                UD_TX_STATE_IDLE: begin
                    if (req_fire) begin
                        req_q <= ud_req;
                        status_q <= precheck_status(ud_req);
                        error_code_q <= {11'd0, precheck_status(ud_req)};
                        if (precheck_status(ud_req) == UD_TX_STATUS_OK) begin
                            state_q <= UD_TX_STATE_AH_LOOKUP;
                        end else begin
                            state_q <= UD_TX_STATE_ERROR;
                        end
                    end
                end

                UD_TX_STATE_AH_LOOKUP: begin
                    if (ah_lookup_fire) begin
                        state_q <= UD_TX_STATE_WAIT_AH;
                    end
                end

                UD_TX_STATE_WAIT_AH: begin
                    if (ah_resp_fire) begin
                        if (!ah_lookup_hit || !ah_lookup_entry.valid) begin
                            status_q <= UD_TX_STATUS_AH_MISS;
                            error_code_q <= (ah_lookup_error_code != 16'd0) ?
                                            ah_lookup_error_code : {11'd0, UD_TX_STATUS_AH_MISS};
                            state_q <= UD_TX_STATE_ERROR;
                        end else if ((ah_lookup_entry.owner_func != req_q.owner_function) ||
                                     (ah_lookup_entry.pd_id != req_q.pd_id)) begin
                            status_q <= UD_TX_STATUS_AH_PERMISSION;
                            error_code_q <= {11'd0, UD_TX_STATUS_AH_PERMISSION};
                            state_q <= UD_TX_STATE_ERROR;
                        end else if (select_qkey(req_q, ah_lookup_entry) == '0) begin
                            status_q <= UD_TX_STATUS_MISSING_QKEY;
                            error_code_q <= {11'd0, UD_TX_STATUS_MISSING_QKEY};
                            state_q <= UD_TX_STATE_ERROR;
                        end else begin
                            packet_q <= make_ud_packet(req_q, ah_lookup_entry);
                            completion_q <= make_sq_completion(req_q);
                            status_q <= UD_TX_STATUS_OK;
                            error_code_q <= 16'd0;
                            state_q <= UD_TX_STATE_PACKET;
                        end
                    end
                end

                UD_TX_STATE_PACKET: begin
                    if (packet_fire) begin
                        state_q <= req_q.completion_required ? UD_TX_STATE_COMPLETION : UD_TX_STATE_IDLE;
                    end
                end

                UD_TX_STATE_COMPLETION: begin
                    if (completion_fire) begin
                        state_q <= UD_TX_STATE_IDLE;
                    end
                end

                UD_TX_STATE_ERROR: begin
                    if (error_fire) begin
                        state_q <= UD_TX_STATE_IDLE;
                    end
                end

                default: begin
                    state_q <= UD_TX_STATE_IDLE;
                end
            endcase
        end
    end

endmodule
