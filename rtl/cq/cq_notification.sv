// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// CQ notification logic 最小实现。
//
// 本模块接收 CQE write path 的 CQE commit 事件，读取 CQ context 的 armed、
// solicited_only、moderation_count/timer 和 MSI-X vector 字段，决定是否
// 生成 MSI-X request。当前阶段不发送真实 MSI-X TLP，只输出 request 接口。

`timescale 1ns/1ps

import smartnic_pkg::*;

module cq_notification (
    input  logic                         clk,                    // CQ notification 时钟。
    input  logic                         rst_n,                  // 低有效复位。

    // ------------------------------------------------------------------
    // CQE commit input from CQE write path
    // ------------------------------------------------------------------
    input  logic                         cqe_commit_valid,       // CQE 已成功写入 CQ ring。
    output logic                         cqe_commit_ready,       // 本模块可接收 CQE commit。
    input  logic [CQ_ID_W-1:0]           cqe_commit_cqn,         // CQE 所属 CQN。
    input  logic [VF_ID_W-1:0]           cqe_commit_owner_function,// CQE 所属 function。
    input  logic                         cqe_commit_solicited,   // CQE 是否为 solicited completion。
    input  cmpl_status_e                 cqe_commit_status,      // CQE completion status。
    input  logic                         cqe_commit_error,       // CQE 是否表示严重错误。

    // ------------------------------------------------------------------
    // CQ context lookup/read interface
    // ------------------------------------------------------------------
    output logic                         cq_lookup_valid,        // CQ context lookup 请求有效。
    input  logic                         cq_lookup_ready,        // CQ context table 可接收 lookup。
    output logic [CQ_ID_W-1:0]           cq_lookup_cqn,          // 要查询的 CQN。
    output logic [VF_ID_W-1:0]           cq_lookup_function_id,  // 查询所属 function。
    output logic                         cq_lookup_admin_bypass, // notification path 不使用 admin bypass。
    input  logic                         cq_lookup_rsp_valid,    // CQ lookup 响应有效。
    output logic                         cq_lookup_rsp_ready,    // 本模块可接收 lookup 响应。
    input  logic                         cq_lookup_hit,          // CQ context 命中。
    input  logic                         cq_lookup_miss,         // CQ context 未命中。
    input  cq_table_status_e             cq_lookup_status,       // CQ lookup 状态。
    input  cq_context_t                  cq_lookup_context,      // 命中的 CQ context。

    // ------------------------------------------------------------------
    // Timer and MSI-X interface
    // ------------------------------------------------------------------
    input  logic                         timer_tick,             // moderation timer tick。
    input  logic                         msix_ready,             // 下游 MSI-X request path ready。
    output logic                         msix_req_valid,         // MSI-X request 有效。
    output logic [CQ_VECTOR_W-1:0]       msix_req_vector,        // MSI-X vector。
    output logic [CQ_ID_W-1:0]           msix_req_cqn,           // 触发通知的 CQN。
    output logic [VF_ID_W-1:0]           msix_req_owner_function,// 通知所属 function。
    output cq_notification_reason_e      msix_req_reason,        // 通知原因。

    // ------------------------------------------------------------------
    // CQ context update hints
    // ------------------------------------------------------------------
    output logic                         cq_context_update_valid,// moderation/armed 更新有效。
    output logic [CQ_ID_W-1:0]           cq_context_update_cqn,  // 要更新的 CQN。
    output logic [15:0]                  moderation_counter_update,// 新 moderation counter。
    output logic [15:0]                  moderation_timer_update,// 新 moderation timer counter。
    output logic                         armed_clear_update,     // 1 表示清除 CQ armed 标志。
    output cq_notification_error_e       notification_error_code,// 通知逻辑错误码。

    // ------------------------------------------------------------------
    // Debug/status
    // ------------------------------------------------------------------
    output cq_notification_state_e       debug_state             // 当前通知 FSM 状态。
);

    cq_notification_state_e state_reg;
    cq_notification_error_e error_reg;
    cq_context_t cq_ctx_reg;
    logic [CQ_ID_W-1:0] cqn_reg;
    logic [VF_ID_W-1:0] owner_function_reg;
    logic solicited_reg;
    cmpl_status_e status_reg;
    logic error_commit_reg;
    logic lookup_issued_reg;
    logic pending_timer_active_reg;
    logic [CQ_ID_W-1:0] pending_cqn_reg;
    logic [VF_ID_W-1:0] pending_owner_reg;
    logic [CQ_VECTOR_W-1:0] pending_vector_reg;
    logic [15:0] pending_counter_reg;
    logic [15:0] pending_timer_reg;
    logic [15:0] pending_timer_threshold_reg;
    cq_notification_reason_e reason_reg;
    logic issue_notify_reg;
    logic update_context_reg;
    logic clear_armed_reg;
    logic [15:0] next_counter_reg;
    logic [15:0] next_timer_reg;

    logic commit_fire;
    logic lookup_fire;
    logic lookup_rsp_fire;
    logic msix_fire;
    logic lookup_ok;
    logic vector_valid;
    logic armed_or_error;
    logic solicited_allowed;
    logic notify_candidate;
    logic moderation_immediate;
    logic moderation_count_hit;
    logic timer_fire;
    logic timer_due;
    logic [15:0] counter_plus_one;
    logic [15:0] timer_plus_one;

    assign debug_state = state_reg;
    assign notification_error_code = error_reg;

    assign cqe_commit_ready = (state_reg == CQ_NOTIFY_STATE_IDLE) && !timer_fire;
    assign commit_fire = cqe_commit_valid && cqe_commit_ready;

    assign cq_lookup_valid = (state_reg == CQ_NOTIFY_STATE_LOOKUP_CQ) && !lookup_issued_reg;
    assign cq_lookup_cqn = cqn_reg;
    assign cq_lookup_function_id = owner_function_reg;
    assign cq_lookup_admin_bypass = 1'b0;
    assign cq_lookup_rsp_ready = (state_reg == CQ_NOTIFY_STATE_CHECK_ARM);
    assign lookup_fire = cq_lookup_valid && cq_lookup_ready;
    assign lookup_rsp_fire = cq_lookup_rsp_valid && cq_lookup_rsp_ready;

    assign lookup_ok = cq_lookup_hit &&
                       !cq_lookup_miss &&
                       (cq_lookup_status == CQ_TABLE_STATUS_OK) &&
                       cq_lookup_context.valid &&
                       (cq_lookup_context.owner_function == owner_function_reg);
    assign vector_valid = (cq_ctx_reg.msix_vector < CQ_VECTOR_W'(PCIE_MSIX_VECTOR_COUNT));
    assign armed_or_error = cq_ctx_reg.armed || error_commit_reg;
    assign solicited_allowed = !cq_ctx_reg.solicited_only || solicited_reg || error_commit_reg;
    assign notify_candidate = armed_or_error && solicited_allowed;
    assign counter_plus_one = cq_ctx_reg.moderation_counter + 16'd1;
    assign moderation_immediate = (cq_ctx_reg.moderation_count <= 16'd1) || error_commit_reg;
    assign moderation_count_hit = moderation_immediate ||
                                  (counter_plus_one >= cq_ctx_reg.moderation_count);
    assign timer_plus_one = pending_timer_reg + 16'd1;
    assign timer_due = pending_timer_active_reg &&
                       (pending_timer_threshold_reg != 16'd0) &&
                       (pending_counter_reg != 16'd0) &&
                       (timer_plus_one >= pending_timer_threshold_reg);
    assign timer_fire = (state_reg == CQ_NOTIFY_STATE_IDLE) && timer_tick && timer_due;

    assign msix_req_valid = (state_reg == CQ_NOTIFY_STATE_ISSUE_MSIX);
    assign msix_req_vector = (reason_reg == CQ_NOTIFY_REASON_MOD_TIMER) && !issue_notify_reg ?
                             pending_vector_reg : cq_ctx_reg.msix_vector;
    assign msix_req_cqn = (reason_reg == CQ_NOTIFY_REASON_MOD_TIMER) && !issue_notify_reg ?
                          pending_cqn_reg : cqn_reg;
    assign msix_req_owner_function = (reason_reg == CQ_NOTIFY_REASON_MOD_TIMER) && !issue_notify_reg ?
                                     pending_owner_reg : owner_function_reg;
    assign msix_req_reason = reason_reg;
    assign msix_fire = msix_req_valid && msix_ready;

    assign cq_context_update_valid = (state_reg == CQ_NOTIFY_STATE_CLEAR_ARM) ||
                                     ((state_reg == CQ_NOTIFY_STATE_DONE) && update_context_reg);
    assign cq_context_update_cqn = (reason_reg == CQ_NOTIFY_REASON_MOD_TIMER) && !issue_notify_reg ?
                                   pending_cqn_reg : cqn_reg;
    assign moderation_counter_update = next_counter_reg;
    assign moderation_timer_update = next_timer_reg;
    assign armed_clear_update = clear_armed_reg;

    function automatic cq_notification_error_e lookup_status_to_notify_error(
        input cq_table_status_e status_i,
        input logic hit_i,
        input logic miss_i,
        input cq_context_t ctx_i,
        input logic [VF_ID_W-1:0] owner_i
    );
        begin
            if (!hit_i || miss_i || !ctx_i.valid || (status_i == CQ_TABLE_STATUS_MISS)) begin
                return CQ_NOTIFY_ERR_CQ_MISS;
            end
            if ((status_i == CQ_TABLE_STATUS_PERMISSION) || (ctx_i.owner_function != owner_i)) begin
                return CQ_NOTIFY_ERR_PERMISSION;
            end
            return CQ_NOTIFY_ERR_NONE;
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= CQ_NOTIFY_STATE_IDLE;
            error_reg <= CQ_NOTIFY_ERR_NONE;
            cq_ctx_reg <= '0;
            cqn_reg <= '0;
            owner_function_reg <= '0;
            solicited_reg <= 1'b0;
            status_reg <= CMPL_SUCCESS;
            error_commit_reg <= 1'b0;
            lookup_issued_reg <= 1'b0;
            pending_timer_active_reg <= 1'b0;
            pending_cqn_reg <= '0;
            pending_owner_reg <= '0;
            pending_vector_reg <= '0;
            pending_counter_reg <= 16'd0;
            pending_timer_reg <= 16'd0;
            pending_timer_threshold_reg <= 16'd0;
            reason_reg <= CQ_NOTIFY_REASON_COMPLETION;
            issue_notify_reg <= 1'b0;
            update_context_reg <= 1'b0;
            clear_armed_reg <= 1'b0;
            next_counter_reg <= 16'd0;
            next_timer_reg <= 16'd0;
        end else begin
            unique case (state_reg)
                CQ_NOTIFY_STATE_IDLE: begin
                    lookup_issued_reg <= 1'b0;
                    error_reg <= CQ_NOTIFY_ERR_NONE;
                    update_context_reg <= 1'b0;
                    clear_armed_reg <= 1'b0;
                    issue_notify_reg <= 1'b0;

                    if (timer_fire) begin
                        reason_reg <= CQ_NOTIFY_REASON_MOD_TIMER;
                        issue_notify_reg <= 1'b0;
                        next_counter_reg <= 16'd0;
                        next_timer_reg <= 16'd0;
                        clear_armed_reg <= 1'b1;
                        state_reg <= CQ_NOTIFY_STATE_ISSUE_MSIX;
                    end else if (pending_timer_active_reg && timer_tick) begin
                        pending_timer_reg <= timer_plus_one;
                    end else begin
                        if (commit_fire) begin
                            cqn_reg <= cqe_commit_cqn;
                            owner_function_reg <= cqe_commit_owner_function;
                            solicited_reg <= cqe_commit_solicited;
                            status_reg <= cqe_commit_status;
                            error_commit_reg <= cqe_commit_error || (cqe_commit_status != CMPL_SUCCESS);
                            state_reg <= CQ_NOTIFY_STATE_LOOKUP_CQ;
                        end
                    end
                end

                CQ_NOTIFY_STATE_LOOKUP_CQ: begin
                    if (lookup_fire) begin
                        lookup_issued_reg <= 1'b1;
                        state_reg <= CQ_NOTIFY_STATE_CHECK_ARM;
                    end
                end

                CQ_NOTIFY_STATE_CHECK_ARM: begin
                    if (lookup_rsp_fire) begin
                        if (!lookup_ok) begin
                            error_reg <= lookup_status_to_notify_error(cq_lookup_status,
                                                                       cq_lookup_hit,
                                                                       cq_lookup_miss,
                                                                       cq_lookup_context,
                                                                       owner_function_reg);
                            state_reg <= CQ_NOTIFY_STATE_ERROR;
                        end else begin
                            cq_ctx_reg <= cq_lookup_context;
                            state_reg <= CQ_NOTIFY_STATE_CHECK_SOL;
                        end
                    end
                end

                CQ_NOTIFY_STATE_CHECK_SOL: begin
                    if (!vector_valid && (cq_ctx_reg.armed || error_commit_reg)) begin
                        error_reg <= CQ_NOTIFY_ERR_VECTOR;
                        state_reg <= CQ_NOTIFY_STATE_ERROR;
                    end else if (!notify_candidate) begin
                        // Polling mode 或 solicited_only 未满足：CQE 保留给 poll_cq，不发 MSI-X。
                        state_reg <= CQ_NOTIFY_STATE_DONE;
                    end else begin
                        state_reg <= CQ_NOTIFY_STATE_UPDATE_MOD;
                    end
                end

                CQ_NOTIFY_STATE_UPDATE_MOD: begin
                    update_context_reg <= 1'b1;
                    if (moderation_count_hit) begin
                        next_counter_reg <= 16'd0;
                        next_timer_reg <= 16'd0;
                        clear_armed_reg <= 1'b1;
                        issue_notify_reg <= 1'b1;
                        reason_reg <= error_commit_reg ? CQ_NOTIFY_REASON_ERROR :
                                      (solicited_reg ? CQ_NOTIFY_REASON_SOLICITED :
                                       (moderation_immediate ? CQ_NOTIFY_REASON_COMPLETION :
                                        CQ_NOTIFY_REASON_MOD_COUNT));
                        state_reg <= CQ_NOTIFY_STATE_ISSUE_MSIX;
                    end else begin
                        next_counter_reg <= counter_plus_one;
                        next_timer_reg <= 16'd1;
                        pending_timer_active_reg <= (cq_ctx_reg.moderation_timer != 16'd0);
                        pending_cqn_reg <= cqn_reg;
                        pending_owner_reg <= owner_function_reg;
                        pending_vector_reg <= cq_ctx_reg.msix_vector;
                        pending_counter_reg <= counter_plus_one;
                        pending_timer_reg <= 16'd1;
                        pending_timer_threshold_reg <= cq_ctx_reg.moderation_timer;
                        clear_armed_reg <= 1'b0;
                        state_reg <= CQ_NOTIFY_STATE_DONE;
                    end
                end

                CQ_NOTIFY_STATE_WAIT_TIMER: begin
                    state_reg <= CQ_NOTIFY_STATE_IDLE;
                end

                CQ_NOTIFY_STATE_ISSUE_MSIX: begin
                    if (msix_fire) begin
                        pending_timer_active_reg <= 1'b0;
                        pending_counter_reg <= 16'd0;
                        pending_timer_reg <= 16'd0;
                        state_reg <= CQ_NOTIFY_STATE_CLEAR_ARM;
                    end
                end

                CQ_NOTIFY_STATE_CLEAR_ARM: begin
                    state_reg <= CQ_NOTIFY_STATE_DONE;
                end

                CQ_NOTIFY_STATE_DONE: begin
                    state_reg <= CQ_NOTIFY_STATE_IDLE;
                end

                CQ_NOTIFY_STATE_ERROR: begin
                    state_reg <= CQ_NOTIFY_STATE_IDLE;
                end

                default: begin
                    state_reg <= CQ_NOTIFY_STATE_IDLE;
                end
            endcase
        end
    end

endmodule : cq_notification
