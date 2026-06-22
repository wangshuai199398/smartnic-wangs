`timescale 1ns/1ps

module roce_packet_builder
    import smartnic_pkg::*;
(
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic                  build_req_valid,
    output logic                  build_req_ready,
    input  packet_build_req_t     build_req,

    output logic                  frame_valid,
    input  logic                  frame_ready,
    output logic [511:0]          frame_data,
    output logic [15:0]           frame_len,
    output logic                  frame_last,

    output logic                  build_error_valid,
    input  logic                  build_error_ready,
    output logic [15:0]           build_error_desc_id,
    output logic [QP_ID_W-1:0]    build_error_qpn,
    output logic [CQ_ID_W-1:0]    build_error_cqn,
    output logic [VF_ID_W-1:0]    build_error_owner_function,
    output logic [PD_ID_W-1:0]    build_error_pd_id,
    output roce_opcode_e          build_error_opcode,
    output packet_build_error_e   build_error_code
);

    localparam logic [15:0] ETH_HDR_BYTES  = 16'd14;
    localparam logic [15:0] VLAN_HDR_BYTES = 16'd4;
    localparam logic [15:0] IPV4_HDR_BYTES = 16'd20;
    localparam logic [15:0] UDP_HDR_BYTES  = 16'd8;
    localparam logic [15:0] BTH_HDR_BYTES  = 16'd12;
    localparam logic [15:0] RETH_HDR_BYTES = 16'd16;
    localparam logic [15:0] AETH_HDR_BYTES = 16'd4;
    localparam logic [15:0] DETH_HDR_BYTES = 16'd8;
    localparam logic [15:0] IMM_HDR_BYTES  = 16'd4;
    localparam logic [15:0] ICRC_BYTES     = 16'd4;

    packet_build_req_t   req_q;
    logic                holding_q;
    logic                error_path_q;
    logic [511:0]        frame_q;
    logic [15:0]         frame_len_q;
    packet_build_error_e error_q;

    logic [511:0]        frame_next;
    logic [15:0]         l2_len;
    logic [15:0]         ext_len;
    logic [15:0]         header_len;
    logic [15:0]         ip_total_len;
    logic [15:0]         udp_len;
    logic [15:0]         total_len;
    logic [15:0]         payload_offset;
    logic [9:0]          payload_shift;
    logic                supported_opcode;
    logic                needs_reth;
    logic                needs_aeth;
    logic                needs_deth;
    logic                needs_imm;
    packet_build_error_e error_next;
    logic                out_ready;

    assign out_ready = error_path_q ? build_error_ready : frame_ready;
    assign build_req_ready = !holding_q || out_ready;

    assign frame_valid = holding_q && !error_path_q;
    assign frame_data  = frame_q;
    assign frame_len   = frame_len_q;
    assign frame_last  = 1'b1;

    assign build_error_valid          = holding_q && error_path_q;
    assign build_error_desc_id        = req_q.desc_id;
    assign build_error_qpn            = req_q.qpn;
    assign build_error_cqn            = req_q.cqn;
    assign build_error_owner_function = req_q.owner_function;
    assign build_error_pd_id          = req_q.pd_id;
    assign build_error_opcode         = req_q.opcode;
    assign build_error_code           = error_q;

    always_comb begin
        supported_opcode = 1'b0;
        needs_reth = 1'b0;
        needs_aeth = 1'b0;
        needs_deth = 1'b0;
        needs_imm  = build_req.has_imm;
        unique case (build_req.opcode)
            ROCE_OPCODE_SEND_ONLY: begin
                supported_opcode = 1'b1;
            end
            ROCE_OPCODE_SEND_ONLY_IMM: begin
                supported_opcode = 1'b1;
                needs_imm = 1'b1;
            end
            ROCE_OPCODE_RDMA_WRITE_ONLY,
            ROCE_OPCODE_RDMA_READ_REQ: begin
                supported_opcode = 1'b1;
                needs_reth = 1'b1;
            end
            ROCE_OPCODE_RDMA_READ_RESP,
            ROCE_OPCODE_ACK: begin
                supported_opcode = 1'b1;
                needs_aeth = 1'b1;
            end
            ROCE_OPCODE_UD_SEND_ONLY: begin
                supported_opcode = 1'b1;
                needs_deth = 1'b1;
            end
            ROCE_OPCODE_CNP: begin
                supported_opcode = 1'b1;
            end
            default: begin
                supported_opcode = 1'b0;
            end
        endcase

        ext_len = (needs_reth ? RETH_HDR_BYTES : 16'd0)
                + (needs_aeth ? AETH_HDR_BYTES : 16'd0)
                + (needs_deth ? DETH_HDR_BYTES : 16'd0)
                + (needs_imm  ? IMM_HDR_BYTES  : 16'd0);
        l2_len = ETH_HDR_BYTES + (build_req.has_vlan ? VLAN_HDR_BYTES : 16'd0);
        header_len = l2_len + IPV4_HDR_BYTES + UDP_HDR_BYTES + BTH_HDR_BYTES + ext_len;
        payload_offset = header_len;
        ip_total_len = IPV4_HDR_BYTES + UDP_HDR_BYTES + BTH_HDR_BYTES + ext_len
                     + build_req.payload_len + ICRC_BYTES;
        udp_len = UDP_HDR_BYTES + BTH_HDR_BYTES + ext_len + build_req.payload_len + ICRC_BYTES;
        total_len = l2_len + ip_total_len;

        frame_next = '0;
        frame_next[47:0]   = build_req.dst_mac;
        frame_next[95:48]  = build_req.src_mac;
        frame_next[111:96] = build_req.has_vlan ? ETH_TYPE_VLAN : ETH_TYPE_IPV4;

        if (build_req.has_vlan) begin
            frame_next[127:112] = build_req.vlan_tci;
            frame_next[143:128] = ETH_TYPE_IPV4;
            frame_next[151:148] = IPV4_VERSION;
            frame_next[147:144] = IPV4_MIN_IHL;
            frame_next[175:160] = ip_total_len;
            frame_next[223:216] = IP_PROTO_UDP;
            frame_next[271:240] = build_req.src_ipv4;
            frame_next[303:272] = build_req.dst_ipv4;
            frame_next[319:304] = build_req.udp_src_port;
            frame_next[335:320] = (build_req.udp_dst_port == 16'd0) ? ROCEV2_UDP_PORT : build_req.udp_dst_port;
            frame_next[351:344] = build_req.opcode;
            frame_next[355:352] = BTH_TRANSPORT_VER;
            frame_next[367:352] = build_req.pkey;
            frame_next[383:360] = build_req.dest_qpn;
            frame_next[415:392] = build_req.psn;
            frame_next[479:416] = build_req.remote_va;
            frame_next[511:480] = build_req.rkey;
        end else begin
            frame_next[119:116] = IPV4_VERSION;
            frame_next[115:112] = IPV4_MIN_IHL;
            frame_next[143:128] = ip_total_len;
            frame_next[191:184] = IP_PROTO_UDP;
            frame_next[239:208] = build_req.src_ipv4;
            frame_next[271:240] = build_req.dst_ipv4;
            frame_next[287:272] = build_req.udp_src_port;
            frame_next[303:288] = (build_req.udp_dst_port == 16'd0) ? ROCEV2_UDP_PORT : build_req.udp_dst_port;
            frame_next[319:312] = build_req.opcode;
            frame_next[323:320] = BTH_TRANSPORT_VER;
            frame_next[335:320] = build_req.pkey;
            frame_next[351:328] = build_req.dest_qpn;
            frame_next[383:360] = build_req.psn;

            if (needs_reth) begin
                frame_next[447:384] = build_req.remote_va;
                frame_next[479:448] = build_req.rkey;
                frame_next[511:480] = build_req.dma_length;
            end else if (needs_aeth) begin
                frame_next[415:384] = build_req.aeth;
            end else if (needs_deth) begin
                frame_next[415:384] = build_req.qkey;
                frame_next[447:424] = build_req.src_qpn;
            end else if (needs_imm) begin
                frame_next[415:384] = build_req.imm_data;
            end
        end

        // TODO 8.5: ICRC 当前使用请求中的 placeholder，不做真实 invariant CRC 计算。
        if (!build_req.has_vlan && (payload_offset + ICRC_BYTES <= 16'd64)) begin
            payload_shift = {4'd0, payload_offset[5:0]} << 3;
            frame_next = frame_next | (build_req.payload_data << payload_shift);
            frame_next[511:480] = build_req.icrc_placeholder;
        end

        error_next = PKT_BUILD_OK;
        if (!supported_opcode) begin
            error_next = PKT_BUILD_ERR_UNSUPPORTED;
        end else if (total_len > 16'd64) begin
            // 当前最小 builder 只输出单个 512-bit frame beat。
            error_next = PKT_BUILD_ERR_MULTI_BEAT_STUB;
        end else if (payload_offset + build_req.payload_len + ICRC_BYTES > total_len) begin
            error_next = PKT_BUILD_ERR_LENGTH;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            holding_q    <= 1'b0;
            error_path_q <= 1'b0;
            req_q        <= '0;
            frame_q      <= '0;
            frame_len_q  <= 16'd0;
            error_q      <= PKT_BUILD_OK;
        end else begin
            if (holding_q && out_ready) begin
                holding_q <= 1'b0;
            end

            if (build_req_valid && build_req_ready) begin
                holding_q    <= 1'b1;
                error_path_q <= (error_next != PKT_BUILD_OK);
                req_q        <= build_req;
                frame_q      <= frame_next;
                frame_len_q  <= total_len;
                error_q      <= error_next;
            end
        end
    end

endmodule
