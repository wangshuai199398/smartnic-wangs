`timescale 1ns/1ps

module rc_immediate_engine
    import smartnic_pkg::*;
(
    input  logic                         clk,
    input  logic                         rst_n,

    // TX side helper：把 WQE/dispatch 转成带 immediate 的 packet build request。
    input  logic                         tx_req_valid,
    output logic                         tx_req_ready,
    input  sq_dispatch_req_t             tx_req,
    input  logic [PSN_W-1:0]             tx_psn,
    output logic                         tx_packet_valid,
    input  logic                         tx_packet_ready,
    output packet_build_req_t            tx_packet,

    // RX side：来自 parser / payload extractor 的 RC packet metadata。
    input  logic                         rx_valid,
    output logic                         rx_ready,
    input  packet_meta_t                 rx_meta,
    input  packet_payload_stream_t       rx_payload,

    // RQ availability：SEND_WITH_IMM 和 WRITE_WITH_IMM 都需要远端 RQ WQE。
    input  logic                         rq_available,
    input  logic [WR_ID_W-1:0]           rq_wr_id,
    input  logic [CQ_ID_W-1:0]           recv_cqn,

    // RDMA_WRITE_WITH_IMM 先复用 RDMA_WRITE 的 remote memory validation/write。
    output logic                         remote_write_valid,
    input  logic                         remote_write_ready,
    output logic [QP_ID_W-1:0]           remote_write_qpn,
    output logic [VF_ID_W-1:0]           remote_write_owner_function,
    output logic [PD_ID_W-1:0]           remote_write_pd_id,
    output logic [ADDR_W-1:0]            remote_write_va,
    output logic [KEY_W-1:0]             remote_write_rkey,
    output logic [DMA_LEN_W-1:0]         remote_write_len,
    input  logic                         remote_write_done_valid,
    output logic                         remote_write_done_ready,
    input  logic                         remote_write_ok,
    input  logic [15:0]                  remote_write_error_code,

    // Receive CQE seed。completion_engine 负责最终 64-byte CQE 格式化。
    output logic                         completion_valid,
    input  logic                         completion_ready,
    output completion_event_t            completion_event,

    // RNR/error debug path。RNR 不生成 receive CQE。
    output logic                         rnr_error_valid,
    input  logic                         rnr_error_ready,
    output logic [QP_ID_W-1:0]           rnr_error_qpn,
    output rc_imm_status_e               debug_status
);

    typedef enum logic [3:0] {
        IMM_STATE_IDLE         = 4'd0,
        IMM_STATE_TX_PACKET    = 4'd1,
        IMM_STATE_REMOTE_WRITE = 4'd2,
        IMM_STATE_WAIT_WRITE   = 4'd3,
        IMM_STATE_COMPLETION   = 4'd4,
        IMM_STATE_RNR          = 4'd5,
        IMM_STATE_ERROR        = 4'd6
    } imm_state_e;

    imm_state_e state_q;
    sq_dispatch_req_t tx_req_q;
    packet_meta_t rx_meta_q;
    packet_payload_stream_t rx_payload_q;
    packet_build_req_t tx_packet_q;
    completion_event_t completion_q;
    rc_imm_status_e status_q;

    logic tx_is_send_imm;
    logic tx_is_write_imm;
    logic rx_is_send_imm;
    logic rx_is_write_imm;
    logic tx_fire;
    logic rx_fire;
    logic tx_packet_fire;
    logic remote_write_fire;
    logic remote_write_done_fire;
    logic completion_fire;
    logic rnr_fire;

    assign tx_is_send_imm = (tx_req.opcode == RDMA_OP_SEND_WITH_IMM);
    assign tx_is_write_imm = (tx_req.opcode == RDMA_OP_RDMA_WRITE_WITH_IMM);
    assign rx_is_send_imm = (rx_meta.opcode == ROCE_OPCODE_SEND_ONLY_IMM);
    assign rx_is_write_imm = (rx_meta.opcode == ROCE_OPCODE_RDMA_WRITE_ONLY_IMM);

    assign tx_req_ready = (state_q == IMM_STATE_IDLE);
    assign rx_ready = (state_q == IMM_STATE_IDLE);
    assign tx_fire = tx_req_valid && tx_req_ready;
    assign rx_fire = rx_valid && rx_ready;

    assign tx_packet_valid = (state_q == IMM_STATE_TX_PACKET);
    assign tx_packet = tx_packet_q;
    assign tx_packet_fire = tx_packet_valid && tx_packet_ready;

    assign remote_write_valid = (state_q == IMM_STATE_REMOTE_WRITE);
    assign remote_write_qpn = rx_meta_q.dest_qpn;
    assign remote_write_owner_function = rx_meta_q.owner_function;
    assign remote_write_pd_id = rx_meta_q.pd_id;
    assign remote_write_va = rx_meta_q.remote_va;
    assign remote_write_rkey = rx_meta_q.rkey;
    assign remote_write_len = rx_meta_q.dma_length;
    assign remote_write_fire = remote_write_valid && remote_write_ready;
    assign remote_write_done_ready = (state_q == IMM_STATE_WAIT_WRITE);
    assign remote_write_done_fire = remote_write_done_valid && remote_write_done_ready;

    assign completion_valid = (state_q == IMM_STATE_COMPLETION);
    assign completion_event = completion_q;
    assign completion_fire = completion_valid && completion_ready;

    assign rnr_error_valid = (state_q == IMM_STATE_RNR);
    assign rnr_error_qpn = rx_meta_q.dest_qpn;
    assign rnr_fire = rnr_error_valid && rnr_error_ready;
    assign debug_status = status_q;

    function automatic logic [31:0] imm_to_network(input logic [31:0] imm);
        begin
            imm_to_network = {imm[31:24], imm[23:16], imm[15:8], imm[7:0]};
        end
    endfunction

    function automatic packet_build_req_t make_tx_packet(
        input sq_dispatch_req_t req,
        input logic [PSN_W-1:0] psn
    );
        packet_build_req_t p;
        p = '0;
        p.desc_id = 16'(req.sq_consumer);
        p.qpn = req.qpn;
        p.cqn = req.send_cqn;
        p.owner_function = req.owner_func;
        p.pd_id = req.pd_id;
        p.opcode = (req.opcode == RDMA_OP_SEND_WITH_IMM) ?
                   ROCE_OPCODE_SEND_ONLY_IMM : ROCE_OPCODE_RDMA_WRITE_ONLY_IMM;
        p.status = PKT_BUILD_OK;
        p.dest_qpn = req.wqe.remote_va[QP_ID_W-1:0]; // TODO: 后续接 remote_qpn/AH context。
        p.psn = psn;
        p.remote_va = req.wqe.remote_va;
        p.rkey = req.wqe.rkey;
        p.dma_length = req.wqe.length;
        p.has_imm = 1'b1;
        p.imm_data = imm_to_network(req.wqe.imm_data);
        p.payload_len = 16'(req.wqe.length[15:0]);
        return p;
    endfunction

    function automatic completion_event_t make_recv_completion(
        input packet_meta_t meta,
        input packet_payload_stream_t payload,
        input logic [WR_ID_W-1:0] wr_id,
        input logic [CQ_ID_W-1:0] cqn_i,
        input rdma_opcode_e opcode_i,
        input cmpl_status_e status_i,
        input rc_imm_status_e imm_status
    );
        completion_event_t c;
        c = '0;
        c.event_type = CMPL_EVENT_RQ;
        c.qpn = meta.dest_qpn;
        c.cqn = cqn_i;
        c.owner_function = meta.owner_function;
        c.wr_id = wr_id;
        c.opcode = opcode_i;
        c.status = status_i;
        c.byte_len = payload.valid_bytes;
        c.imm_data = meta.imm_data;
        c.has_imm = 1'b1;
        c.solicited = 1'b0;
        c.vendor_error = {27'd0, imm_status};
        c.source_engine = CMPL_SRC_TRANSPORT;
        return c;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= IMM_STATE_IDLE;
            tx_req_q <= '0;
            rx_meta_q <= '0;
            rx_payload_q <= '0;
            tx_packet_q <= '0;
            completion_q <= '0;
            status_q <= RC_IMM_STATUS_OK;
        end else begin
            unique case (state_q)
                IMM_STATE_IDLE: begin
                    status_q <= RC_IMM_STATUS_OK;
                    if (tx_fire) begin
                        tx_req_q <= tx_req;
                        if (tx_is_send_imm || tx_is_write_imm) begin
                            tx_packet_q <= make_tx_packet(tx_req, tx_psn);
                            state_q <= IMM_STATE_TX_PACKET;
                        end else begin
                            status_q <= RC_IMM_STATUS_BAD_OPCODE;
                            state_q <= IMM_STATE_ERROR;
                        end
                    end else if (rx_fire) begin
                        rx_meta_q <= rx_meta;
                        rx_payload_q <= rx_payload;
                        if (!(rx_is_send_imm || rx_is_write_imm) || !rx_meta.has_imm) begin
                            status_q <= RC_IMM_STATUS_BAD_OPCODE;
                            state_q <= IMM_STATE_ERROR;
                        end else if (!rq_available) begin
                            status_q <= RC_IMM_STATUS_RNR;
                            state_q <= IMM_STATE_RNR;
                        end else if (rx_is_write_imm) begin
                            state_q <= IMM_STATE_REMOTE_WRITE;
                        end else begin
                            completion_q <= make_recv_completion(
                                rx_meta,
                                rx_payload,
                                rq_wr_id,
                                recv_cqn,
                                RDMA_OP_SEND_WITH_IMM,
                                CMPL_SUCCESS,
                                RC_IMM_STATUS_OK
                            );
                            state_q <= IMM_STATE_COMPLETION;
                        end
                    end
                end

                IMM_STATE_TX_PACKET: begin
                    if (tx_packet_fire) begin
                        state_q <= IMM_STATE_IDLE;
                    end
                end

                IMM_STATE_REMOTE_WRITE: begin
                    if (remote_write_fire) begin
                        state_q <= IMM_STATE_WAIT_WRITE;
                    end
                end

                IMM_STATE_WAIT_WRITE: begin
                    if (remote_write_done_fire) begin
                        if (remote_write_ok) begin
                            completion_q <= make_recv_completion(
                                rx_meta_q,
                                rx_payload_q,
                                rq_wr_id,
                                recv_cqn,
                                RDMA_OP_RDMA_WRITE_WITH_IMM,
                                CMPL_SUCCESS,
                                RC_IMM_STATUS_OK
                            );
                            state_q <= IMM_STATE_COMPLETION;
                        end else begin
                            status_q <= RC_IMM_STATUS_REMOTE_DENY;
                            completion_q <= '0;
                            completion_q.event_type <= CMPL_EVENT_ERROR;
                            completion_q.qpn <= rx_meta_q.dest_qpn;
                            completion_q.cqn <= recv_cqn;
                            completion_q.owner_function <= rx_meta_q.owner_function;
                            completion_q.opcode <= RDMA_OP_RDMA_WRITE_WITH_IMM;
                            completion_q.status <= CMPL_REM_ACCESS_ERR;
                            completion_q.vendor_error <= {16'd0, remote_write_error_code};
                            completion_q.source_engine <= CMPL_SRC_TRANSPORT;
                            state_q <= IMM_STATE_ERROR;
                        end
                    end
                end

                IMM_STATE_COMPLETION: begin
                    if (completion_fire) begin
                        state_q <= IMM_STATE_IDLE;
                    end
                end

                IMM_STATE_RNR: begin
                    if (rnr_fire) begin
                        state_q <= IMM_STATE_IDLE;
                    end
                end

                IMM_STATE_ERROR: begin
                    // 错误路径不生成 receive CQE，避免无效 remote write 产生完成。
                    state_q <= IMM_STATE_IDLE;
                end

                default: begin
                    state_q <= IMM_STATE_IDLE;
                end
            endcase
        end
    end

endmodule
