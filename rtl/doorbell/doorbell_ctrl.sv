// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// Top-level Doorbell control path。
//
// 本模块接收 PCIe BAR0/MMIO Doorbell 写入后的简化事件，将 SQ/RQ/CQ_ARM
// Doorbell 分发到已有 3.x Doorbell handler，并连接到 QP/CQ manager 的
// producer/arm 更新接口。它不读取 WQE，不执行 RDMA 数据通路，也不生成 CQE。

`timescale 1ns/1ps

import smartnic_pkg::*;

module doorbell_ctrl (
    input  logic                         clk,                     // Doorbell 控制时钟。
    input  logic                         rst_n,                   // 低有效复位。

    // ------------------------------------------------------------------
    // PCIe BAR0 Doorbell event
    // ------------------------------------------------------------------
    input  logic                         db_valid,                // Doorbell 写入事件有效。
    output logic                         db_ready,                // 控制器可接收 Doorbell。
    input  logic [QP_ID_W-1:0]           db_qp_num,               // SQ/RQ 使用 QPN；CQ_ARM 使用低位 CQN。
    input  doorbell_type_e               db_type,                 // SQ、RQ 或 CQ_ARM。
    input  logic [PCIE_BAR_DATA_W-1:0]   db_value,                // producer index / consumer index / flags payload。
    input  logic [VF_ID_W-1:0]           db_owner_function,       // 发起 Doorbell 的 PF/VF function。
    input  logic                         csr_order_ready,         // CSR 配置已对 datapath 可见；当前 top 绑 1。

    // ------------------------------------------------------------------
    // Minimal ownership/context validity inputs
    // ------------------------------------------------------------------
    input  logic                         function_enabled,        // 当前 function 是否启用。
    input  sriov_resource_window_t       resource_window,         // 当前 function 可访问的 QP/CQ 窗口。
    input  logic                         qpn_valid_hint,          // QP context 有效性提示；真实 miss 由 QP table 再检查。
    input  logic                         cqn_valid_hint,          // CQ context 有效性提示；真实 miss 由 CQ table 再检查。
    input  logic [QUEUE_IDX_W-1:0]       current_sq_pi_hint,      // SQ PI 当前值提示，用于 wraparound 标记。
    input  logic [QUEUE_IDX_W-1:0]       current_rq_pi_hint,      // RQ PI 当前值提示，用于 wraparound 标记。

    // ------------------------------------------------------------------
    // QP SQ producer index update
    // ------------------------------------------------------------------
    output logic                         sq_pi_update_valid,      // SQ PI 更新请求有效。
    input  logic                         sq_pi_update_ready,      // QP manager 可接收 SQ PI 更新。
    output logic [QP_ID_W-1:0]           sq_pi_update_qpn,        // SQ PI 更新目标 QPN。
    output logic [VF_ID_W-1:0]           sq_pi_update_function_id,// SQ PI 更新所属 function。
    output logic [QUEUE_IDX_W-1:0]       sq_pi_update_new_pi,     // 新 SQ producer index。
    output logic                         sq_pi_update_error,      // SQ Doorbell handler 错误。

    // ------------------------------------------------------------------
    // QP RQ producer index update
    // ------------------------------------------------------------------
    output logic                         rq_pi_update_valid,      // RQ PI 更新请求有效。
    input  logic                         rq_pi_update_ready,      // QP manager 可接收 RQ PI 更新。
    output logic [QP_ID_W-1:0]           rq_pi_update_qpn,        // RQ PI 更新目标 QPN。
    output logic [VF_ID_W-1:0]           rq_pi_update_function_id,// RQ PI 更新所属 function。
    output logic [QUEUE_IDX_W-1:0]       rq_pi_update_new_pi,     // 新 RQ producer index。
    output logic                         rq_pi_update_error,      // RQ Doorbell handler 错误。

    // ------------------------------------------------------------------
    // CQ arm update
    // ------------------------------------------------------------------
    output logic                         cq_arm_valid,            // CQ arm 请求有效。
    input  logic                         cq_arm_ready,            // CQ manager 可接收 arm 请求。
    output logic [CQ_ID_W-1:0]           cq_arm_cqn,              // CQ arm 目标 CQN。
    output logic [VF_ID_W-1:0]           cq_arm_function_id,      // CQ arm 所属 function。
    output logic [QUEUE_IDX_W-1:0]       cq_arm_consumer_index,   // 软件提交的 CQ consumer index。
    output logic                         cq_arm_armed,            // 置 1 表示进入 armed 状态。
    output logic                         cq_arm_solicited_only,   // 只允许 solicited CQE 触发通知。
    output logic                         cq_arm_error,            // CQ arm Doorbell handler 错误。

    // ------------------------------------------------------------------
    // Scheduler wakeup hints
    // ------------------------------------------------------------------
    output logic                         sq_scheduler_valid,      // SQ scheduler wakeup 有效。
    input  logic                         sq_scheduler_ready,      // SQ scheduler 可接收 wakeup。
    output logic [QP_ID_W-1:0]           sq_scheduler_qpn,        // 被唤醒的 SQ QPN。
    output logic [VF_ID_W-1:0]           sq_scheduler_function_id,// SQ wakeup 所属 function。
    output logic                         rq_post_valid,           // RQ post-processing wakeup 有效。
    input  logic                         rq_post_ready,           // RQ/RX 路径可接收 wakeup。
    output logic [QP_ID_W-1:0]           rq_post_qpn,             // 新 posted receive buffer 所属 QPN。
    output logic [VF_ID_W-1:0]           rq_post_function_id,     // RQ wakeup 所属 function。

    // ------------------------------------------------------------------
    // Debug/status
    // ------------------------------------------------------------------
    output logic                         db_error_valid,          // Doorbell 错误事件有效。
    input  logic                         db_error_ready,          // 调试/统计路径可接收错误。
    output doorbell_error_e              db_error_code,           // Doorbell 错误码。
    output doorbell_type_e               debug_last_type,         // 最近接收的 Doorbell 类型。
    output logic [QP_ID_W-1:0]           debug_last_qp_num        // 最近接收的 QPN/CQN。
);

    logic pending_valid;
    logic [QP_ID_W-1:0] pending_qp_num;
    doorbell_type_e pending_type;
    logic [PCIE_BAR_DATA_W-1:0] pending_value;
    logic [VF_ID_W-1:0] pending_owner;
    logic pending_is_sq;
    logic pending_is_rq;
    logic pending_is_cq_arm;
    logic type_supported;
    logic target_in_window;
    logic access_allowed;
    logic access_error;
    sriov_access_status_e access_error_code;
    logic handler_accept;
    logic unsupported_accept;

    logic sq_db_valid;
    logic sq_db_ready;
    logic rq_db_valid;
    logic rq_db_ready;
    logic cq_db_valid;
    logic cq_db_ready;

    logic sq_handler_valid;
    logic sq_handler_ready;
    logic [QP_ID_W-1:0] sq_handler_qpn;
    logic [VF_ID_W-1:0] sq_handler_function_id;
    logic [QUEUE_IDX_W-1:0] sq_handler_new_pi;
    logic sq_handler_error;
    doorbell_error_e sq_handler_error_code;
    logic [DB_SEQUENCE_W-1:0] sq_handler_sequence;
    logic [DB_FLAGS_W-1:0] sq_handler_flags;
    logic sq_handler_wrap;

    logic rq_handler_valid;
    logic rq_handler_ready;
    logic [QP_ID_W-1:0] rq_handler_qpn;
    logic [VF_ID_W-1:0] rq_handler_function_id;
    logic [QUEUE_IDX_W-1:0] rq_handler_new_pi;
    logic rq_handler_error;
    doorbell_error_e rq_handler_error_code;
    logic [DB_SEQUENCE_W-1:0] rq_handler_sequence;
    logic [DB_FLAGS_W-1:0] rq_handler_flags;
    logic rq_handler_wrap;

    logic cq_handler_valid;
    logic cq_handler_ready;
    logic [CQ_ID_W-1:0] cq_handler_cqn;
    logic [VF_ID_W-1:0] cq_handler_function_id;
    logic [QUEUE_IDX_W-1:0] cq_handler_consumer_index;
    logic cq_handler_solicited_only;
    logic cq_handler_armed;
    logic cq_handler_error;
    doorbell_error_e cq_handler_error_code;
    logic [DB_SEQUENCE_W-1:0] cq_handler_sequence;
    logic [DB_FLAGS_W-1:0] cq_handler_flags;

    logic sq_update_fire;
    logic rq_update_fire;
    logic cq_arm_fire;
    logic sq_scheduler_fire;
    logic rq_post_fire;
    logic db_error_fire;

    assign pending_is_sq = (pending_type == DB_TYPE_SQ);
    assign pending_is_rq = (pending_type == DB_TYPE_RQ);
    assign pending_is_cq_arm = (pending_type == DB_TYPE_CQ_ARM);
    assign type_supported = pending_is_sq || pending_is_rq || pending_is_cq_arm;

    always_comb begin
        if (pending_is_cq_arm) begin
            target_in_window = (CQ_ID_W'(pending_qp_num) >= resource_window.cq_base) &&
                               (CQ_ID_W'(pending_qp_num) <= resource_window.cq_limit);
        end else begin
            target_in_window = (pending_qp_num >= resource_window.qp_base) &&
                               (pending_qp_num <= resource_window.qp_limit);
        end
    end

    assign access_allowed = function_enabled && type_supported && target_in_window && csr_order_ready;
    assign access_error = !access_allowed;
    assign access_error_code = !function_enabled ? SRIOV_ACCESS_DISABLED :
                               (!target_in_window ? SRIOV_ACCESS_OUT_OF_RANGE : SRIOV_ACCESS_DENIED);

    assign sq_db_valid = pending_valid && pending_is_sq;
    assign rq_db_valid = pending_valid && pending_is_rq;
    assign cq_db_valid = pending_valid && pending_is_cq_arm;
    assign handler_accept = (sq_db_valid && sq_db_ready) ||
                            (rq_db_valid && rq_db_ready) ||
                            (cq_db_valid && cq_db_ready) ||
                            unsupported_accept;
    assign unsupported_accept = pending_valid && !type_supported;

    assign db_ready = !pending_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_valid <= 1'b0;
            pending_qp_num <= '0;
            pending_type <= DB_TYPE_NONE;
            pending_value <= '0;
            pending_owner <= '0;
            debug_last_type <= DB_TYPE_NONE;
            debug_last_qp_num <= '0;
        end else begin
            if (handler_accept) begin
                pending_valid <= 1'b0;
            end

            if (db_valid && db_ready) begin
                pending_valid <= 1'b1;
                pending_qp_num <= db_qp_num;
                pending_type <= db_type;
                pending_value <= db_value;
                pending_owner <= db_owner_function;
                debug_last_type <= db_type;
                debug_last_qp_num <= db_qp_num;
            end
        end
    end

    sq_doorbell_handler u_sq_doorbell_handler (
        .clk(clk),
        .rst_n(rst_n),
        .sq_db_valid(sq_db_valid),
        .sq_db_ready(sq_db_ready),
        .doorbell_type(pending_type),
        .qpn(pending_qp_num),
        .queue_index(pending_value[QUEUE_IDX_W-1:0]),
        .raw_payload(pending_value),
        .owner_function(pending_owner),
        .access_allowed(access_allowed),
        .access_error(access_error),
        .access_error_code(access_error_code),
        .qpn_valid(qpn_valid_hint),
        .current_sq_producer_index(current_sq_pi_hint),
        .qp_update_valid(sq_handler_valid),
        .qp_update_ready(sq_handler_ready),
        .qp_update_qpn(sq_handler_qpn),
        .qp_update_function_id(sq_handler_function_id),
        .qp_update_new_sq_pi(sq_handler_new_pi),
        .qp_update_wraparound(sq_handler_wrap),
        .qp_update_error(sq_handler_error),
        .qp_update_error_code(sq_handler_error_code),
        .qp_update_doorbell_sequence(sq_handler_sequence),
        .qp_update_flags(sq_handler_flags)
    );

    rq_doorbell_handler u_rq_doorbell_handler (
        .clk(clk),
        .rst_n(rst_n),
        .rq_db_valid(rq_db_valid),
        .rq_db_ready(rq_db_ready),
        .doorbell_type(pending_type),
        .qpn(pending_qp_num),
        .queue_index(pending_value[QUEUE_IDX_W-1:0]),
        .raw_payload(pending_value),
        .owner_function(pending_owner),
        .access_allowed(access_allowed),
        .access_error(access_error),
        .access_error_code(access_error_code),
        .qpn_valid(qpn_valid_hint),
        .current_rq_producer_index(current_rq_pi_hint),
        .qp_rq_update_valid(rq_handler_valid),
        .qp_rq_update_ready(rq_handler_ready),
        .qp_rq_update_qpn(rq_handler_qpn),
        .qp_rq_update_function_id(rq_handler_function_id),
        .qp_rq_update_new_pi(rq_handler_new_pi),
        .qp_rq_update_wraparound(rq_handler_wrap),
        .qp_rq_update_error(rq_handler_error),
        .qp_rq_update_error_code(rq_handler_error_code),
        .qp_rq_update_doorbell_sequence(rq_handler_sequence),
        .qp_rq_update_flags(rq_handler_flags)
    );

    cq_arm_doorbell_handler u_cq_arm_doorbell_handler (
        .clk(clk),
        .rst_n(rst_n),
        .cq_db_valid(cq_db_valid),
        .cq_db_ready(cq_db_ready),
        .doorbell_type(pending_type),
        .cqn(CQ_ID_W'(pending_qp_num)),
        .queue_index(pending_value[QUEUE_IDX_W-1:0]),
        .raw_payload(pending_value),
        .owner_function(pending_owner),
        .access_allowed(access_allowed),
        .access_error(access_error),
        .access_error_code(access_error_code),
        .cqn_valid(cqn_valid_hint),
        .cq_arm_valid(cq_handler_valid),
        .cq_arm_ready(cq_handler_ready),
        .cq_arm_cqn(cq_handler_cqn),
        .cq_arm_function_id(cq_handler_function_id),
        .cq_arm_consumer_index(cq_handler_consumer_index),
        .cq_arm_solicited_only(cq_handler_solicited_only),
        .cq_arm_armed(cq_handler_armed),
        .cq_arm_error(cq_handler_error),
        .cq_arm_error_code(cq_handler_error_code),
        .cq_arm_sequence(cq_handler_sequence),
        .cq_arm_flags(cq_handler_flags)
    );

    assign sq_pi_update_valid = sq_handler_valid;
    assign sq_handler_ready = sq_pi_update_ready;
    assign sq_pi_update_qpn = sq_handler_qpn;
    assign sq_pi_update_function_id = sq_handler_function_id;
    assign sq_pi_update_new_pi = sq_handler_new_pi;
    assign sq_pi_update_error = sq_handler_error;

    assign rq_pi_update_valid = rq_handler_valid;
    assign rq_handler_ready = rq_pi_update_ready;
    assign rq_pi_update_qpn = rq_handler_qpn;
    assign rq_pi_update_function_id = rq_handler_function_id;
    assign rq_pi_update_new_pi = rq_handler_new_pi;
    assign rq_pi_update_error = rq_handler_error;

    assign cq_arm_valid = cq_handler_valid;
    assign cq_handler_ready = cq_arm_ready;
    assign cq_arm_cqn = cq_handler_cqn;
    assign cq_arm_function_id = cq_handler_function_id;
    assign cq_arm_consumer_index = cq_handler_consumer_index;
    assign cq_arm_armed = cq_handler_armed;
    assign cq_arm_solicited_only = cq_handler_solicited_only;
    assign cq_arm_error = cq_handler_error;

    assign sq_update_fire = sq_handler_valid && sq_pi_update_ready;
    assign rq_update_fire = rq_handler_valid && rq_pi_update_ready;
    assign cq_arm_fire = cq_handler_valid && cq_arm_ready;
    assign sq_scheduler_fire = sq_scheduler_valid && sq_scheduler_ready;
    assign rq_post_fire = rq_post_valid && rq_post_ready;
    assign db_error_fire = db_error_valid && db_error_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sq_scheduler_valid <= 1'b0;
            sq_scheduler_qpn <= '0;
            sq_scheduler_function_id <= '0;
            rq_post_valid <= 1'b0;
            rq_post_qpn <= '0;
            rq_post_function_id <= '0;
            db_error_valid <= 1'b0;
            db_error_code <= DB_ERR_NONE;
        end else begin
            if (sq_scheduler_fire) begin
                sq_scheduler_valid <= 1'b0;
            end
            if (rq_post_fire) begin
                rq_post_valid <= 1'b0;
            end
            if (db_error_fire) begin
                db_error_valid <= 1'b0;
            end

            if (sq_update_fire) begin
                if (sq_handler_error) begin
                    db_error_valid <= 1'b1;
                    db_error_code <= sq_handler_error_code;
                end else begin
                    sq_scheduler_valid <= 1'b1;
                    sq_scheduler_qpn <= sq_handler_qpn;
                    sq_scheduler_function_id <= sq_handler_function_id;
                end
            end

            if (rq_update_fire) begin
                if (rq_handler_error) begin
                    db_error_valid <= 1'b1;
                    db_error_code <= rq_handler_error_code;
                end else begin
                    rq_post_valid <= 1'b1;
                    rq_post_qpn <= rq_handler_qpn;
                    rq_post_function_id <= rq_handler_function_id;
                end
            end

            if (cq_arm_fire && cq_handler_error) begin
                db_error_valid <= 1'b1;
                db_error_code <= cq_handler_error_code;
            end

            if (unsupported_accept) begin
                db_error_valid <= 1'b1;
                db_error_code <= DB_ERR_BAD_PAYLOAD;
            end
        end
    end

    // 当前阶段保留 handler 调试字段，后续可映射到统计/trace CSR。
    logic unused_sq_wrap;
    logic unused_rq_wrap;
    logic [DB_SEQUENCE_W-1:0] unused_sq_sequence;
    logic [DB_SEQUENCE_W-1:0] unused_rq_sequence;
    logic [DB_SEQUENCE_W-1:0] unused_cq_sequence;
    logic [DB_FLAGS_W-1:0] unused_sq_flags;
    logic [DB_FLAGS_W-1:0] unused_rq_flags;
    logic [DB_FLAGS_W-1:0] unused_cq_flags;

    assign unused_sq_wrap = sq_handler_wrap;
    assign unused_rq_wrap = rq_handler_wrap;
    assign unused_sq_sequence = sq_handler_sequence;
    assign unused_rq_sequence = rq_handler_sequence;
    assign unused_cq_sequence = cq_handler_sequence;
    assign unused_sq_flags = sq_handler_flags;
    assign unused_rq_flags = rq_handler_flags;
    assign unused_cq_flags = cq_handler_flags;

endmodule : doorbell_ctrl
