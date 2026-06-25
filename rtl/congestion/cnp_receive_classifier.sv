`timescale 1ns/1ps

module cnp_receive_classifier
    import smartnic_pkg::*;
#(
    parameter int CNP_COUNTER_TABLE_DEPTH = 64,
    parameter int CNP_COUNTER_INDEX_W = 6
) (
    input  logic                 clk,
    input  logic                 rst_n,

    // 来自 ingress validator/parser 的 metadata。payload 对 CNP 分类不是必需的。
    input  logic                 meta_valid,
    output logic                 meta_ready,
    input  packet_meta_t         meta_in,

    // QP table lookup 结果由上层/后续集成提供；本模块不直接实例化 QP table。
    output logic                 qp_lookup_valid,
    input  logic                 qp_lookup_ready,
    output logic [QP_ID_W-1:0]   qp_lookup_qpn,
    output logic [VF_ID_W-1:0]   qp_lookup_owner_function,
    input  logic                 qp_lookup_hit,
    input  logic                 qp_lookup_active,

    // 送给 10.3 DCQCN state machine 的事件队列。
    output logic                 dcqcn_event_valid,
    input  logic                 dcqcn_event_ready,
    output cnp_event_t           dcqcn_event,

    // Drop/debug path。
    output logic                 cnp_drop_valid,
    input  logic                 cnp_drop_ready,
    output cnp_class_status_e    cnp_drop_status,
    output logic [QP_ID_W-1:0]   cnp_drop_qpn,

    output logic [CNP_COUNTER_W-1:0] cnp_received_total,
    output logic [CNP_COUNTER_W-1:0] cnp_invalid_total,
    output logic [CNP_COUNTER_W-1:0] cnp_received_count,
    output logic [CNP_COUNTER_W-1:0] cnp_dropped_invalid_count
);

    typedef enum logic [1:0] {
        CLASS_IDLE      = 2'd0,
        CLASS_LOOKUP_QP = 2'd1,
        CLASS_EMIT      = 2'd2,
        CLASS_DROP      = 2'd3
    } class_state_e;

    class_state_e state_q;
    packet_meta_t meta_q;
    cnp_event_t   event_q;
    cnp_class_status_e drop_status_q;
    logic [CNP_COUNTER_W-1:0] received_table_q [CNP_COUNTER_TABLE_DEPTH];
    logic [CNP_COUNTER_W-1:0] invalid_table_q [CNP_COUNTER_TABLE_DEPTH];
    logic [CNP_COUNTER_INDEX_W-1:0] qpn_idx;
    logic malformed_now;
    logic lookup_ok;
    integer i;

    assign qpn_idx = meta_q.dest_qpn[CNP_COUNTER_INDEX_W-1:0];
    assign malformed_now = (meta_in.status != PKT_PARSE_STATUS_OK) ||
                           (meta_in.udp_dst_port != ROCEV2_UDP_PORT) ||
                           (meta_in.opcode != ROCE_OPCODE_CNP);
    assign lookup_ok = qp_lookup_hit && qp_lookup_active;

    assign meta_ready = (state_q == CLASS_IDLE);
    assign qp_lookup_valid = (state_q == CLASS_LOOKUP_QP);
    assign qp_lookup_qpn = meta_q.dest_qpn;
    assign qp_lookup_owner_function = meta_q.owner_function;

    assign dcqcn_event_valid = (state_q == CLASS_EMIT);
    assign dcqcn_event = event_q;

    assign cnp_drop_valid = (state_q == CLASS_DROP);
    assign cnp_drop_status = drop_status_q;
    assign cnp_drop_qpn = meta_q.dest_qpn;
    assign cnp_received_count = received_table_q[qpn_idx];
    assign cnp_dropped_invalid_count = invalid_table_q[qpn_idx];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= CLASS_IDLE;
            meta_q <= '0;
            event_q <= '0;
            drop_status_q <= CNP_CLASS_STATUS_NOT_CNP;
            cnp_received_total <= '0;
            cnp_invalid_total <= '0;
            for (i = 0; i < CNP_COUNTER_TABLE_DEPTH; i = i + 1) begin
                received_table_q[i] <= '0;
                invalid_table_q[i] <= '0;
            end
        end else begin
            unique case (state_q)
                CLASS_IDLE: begin
                    if (meta_valid && meta_ready) begin
                        meta_q <= meta_in;
                        if (meta_in.opcode != ROCE_OPCODE_CNP) begin
                            drop_status_q <= CNP_CLASS_STATUS_NOT_CNP;
                            state_q <= CLASS_DROP;
                        end else if (malformed_now) begin
                            drop_status_q <= CNP_CLASS_STATUS_MALFORMED;
                            state_q <= CLASS_DROP;
                        end else begin
                            state_q <= CLASS_LOOKUP_QP;
                        end
                    end
                end

                CLASS_LOOKUP_QP: begin
                    if (qp_lookup_ready) begin
                        if (lookup_ok) begin
                            event_q <= '0;
                            event_q.desc_id <= meta_q.desc_id;
                            event_q.qpn <= meta_q.dest_qpn;
                            event_q.cqn <= meta_q.cqn;
                            event_q.owner_function <= meta_q.owner_function;
                            event_q.pd_id <= meta_q.pd_id;
                            event_q.congestion_type <= cnp_congestion_type_e'(meta_q.imm_data[1:0]);
                            event_q.source_qpn <= meta_q.src_qpn;
                            event_q.status <= CNP_CLASS_STATUS_OK;
                            state_q <= CLASS_EMIT;
                        end else begin
                            drop_status_q <= CNP_CLASS_STATUS_QP_MISS;
                            state_q <= CLASS_DROP;
                        end
                    end
                end

                CLASS_EMIT: begin
                    if (dcqcn_event_ready) begin
                        cnp_received_total <= cnp_received_total + {{(CNP_COUNTER_W-1){1'b0}}, 1'b1};
                        received_table_q[qpn_idx] <= received_table_q[qpn_idx] + {{(CNP_COUNTER_W-1){1'b0}}, 1'b1};
                        state_q <= CLASS_IDLE;
                    end
                end

                CLASS_DROP: begin
                    if (cnp_drop_ready) begin
                        if (drop_status_q != CNP_CLASS_STATUS_NOT_CNP) begin
                            cnp_invalid_total <= cnp_invalid_total + {{(CNP_COUNTER_W-1){1'b0}}, 1'b1};
                            invalid_table_q[qpn_idx] <= invalid_table_q[qpn_idx] + {{(CNP_COUNTER_W-1){1'b0}}, 1'b1};
                        end
                        state_q <= CLASS_IDLE;
                    end
                end

                default: begin
                    state_q <= CLASS_IDLE;
                end
            endcase
        end
    end

endmodule
