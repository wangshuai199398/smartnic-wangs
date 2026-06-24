`timescale 1ns/1ps

module roce_packet_parser
    import smartnic_pkg::*;
(
    input  logic                 clk,
    input  logic                 rst_n,

    // 入站帧接口。8.1 只解析首个 512-bit beat，完整多 beat payload 提取留给 8.3。
    input  logic                 frame_valid,
    output logic                 frame_ready,
    input  logic [511:0]         frame_data,
    input  logic [15:0]          frame_len,
    input  logic                 frame_last,

    // 上游透传上下文，用于把解析结果关联回 QP/CQ/MR/DMA/完成路径。
    input  logic [15:0]          desc_id,
    input  logic [QP_ID_W-1:0]   qpn,
    input  logic [CQ_ID_W-1:0]   cqn,
    input  logic [VF_ID_W-1:0]   owner_function,
    input  logic [PD_ID_W-1:0]   pd_id,

    // 解析后的 packet metadata。8.1 不做协议合法性判断；8.2 负责 drop/validate。
    output logic                 meta_valid,
    input  logic                 meta_ready,
    output packet_meta_t         meta,
    output packet_parse_status_e parse_status,
    output logic [15:0]          error_code
);

    localparam logic [15:0] ETH_BASE_HDR_BYTES = 16'd14;
    localparam logic [15:0] VLAN_HDR_BYTES     = 16'd4;
    localparam logic [15:0] IPV4_HDR_BYTES     = 16'd20;
    localparam logic [15:0] UDP_HDR_BYTES      = 16'd8;
    localparam logic [15:0] BTH_HDR_BYTES      = 16'd12;
    localparam logic [15:0] RETH_HDR_BYTES     = 16'd16;
    localparam logic [15:0] AETH_HDR_BYTES     = 16'd4;
    localparam logic [15:0] DETH_HDR_BYTES     = 16'd8;
    localparam logic [15:0] IMM_HDR_BYTES      = 16'd4;
    localparam logic [15:0] ICRC_BYTES         = 16'd4;

    packet_meta_t         meta_q;
    packet_parse_status_e status_q;
    logic [15:0]          error_q;

    packet_meta_t         meta_next;
    packet_parse_status_e status_next;
    logic [15:0]          error_next;

    logic                 accept_frame;
    logic                 vlan_present;
    logic [15:0]          inner_ethertype;
    logic [15:0]          vlan_tci;
    logic [15:0]          roce_header_offset;
    logic [15:0]          ext_header_bytes;
    logic [15:0]          payload_offset_calc;
    logic [15:0]          min_roce_frame_len;
    logic [7:0]           opcode_raw;
    logic [7:0]           ingress_dsfield;
    logic                 ingress_ecn_valid;

    assign frame_ready  = !meta_valid || meta_ready;
    assign accept_frame = frame_valid && frame_ready;
    assign meta         = meta_q;
    assign parse_status = status_q;
    assign error_code   = error_q;

    always_comb begin
        vlan_present      = (frame_data[111:96] == ETH_TYPE_VLAN) || (frame_data[111:96] == ETH_TYPE_QINQ);
        inner_ethertype   = vlan_present ? frame_data[143:128] : frame_data[111:96];
        vlan_tci          = vlan_present ? frame_data[127:112] : 16'h0000;
        ingress_dsfield   = 8'h00;
        ingress_ecn_valid = 1'b0;
        roce_header_offset = ETH_BASE_HDR_BYTES + (vlan_present ? VLAN_HDR_BYTES : 16'd0)
                           + IPV4_HDR_BYTES + UDP_HDR_BYTES + BTH_HDR_BYTES;

        // 8.1 只根据 opcode 标记扩展头存在性；完整 opcode 合法性和长度校验留给 8.2。
        opcode_raw        = vlan_present ? frame_data[351:344] : frame_data[319:312];
        ext_header_bytes  = 16'd0;
        unique case (opcode_raw)
            ROCE_OPCODE_RDMA_WRITE_ONLY,
            ROCE_OPCODE_RDMA_READ_REQ:  ext_header_bytes = RETH_HDR_BYTES;
            ROCE_OPCODE_RDMA_READ_RESP,
            ROCE_OPCODE_ACK:            ext_header_bytes = AETH_HDR_BYTES;
            ROCE_OPCODE_SEND_ONLY_IMM:  ext_header_bytes = IMM_HDR_BYTES;
            ROCE_OPCODE_UD_SEND_ONLY:   ext_header_bytes = DETH_HDR_BYTES;
            default:                    ext_header_bytes = 16'd0;
        endcase

        payload_offset_calc = roce_header_offset + ext_header_bytes;
        min_roce_frame_len  = roce_header_offset + ICRC_BYTES;

        meta_next = '0;
        meta_next.desc_id        = desc_id;
        meta_next.qpn            = qpn;
        meta_next.cqn            = cqn;
        meta_next.owner_function = owner_function;
        meta_next.pd_id          = pd_id;
        meta_next.opcode         = roce_opcode_e'(opcode_raw);
        meta_next.frame_len      = frame_len;
        meta_next.ethertype      = inner_ethertype;
        meta_next.has_vlan       = vlan_present;
        meta_next.vlan_tci       = vlan_tci;
        meta_next.payload_offset = payload_offset_calc;
        meta_next.icrc           = frame_data[511:480];

        if (vlan_present) begin
            meta_next.ip_version  = frame_data[151:148];
            meta_next.ip_ihl      = frame_data[147:144];
            if (inner_ethertype == ETH_TYPE_IPV6) begin
                ingress_dsfield   = frame_data[147:140];
                ingress_ecn_valid = 1'b1;
            end else begin
                ingress_dsfield   = frame_data[159:152];
                ingress_ecn_valid = (inner_ethertype == ETH_TYPE_IPV4);
            end
            meta_next.ip_total_length = frame_data[175:160];
            meta_next.ip_protocol = frame_data[223:216];
            meta_next.ip_checksum = frame_data[239:224];
            meta_next.ipv4_src     = frame_data[271:240];
            meta_next.ipv4_dst     = frame_data[303:272];
            meta_next.udp_src_port = frame_data[319:304];
            meta_next.udp_dst_port = frame_data[335:320];
            meta_next.udp_length   = 16'd0;
            meta_next.udp_checksum = 16'd0;
            meta_next.bth_transport_version = frame_data[355:352];
            meta_next.pkey         = frame_data[367:352];
            meta_next.dest_qpn     = frame_data[383:360];
            meta_next.psn          = frame_data[415:392];

            // VLAN 布局下首个 512-bit beat 只能容纳 RETH 的 remote_va/rkey，
            // RETH length 可能落在下一 beat；完整多 beat 解析留给 8.3。
            meta_next.remote_va    = frame_data[479:416];
            meta_next.rkey         = frame_data[511:480];
            meta_next.aeth         = frame_data[447:416];
            meta_next.qkey         = frame_data[447:416];
            meta_next.src_qpn      = frame_data[479:456];
            meta_next.imm_data     = frame_data[447:416];
        end else begin
            meta_next.ip_version  = frame_data[119:116];
            meta_next.ip_ihl      = frame_data[115:112];
            if (inner_ethertype == ETH_TYPE_IPV6) begin
                ingress_dsfield   = frame_data[115:108];
                ingress_ecn_valid = 1'b1;
            end else begin
                ingress_dsfield   = frame_data[127:120];
                ingress_ecn_valid = (inner_ethertype == ETH_TYPE_IPV4);
            end
            meta_next.ip_total_length = frame_data[143:128];
            meta_next.ip_protocol = frame_data[191:184];
            meta_next.ip_checksum = frame_data[207:192];
            meta_next.ipv4_src     = frame_data[239:208];
            meta_next.ipv4_dst     = frame_data[271:240];
            meta_next.udp_src_port = frame_data[287:272];
            meta_next.udp_dst_port = frame_data[303:288];
            meta_next.udp_length   = 16'd0;
            meta_next.udp_checksum = 16'd0;
            meta_next.bth_transport_version = frame_data[323:320];
            meta_next.pkey         = frame_data[335:320];
            meta_next.dest_qpn     = frame_data[351:328];
            meta_next.psn          = frame_data[383:360];
            meta_next.remote_va    = frame_data[447:384];
            meta_next.rkey         = frame_data[479:448];
            meta_next.dma_length   = frame_data[511:480];
            meta_next.aeth         = frame_data[415:384];
            meta_next.qkey         = frame_data[415:384];
            meta_next.src_qpn      = frame_data[447:424];
            meta_next.imm_data     = frame_data[415:384];
        end

        meta_next.ip_dsfield = ingress_dsfield;
        meta_next.ipv6_traffic_class = (inner_ethertype == ETH_TYPE_IPV6) ? ingress_dsfield : 8'h00;
        meta_next.ecn = ingress_dsfield[1:0];
        meta_next.ecn_valid = ingress_ecn_valid;
        meta_next.ecn_ce = ingress_ecn_valid && (ingress_dsfield[1:0] == ECN_CE);

        meta_next.has_reth = (opcode_raw == ROCE_OPCODE_RDMA_WRITE_ONLY) ||
                             (opcode_raw == ROCE_OPCODE_RDMA_WRITE_ONLY_IMM) ||
                             (opcode_raw == ROCE_OPCODE_RDMA_READ_REQ);
        meta_next.has_aeth = (opcode_raw == ROCE_OPCODE_RDMA_READ_RESP) ||
                             (opcode_raw == ROCE_OPCODE_ACK);
        meta_next.has_deth = (opcode_raw == ROCE_OPCODE_UD_SEND_ONLY);
        meta_next.has_imm  = (opcode_raw == ROCE_OPCODE_SEND_ONLY_IMM) ||
                             (opcode_raw == ROCE_OPCODE_RDMA_WRITE_ONLY_IMM);

        if (frame_len > payload_offset_calc + ICRC_BYTES) begin
            meta_next.payload_len = frame_len - payload_offset_calc - ICRC_BYTES;
        end else begin
            meta_next.payload_len = 16'd0;
        end

        status_next = PKT_PARSE_STATUS_OK;
        error_next  = 16'h0000;
        if (!frame_last) begin
            status_next = PKT_PARSE_STATUS_NEED_MORE_DATA;
            error_next  = 16'h0001;
        end else if (frame_len < min_roce_frame_len) begin
            status_next = PKT_PARSE_STATUS_SHORT_FRAME;
            error_next  = 16'h0002;
        end else if (inner_ethertype == ETH_TYPE_IPV6) begin
            // TODO: 10.x 后续阶段再实现完整 IPv6 RoCEv2 header layout。
            // 10.1 只要求 ingress ECN/CE detection，因此仍保留 ECN metadata。
            status_next = PKT_PARSE_STATUS_UNSUPPORTED_LAYOUT;
            error_next  = 16'h0003;
        end
        meta_next.status = status_next;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            meta_valid <= 1'b0;
            meta_q     <= '0;
            status_q   <= PKT_PARSE_STATUS_OK;
            error_q    <= 16'h0000;
        end else begin
            if (meta_valid && meta_ready) begin
                meta_valid <= 1'b0;
            end

            if (accept_frame) begin
                meta_valid <= 1'b1;
                meta_q     <= meta_next;
                status_q   <= status_next;
                error_q    <= error_next;
            end
        end
    end

endmodule
