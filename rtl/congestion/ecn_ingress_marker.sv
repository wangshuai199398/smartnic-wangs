`timescale 1ns/1ps

module ecn_ingress_marker
    import smartnic_pkg::*;
(
    input  logic                 clk,
    input  logic                 rst_n,

    // 来自 packet parser/validator 的 ingress metadata。
    input  logic                 meta_valid,
    output logic                 meta_ready,
    input  packet_meta_t         meta_in,

    // 透传给 transport receive path 的 metadata。非 ECN 包不改变语义。
    output logic                 marked_valid,
    input  logic                 marked_ready,
    output packet_meta_t         marked_meta,

    // CE mark hook：后续 CNP/DCQCN 逻辑可消费该事件。
    output logic                 congestion_mark_valid,
    input  logic                 congestion_mark_ready,
    output logic [15:0]          congestion_mark_desc_id,
    output logic [QP_ID_W-1:0]   congestion_mark_qpn,
    output logic [CQ_ID_W-1:0]   congestion_mark_cqn,
    output logic [VF_ID_W-1:0]   congestion_mark_owner_function,
    output logic [PD_ID_W-1:0]   congestion_mark_pd_id,
    output roce_opcode_e         congestion_mark_opcode,
    output logic [1:0]           congestion_mark_ecn,

    // 10.1 阶段轻量计数器。完整 counter CSR 映射留给后续控制面阶段。
    output logic [31:0]          ecn_packet_count,
    output logic [31:0]          ce_packet_count,
    output logic [31:0]          malformed_ecn_count
);

    packet_meta_t meta_q;
    logic         holding_q;
    logic         ce_q;
    logic         out_ready;

    assign ce_q = meta_q.ecn_valid && meta_q.ecn_ce;
    assign congestion_mark_valid = holding_q && ce_q;
    assign marked_valid = holding_q;
    assign marked_meta = meta_q;

    assign congestion_mark_desc_id        = meta_q.desc_id;
    assign congestion_mark_qpn            = meta_q.qpn;
    assign congestion_mark_cqn            = meta_q.cqn;
    assign congestion_mark_owner_function = meta_q.owner_function;
    assign congestion_mark_pd_id          = meta_q.pd_id;
    assign congestion_mark_opcode         = meta_q.opcode;
    assign congestion_mark_ecn            = meta_q.ecn;

    assign out_ready = marked_ready && (!congestion_mark_valid || congestion_mark_ready);
    assign meta_ready = !holding_q || out_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            holding_q           <= 1'b0;
            meta_q              <= '0;
            ecn_packet_count    <= 32'd0;
            ce_packet_count     <= 32'd0;
            malformed_ecn_count <= 32'd0;
        end else begin
            if (holding_q && out_ready) begin
                holding_q <= 1'b0;
            end

            if (meta_valid && meta_ready) begin
                holding_q <= 1'b1;
                meta_q    <= meta_in;

                if (meta_in.ecn_valid) begin
                    ecn_packet_count <= ecn_packet_count + 32'd1;
                    if (meta_in.ecn_ce) begin
                        ce_packet_count <= ce_packet_count + 32'd1;
                    end
                    if (meta_in.status != PKT_PARSE_STATUS_OK) begin
                        malformed_ecn_count <= malformed_ecn_count + 32'd1;
                    end
                end
            end
        end
    end

endmodule
