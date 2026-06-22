`timescale 1ns/1ps

module roce_ingress_validator
    import smartnic_pkg::*;
(
    input  logic                     clk,
    input  logic                     rst_n,

    // 来自 8.1 parser 的 metadata 输入。
    input  logic                     meta_valid,
    output logic                     meta_ready,
    input  packet_meta_t             meta_in,

    // 校验和结果输入。真实 checksum 计算器后续可替换该 stub 接口。
    input  logic                     checksum_valid,
    input  logic                     checksum_ok,

    // 通过校验的 metadata，供 8.3 payload extraction / transport RX 使用。
    output logic                     validated_valid,
    input  logic                     validated_ready,
    output packet_meta_t             validated_meta,

    // 被拒绝的 metadata，供 drop counter/debug/error path 使用。
    output logic                     drop_valid,
    input  logic                     drop_ready,
    output packet_meta_t             drop_meta,
    output packet_validation_error_e validation_error,
    output logic [15:0]              error_code
);

    localparam logic [15:0] ETH_HDR_BYTES  = 16'd14;
    localparam logic [15:0] VLAN_HDR_BYTES = 16'd4;
    localparam logic [15:0] IPV4_HDR_BYTES = 16'd20;
    localparam logic [15:0] UDP_HDR_BYTES  = 16'd8;
    localparam logic [15:0] BTH_HDR_BYTES  = 16'd12;
    localparam logic [15:0] ICRC_BYTES     = 16'd4;

    packet_meta_t             meta_q;
    packet_validation_error_e error_q;
    logic                     holding_q;
    logic                     drop_q;

    packet_validation_error_e error_next;
    logic                     is_supported_opcode;
    logic [15:0]              l2_header_len;
    logic [15:0]              min_payload_offset;
    logic [15:0]              min_frame_len;
    logic [15:0]              expected_ip_total_length;
    logic [15:0]              min_udp_length;
    logic                     out_ready;

    assign validated_valid = holding_q && !drop_q;
    assign drop_valid      = holding_q && drop_q;
    assign validated_meta  = meta_q;
    assign drop_meta       = meta_q;
    assign validation_error = error_q;
    assign error_code      = {11'd0, error_q};
    assign out_ready       = drop_q ? drop_ready : validated_ready;
    assign meta_ready      = !holding_q || out_ready;

    always_comb begin
        is_supported_opcode = 1'b0;
        unique case (meta_in.opcode)
            ROCE_OPCODE_SEND_ONLY,
            ROCE_OPCODE_SEND_ONLY_IMM,
            ROCE_OPCODE_RDMA_WRITE_ONLY,
            ROCE_OPCODE_RDMA_READ_REQ,
            ROCE_OPCODE_RDMA_READ_RESP,
            ROCE_OPCODE_ACK,
            ROCE_OPCODE_CNP,
            ROCE_OPCODE_UD_SEND_ONLY: is_supported_opcode = 1'b1;
            default:                  is_supported_opcode = 1'b0;
        endcase

        l2_header_len = ETH_HDR_BYTES + (meta_in.has_vlan ? VLAN_HDR_BYTES : 16'd0);
        min_payload_offset = l2_header_len + IPV4_HDR_BYTES + UDP_HDR_BYTES + BTH_HDR_BYTES;
        min_frame_len = min_payload_offset + ICRC_BYTES;
        expected_ip_total_length = (meta_in.frame_len > l2_header_len)
                                 ? (meta_in.frame_len - l2_header_len)
                                 : 16'd0;
        min_udp_length = UDP_HDR_BYTES + BTH_HDR_BYTES + meta_in.payload_len + ICRC_BYTES;

        error_next = PKT_VALIDATION_OK;

        if (meta_in.status != PKT_PARSE_STATUS_OK) begin
            error_next = PKT_VALIDATION_ERR_PARSE;
        end else if (meta_in.ethertype != ETH_TYPE_IPV4) begin
            error_next = PKT_VALIDATION_ERR_ETHERTYPE;
        end else if (meta_in.ip_version != IPV4_VERSION) begin
            error_next = PKT_VALIDATION_ERR_IP_VERSION;
        end else if (meta_in.ip_ihl != IPV4_MIN_IHL) begin
            // TODO: 后续可支持 IPv4 options；当前只允许 20B header。
            error_next = PKT_VALIDATION_ERR_IHL;
        end else if (meta_in.ip_protocol != IP_PROTO_UDP) begin
            error_next = PKT_VALIDATION_ERR_PROTOCOL;
        end else if (meta_in.udp_dst_port != ROCEV2_UDP_PORT) begin
            error_next = PKT_VALIDATION_ERR_UDP_PORT;
        end else if (meta_in.bth_transport_version != BTH_TRANSPORT_VER) begin
            error_next = PKT_VALIDATION_ERR_BTH_VERSION;
        end else if (!is_supported_opcode) begin
            error_next = PKT_VALIDATION_ERR_OPCODE;
        end else if (!checksum_valid || !checksum_ok) begin
            // TODO: 8.2 只消费 checksum checker 的结果；checksum/ICRC 计算器后续单独实现。
            error_next = PKT_VALIDATION_ERR_CHECKSUM;
        end else if (meta_in.frame_len < min_frame_len) begin
            error_next = PKT_VALIDATION_ERR_LENGTH;
        end else if (meta_in.payload_offset < min_payload_offset) begin
            error_next = PKT_VALIDATION_ERR_LENGTH;
        end else if (meta_in.payload_offset + meta_in.payload_len + ICRC_BYTES > meta_in.frame_len) begin
            error_next = PKT_VALIDATION_ERR_LENGTH;
        end else if (meta_in.ip_total_length != expected_ip_total_length) begin
            error_next = PKT_VALIDATION_ERR_LENGTH;
        end else if (meta_in.ip_total_length < IPV4_HDR_BYTES + UDP_HDR_BYTES + BTH_HDR_BYTES) begin
            error_next = PKT_VALIDATION_ERR_LENGTH;
        end else if (meta_in.udp_length < min_udp_length) begin
            error_next = PKT_VALIDATION_ERR_LENGTH;
        end else if (meta_in.udp_length > meta_in.ip_total_length - IPV4_HDR_BYTES) begin
            error_next = PKT_VALIDATION_ERR_LENGTH;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            holding_q <= 1'b0;
            drop_q    <= 1'b0;
            meta_q    <= '0;
            error_q   <= PKT_VALIDATION_OK;
        end else begin
            if (holding_q && out_ready) begin
                holding_q <= 1'b0;
            end

            if (meta_valid && meta_ready) begin
                holding_q <= 1'b1;
                drop_q    <= (error_next != PKT_VALIDATION_OK);
                meta_q    <= meta_in;
                error_q   <= error_next;
            end
        end
    end

endmodule
