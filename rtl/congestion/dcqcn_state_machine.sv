`timescale 1ns/1ps

module dcqcn_state_machine
    import smartnic_pkg::*;
#(
    parameter int DCQCN_TABLE_DEPTH = 64,
    parameter int DCQCN_TABLE_INDEX_W = 6
) (
    input  logic                 clk,
    input  logic                 rst_n,

    // Per-QP 参数配置入口。后续 11.x/12.x 可由 CSR/control plane 驱动。
    input  logic                 config_valid,
    output logic                 config_ready,
    input  logic [QP_ID_W-1:0]   config_qpn,
    input  logic [VF_ID_W-1:0]   config_owner_function,
    input  logic [DCQCN_RATE_W-1:0] config_current_rate,
    input  logic [DCQCN_RATE_W-1:0] config_target_rate,
    input  logic [DCQCN_RATE_W-1:0] config_min_rate,
    input  logic [DCQCN_RATE_W-1:0] config_ai_rate,
    input  logic [3:0]           config_alpha_g_shift,
    input  logic [DCQCN_ALPHA_W-1:0] config_initial_alpha,

    // 来自 10.2 CNP receive classifier 的事件。
    input  logic                 cnp_event_valid,
    output logic                 cnp_event_ready,
    input  cnp_event_t           cnp_event,

    // Recovery timer/no-CNP tick。每个 tick 对一个 QP 做 additive increase。
    input  logic                 recovery_tick_valid,
    output logic                 recovery_tick_ready,
    input  logic [QP_ID_W-1:0]   recovery_tick_qpn,
    input  logic [VF_ID_W-1:0]   recovery_tick_owner_function,

    // 输出给 10.4 pacing/token bucket 的 per-QP rate update。
    output logic                 rate_update_valid,
    input  logic                 rate_update_ready,
    output dcqcn_rate_update_t   rate_update,

    output logic [DCQCN_COUNTER_W-1:0] cnp_events,
    output logic [DCQCN_COUNTER_W-1:0] rate_decrease,
    output logic [DCQCN_COUNTER_W-1:0] rate_increase,
    output logic [DCQCN_COUNTER_W-1:0] state_transitions
);

    typedef struct packed {
        logic                       valid;
        logic [QP_ID_W-1:0]         qpn;
        logic [VF_ID_W-1:0]         owner_function;
        logic [DCQCN_RATE_W-1:0]    current_rate;
        logic [DCQCN_RATE_W-1:0]    target_rate;
        logic [DCQCN_RATE_W-1:0]    min_rate;
        logic [DCQCN_RATE_W-1:0]    ai_rate;
        logic [3:0]                 alpha_g_shift;
        logic [DCQCN_ALPHA_W-1:0]   alpha;
        dcqcn_state_e               state;
    } dcqcn_qp_state_t;

    dcqcn_qp_state_t table_q [DCQCN_TABLE_DEPTH];
    dcqcn_rate_update_t update_q;
    logic holding_update_q;
    logic [DCQCN_TABLE_INDEX_W-1:0] config_idx;
    logic [DCQCN_TABLE_INDEX_W-1:0] cnp_idx;
    logic [DCQCN_TABLE_INDEX_W-1:0] recovery_idx;
    logic can_accept_update;
    logic [DCQCN_RATE_W-1:0] halved_rate;
    logic [DCQCN_RATE_W-1:0] decreased_rate;
    logic [DCQCN_RATE_W:0] increased_rate_wide;
    logic [DCQCN_RATE_W-1:0] increased_rate;
    logic [DCQCN_ALPHA_W-1:0] alpha_decay;
    logic [DCQCN_ALPHA_W-1:0] alpha_add;
    logic [DCQCN_ALPHA_W:0] alpha_next_wide;
    logic [DCQCN_ALPHA_W-1:0] alpha_next;
    dcqcn_state_e next_state;
    integer i;

    assign config_idx = config_qpn[DCQCN_TABLE_INDEX_W-1:0];
    assign cnp_idx = cnp_event.qpn[DCQCN_TABLE_INDEX_W-1:0];
    assign recovery_idx = recovery_tick_qpn[DCQCN_TABLE_INDEX_W-1:0];
    assign can_accept_update = !holding_update_q || rate_update_ready;

    assign config_ready = can_accept_update && !cnp_event_valid && !recovery_tick_valid;
    assign cnp_event_ready = can_accept_update;
    assign recovery_tick_ready = can_accept_update && !cnp_event_valid;

    assign rate_update_valid = holding_update_q;
    assign rate_update = update_q;

    always_comb begin
        halved_rate = table_q[cnp_idx].current_rate >> 1;
        decreased_rate = (halved_rate < table_q[cnp_idx].min_rate)
                       ? table_q[cnp_idx].min_rate
                       : halved_rate;

        alpha_decay = table_q[cnp_idx].alpha >> table_q[cnp_idx].alpha_g_shift;
        alpha_add = DCQCN_ALPHA_MAX >> table_q[cnp_idx].alpha_g_shift;
        alpha_next_wide = {1'b0, table_q[cnp_idx].alpha}
                        - {1'b0, alpha_decay}
                        + {1'b0, alpha_add};
        alpha_next = alpha_next_wide[DCQCN_ALPHA_W]
                   ? DCQCN_ALPHA_MAX
                   : alpha_next_wide[DCQCN_ALPHA_W-1:0];

        increased_rate_wide = {1'b0, table_q[recovery_idx].current_rate}
                            + {1'b0, table_q[recovery_idx].ai_rate};
        increased_rate = (increased_rate_wide[DCQCN_RATE_W] ||
                          (increased_rate_wide[DCQCN_RATE_W-1:0] > table_q[recovery_idx].target_rate))
                       ? table_q[recovery_idx].target_rate
                       : increased_rate_wide[DCQCN_RATE_W-1:0];
        next_state = (increased_rate == table_q[recovery_idx].target_rate)
                   ? DCQCN_STATE_NORMAL
                   : DCQCN_STATE_RECOVERY;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            holding_update_q <= 1'b0;
            update_q <= '0;
            cnp_events <= '0;
            rate_decrease <= '0;
            rate_increase <= '0;
            state_transitions <= '0;
            for (i = 0; i < DCQCN_TABLE_DEPTH; i = i + 1) begin
                table_q[i] <= '0;
                table_q[i].state <= DCQCN_STATE_NORMAL;
            end
        end else begin
            if (holding_update_q && rate_update_ready) begin
                holding_update_q <= 1'b0;
            end

            if (cnp_event_valid && cnp_event_ready) begin
                table_q[cnp_idx].valid <= 1'b1;
                table_q[cnp_idx].qpn <= cnp_event.qpn;
                table_q[cnp_idx].owner_function <= cnp_event.owner_function;
                table_q[cnp_idx].current_rate <= decreased_rate;
                table_q[cnp_idx].alpha <= alpha_next;
                table_q[cnp_idx].state <= DCQCN_STATE_CONGESTED;

                update_q.qpn <= cnp_event.qpn;
                update_q.owner_function <= cnp_event.owner_function;
                update_q.current_rate <= decreased_rate;
                update_q.target_rate <= table_q[cnp_idx].target_rate;
                update_q.min_rate <= table_q[cnp_idx].min_rate;
                update_q.alpha <= alpha_next;
                update_q.state <= DCQCN_STATE_CONGESTED;
                holding_update_q <= 1'b1;

                cnp_events <= cnp_events + {{(DCQCN_COUNTER_W-1){1'b0}}, 1'b1};
                rate_decrease <= rate_decrease + {{(DCQCN_COUNTER_W-1){1'b0}}, 1'b1};
                if (table_q[cnp_idx].state != DCQCN_STATE_CONGESTED) begin
                    state_transitions <= state_transitions + {{(DCQCN_COUNTER_W-1){1'b0}}, 1'b1};
                end
            end else if (recovery_tick_valid && recovery_tick_ready) begin
                table_q[recovery_idx].valid <= 1'b1;
                table_q[recovery_idx].qpn <= recovery_tick_qpn;
                table_q[recovery_idx].owner_function <= recovery_tick_owner_function;
                table_q[recovery_idx].current_rate <= increased_rate;
                table_q[recovery_idx].state <= next_state;

                update_q.qpn <= recovery_tick_qpn;
                update_q.owner_function <= recovery_tick_owner_function;
                update_q.current_rate <= increased_rate;
                update_q.target_rate <= table_q[recovery_idx].target_rate;
                update_q.min_rate <= table_q[recovery_idx].min_rate;
                update_q.alpha <= table_q[recovery_idx].alpha;
                update_q.state <= next_state;
                holding_update_q <= 1'b1;

                if (increased_rate > table_q[recovery_idx].current_rate) begin
                    rate_increase <= rate_increase + {{(DCQCN_COUNTER_W-1){1'b0}}, 1'b1};
                end
                if (table_q[recovery_idx].state != next_state) begin
                    state_transitions <= state_transitions + {{(DCQCN_COUNTER_W-1){1'b0}}, 1'b1};
                end
            end else if (config_valid && config_ready) begin
                table_q[config_idx].valid <= 1'b1;
                table_q[config_idx].qpn <= config_qpn;
                table_q[config_idx].owner_function <= config_owner_function;
                table_q[config_idx].current_rate <= config_current_rate;
                table_q[config_idx].target_rate <= config_target_rate;
                table_q[config_idx].min_rate <= config_min_rate;
                table_q[config_idx].ai_rate <= config_ai_rate;
                table_q[config_idx].alpha_g_shift <= config_alpha_g_shift;
                table_q[config_idx].alpha <= config_initial_alpha;
                table_q[config_idx].state <= DCQCN_STATE_NORMAL;

                update_q.qpn <= config_qpn;
                update_q.owner_function <= config_owner_function;
                update_q.current_rate <= config_current_rate;
                update_q.target_rate <= config_target_rate;
                update_q.min_rate <= config_min_rate;
                update_q.alpha <= config_initial_alpha;
                update_q.state <= DCQCN_STATE_NORMAL;
                holding_update_q <= 1'b1;
            end
        end
    end

endmodule
