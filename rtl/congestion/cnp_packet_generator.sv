`timescale 1ns/1ps

module cnp_packet_generator
    import smartnic_pkg::*;
#(
    parameter int RATE_TABLE_DEPTH = 64,
    parameter int RATE_TABLE_INDEX_W = 6
) (
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic                 cnp_enable,
    input  logic [CNP_RATE_LIMIT_W-1:0] cnp_rate_limit_cycles,

    // 10.1 ecn_ingress_marker 输出的 CE mark 事件。
    input  logic                 ce_mark_valid,
    output logic                 ce_mark_ready,
    input  logic [15:0]          ce_mark_desc_id,
    input  logic [QP_ID_W-1:0]   ce_mark_qpn,
    input  logic [CQ_ID_W-1:0]   ce_mark_cqn,
    input  logic [VF_ID_W-1:0]   ce_mark_owner_function,
    input  logic [PD_ID_W-1:0]   ce_mark_pd_id,
    input  roce_opcode_e         ce_mark_opcode,

    // Queue/port congestion injection hooks；真实阈值比较留给 10.4/10.5/top 集成。
    input  logic                 queue_congestion_valid,
    output logic                 queue_congestion_ready,
    input  logic [QP_ID_W-1:0]   queue_congestion_qpn,
    input  logic [VF_ID_W-1:0]   queue_congestion_owner_function,

    input  logic                 port_congestion_valid,
    output logic                 port_congestion_ready,
    input  logic [QP_ID_W-1:0]   port_congestion_qpn,
    input  logic [VF_ID_W-1:0]   port_congestion_owner_function,

    // Packet builder 默认地址配置。后续 11.x/12.x 可由 CSR 写入。
    input  logic [47:0]          local_mac,
    input  logic [47:0]          peer_mac,
    input  logic [31:0]          local_ipv4,
    input  logic [31:0]          peer_ipv4,
    input  logic [15:0]          udp_src_port,
    input  logic [PKEY_W-1:0]    pkey,

    output logic                 build_req_valid,
    input  logic                 build_req_ready,
    output packet_build_req_t    build_req,

    // Debug / observability.
    output logic                 cnp_status_valid,
    output logic [QP_ID_W-1:0]   cnp_status_qpn,
    output cnp_gen_status_e      cnp_status,
    output logic [CNP_COUNTER_W-1:0] cnp_generated_total,
    output logic [CNP_COUNTER_W-1:0] cnp_rate_limited
);

    packet_build_req_t req_q;
    logic              holding_q;
    logic [RATE_TABLE_INDEX_W-1:0] selected_idx;
    logic [QP_ID_W-1:0] selected_qpn;
    logic [CQ_ID_W-1:0] selected_cqn;
    logic [VF_ID_W-1:0] selected_owner;
    logic [PD_ID_W-1:0] selected_pd;
    logic [15:0]        selected_desc_id;
    cnp_congestion_type_e selected_type;
    logic              selected_valid;
    logic              selected_is_ce;
    logic              selected_is_queue;
    logic              selected_is_port;
    logic              accept_selected;
    logic              rate_limited_now;
    logic [CNP_RATE_LIMIT_W-1:0] cooldown_q [RATE_TABLE_DEPTH];
    integer i;

    assign selected_is_ce    = ce_mark_valid;
    assign selected_is_queue = !ce_mark_valid && queue_congestion_valid;
    assign selected_is_port  = !ce_mark_valid && !queue_congestion_valid && port_congestion_valid;
    assign selected_valid    = selected_is_ce || selected_is_queue || selected_is_port;

    always_comb begin
        selected_qpn     = ce_mark_qpn;
        selected_cqn     = ce_mark_cqn;
        selected_owner   = ce_mark_owner_function;
        selected_pd      = ce_mark_pd_id;
        selected_desc_id = ce_mark_desc_id;
        selected_type    = CNP_CONGESTION_ECN;
        if (selected_is_queue) begin
            selected_qpn     = queue_congestion_qpn;
            selected_cqn     = '0;
            selected_owner   = queue_congestion_owner_function;
            selected_pd      = '0;
            selected_desc_id = 16'h0000;
            selected_type    = CNP_CONGESTION_QUEUE;
        end else if (selected_is_port) begin
            selected_qpn     = port_congestion_qpn;
            selected_cqn     = '0;
            selected_owner   = port_congestion_owner_function;
            selected_pd      = '0;
            selected_desc_id = 16'h0000;
            selected_type    = CNP_CONGESTION_PORT;
        end
        selected_idx = selected_qpn[RATE_TABLE_INDEX_W-1:0];
    end

    assign rate_limited_now = selected_valid && (cooldown_q[selected_idx] != '0);
    assign accept_selected = selected_valid && !holding_q && cnp_enable && !rate_limited_now;

    // Disabled/rate-limited triggers are consumed and counted so congestion sideband
    // events do not wedge the receive pipeline.
    assign ce_mark_ready = selected_is_ce && !holding_q;
    assign queue_congestion_ready = selected_is_queue && !holding_q;
    assign port_congestion_ready = selected_is_port && !holding_q;

    assign build_req_valid = holding_q;
    assign build_req = req_q;

    assign cnp_status_valid = selected_valid && (!holding_q);
    assign cnp_status_qpn = selected_qpn;
    assign cnp_status = !cnp_enable ? CNP_GEN_STATUS_DISABLED
                      : rate_limited_now ? CNP_GEN_STATUS_RATE_LIMITED
                      : holding_q ? CNP_GEN_STATUS_BACKPRESSURE
                      : CNP_GEN_STATUS_OK;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            holding_q <= 1'b0;
            req_q <= '0;
            cnp_generated_total <= '0;
            cnp_rate_limited <= '0;
            for (i = 0; i < RATE_TABLE_DEPTH; i = i + 1) begin
                cooldown_q[i] <= '0;
            end
        end else begin
            for (i = 0; i < RATE_TABLE_DEPTH; i = i + 1) begin
                if (cooldown_q[i] != '0) begin
                    cooldown_q[i] <= cooldown_q[i] - {{(CNP_RATE_LIMIT_W-1){1'b0}}, 1'b1};
                end
            end

            if (holding_q && build_req_ready) begin
                holding_q <= 1'b0;
            end

            if (selected_valid && !holding_q && cnp_enable && rate_limited_now) begin
                cnp_rate_limited <= cnp_rate_limited + {{(CNP_COUNTER_W-1){1'b0}}, 1'b1};
            end

            if (accept_selected) begin
                holding_q <= 1'b1;
                cnp_generated_total <= cnp_generated_total + {{(CNP_COUNTER_W-1){1'b0}}, 1'b1};
                cooldown_q[selected_idx] <= cnp_rate_limit_cycles;

                req_q <= '0;
                req_q.desc_id        <= selected_desc_id;
                req_q.qpn            <= selected_qpn;
                req_q.cqn            <= selected_cqn;
                req_q.owner_function <= selected_owner;
                req_q.pd_id          <= selected_pd;
                req_q.opcode         <= ROCE_OPCODE_CNP;
                req_q.status         <= PKT_BUILD_OK;
                req_q.dst_mac        <= peer_mac;
                req_q.src_mac        <= local_mac;
                req_q.src_ipv4       <= local_ipv4;
                req_q.dst_ipv4       <= peer_ipv4;
                req_q.udp_src_port   <= udp_src_port;
                req_q.udp_dst_port   <= ROCEV2_UDP_PORT;
                req_q.pkey           <= pkey;
                req_q.dest_qpn       <= selected_qpn;
                req_q.src_qpn        <= selected_qpn;
                req_q.psn            <= '0;
                req_q.has_imm        <= 1'b1;
                req_q.imm_data       <= {30'd0, selected_type};
                req_q.payload_len    <= 16'd0;
                req_q.icrc_placeholder <= 32'h4350_4e21; // "CPN!" 占位 ICRC/debug tag。
            end
        end
    end

endmodule
