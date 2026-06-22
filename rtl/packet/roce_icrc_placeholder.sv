`timescale 1ns/1ps

module roce_icrc_placeholder
    import smartnic_pkg::*;
(
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic                 req_valid,
    output logic                 req_ready,
    input  logic [15:0]          req_desc_id,
    input  logic [QP_ID_W-1:0]   req_qpn,
    input  logic [CQ_ID_W-1:0]   req_cqn,
    input  logic [VF_ID_W-1:0]   req_owner_function,
    input  logic [PD_ID_W-1:0]   req_pd_id,
    input  roce_opcode_e         req_opcode,
    input  logic [511:0]         req_frame_data,
    input  logic [15:0]          req_frame_len,
    input  logic [31:0]          req_existing_icrc,
    input  logic                 req_is_tx,

    output logic                 result_valid,
    input  logic                 result_ready,
    output packet_icrc_result_t  result
);

    packet_icrc_result_t result_q;
    logic                holding_q;

    assign req_ready    = !holding_q || result_ready;
    assign result_valid = holding_q;
    assign result       = result_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            holding_q <= 1'b0;
            result_q  <= '0;
        end else begin
            if (holding_q && result_ready) begin
                holding_q <= 1'b0;
            end

            if (req_valid && req_ready) begin
                holding_q <= 1'b1;
                result_q.desc_id <= req_desc_id;
                result_q.qpn <= req_qpn;
                result_q.cqn <= req_cqn;
                result_q.owner_function <= req_owner_function;
                result_q.pd_id <= req_pd_id;
                result_q.opcode <= req_opcode;
                result_q.status <= req_is_tx ? PKT_ICRC_STATUS_PLACEHOLDER
                                             : PKT_ICRC_STATUS_UNCHECKED;
                result_q.error_code <= req_is_tx ? 16'h0000 : 16'h0001;
                result_q.icrc_value <= req_existing_icrc;
                result_q.compatibility_limited <= 1'b1;

                // TODO 8.5 后续版本：这里替换为 RoCEv2 invariant CRC 计算。
                // 当前模块刻意只透传 ICRC 字段，隔离兼容性限制。
                void'(req_frame_data);
                void'(req_frame_len);
            end
        end
    end

endmodule
