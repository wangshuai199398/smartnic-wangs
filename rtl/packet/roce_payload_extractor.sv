`timescale 1ns/1ps

module roce_payload_extractor
    import smartnic_pkg::*;
(
    input  logic                    clk,
    input  logic                    rst_n,

    // 来自 8.2 validator 的 metadata。
    input  logic                    meta_valid,
    output logic                    meta_ready,
    input  packet_meta_t            meta_in,

    // 与 metadata 对应的入站 frame beat。8.3 最小版本只处理单 beat payload。
    input  logic                    frame_valid,
    output logic                    frame_ready,
    input  logic [511:0]            frame_data,
    input  logic [15:0]             frame_len,
    input  logic                    frame_last,

    // 送往后续 transport RX 的 metadata。第 9 阶段会真正消费该接口。
    output logic                    transport_meta_valid,
    input  logic                    transport_meta_ready,
    output packet_meta_t            transport_meta,

    // 送往 receive DMA/RQ path 的 payload stream。真实 Recv DMA 连接留给后续集成。
    output logic                    rx_payload_valid,
    input  logic                    rx_payload_ready,
    output packet_payload_stream_t  rx_payload,

    // 结构性错误输出。已通过 8.2 validation 的包通常不会走到这里。
    output logic                    extract_error_valid,
    input  logic                    extract_error_ready,
    output logic [15:0]             extract_error_desc_id,
    output logic [QP_ID_W-1:0]      extract_error_qpn,
    output logic [CQ_ID_W-1:0]      extract_error_cqn,
    output logic [VF_ID_W-1:0]      extract_error_owner_function,
    output logic [PD_ID_W-1:0]      extract_error_pd_id,
    output roce_opcode_e            extract_error_opcode,
    output packet_payload_error_e   extract_error_code
);

    localparam logic [15:0] ICRC_BYTES = 16'd4;

    packet_meta_t           meta_q;
    packet_payload_stream_t payload_q;
    packet_payload_error_e  error_q;
    logic                   holding_q;
    logic                   error_path_q;
    logic                   payload_needed_q;

    packet_payload_stream_t payload_next;
    packet_payload_error_e  error_next;
    logic                   error_path_next;
    logic                   payload_needed_next;
    logic [15:0]            available_payload_bytes;
    logic [15:0]            payload_end;
    logic [9:0]             shift_bits;
    logic                   out_ready;
    logic                   can_accept;

    assign out_ready = error_path_q ? extract_error_ready
                     : (transport_meta_ready && (!payload_needed_q || rx_payload_ready));
    assign can_accept = !holding_q || out_ready;
    assign meta_ready = can_accept && frame_valid;
    assign frame_ready = can_accept && meta_valid;

    assign transport_meta_valid = holding_q && !error_path_q;
    assign transport_meta       = meta_q;
    assign rx_payload_valid     = holding_q && !error_path_q && payload_needed_q;
    assign rx_payload           = payload_q;

    assign extract_error_valid          = holding_q && error_path_q;
    assign extract_error_desc_id        = meta_q.desc_id;
    assign extract_error_qpn            = meta_q.qpn;
    assign extract_error_cqn            = meta_q.cqn;
    assign extract_error_owner_function = meta_q.owner_function;
    assign extract_error_pd_id          = meta_q.pd_id;
    assign extract_error_opcode         = meta_q.opcode;
    assign extract_error_code           = error_q;

    always_comb begin
        payload_next = '0;
        payload_next.desc_id        = meta_in.desc_id;
        payload_next.qpn            = meta_in.qpn;
        payload_next.cqn            = meta_in.cqn;
        payload_next.owner_function = meta_in.owner_function;
        payload_next.pd_id          = meta_in.pd_id;
        payload_next.opcode         = meta_in.opcode;
        payload_next.status         = PKT_PAYLOAD_OK;
        payload_next.error_code     = 16'h0000;
        payload_next.payload_len    = meta_in.payload_len;
        payload_next.valid_bytes    = meta_in.payload_len;
        payload_next.byte_offset    = 16'd0;
        payload_next.first          = 1'b1;
        payload_next.last           = 1'b1;
        payload_next.has_imm        = meta_in.has_imm;
        payload_next.imm_data       = meta_in.imm_data;
        payload_next.remote_va      = meta_in.remote_va;
        payload_next.rkey           = meta_in.rkey;
        payload_next.dma_length     = meta_in.dma_length;
        payload_next.dest_qpn       = meta_in.dest_qpn;
        payload_next.psn            = meta_in.psn;

        shift_bits = {4'd0, meta_in.payload_offset[5:0]} << 3;
        payload_next.data = frame_data >> shift_bits;

        payload_end = meta_in.payload_offset + meta_in.payload_len + ICRC_BYTES;
        available_payload_bytes = (meta_in.payload_offset < 16'd64)
                                ? (16'd64 - meta_in.payload_offset)
                                : 16'd0;

        error_next = PKT_PAYLOAD_OK;
        error_path_next = 1'b0;
        payload_needed_next = (meta_in.payload_len != 16'd0);

        if (meta_in.status != PKT_PARSE_STATUS_OK) begin
            error_next = PKT_PAYLOAD_ERR_META_STATUS;
            error_path_next = 1'b1;
        end else if (!frame_last) begin
            // TODO: 后续 8.3 增量可扩展为多 beat payload reassembly。
            error_next = PKT_PAYLOAD_ERR_FRAME_NOT_LAST;
            error_path_next = 1'b1;
        end else if (frame_len != meta_in.frame_len) begin
            error_next = PKT_PAYLOAD_ERR_LENGTH;
            error_path_next = 1'b1;
        end else if (payload_end > frame_len) begin
            error_next = PKT_PAYLOAD_ERR_LENGTH;
            error_path_next = 1'b1;
        end else if (meta_in.payload_len > available_payload_bytes) begin
            // 当前最小版本只支持首个 512-bit beat 内的 payload。
            error_next = PKT_PAYLOAD_ERR_MULTI_BEAT_STUB;
            error_path_next = 1'b1;
        end

        if (error_path_next) begin
            payload_next.status = error_next;
            payload_next.error_code = {11'd0, error_next};
            payload_needed_next = 1'b0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            holding_q        <= 1'b0;
            error_path_q     <= 1'b0;
            payload_needed_q <= 1'b0;
            meta_q           <= '0;
            payload_q        <= '0;
            error_q          <= PKT_PAYLOAD_OK;
        end else begin
            if (holding_q && out_ready) begin
                holding_q <= 1'b0;
            end

            if (meta_valid && frame_valid && can_accept) begin
                holding_q        <= 1'b1;
                error_path_q     <= error_path_next;
                payload_needed_q <= payload_needed_next;
                meta_q           <= meta_in;
                payload_q        <= payload_next;
                error_q          <= error_next;
            end
        end
    end

endmodule
