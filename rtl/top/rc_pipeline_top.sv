// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// RC Send/Recv minimal loop integration。
//
// 该模块把 11.4 要求的 QP -> transport -> packet -> DMA -> completion
// 控制顺序固化为一个最小 ready/valid pipeline。当前只支持单 active QP、
// 单 packet RC_SEND，不实现 retry/RNR/congestion/multi-QP arbitration。

`timescale 1ns/1ps

import smartnic_pkg::*;

module rc_pipeline_top (
    input  logic                         clk,
    input  logic                         rst_n,

    // ------------------------------------------------------------------
    // Minimal RC Send hook from QP SQ / testbench
    // ------------------------------------------------------------------
    input  logic                         send_req_valid,
    output logic                         send_req_ready,
    input  logic [QP_ID_W-1:0]           send_qpn,
    input  logic [CQ_ID_W-1:0]           send_cqn,
    input  logic [VF_ID_W-1:0]           send_owner_function,
    input  logic [PD_ID_W-1:0]           send_pd_id,
    input  logic [WR_ID_W-1:0]           send_wr_id,
    input  logic [DMA_LEN_W-1:0]         send_payload_len,
    input  logic [511:0]                 send_payload_data,
    input  logic                         send_solicited,

    // ------------------------------------------------------------------
    // Minimal RC Receive hook from packet parser / testbench
    // ------------------------------------------------------------------
    input  logic                         recv_req_valid,
    output logic                         recv_req_ready,
    input  logic [QP_ID_W-1:0]           recv_qpn,
    input  logic [CQ_ID_W-1:0]           recv_cqn,
    input  logic [VF_ID_W-1:0]           recv_owner_function,
    input  logic [PD_ID_W-1:0]           recv_pd_id,
    input  logic [WR_ID_W-1:0]           recv_wr_id,
    input  logic [DMA_LEN_W-1:0]         recv_payload_len,
    input  logic [511:0]                 recv_payload_data,
    input  logic                         recv_solicited,

    // ------------------------------------------------------------------
    // Packet builder request
    // ------------------------------------------------------------------
    output logic                         packet_build_valid,
    input  logic                         packet_build_ready,
    output packet_build_req_t            packet_build_req,

    // ------------------------------------------------------------------
    // Minimal DMA hooks
    // ------------------------------------------------------------------
    output logic                         dma_read_valid,
    input  logic                         dma_read_ready,
    output logic [QP_ID_W-1:0]           dma_read_qpn,
    output logic [DMA_LEN_W-1:0]         dma_read_len,
    output logic                         dma_write_valid,
    input  logic                         dma_write_ready,
    output logic [QP_ID_W-1:0]           dma_write_qpn,
    output logic [DMA_LEN_W-1:0]         dma_write_len,

    // ------------------------------------------------------------------
    // Completion event to completion_engine
    // ------------------------------------------------------------------
    output logic                         completion_event_valid,
    input  logic                         completion_event_ready,
    output completion_event_t            completion_event,

    // ------------------------------------------------------------------
    // CQ commit hint for notification logic
    // ------------------------------------------------------------------
    output logic                         cq_commit_valid,
    input  logic                         cq_commit_ready,
    output logic [CQ_ID_W-1:0]           cq_commit_cqn,
    output logic [VF_ID_W-1:0]           cq_commit_owner_function,
    output logic                         cq_commit_solicited,
    output cmpl_status_e                 cq_commit_status,

    output logic [PSN_W-1:0]             debug_next_psn,
    output logic [3:0]                   debug_state
);

    typedef enum logic [3:0] {
        RC_PIPE_IDLE           = 4'd0,
        RC_PIPE_SEND_DMA_READ  = 4'd1,
        RC_PIPE_SEND_PACKET    = 4'd2,
        RC_PIPE_SEND_COMPLETE  = 4'd3,
        RC_PIPE_RECV_DMA_WRITE = 4'd4,
        RC_PIPE_RECV_COMPLETE  = 4'd5,
        RC_PIPE_CQ_COMMIT      = 4'd6
    } rc_pipe_state_e;

    rc_pipe_state_e state_q;
    logic active_is_send_q;
    logic [QP_ID_W-1:0] active_qpn_q;
    logic [CQ_ID_W-1:0] active_cqn_q;
    logic [VF_ID_W-1:0] active_owner_q;
    logic [PD_ID_W-1:0] active_pd_q;
    logic [WR_ID_W-1:0] active_wr_id_q;
    logic [DMA_LEN_W-1:0] active_len_q;
    logic [511:0] active_payload_q;
    logic active_solicited_q;
    logic [PSN_W-1:0] psn_q;
    packet_build_req_t build_req_q;
    completion_event_t completion_q;

    logic send_fire;
    logic recv_fire;
    logic dma_read_fire;
    logic dma_write_fire;
    logic packet_fire;
    logic completion_fire;
    logic cq_commit_fire;

    assign debug_next_psn = psn_q;
    assign debug_state = state_q;
    assign send_req_ready = (state_q == RC_PIPE_IDLE);
    assign recv_req_ready = (state_q == RC_PIPE_IDLE) && !send_req_valid;
    assign send_fire = send_req_valid && send_req_ready;
    assign recv_fire = recv_req_valid && recv_req_ready;

    assign dma_read_valid = (state_q == RC_PIPE_SEND_DMA_READ);
    assign dma_read_qpn = active_qpn_q;
    assign dma_read_len = active_len_q;
    assign dma_read_fire = dma_read_valid && dma_read_ready;

    assign dma_write_valid = (state_q == RC_PIPE_RECV_DMA_WRITE);
    assign dma_write_qpn = active_qpn_q;
    assign dma_write_len = active_len_q;
    assign dma_write_fire = dma_write_valid && dma_write_ready;

    assign packet_build_valid = (state_q == RC_PIPE_SEND_PACKET);
    assign packet_build_req = build_req_q;
    assign packet_fire = packet_build_valid && packet_build_ready;

    assign completion_event_valid = (state_q == RC_PIPE_SEND_COMPLETE) ||
                                    (state_q == RC_PIPE_RECV_COMPLETE);
    assign completion_event = completion_q;
    assign completion_fire = completion_event_valid && completion_event_ready;

    assign cq_commit_valid = (state_q == RC_PIPE_CQ_COMMIT);
    assign cq_commit_cqn = active_cqn_q;
    assign cq_commit_owner_function = active_owner_q;
    assign cq_commit_solicited = active_solicited_q;
    assign cq_commit_status = CMPL_SUCCESS;
    assign cq_commit_fire = cq_commit_valid && cq_commit_ready;

    function automatic packet_build_req_t make_send_packet_req(
        input logic [QP_ID_W-1:0] qpn_i,
        input logic [CQ_ID_W-1:0] cqn_i,
        input logic [VF_ID_W-1:0] owner_i,
        input logic [PD_ID_W-1:0] pd_i,
        input logic [PSN_W-1:0] psn_i,
        input logic [DMA_LEN_W-1:0] len_i,
        input logic [511:0] payload_i
    );
        packet_build_req_t req;
        begin
            req = '0;
            req.desc_id = 16'd0;
            req.qpn = qpn_i;
            req.cqn = cqn_i;
            req.owner_function = owner_i;
            req.pd_id = pd_i;
            req.opcode = ROCE_OPCODE_SEND_ONLY;
            req.dst_mac = 48'h02_00_00_00_00_02;
            req.src_mac = 48'h02_00_00_00_00_01;
            req.src_ipv4 = 32'h0a00_0001;
            req.dst_ipv4 = 32'h0a00_0002;
            req.udp_src_port = ROCEV2_UDP_PORT;
            req.udp_dst_port = ROCEV2_UDP_PORT;
            req.dest_qpn = qpn_i;
            req.psn = psn_i;
            req.payload_data = payload_i;
            req.payload_len = len_i[15:0];
            req.icrc_placeholder = 32'hffff_ffff;
            return req;
        end
    endfunction

    function automatic completion_event_t make_completion(
        input logic is_send_i,
        input logic [QP_ID_W-1:0] qpn_i,
        input logic [CQ_ID_W-1:0] cqn_i,
        input logic [VF_ID_W-1:0] owner_i,
        input logic [WR_ID_W-1:0] wr_id_i,
        input logic [DMA_LEN_W-1:0] len_i,
        input logic solicited_i
    );
        completion_event_t event;
        begin
            event = '0;
            event.event_type = is_send_i ? CMPL_EVENT_SQ : CMPL_EVENT_RQ;
            event.qpn = qpn_i;
            event.cqn = cqn_i;
            event.owner_function = owner_i;
            event.wr_id = wr_id_i;
            event.opcode = RDMA_OP_SEND;
            event.status = CMPL_SUCCESS;
            event.byte_len = len_i;
            event.solicited = solicited_i;
            event.source_engine = is_send_i ? CMPL_SRC_TRANSPORT : CMPL_SRC_RQ;
            return event;
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= RC_PIPE_IDLE;
            active_is_send_q <= 1'b0;
            active_qpn_q <= '0;
            active_cqn_q <= '0;
            active_owner_q <= '0;
            active_pd_q <= '0;
            active_wr_id_q <= '0;
            active_len_q <= '0;
            active_payload_q <= '0;
            active_solicited_q <= 1'b0;
            psn_q <= '0;
            build_req_q <= '0;
            completion_q <= '0;
        end else begin
            unique case (state_q)
                RC_PIPE_IDLE: begin
                    if (send_fire) begin
                        active_is_send_q <= 1'b1;
                        active_qpn_q <= send_qpn;
                        active_cqn_q <= send_cqn;
                        active_owner_q <= send_owner_function;
                        active_pd_q <= send_pd_id;
                        active_wr_id_q <= send_wr_id;
                        active_len_q <= send_payload_len;
                        active_payload_q <= send_payload_data;
                        active_solicited_q <= send_solicited;
                        build_req_q <= make_send_packet_req(send_qpn,
                                                            send_cqn,
                                                            send_owner_function,
                                                            send_pd_id,
                                                            psn_q,
                                                            send_payload_len,
                                                            send_payload_data);
                        completion_q <= make_completion(1'b1,
                                                        send_qpn,
                                                        send_cqn,
                                                        send_owner_function,
                                                        send_wr_id,
                                                        send_payload_len,
                                                        send_solicited);
                        state_q <= RC_PIPE_SEND_DMA_READ;
                    end else if (recv_fire) begin
                        active_is_send_q <= 1'b0;
                        active_qpn_q <= recv_qpn;
                        active_cqn_q <= recv_cqn;
                        active_owner_q <= recv_owner_function;
                        active_pd_q <= recv_pd_id;
                        active_wr_id_q <= recv_wr_id;
                        active_len_q <= recv_payload_len;
                        active_payload_q <= recv_payload_data;
                        active_solicited_q <= recv_solicited;
                        completion_q <= make_completion(1'b0,
                                                        recv_qpn,
                                                        recv_cqn,
                                                        recv_owner_function,
                                                        recv_wr_id,
                                                        recv_payload_len,
                                                        recv_solicited);
                        state_q <= RC_PIPE_RECV_DMA_WRITE;
                    end
                end

                RC_PIPE_SEND_DMA_READ: begin
                    if (dma_read_fire) begin
                        state_q <= RC_PIPE_SEND_PACKET;
                    end
                end

                RC_PIPE_SEND_PACKET: begin
                    if (packet_fire) begin
                        psn_q <= psn_q + 1'b1;
                        state_q <= RC_PIPE_SEND_COMPLETE;
                    end
                end

                RC_PIPE_SEND_COMPLETE,
                RC_PIPE_RECV_COMPLETE: begin
                    if (completion_fire) begin
                        state_q <= RC_PIPE_CQ_COMMIT;
                    end
                end

                RC_PIPE_RECV_DMA_WRITE: begin
                    if (dma_write_fire) begin
                        state_q <= RC_PIPE_RECV_COMPLETE;
                    end
                end

                RC_PIPE_CQ_COMMIT: begin
                    if (cq_commit_fire) begin
                        state_q <= RC_PIPE_IDLE;
                    end
                end

                default: begin
                    state_q <= RC_PIPE_IDLE;
                end
            endcase
        end
    end

    // 保留字段用于后续把真实 QP/MR/DMA metadata 接入本 pipeline。
    logic unused_active_is_send;
    logic [PD_ID_W-1:0] unused_active_pd;
    logic [511:0] unused_active_payload;

    assign unused_active_is_send = active_is_send_q;
    assign unused_active_pd = active_pd_q;
    assign unused_active_payload = active_payload_q;

endmodule : rc_pipeline_top
