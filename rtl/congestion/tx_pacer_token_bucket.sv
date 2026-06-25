`timescale 1ns/1ps

module tx_pacer_token_bucket
    import smartnic_pkg::*;
#(
    parameter int PACER_TABLE_DEPTH = 64,
    parameter int PACER_TABLE_INDEX_W = 6
) (
    input  logic                 clk,
    input  logic                 rst_n,

    // 全局 pacing 使能。关闭时旁路允许发送，但仍返回 DISABLED 状态。
    input  logic                 pacer_enable,

    // Per-QP bucket 配置入口，后续可由 CSR/control plane 驱动。
    input  logic                 config_valid,
    output logic                 config_ready,
    input  logic [QP_ID_W-1:0]   config_qpn,
    input  logic [VF_ID_W-1:0]   config_owner_function,
    input  logic [PACER_TOKEN_W-1:0] config_bucket_size,
    input  logic [PACER_TOKEN_W-1:0] config_initial_tokens,
    input  logic [PACER_TIME_W-1:0]  config_time_now,

    // 来自 10.3 DCQCN state machine 的 current_rate 更新。
    input  logic                 rate_update_valid,
    output logic                 rate_update_ready,
    input  dcqcn_rate_update_t   rate_update,

    // TX path 在准备发送一个 packet 前提交 pacing 请求。
    input  logic                 pace_req_valid,
    output logic                 pace_req_ready,
    input  pacer_tx_req_t        pace_req,
    input  logic [PACER_TIME_W-1:0] time_now,

    // pacing 判定。ALLOWED 才允许 TX path 继续发包。
    output logic                 pace_decision_valid,
    input  logic                 pace_decision_ready,
    output pacer_decision_t      pace_decision,

    output logic [PACER_COUNTER_W-1:0] tokens_refilled,
    output logic [PACER_COUNTER_W-1:0] tx_throttled_events,
    output logic [PACER_COUNTER_W-1:0] tx_allowed_packets
);

    typedef struct packed {
        logic                       valid;
        logic [QP_ID_W-1:0]         qpn;
        logic [VF_ID_W-1:0]         owner_function;
        logic [DCQCN_RATE_W-1:0]    rate;
        logic [PACER_TOKEN_W-1:0]   bucket_size;
        logic [PACER_TOKEN_W-1:0]   tokens;
        logic [PACER_TIME_W-1:0]    last_update_time;
    } pacer_bucket_t;

    pacer_bucket_t table_q [PACER_TABLE_DEPTH];
    pacer_decision_t decision_q;
    logic holding_decision_q;

    logic [PACER_TABLE_INDEX_W-1:0] config_idx;
    logic [PACER_TABLE_INDEX_W-1:0] rate_idx;
    logic [PACER_TABLE_INDEX_W-1:0] pace_idx;
    logic can_accept;

    logic [PACER_TIME_W-1:0] delta_time;
    logic [DCQCN_RATE_W+PACER_TIME_W:0] refill_product;
    logic [PACER_TOKEN_W-1:0] refill_amount;
    logic [PACER_TOKEN_W:0] token_sum_wide;
    logic [PACER_TOKEN_W-1:0] refilled_tokens;
    logic [PACER_TOKEN_W-1:0] consumed_tokens;
    logic [PACER_TOKEN_W-1:0] actual_refill;
    logic entry_match;
    integer i;

    assign config_idx = config_qpn[PACER_TABLE_INDEX_W-1:0];
    assign rate_idx = rate_update.qpn[PACER_TABLE_INDEX_W-1:0];
    assign pace_idx = pace_req.qpn[PACER_TABLE_INDEX_W-1:0];
    assign can_accept = !holding_decision_q || pace_decision_ready;

    // 同周期优先处理 rate update，再处理配置，最后处理 TX pacing 请求。
    assign rate_update_ready = can_accept;
    assign config_ready = can_accept && !rate_update_valid;
    assign pace_req_ready = can_accept && !rate_update_valid && !config_valid;

    assign pace_decision_valid = holding_decision_q;
    assign pace_decision = decision_q;

    always_comb begin
        delta_time = time_now - table_q[pace_idx].last_update_time;
        refill_product = table_q[pace_idx].rate * delta_time;
        refill_amount = refill_product[PACER_TOKEN_W]
                      ? {PACER_TOKEN_W{1'b1}}
                      : refill_product[PACER_TOKEN_W-1:0];

        token_sum_wide = {1'b0, table_q[pace_idx].tokens} + {1'b0, refill_amount};
        if (token_sum_wide[PACER_TOKEN_W] ||
            (token_sum_wide[PACER_TOKEN_W-1:0] > table_q[pace_idx].bucket_size)) begin
            refilled_tokens = table_q[pace_idx].bucket_size;
        end else begin
            refilled_tokens = token_sum_wide[PACER_TOKEN_W-1:0];
        end

        consumed_tokens = refilled_tokens - {{(PACER_TOKEN_W-PACER_PACKET_LEN_W){1'b0}}, pace_req.packet_size};
        actual_refill = (refilled_tokens > table_q[pace_idx].tokens)
                      ? (refilled_tokens - table_q[pace_idx].tokens)
                      : '0;

        entry_match = table_q[pace_idx].valid &&
                      (table_q[pace_idx].qpn == pace_req.qpn) &&
                      (table_q[pace_idx].owner_function == pace_req.owner_function);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            holding_decision_q <= 1'b0;
            decision_q <= '0;
            tokens_refilled <= '0;
            tx_throttled_events <= '0;
            tx_allowed_packets <= '0;
            for (i = 0; i < PACER_TABLE_DEPTH; i = i + 1) begin
                table_q[i] <= '0;
            end
        end else begin
            if (holding_decision_q && pace_decision_ready) begin
                holding_decision_q <= 1'b0;
            end

            if (rate_update_valid && rate_update_ready) begin
                table_q[rate_idx].valid <= 1'b1;
                table_q[rate_idx].qpn <= rate_update.qpn;
                table_q[rate_idx].owner_function <= rate_update.owner_function;
                table_q[rate_idx].rate <= rate_update.current_rate;
            end else if (config_valid && config_ready) begin
                table_q[config_idx].valid <= 1'b1;
                table_q[config_idx].qpn <= config_qpn;
                table_q[config_idx].owner_function <= config_owner_function;
                table_q[config_idx].bucket_size <= config_bucket_size;
                table_q[config_idx].tokens <= (config_initial_tokens > config_bucket_size)
                                            ? config_bucket_size
                                            : config_initial_tokens;
                table_q[config_idx].last_update_time <= config_time_now;
            end else if (pace_req_valid && pace_req_ready) begin
                decision_q.desc_id <= pace_req.desc_id;
                decision_q.qpn <= pace_req.qpn;
                decision_q.owner_function <= pace_req.owner_function;
                decision_q.pd_id <= pace_req.pd_id;
                decision_q.opcode <= pace_req.opcode;
                holding_decision_q <= 1'b1;

                if (!pacer_enable) begin
                    decision_q.tokens_after <= table_q[pace_idx].tokens;
                    decision_q.status <= PACER_STATUS_DISABLED;
                    tx_allowed_packets <= tx_allowed_packets + {{(PACER_COUNTER_W-1){1'b0}}, 1'b1};
                end else if (!entry_match || (table_q[pace_idx].bucket_size == '0) || (pace_req.packet_size == '0)) begin
                    decision_q.tokens_after <= refilled_tokens;
                    decision_q.status <= PACER_STATUS_INVALID;
                end else begin
                    table_q[pace_idx].tokens <= refilled_tokens;
                    table_q[pace_idx].last_update_time <= time_now;
                    tokens_refilled <= tokens_refilled + actual_refill[PACER_COUNTER_W-1:0];

                    if (refilled_tokens >= {{(PACER_TOKEN_W-PACER_PACKET_LEN_W){1'b0}}, pace_req.packet_size}) begin
                        table_q[pace_idx].tokens <= consumed_tokens;
                        decision_q.tokens_after <= consumed_tokens;
                        decision_q.status <= PACER_STATUS_ALLOWED;
                        tx_allowed_packets <= tx_allowed_packets + {{(PACER_COUNTER_W-1){1'b0}}, 1'b1};
                    end else begin
                        decision_q.tokens_after <= refilled_tokens;
                        decision_q.status <= PACER_STATUS_THROTTLED;
                        tx_throttled_events <= tx_throttled_events + {{(PACER_COUNTER_W-1){1'b0}}, 1'b1};
                    end
                end
            end
        end
    end

endmodule
