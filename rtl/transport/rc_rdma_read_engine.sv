`timescale 1ns/1ps

module rc_rdma_read_engine
    import smartnic_pkg::*;
(
    input  logic                         clk,
    input  logic                         rst_n,

    // Responder side QP context snapshot。后续会由 QP context table lookup 驱动。
    input  logic                         responder_ctx_valid,
    input  qp_type_e                     responder_qp_type,
    input  qp_state_e                    responder_qp_state,
    input  logic [VF_ID_W-1:0]           responder_owner_function,
    input  logic [PD_ID_W-1:0]           responder_pd_id,

    // Requester side：来自 SQ engine / DMA dispatch 的 RDMA Read descriptor。
    input  logic                         read_req_valid,
    output logic                         read_req_ready,
    input  rc_rdma_read_req_t            read_req,

    // 输出 RDMA Read Request 给 packet builder / TX path。
    output logic                         read_request_packet_valid,
    input  logic                         read_request_packet_ready,
    output packet_build_req_t            read_request_packet,

    // Responder side：接收入站 RDMA Read Request metadata。
    input  logic                         inbound_read_req_valid,
    output logic                         inbound_read_req_ready,
    input  packet_meta_t                 inbound_read_req_meta,

    // Responder side：MR check pipeline 请求/响应。
    output logic                         mr_check_valid,
    input  logic                         mr_check_ready,
    output logic [KEY_W-1:0]             mr_check_rkey,
    output logic [ADDR_W-1:0]            mr_check_va,
    output logic [DMA_LEN_W-1:0]         mr_check_len,
    output logic [QP_ID_W-1:0]           mr_check_qpn,
    output logic [VF_ID_W-1:0]           mr_check_owner_function,
    output logic [PD_ID_W-1:0]           mr_check_pd_id,
    input  logic                         mr_check_resp_valid,
    output logic                         mr_check_resp_ready,
    input  logic                         mr_check_allowed,
    input  logic [ADDR_W-1:0]            mr_check_physical_addr,
    input  logic [15:0]                  mr_check_error_code,

    // Responder side：DMA host read 请求/响应。
    output logic                         dma_read_req_valid,
    input  logic                         dma_read_req_ready,
    output logic [ADDR_W-1:0]            dma_read_req_addr,
    output logic [DMA_LEN_W-1:0]         dma_read_req_len,
    output logic [15:0]                  dma_read_req_desc_id,
    output logic [QP_ID_W-1:0]           dma_read_req_qpn,
    output logic [VF_ID_W-1:0]           dma_read_req_owner_function,
    input  logic                         dma_read_resp_valid,
    output logic                         dma_read_resp_ready,
    input  logic [511:0]                 dma_read_resp_data,
    input  logic [15:0]                  dma_read_resp_len,
    input  logic                         dma_read_resp_error,
    input  logic                         dma_read_resp_last,

    // Responder side：输出 RDMA Read Response packet。
    output logic                         read_response_packet_valid,
    input  logic                         read_response_packet_ready,
    output packet_build_req_t            read_response_packet,
    output logic                         read_response_first,
    output logic                         read_response_middle,
    output logic                         read_response_last,
    output logic                         read_response_only,

    // Requester response receive side：接收入站 RDMA Read Response。
    input  logic                         inbound_resp_valid,
    output logic                         inbound_resp_ready,
    input  packet_meta_t                 inbound_resp_meta,
    input  logic                         inbound_resp_payload_valid,
    output logic                         inbound_resp_payload_ready,
    input  packet_payload_stream_t       inbound_resp_payload,

    // Requester response receive side：写入本地 buffer。
    output logic                         local_write_valid,
    input  logic                         local_write_ready,
    output rc_rdma_read_local_write_t    local_write,

    // Requester side：所有 response 完成或错误时生成 completion event。
    output logic                         completion_valid,
    input  logic                         completion_ready,
    output completion_event_t            completion_event,

    output rc_rdma_read_outstanding_t    debug_outstanding,
    output rc_rdma_read_status_e         debug_status
);

    typedef enum logic [4:0] {
        READ_STATE_IDLE              = 5'd0,
        READ_STATE_BUILD_REQUEST     = 5'd1,
        READ_STATE_MR_CHECK          = 5'd2,
        READ_STATE_WAIT_MR           = 5'd3,
        READ_STATE_DMA_READ_REQ      = 5'd4,
        READ_STATE_WAIT_DMA          = 5'd5,
        READ_STATE_BUILD_RESPONSE    = 5'd6,
        READ_STATE_WRITE_LOCAL       = 5'd7,
        READ_STATE_COMPLETE          = 5'd8,
        READ_STATE_ERROR_COMPLETE    = 5'd9
    } read_state_e;

    read_state_e state_q;
    rc_rdma_read_outstanding_t outstanding_q;
    rc_rdma_read_req_t req_q;
    packet_meta_t inbound_req_q;
    packet_meta_t resp_meta_q;
    packet_payload_stream_t resp_payload_q;
    packet_build_req_t request_packet_q;
    packet_build_req_t response_packet_q;
    rc_rdma_read_local_write_t local_write_q;
    completion_event_t completion_q;
    rc_rdma_read_status_e status_q;
    logic [ADDR_W-1:0] responder_pa_q;

    logic read_req_fire;
    logic inbound_read_req_fire;
    logic inbound_resp_fire;
    logic request_packet_fire;
    logic mr_check_fire;
    logic mr_resp_fire;
    logic dma_read_req_fire;
    logic dma_read_resp_fire;
    logic response_packet_fire;
    logic local_write_fire;
    logic completion_fire;
    logic [DMA_LEN_W-1:0] remaining_len;
    logic response_len_error;
    logic requester_qp_ok;
    logic responder_qp_ok;

    assign debug_outstanding = outstanding_q;
    assign debug_status = status_q;
    assign remaining_len = outstanding_q.total_len - outstanding_q.received_len;

    assign requester_qp_ok = (read_req.qp_type == QP_TYPE_RC) &&
                             (read_req.qp_state == QP_STATE_RTS);
    assign responder_qp_ok = responder_ctx_valid &&
                             (responder_qp_type == QP_TYPE_RC) &&
                             ((responder_qp_state == QP_STATE_RTR) ||
                              (responder_qp_state == QP_STATE_RTS));

    assign read_req_ready = (state_q == READ_STATE_IDLE) && !outstanding_q.valid;
    assign inbound_read_req_ready = (state_q == READ_STATE_IDLE);
    assign inbound_resp_ready = (state_q == READ_STATE_IDLE) && inbound_resp_payload_valid;
    assign inbound_resp_payload_ready = (state_q == READ_STATE_IDLE) && inbound_resp_valid;

    assign read_req_fire = read_req_valid && read_req_ready;
    assign inbound_read_req_fire = inbound_read_req_valid && inbound_read_req_ready;
    assign inbound_resp_fire = inbound_resp_valid && inbound_resp_ready &&
                               inbound_resp_payload_valid && inbound_resp_payload_ready;

    assign read_request_packet_valid = (state_q == READ_STATE_BUILD_REQUEST);
    assign read_request_packet = request_packet_q;
    assign request_packet_fire = read_request_packet_valid && read_request_packet_ready;

    assign mr_check_valid = (state_q == READ_STATE_MR_CHECK);
    assign mr_check_rkey = inbound_req_q.rkey;
    assign mr_check_va = inbound_req_q.remote_va;
    assign mr_check_len = inbound_req_q.dma_length;
    assign mr_check_qpn = inbound_req_q.dest_qpn;
    assign mr_check_owner_function = inbound_req_q.owner_function;
    assign mr_check_pd_id = responder_pd_id;
    assign mr_check_fire = mr_check_valid && mr_check_ready;
    assign mr_check_resp_ready = (state_q == READ_STATE_WAIT_MR);
    assign mr_resp_fire = mr_check_resp_valid && mr_check_resp_ready;

    assign dma_read_req_valid = (state_q == READ_STATE_DMA_READ_REQ);
    assign dma_read_req_addr = responder_pa_q;
    assign dma_read_req_len = inbound_req_q.dma_length;
    assign dma_read_req_desc_id = inbound_req_q.desc_id;
    assign dma_read_req_qpn = inbound_req_q.dest_qpn;
    assign dma_read_req_owner_function = inbound_req_q.owner_function;
    assign dma_read_req_fire = dma_read_req_valid && dma_read_req_ready;
    assign dma_read_resp_ready = (state_q == READ_STATE_WAIT_DMA);
    assign dma_read_resp_fire = dma_read_resp_valid && dma_read_resp_ready;

    assign read_response_packet_valid = (state_q == READ_STATE_BUILD_RESPONSE);
    assign read_response_packet = response_packet_q;
    assign read_response_first = 1'b1;
    assign read_response_middle = 1'b0;
    assign read_response_last = 1'b1;
    assign read_response_only = 1'b1;
    assign response_packet_fire = read_response_packet_valid && read_response_packet_ready;

    assign response_len_error = (resp_payload_q.valid_bytes == 16'd0) ||
                                (DMA_LEN_W'(resp_payload_q.valid_bytes) > remaining_len);
    assign local_write_valid = (state_q == READ_STATE_WRITE_LOCAL);
    assign local_write = local_write_q;
    assign local_write_fire = local_write_valid && local_write_ready;

    assign completion_valid = (state_q == READ_STATE_COMPLETE) ||
                              (state_q == READ_STATE_ERROR_COMPLETE);
    assign completion_event = completion_q;
    assign completion_fire = completion_valid && completion_ready;

    function automatic packet_build_req_t make_read_request_packet(input rc_rdma_read_req_t req);
        packet_build_req_t p;
        p = '0;
        p.desc_id = req.desc_id;
        p.qpn = req.qpn;
        p.cqn = req.cqn;
        p.owner_function = req.owner_function;
        p.pd_id = req.pd_id;
        p.opcode = ROCE_OPCODE_RDMA_READ_REQ;
        p.status = PKT_BUILD_OK;
        p.dest_qpn = req.remote_qpn;
        p.psn = req.request_psn;
        p.remote_va = req.remote_va;
        p.rkey = req.remote_rkey;
        p.dma_length = req.length;
        return p;
    endfunction

    function automatic packet_build_req_t make_read_response_packet(
        input packet_meta_t meta,
        input logic [511:0] data,
        input logic [15:0] len
    );
        packet_build_req_t p;
        p = '0;
        p.desc_id = meta.desc_id;
        p.qpn = meta.dest_qpn;
        p.cqn = meta.cqn;
        p.owner_function = meta.owner_function;
        p.pd_id = responder_pd_id;
        p.opcode = ROCE_OPCODE_RDMA_READ_RESP;
        p.status = PKT_BUILD_OK;
        p.dest_qpn = meta.src_qpn;
        p.psn = meta.psn + 1'b1;
        p.aeth = 32'h0000_0000;
        p.payload_data = data;
        p.payload_len = len;
        return p;
    endfunction

    function automatic completion_event_t make_completion(
        input rc_rdma_read_outstanding_t ctx,
        input cmpl_status_e cmpl_status,
        input rc_rdma_read_status_e read_status
    );
        completion_event_t c;
        c = '0;
        c.event_type = (cmpl_status == CMPL_SUCCESS) ? CMPL_EVENT_SQ : CMPL_EVENT_ERROR;
        c.qpn = ctx.qpn;
        c.cqn = ctx.cqn;
        c.owner_function = ctx.owner_function;
        c.wr_id = ctx.wr_id;
        c.opcode = RDMA_OP_RDMA_READ;
        c.status = cmpl_status;
        c.byte_len = ctx.received_len;
        c.vendor_error = {27'd0, read_status};
        c.source_engine = CMPL_SRC_TRANSPORT;
        return c;
    endfunction

    function automatic rc_rdma_read_local_write_t make_local_write(
        input rc_rdma_read_outstanding_t ctx,
        input packet_payload_stream_t payload,
        input rc_rdma_read_status_e read_status
    );
        rc_rdma_read_local_write_t w;
        w = '0;
        w.desc_id = ctx.desc_id;
        w.qpn = ctx.qpn;
        w.cqn = ctx.cqn;
        w.owner_function = ctx.owner_function;
        w.pd_id = ctx.pd_id;
        w.wr_id = ctx.wr_id;
        w.local_va = ctx.local_va + ADDR_W'(ctx.received_len);
        w.local_lkey = ctx.local_lkey;
        w.data = payload.data;
        w.byte_len = payload.valid_bytes;
        w.byte_offset = ctx.received_len;
        w.last = (DMA_LEN_W'(payload.valid_bytes) == remaining_len);
        w.status = read_status;
        w.error_code = {11'd0, read_status};
        return w;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= READ_STATE_IDLE;
            outstanding_q <= '0;
            req_q <= '0;
            inbound_req_q <= '0;
            resp_meta_q <= '0;
            resp_payload_q <= '0;
            request_packet_q <= '0;
            response_packet_q <= '0;
            local_write_q <= '0;
            completion_q <= '0;
            status_q <= RC_READ_STATUS_OK;
            responder_pa_q <= '0;
        end else begin
            unique case (state_q)
                READ_STATE_IDLE: begin
                    if (read_req_fire) begin
                        req_q <= read_req;
                        if (outstanding_q.valid) begin
                            status_q <= RC_READ_STATUS_OUTSTANDING_FULL;
                            completion_q <= make_completion(outstanding_q, CMPL_LOC_QP_OP_ERR,
                                                            RC_READ_STATUS_OUTSTANDING_FULL);
                            state_q <= READ_STATE_ERROR_COMPLETE;
                        end else if (read_req.length == '0) begin
                            status_q <= RC_READ_STATUS_LENGTH_MISMATCH;
                            outstanding_q.valid <= 1'b1;
                            outstanding_q.desc_id <= read_req.desc_id;
                            outstanding_q.qpn <= read_req.qpn;
                            outstanding_q.cqn <= read_req.cqn;
                            outstanding_q.owner_function <= read_req.owner_function;
                            outstanding_q.pd_id <= read_req.pd_id;
                            outstanding_q.wr_id <= read_req.wr_id;
                            outstanding_q.total_len <= read_req.length;
                            completion_q <= make_completion(outstanding_q, CMPL_LOC_LEN_ERR,
                                                            RC_READ_STATUS_LENGTH_MISMATCH);
                            state_q <= READ_STATE_ERROR_COMPLETE;
                        end else if (!requester_qp_ok) begin
                            status_q <= (read_req.qp_type != QP_TYPE_RC) ?
                                        RC_READ_STATUS_QP_TYPE_ERR : RC_READ_STATUS_QP_STATE_ERR;
                            outstanding_q.valid <= 1'b1;
                            outstanding_q.desc_id <= read_req.desc_id;
                            outstanding_q.qpn <= read_req.qpn;
                            outstanding_q.cqn <= read_req.cqn;
                            outstanding_q.owner_function <= read_req.owner_function;
                            outstanding_q.pd_id <= read_req.pd_id;
                            outstanding_q.wr_id <= read_req.wr_id;
                            completion_q <= make_completion(outstanding_q, CMPL_LOC_QP_OP_ERR,
                                                            (read_req.qp_type != QP_TYPE_RC) ?
                                                            RC_READ_STATUS_QP_TYPE_ERR :
                                                            RC_READ_STATUS_QP_STATE_ERR);
                            state_q <= READ_STATE_ERROR_COMPLETE;
                        end else begin
                            outstanding_q.valid <= 1'b1;
                            outstanding_q.desc_id <= read_req.desc_id;
                            outstanding_q.qpn <= read_req.qpn;
                            outstanding_q.cqn <= read_req.cqn;
                            outstanding_q.owner_function <= read_req.owner_function;
                            outstanding_q.pd_id <= read_req.pd_id;
                            outstanding_q.wr_id <= read_req.wr_id;
                            outstanding_q.local_va <= read_req.local_va;
                            outstanding_q.local_lkey <= read_req.local_lkey;
                            outstanding_q.total_len <= read_req.length;
                            outstanding_q.received_len <= '0;
                            outstanding_q.next_resp_psn <= read_req.expected_resp_psn;
                            request_packet_q <= make_read_request_packet(read_req);
                            status_q <= RC_READ_STATUS_OK;
                            state_q <= READ_STATE_BUILD_REQUEST;
                        end
                    end else if (inbound_read_req_fire) begin
                        inbound_req_q <= inbound_read_req_meta;
                        if (!responder_qp_ok) begin
                            status_q <= !responder_ctx_valid ? RC_READ_STATUS_QP_LOOKUP_MISS :
                                        ((responder_qp_type != QP_TYPE_RC) ?
                                         RC_READ_STATUS_QP_TYPE_ERR : RC_READ_STATUS_QP_STATE_ERR);
                            state_q <= READ_STATE_ERROR_COMPLETE;
                            completion_q <= '0;
                            completion_q.event_type <= CMPL_EVENT_ERROR;
                            completion_q.qpn <= inbound_read_req_meta.dest_qpn;
                            completion_q.cqn <= inbound_read_req_meta.cqn;
                            completion_q.owner_function <= inbound_read_req_meta.owner_function;
                            completion_q.opcode <= RDMA_OP_RDMA_READ;
                            completion_q.status <= CMPL_LOC_QP_OP_ERR;
                            completion_q.vendor_error <= {27'd0, status_q};
                            completion_q.source_engine <= CMPL_SRC_TRANSPORT;
                        end else begin
                            status_q <= RC_READ_STATUS_OK;
                            state_q <= READ_STATE_MR_CHECK;
                        end
                    end else if (inbound_resp_fire) begin
                        resp_meta_q <= inbound_resp_meta;
                        resp_payload_q <= inbound_resp_payload;
                        if (!outstanding_q.valid) begin
                            status_q <= RC_READ_STATUS_QP_LOOKUP_MISS;
                            completion_q <= '0;
                            completion_q.event_type <= CMPL_EVENT_ERROR;
                            completion_q.qpn <= inbound_resp_meta.dest_qpn;
                            completion_q.cqn <= inbound_resp_meta.cqn;
                            completion_q.owner_function <= inbound_resp_meta.owner_function;
                            completion_q.opcode <= RDMA_OP_RDMA_READ;
                            completion_q.status <= CMPL_BAD_RESP_ERR;
                            completion_q.vendor_error <= {27'd0, RC_READ_STATUS_QP_LOOKUP_MISS};
                            completion_q.source_engine <= CMPL_SRC_TRANSPORT;
                            state_q <= READ_STATE_ERROR_COMPLETE;
                        end else if (inbound_resp_meta.psn != outstanding_q.next_resp_psn) begin
                            status_q <= RC_READ_STATUS_PSN_MISMATCH;
                            completion_q <= make_completion(outstanding_q, CMPL_BAD_RESP_ERR,
                                                            RC_READ_STATUS_PSN_MISMATCH);
                            state_q <= READ_STATE_ERROR_COMPLETE;
                        end else if ((inbound_resp_payload.valid_bytes == 16'd0) ||
                                     (DMA_LEN_W'(inbound_resp_payload.valid_bytes) > remaining_len)) begin
                            status_q <= RC_READ_STATUS_LENGTH_MISMATCH;
                            completion_q <= make_completion(outstanding_q, CMPL_LOC_LEN_ERR,
                                                            RC_READ_STATUS_LENGTH_MISMATCH);
                            state_q <= READ_STATE_ERROR_COMPLETE;
                        end else begin
                            local_write_q <= make_local_write(outstanding_q, inbound_resp_payload,
                                                              RC_READ_STATUS_OK);
                            status_q <= RC_READ_STATUS_OK;
                            state_q <= READ_STATE_WRITE_LOCAL;
                        end
                    end
                end

                READ_STATE_BUILD_REQUEST: begin
                    if (request_packet_fire) begin
                        state_q <= READ_STATE_IDLE;
                    end
                end

                READ_STATE_MR_CHECK: begin
                    if (mr_check_fire) begin
                        state_q <= READ_STATE_WAIT_MR;
                    end
                end

                READ_STATE_WAIT_MR: begin
                    if (mr_resp_fire) begin
                        if (!mr_check_allowed) begin
                            status_q <= (mr_check_error_code == 16'h0006) ?
                                        RC_READ_STATUS_PD_MISMATCH : RC_READ_STATUS_MR_DENIED;
                            completion_q <= '0;
                            completion_q.event_type <= CMPL_EVENT_ERROR;
                            completion_q.qpn <= inbound_req_q.dest_qpn;
                            completion_q.cqn <= inbound_req_q.cqn;
                            completion_q.owner_function <= inbound_req_q.owner_function;
                            completion_q.opcode <= RDMA_OP_RDMA_READ;
                            completion_q.status <= (mr_check_error_code == 16'h0006) ?
                                                   CMPL_LOC_PROT_ERR : CMPL_REM_ACCESS_ERR;
                            completion_q.vendor_error <= {16'd0, mr_check_error_code};
                            completion_q.source_engine <= CMPL_SRC_TRANSPORT;
                            state_q <= READ_STATE_ERROR_COMPLETE;
                        end else begin
                            responder_pa_q <= mr_check_physical_addr;
                            state_q <= READ_STATE_DMA_READ_REQ;
                        end
                    end
                end

                READ_STATE_DMA_READ_REQ: begin
                    if (dma_read_req_fire) begin
                        state_q <= READ_STATE_WAIT_DMA;
                    end
                end

                READ_STATE_WAIT_DMA: begin
                    if (dma_read_resp_fire) begin
                        if (dma_read_resp_error) begin
                            status_q <= RC_READ_STATUS_DMA_READ_ERR;
                            completion_q <= '0;
                            completion_q.event_type <= CMPL_EVENT_ERROR;
                            completion_q.qpn <= inbound_req_q.dest_qpn;
                            completion_q.cqn <= inbound_req_q.cqn;
                            completion_q.owner_function <= inbound_req_q.owner_function;
                            completion_q.opcode <= RDMA_OP_RDMA_READ;
                            completion_q.status <= CMPL_DMA_ERR;
                            completion_q.vendor_error <= {27'd0, RC_READ_STATUS_DMA_READ_ERR};
                            completion_q.source_engine <= CMPL_SRC_TRANSPORT;
                            state_q <= READ_STATE_ERROR_COMPLETE;
                        end else begin
                            response_packet_q <= make_read_response_packet(inbound_req_q,
                                                                           dma_read_resp_data,
                                                                           dma_read_resp_len);
                            status_q <= RC_READ_STATUS_OK;
                            state_q <= READ_STATE_BUILD_RESPONSE;
                        end
                    end
                end

                READ_STATE_BUILD_RESPONSE: begin
                    if (response_packet_fire) begin
                        state_q <= READ_STATE_IDLE;
                    end
                end

                READ_STATE_WRITE_LOCAL: begin
                    if (local_write_fire) begin
                        outstanding_q.received_len <= outstanding_q.received_len +
                                                      DMA_LEN_W'(local_write_q.byte_len);
                        outstanding_q.next_resp_psn <= outstanding_q.next_resp_psn + 1'b1;
                        if (local_write_q.last) begin
                            completion_q <= make_completion(
                                outstanding_q,
                                CMPL_SUCCESS,
                                RC_READ_STATUS_OK
                            );
                            completion_q.byte_len <= outstanding_q.received_len +
                                                     DMA_LEN_W'(local_write_q.byte_len);
                            state_q <= READ_STATE_COMPLETE;
                        end else begin
                            state_q <= READ_STATE_IDLE;
                        end
                    end
                end

                READ_STATE_COMPLETE: begin
                    if (completion_fire) begin
                        outstanding_q <= '0;
                        status_q <= RC_READ_STATUS_OK;
                        state_q <= READ_STATE_IDLE;
                    end
                end

                READ_STATE_ERROR_COMPLETE: begin
                    if (completion_fire) begin
                        outstanding_q <= '0;
                        state_q <= READ_STATE_IDLE;
                    end
                end

                default: begin
                    state_q <= READ_STATE_IDLE;
                end
            endcase
        end
    end

endmodule
