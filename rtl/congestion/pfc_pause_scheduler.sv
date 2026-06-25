`timescale 1ns/1ps

module pfc_pause_scheduler
    import smartnic_pkg::*;
(
    input  logic                 clk,
    input  logic                 rst_n,

    // 802.1Qbb PFC 事件入口。pfc_pause=1 表示 PAUSE，pfc_pause=0 或 pfc_resume=1 表示 RESUME。
    input  logic                 pfc_event_valid,
    output logic                 pfc_event_ready,
    input  logic [PFC_PRIORITY_W-1:0] pfc_priority,
    input  logic                 pfc_pause,
    input  logic                 pfc_resume,
    input  logic [PFC_TIMER_W-1:0] pfc_pause_quanta,

    // TX scheduler 提交的待发送 packet。qp_priority 是该 QP 映射到的 traffic class。
    input  logic                 tx_req_valid,
    output logic                 tx_req_ready,
    input  pacer_tx_req_t        tx_req,
    input  logic [PFC_PRIORITY_W-1:0] tx_qp_priority,

    // 发给 10.4 token bucket 的请求。paused priority 不会透传到这里，从而 freeze token bucket。
    output logic                 pacer_req_valid,
    input  logic                 pacer_req_ready,
    output pacer_tx_req_t        pacer_req,

    // 从 10.4 token bucket 返回的判定，原样透传给 TX scheduler。
    input  logic                 pacer_decision_valid,
    output logic                 pacer_decision_ready,
    input  pacer_decision_t      pacer_decision,

    output logic                 tx_decision_valid,
    input  logic                 tx_decision_ready,
    output pacer_decision_t      tx_decision,

    // 暂停导致的 scheduler backpressure 观测信号。
    output logic                 tx_pfc_blocked,
    output logic [PFC_PRIORITY_W-1:0] tx_blocked_priority,

    output logic [PFC_PRIORITY_COUNT-1:0] pause_state,
    output logic [PFC_COUNTER_W-1:0] pfc_pause_events,
    output logic [PFC_COUNTER_W-1:0] pfc_resume_events,
    output logic [PFC_COUNTER_W-1:0] tx_stalled_due_to_pfc
);

    pfc_pause_state_e state_q [PFC_PRIORITY_COUNT];
    logic [PFC_TIMER_W-1:0] timer_q [PFC_PRIORITY_COUNT];
    logic stall_seen_q;
    integer i;

    assign pfc_event_ready = 1'b1;
    assign tx_pfc_blocked = tx_req_valid && (state_q[tx_qp_priority] == PFC_STATE_PAUSED);
    assign tx_blocked_priority = tx_qp_priority;

    assign pacer_req_valid = tx_req_valid && !tx_pfc_blocked;
    assign pacer_req = tx_req;
    assign tx_req_ready = !tx_pfc_blocked && pacer_req_ready;

    assign tx_decision_valid = pacer_decision_valid;
    assign tx_decision = pacer_decision;
    assign pacer_decision_ready = tx_decision_ready;

    generate
        genvar prio;
        for (prio = 0; prio < PFC_PRIORITY_COUNT; prio = prio + 1) begin : gen_pause_state
            assign pause_state[prio] = (state_q[prio] == PFC_STATE_PAUSED);
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pfc_pause_events <= '0;
            pfc_resume_events <= '0;
            tx_stalled_due_to_pfc <= '0;
            stall_seen_q <= 1'b0;
            for (i = 0; i < PFC_PRIORITY_COUNT; i = i + 1) begin
                state_q[i] <= PFC_STATE_ACTIVE;
                timer_q[i] <= '0;
            end
        end else begin
            for (i = 0; i < PFC_PRIORITY_COUNT; i = i + 1) begin
                if (state_q[i] == PFC_STATE_PAUSED && timer_q[i] != '0) begin
                    timer_q[i] <= timer_q[i] - {{(PFC_TIMER_W-1){1'b0}}, 1'b1};
                    if (timer_q[i] == {{(PFC_TIMER_W-1){1'b0}}, 1'b1}) begin
                        state_q[i] <= PFC_STATE_ACTIVE;
                        pfc_resume_events <= pfc_resume_events + {{(PFC_COUNTER_W-1){1'b0}}, 1'b1};
                    end
                end
            end

            if (pfc_event_valid && pfc_event_ready) begin
                if (pfc_pause && !pfc_resume) begin
                    state_q[pfc_priority] <= PFC_STATE_PAUSED;
                    timer_q[pfc_priority] <= pfc_pause_quanta;
                    pfc_pause_events <= pfc_pause_events + {{(PFC_COUNTER_W-1){1'b0}}, 1'b1};
                end else begin
                    state_q[pfc_priority] <= PFC_STATE_ACTIVE;
                    timer_q[pfc_priority] <= '0;
                    pfc_resume_events <= pfc_resume_events + {{(PFC_COUNTER_W-1){1'b0}}, 1'b1};
                end
            end

            if (tx_pfc_blocked && !stall_seen_q) begin
                tx_stalled_due_to_pfc <= tx_stalled_due_to_pfc + {{(PFC_COUNTER_W-1){1'b0}}, 1'b1};
                stall_seen_q <= 1'b1;
            end else if (!tx_pfc_blocked) begin
                stall_seen_q <= 1'b0;
            end
        end
    end

endmodule
