// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// 11.5 RDMA Write / RDMA Read 顶层集成胶水。
//
// 该模块把单个 RC RDMA_WRITE / RDMA_READ work request 接到 packet builder、
// 简化 DMA hook 和 completion path。真实 WQE fetch、MR table pipeline、
// PCIe DMA、多 packet response、ACK/NAK 和 retry 逻辑由前面各子模块提供，
// 后续 top-level 集成会逐步替换这里的最小 hook。

`timescale 1ns/1ps

module rdma_write_read_engine
    import smartnic_pkg::*;
#(
    parameter logic [47:0] LOCAL_MAC  = 48'h02_00_00_00_00_01,
    parameter logic [47:0] PEER_MAC   = 48'h02_00_00_00_00_02,
    parameter logic [31:0] LOCAL_IPV4 = 32'h0a00_0001,
    parameter logic [31:0] PEER_IPV4  = 32'h0a00_0002
) (
    input  logic                         clk,
    input  logic                         rst_n,

    // 来自 SQ / testbench 的 RDMA one-sided WR。当前只接受 RDMA_WRITE/RDMA_READ。
    input  logic                         wr_valid,
    output logic                         wr_ready,
    input  rdma_opcode_e                 wr_opcode,
    input  logic [15:0]                  wr_desc_id,
    input  logic [QP_ID_W-1:0]           wr_qpn,
    input  logic [CQ_ID_W-1:0]           wr_cqn,
    input  logic [VF_ID_W-1:0]           wr_owner_function,
    input  logic [PD_ID_W-1:0]           wr_pd_id,
    input  logic [WR_ID_W-1:0]           wr_id,
    input  logic [ADDR_W-1:0]            wr_local_va,
    input  logic [KEY_W-1:0]             wr_lkey,
    input  logic [ADDR_W-1:0]            wr_remote_va,
    input  logic [KEY_W-1:0]             wr_rkey,
    input  logic [DMA_LEN_W-1:0]         wr_len,
    input  logic [511:0]                 wr_payload_data,
    input  logic                         wr_solicited,

    // RDMA Read response 注入 hook。真实 RX parser/transport response path 后续接入。
    input  logic                         read_resp_valid,
    output logic                         read_resp_ready,
    input  logic [QP_ID_W-1:0]           read_resp_qpn,
    input  logic [PSN_W-1:0]             read_resp_psn,
    input  logic [DMA_LEN_W-1:0]         read_resp_len,
    input  logic [511:0]                 read_resp_payload_data,
    input  logic                         read_resp_error,

    // Packet builder request。
    output logic                         packet_build_valid,
    input  logic                         packet_build_ready,
    output packet_build_req_t            packet_build_req,

    // 简化 DMA hook：RDMA Write 读取本地 payload，RDMA Read response 写入本地 buffer。
    output logic                         dma_read_valid,
    input  logic                         dma_read_ready,
    output logic [15:0]                  dma_read_desc_id,
    output logic [QP_ID_W-1:0]           dma_read_qpn,
    output logic [ADDR_W-1:0]            dma_read_local_va,
    output logic [KEY_W-1:0]             dma_read_lkey,
    output logic [DMA_LEN_W-1:0]         dma_read_len,
    output logic                         dma_write_valid,
    input  logic                         dma_write_ready,
    output logic [15:0]                  dma_write_desc_id,
    output logic [QP_ID_W-1:0]           dma_write_qpn,
    output logic [ADDR_W-1:0]            dma_write_local_va,
    output logic [KEY_W-1:0]             dma_write_lkey,
    output logic [DMA_LEN_W-1:0]         dma_write_len,

    // Completion event to completion_engine。
    output logic                         completion_event_valid,
    input  logic                         completion_event_ready,
    output completion_event_t            completion_event,

    output logic                         outstanding_read_valid,
    output logic [PSN_W-1:0]             debug_next_psn,
    output logic [3:0]                   debug_state,
    output cmpl_status_e                 debug_status
);

    typedef enum logic [3:0] {
        RDMA_WR_IDLE            = 4'd0,
        RDMA_WR_VALIDATE        = 4'd1,
        RDMA_WR_DMA_READ        = 4'd2,
        RDMA_WR_PACKET          = 4'd3,
        RDMA_WR_COMPLETE        = 4'd4,
        RDMA_RD_PACKET          = 4'd5,
        RDMA_RD_WAIT_RESPONSE   = 4'd6,
        RDMA_RD_DMA_WRITE       = 4'd7,
        RDMA_RD_COMPLETE        = 4'd8,
        RDMA_WR_ERROR_COMPLETE  = 4'd9
    } rdma_wr_state_e;

    rdma_wr_state_e state_q;
    rdma_opcode_e active_opcode_q;
    logic [15:0] desc_id_q;
    logic [QP_ID_W-1:0] qpn_q;
    logic [CQ_ID_W-1:0] cqn_q;
    logic [VF_ID_W-1:0] owner_q;
    logic [PD_ID_W-1:0] pd_q;
    logic [WR_ID_W-1:0] wr_id_q;
    logic [ADDR_W-1:0] local_va_q;
    logic [KEY_W-1:0] lkey_q;
    logic [ADDR_W-1:0] remote_va_q;
    logic [KEY_W-1:0] rkey_q;
    logic [DMA_LEN_W-1:0] len_q;
    logic [511:0] payload_q;
    logic solicited_q;
    logic [PSN_W-1:0] psn_q;
    logic [PSN_W-1:0] read_psn_q;
    logic [DMA_LEN_W-1:0] read_received_len_q;
    logic [511:0] read_payload_q;
    cmpl_status_e status_q;
    packet_build_req_t packet_q;
    completion_event_t completion_q;

    logic wr_fire;
    logic dma_read_fire;
    logic dma_write_fire;
    logic packet_fire;
    logic read_resp_fire;
    logic completion_fire;
    logic opcode_is_write;
    logic opcode_is_read;
    logic request_invalid;

    assign debug_next_psn = psn_q;
    assign debug_state = state_q;
    assign debug_status = status_q;
    assign outstanding_read_valid = (state_q == RDMA_RD_WAIT_RESPONSE) ||
                                    (state_q == RDMA_RD_DMA_WRITE) ||
                                    (state_q == RDMA_RD_COMPLETE);

    assign wr_ready = (state_q == RDMA_WR_IDLE);
    assign wr_fire = wr_valid && wr_ready;

    assign opcode_is_write = (active_opcode_q == RDMA_OP_RDMA_WRITE) ||
                             (active_opcode_q == RDMA_OP_RDMA_WRITE_WITH_IMM);
    assign opcode_is_read = (active_opcode_q == RDMA_OP_RDMA_READ);
    assign request_invalid = (len_q == '0) ||
                             (lkey_q == '0) ||
                             (rkey_q == '0) ||
                             !(opcode_is_write || opcode_is_read);

    assign dma_read_valid = (state_q == RDMA_WR_DMA_READ);
    assign dma_read_desc_id = desc_id_q;
    assign dma_read_qpn = qpn_q;
    assign dma_read_local_va = local_va_q;
    assign dma_read_lkey = lkey_q;
    assign dma_read_len = len_q;
    assign dma_read_fire = dma_read_valid && dma_read_ready;

    assign dma_write_valid = (state_q == RDMA_RD_DMA_WRITE);
    assign dma_write_desc_id = desc_id_q;
    assign dma_write_qpn = qpn_q;
    assign dma_write_local_va = local_va_q;
    assign dma_write_lkey = lkey_q;
    assign dma_write_len = read_received_len_q;
    assign dma_write_fire = dma_write_valid && dma_write_ready;

    assign packet_build_valid = (state_q == RDMA_WR_PACKET) ||
                                (state_q == RDMA_RD_PACKET);
    assign packet_build_req = packet_q;
    assign packet_fire = packet_build_valid && packet_build_ready;

    assign read_resp_ready = (state_q == RDMA_RD_WAIT_RESPONSE) &&
                             (read_resp_qpn == qpn_q);
    assign read_resp_fire = read_resp_valid && read_resp_ready;

    assign completion_event_valid = (state_q == RDMA_WR_COMPLETE) ||
                                    (state_q == RDMA_RD_COMPLETE) ||
                                    (state_q == RDMA_WR_ERROR_COMPLETE);
    assign completion_event = completion_q;
    assign completion_fire = completion_event_valid && completion_event_ready;

    function automatic packet_build_req_t make_packet_req(
        input rdma_opcode_e opcode_i,
        input logic [15:0] desc_id_i,
        input logic [QP_ID_W-1:0] qpn_i,
        input logic [CQ_ID_W-1:0] cqn_i,
        input logic [VF_ID_W-1:0] owner_i,
        input logic [PD_ID_W-1:0] pd_i,
        input logic [PSN_W-1:0] psn_i,
        input logic [ADDR_W-1:0] remote_va_i,
        input logic [KEY_W-1:0] rkey_i,
        input logic [DMA_LEN_W-1:0] len_i,
        input logic [511:0] payload_i
    );
        packet_build_req_t req;
        begin
            req = '0;
            req.desc_id = desc_id_i;
            req.qpn = qpn_i;
            req.cqn = cqn_i;
            req.owner_function = owner_i;
            req.pd_id = pd_i;
            req.opcode = (opcode_i == RDMA_OP_RDMA_READ) ?
                         ROCE_OPCODE_RDMA_READ_REQ :
                         ROCE_OPCODE_RDMA_WRITE_ONLY;
            req.dst_mac = PEER_MAC;
            req.src_mac = LOCAL_MAC;
            req.src_ipv4 = LOCAL_IPV4;
            req.dst_ipv4 = PEER_IPV4;
            req.udp_src_port = ROCEV2_UDP_PORT;
            req.udp_dst_port = ROCEV2_UDP_PORT;
            req.dest_qpn = qpn_i;
            req.psn = psn_i;
            req.remote_va = remote_va_i;
            req.rkey = rkey_i;
            req.dma_length = len_i;
            req.payload_data = payload_i;
            req.payload_len = (opcode_i == RDMA_OP_RDMA_READ) ? 16'd0 : len_i[15:0];
            req.icrc_placeholder = 32'hffff_ffff;
            return req;
        end
    endfunction

    function automatic completion_event_t make_completion_event(
        input rdma_opcode_e opcode_i,
        input cmpl_status_e status_i,
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
            event.event_type = (status_i == CMPL_SUCCESS) ? CMPL_EVENT_SQ : CMPL_EVENT_ERROR;
            event.qpn = qpn_i;
            event.cqn = cqn_i;
            event.owner_function = owner_i;
            event.wr_id = wr_id_i;
            event.opcode = opcode_i;
            event.status = status_i;
            event.byte_len = len_i;
            event.solicited = solicited_i;
            event.source_engine = (status_i == CMPL_SUCCESS) ? CMPL_SRC_TRANSPORT : CMPL_SRC_ERROR;
            return event;
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= RDMA_WR_IDLE;
            active_opcode_q <= RDMA_OP_NOP;
            desc_id_q <= '0;
            qpn_q <= '0;
            cqn_q <= '0;
            owner_q <= '0;
            pd_q <= '0;
            wr_id_q <= '0;
            local_va_q <= '0;
            lkey_q <= '0;
            remote_va_q <= '0;
            rkey_q <= '0;
            len_q <= '0;
            payload_q <= '0;
            solicited_q <= 1'b0;
            psn_q <= '0;
            read_psn_q <= '0;
            read_received_len_q <= '0;
            read_payload_q <= '0;
            status_q <= CMPL_SUCCESS;
            packet_q <= '0;
            completion_q <= '0;
        end else begin
            unique case (state_q)
                RDMA_WR_IDLE: begin
                    if (wr_fire) begin
                        active_opcode_q <= wr_opcode;
                        desc_id_q <= wr_desc_id;
                        qpn_q <= wr_qpn;
                        cqn_q <= wr_cqn;
                        owner_q <= wr_owner_function;
                        pd_q <= wr_pd_id;
                        wr_id_q <= wr_id;
                        local_va_q <= wr_local_va;
                        lkey_q <= wr_lkey;
                        remote_va_q <= wr_remote_va;
                        rkey_q <= wr_rkey;
                        len_q <= wr_len;
                        payload_q <= wr_payload_data;
                        solicited_q <= wr_solicited;
                        read_received_len_q <= '0;
                        read_payload_q <= '0;
                        status_q <= CMPL_SUCCESS;
                        state_q <= RDMA_WR_VALIDATE;
                    end
                end

                RDMA_WR_VALIDATE: begin
                    if (request_invalid) begin
                        status_q <= (len_q == '0) ? CMPL_LOC_LEN_ERR : CMPL_LOC_PROT_ERR;
                        completion_q <= make_completion_event(active_opcode_q,
                                                              (len_q == '0) ? CMPL_LOC_LEN_ERR : CMPL_LOC_PROT_ERR,
                                                              qpn_q,
                                                              cqn_q,
                                                              owner_q,
                                                              wr_id_q,
                                                              len_q,
                                                              solicited_q);
                        state_q <= RDMA_WR_ERROR_COMPLETE;
                    end else if (opcode_is_write) begin
                        // TODO: 接入 7.4 MR pipeline 后，这里应等待 lkey LOCAL_READ 通过。
                        packet_q <= make_packet_req(active_opcode_q,
                                                    desc_id_q,
                                                    qpn_q,
                                                    cqn_q,
                                                    owner_q,
                                                    pd_q,
                                                    psn_q,
                                                    remote_va_q,
                                                    rkey_q,
                                                    len_q,
                                                    payload_q);
                        state_q <= RDMA_WR_DMA_READ;
                    end else begin
                        // TODO: 接入 QP context 后，RDMA Read request/response PSN 应来自 per-QP PSN。
                        packet_q <= make_packet_req(active_opcode_q,
                                                    desc_id_q,
                                                    qpn_q,
                                                    cqn_q,
                                                    owner_q,
                                                    pd_q,
                                                    psn_q,
                                                    remote_va_q,
                                                    rkey_q,
                                                    len_q,
                                                    '0);
                        read_psn_q <= psn_q;
                        state_q <= RDMA_RD_PACKET;
                    end
                end

                RDMA_WR_DMA_READ: begin
                    if (dma_read_fire) begin
                        state_q <= RDMA_WR_PACKET;
                    end
                end

                RDMA_WR_PACKET: begin
                    if (packet_fire) begin
                        psn_q <= psn_q + {{(PSN_W-1){1'b0}}, 1'b1};
                        completion_q <= make_completion_event(RDMA_OP_RDMA_WRITE,
                                                              CMPL_SUCCESS,
                                                              qpn_q,
                                                              cqn_q,
                                                              owner_q,
                                                              wr_id_q,
                                                              len_q,
                                                              solicited_q);
                        state_q <= RDMA_WR_COMPLETE;
                    end
                end

                RDMA_RD_PACKET: begin
                    if (packet_fire) begin
                        psn_q <= psn_q + {{(PSN_W-1){1'b0}}, 1'b1};
                        state_q <= RDMA_RD_WAIT_RESPONSE;
                    end
                end

                RDMA_RD_WAIT_RESPONSE: begin
                    if (read_resp_fire) begin
                        read_payload_q <= read_resp_payload_data;
                        read_received_len_q <= read_resp_len;
                        if (read_resp_error) begin
                            status_q <= CMPL_DMA_ERR;
                            completion_q <= make_completion_event(RDMA_OP_RDMA_READ,
                                                                  CMPL_DMA_ERR,
                                                                  qpn_q,
                                                                  cqn_q,
                                                                  owner_q,
                                                                  wr_id_q,
                                                                  read_resp_len,
                                                                  solicited_q);
                            state_q <= RDMA_WR_ERROR_COMPLETE;
                        end else if (read_resp_psn != read_psn_q) begin
                            status_q <= CMPL_BAD_RESP_ERR;
                            completion_q <= make_completion_event(RDMA_OP_RDMA_READ,
                                                                  CMPL_BAD_RESP_ERR,
                                                                  qpn_q,
                                                                  cqn_q,
                                                                  owner_q,
                                                                  wr_id_q,
                                                                  read_resp_len,
                                                                  solicited_q);
                            state_q <= RDMA_WR_ERROR_COMPLETE;
                        end else if (read_resp_len != len_q) begin
                            status_q <= CMPL_LOC_LEN_ERR;
                            completion_q <= make_completion_event(RDMA_OP_RDMA_READ,
                                                                  CMPL_LOC_LEN_ERR,
                                                                  qpn_q,
                                                                  cqn_q,
                                                                  owner_q,
                                                                  wr_id_q,
                                                                  read_resp_len,
                                                                  solicited_q);
                            state_q <= RDMA_WR_ERROR_COMPLETE;
                        end else begin
                            state_q <= RDMA_RD_DMA_WRITE;
                        end
                    end
                end

                RDMA_RD_DMA_WRITE: begin
                    if (dma_write_fire) begin
                        completion_q <= make_completion_event(RDMA_OP_RDMA_READ,
                                                              CMPL_SUCCESS,
                                                              qpn_q,
                                                              cqn_q,
                                                              owner_q,
                                                              wr_id_q,
                                                              read_received_len_q,
                                                              solicited_q);
                        state_q <= RDMA_RD_COMPLETE;
                    end
                end

                RDMA_WR_COMPLETE,
                RDMA_RD_COMPLETE,
                RDMA_WR_ERROR_COMPLETE: begin
                    if (completion_fire) begin
                        state_q <= RDMA_WR_IDLE;
                    end
                end

                default: begin
                    state_q <= RDMA_WR_IDLE;
                end
            endcase
        end
    end

endmodule : rdma_write_read_engine
