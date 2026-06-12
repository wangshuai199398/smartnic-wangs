// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// QP lifecycle command manager 最小实现。
//
// 本模块把 CSR mailbox/admin command path 的 QP 命令翻译成 QP context table
// 的 lookup/read/write 操作。当前阶段只实现 create/modify/query/destroy/error
// transition 框架，不实现完整 IBTA 状态迁移校验，不读取 WQE，也不执行
// RDMA 数据通路。DESTROY_QP 和 QP_TO_ERROR 通过 cleanup manager 接口完成
// pending work quiesce 和 flushed completion 框架。

`timescale 1ns/1ps

import smartnic_pkg::*;

module qp_lifecycle_manager (
    input  logic                         clk,                    // QP lifecycle manager 时钟。
    input  logic                         rst_n,                  // 低有效复位。

    // ------------------------------------------------------------------
    // Admin/CSR command input
    // ------------------------------------------------------------------
    input  logic                         cmd_valid,              // QP lifecycle 命令有效。
    output logic                         cmd_ready,              // 本模块可接收命令。
    input  csr_cmd_e                     cmd_id,                 // 命令 ID：CREATE/MODIFY/QUERY/DESTROY/QP_TO_ERROR。
    input  logic [QP_ID_W-1:0]           cmd_qpn,                // 目标 QPN。
    input  logic [VF_ID_W-1:0]           cmd_owner_function,     // 命令所属 PF/VF function。
    input  logic                         cmd_admin_bypass,       // PF/admin 路径权限绕过预留。
    input  qp_context_t                  cmd_qp_context,         // CREATE/MODIFY 使用的 QP context payload。
    input  logic [31:0]                  cmd_modify_mask,        // MODIFY_QP 字段更新 mask。
    input  logic [15:0]                  cmd_sequence,           // 上游命令序号，响应时原样返回。
    input  logic [15:0]                  cmd_error_code,         // QP_TO_ERROR 或 MODIFY error 字段使用的错误码。

    // ------------------------------------------------------------------
    // Admin/CSR command response
    // ------------------------------------------------------------------
    output logic                         cmd_rsp_valid,          // QP lifecycle 响应有效。
    input  logic                         cmd_rsp_ready,          // 上游已接收响应。
    output logic [15:0]                  cmd_rsp_sequence,       // 响应对应的命令序号。
    output qp_lifecycle_status_e         cmd_status,             // 命令执行状态。
    output qp_lifecycle_error_e          cmd_rsp_error_code,     // 命令错误码。
    output qp_context_t                  cmd_rsp_qp_context,     // QUERY 或更新后的 QP context。

    // ------------------------------------------------------------------
    // QP cleanup manager interface
    // ------------------------------------------------------------------
    output logic                         cleanup_destroy_valid,  // DESTROY_QP cleanup 请求有效。
    input  logic                         cleanup_destroy_ready,  // cleanup manager 可接收 DESTROY_QP。
    output logic [QP_ID_W-1:0]           cleanup_destroy_qpn,    // cleanup 目标 QPN。
    output logic [VF_ID_W-1:0]           cleanup_destroy_function_id,// cleanup 请求 function。
    output logic                         cleanup_destroy_admin_bypass,// admin 权限绕过。
    output logic [15:0]                  cleanup_destroy_sequence,// cleanup 请求序号。
    output logic                         cleanup_error_valid,    // QP_TO_ERROR cleanup 请求有效。
    input  logic                         cleanup_error_ready,    // cleanup manager 可接收 QP_TO_ERROR。
    output logic [QP_ID_W-1:0]           cleanup_error_qpn,      // cleanup 目标 QPN。
    output logic [VF_ID_W-1:0]           cleanup_error_function_id,// cleanup 请求 function。
    output logic                         cleanup_error_admin_bypass,// admin 权限绕过。
    output logic [15:0]                  cleanup_error_error_code,// 写入 QP context 的错误码。
    output logic [15:0]                  cleanup_error_sequence, // cleanup 请求序号。
    input  logic                         cleanup_done_valid,     // cleanup manager 响应有效。
    output logic                         cleanup_done_ready,     // lifecycle 已接收 cleanup 响应。
    input  qp_cleanup_error_e            cleanup_done_error_code,// cleanup 错误码。
    input  qp_context_t                  cleanup_done_context,   // cleanup 后 context。

    output qp_lifecycle_state_e          lifecycle_state         // 调试可见的 lifecycle FSM 状态。
);

    qp_lifecycle_state_e state_reg;             // 当前 lifecycle FSM 状态。
    csr_cmd_e cmd_id_reg;                       // 已接收命令 ID。
    logic [QP_ID_W-1:0] cmd_qpn_reg;            // 已接收 QPN。
    logic [VF_ID_W-1:0] cmd_owner_function_reg; // 已接收 owner function。
    logic cmd_admin_bypass_reg;                 // 已接收 admin bypass。
    qp_context_t cmd_payload_reg;               // 已接收 context payload。
    logic [31:0] cmd_modify_mask_reg;           // 已接收 modify mask。
    logic [15:0] cmd_sequence_reg;              // 已接收命令序号。
    logic [15:0] cmd_error_code_reg;            // 已接收命令错误码。
    qp_context_t lookup_context_reg;            // LOOKUP 阶段读出的 context。
    qp_table_status_e lookup_status_reg;        // LOOKUP 阶段 QP 表状态。
    qp_context_t update_context_reg;            // UPDATE 阶段要写回的 context。
    qp_lifecycle_error_e error_code_next_reg;   // 当前命令失败原因。
    logic lookup_issued_reg;                    // LOOKUP 请求是否已发出。
    logic update_issued_reg;                    // UPDATE 请求是否已发出。

    logic cmd_fire;                             // 命令输入握手成功。
    logic rsp_fire;                             // 响应握手成功。
    logic table_read_valid;                     // 内部 QP 表读请求。
    logic table_read_ready;                     // 内部 QP 表可接收读请求。
    logic table_read_rsp_valid;                 // 内部 QP 表读响应有效。
    logic table_read_hit;                       // 内部 QP 表读命中。
    qp_table_status_e table_read_status;        // 内部 QP 表读状态。
    qp_context_t table_read_data;               // 内部 QP 表读数据。
    logic table_write_valid;                    // 内部 QP 表写请求。
    logic table_write_ready;                    // 内部 QP 表可接收写请求。
    logic table_write_rsp_valid;                // 内部 QP 表写响应有效。
    qp_table_status_e table_write_status;       // 内部 QP 表写状态。
    logic cleanup_req_issued_reg;               // cleanup 请求是否已发出。
    logic cleanup_destroy_fire;                 // cleanup destroy 请求握手。
    logic cleanup_error_fire;                   // cleanup error 请求握手。
    logic cleanup_done_fire;                    // cleanup 响应握手。
    logic state_validate_valid;                 // MODIFY_QP 状态修改校验请求。
    qp_type_e state_validate_qp_type;           // 状态校验使用的 QP type。
    logic state_validate_allowed;               // 状态校验是否允许迁移。
    qp_state_validate_error_e state_validate_error_code; // 状态校验错误码。
    logic [31:0] state_required_attr_mask;      // 状态迁移需要的属性 mask。
    logic [31:0] state_missing_attr_mask;       // 状态迁移缺失的属性 mask。

    assign lifecycle_state = state_reg;
    assign cmd_ready = (state_reg == QP_LC_STATE_IDLE) && (!cmd_rsp_valid || cmd_rsp_ready);
    assign cmd_fire = cmd_valid && cmd_ready;
    assign rsp_fire = cmd_rsp_valid && cmd_rsp_ready;

    assign table_read_valid = (state_reg == QP_LC_STATE_LOOKUP) && !lookup_issued_reg;
    assign table_write_valid = (state_reg == QP_LC_STATE_UPDATE) && !update_issued_reg;
    assign cleanup_destroy_valid = (state_reg == QP_LC_STATE_CLEANUP) &&
                                   (cmd_id_reg == CSR_CMD_DESTROY_QP) &&
                                   !cleanup_req_issued_reg;
    assign cleanup_destroy_qpn = cmd_qpn_reg;
    assign cleanup_destroy_function_id = cmd_owner_function_reg;
    assign cleanup_destroy_admin_bypass = cmd_admin_bypass_reg;
    assign cleanup_destroy_sequence = cmd_sequence_reg;
    assign cleanup_error_valid = (state_reg == QP_LC_STATE_CLEANUP) &&
                                 (cmd_id_reg == CSR_CMD_QP_TO_ERROR) &&
                                 !cleanup_req_issued_reg;
    assign cleanup_error_qpn = cmd_qpn_reg;
    assign cleanup_error_function_id = cmd_owner_function_reg;
    assign cleanup_error_admin_bypass = cmd_admin_bypass_reg;
    assign cleanup_error_error_code = cmd_error_code_reg;
    assign cleanup_error_sequence = cmd_sequence_reg;
    assign cleanup_done_ready = (state_reg == QP_LC_STATE_CLEANUP);
    assign cleanup_destroy_fire = cleanup_destroy_valid && cleanup_destroy_ready;
    assign cleanup_error_fire = cleanup_error_valid && cleanup_error_ready;
    assign cleanup_done_fire = cleanup_done_valid && cleanup_done_ready;
    assign state_validate_valid = (cmd_id_reg == CSR_CMD_MODIFY_QP) &&
                                  ((cmd_modify_mask_reg & QP_MOD_MASK_STATE) != 32'h0000_0000);
    assign state_validate_qp_type = ((cmd_modify_mask_reg & QP_MOD_MASK_TYPE) != 32'h0000_0000) ?
                                    cmd_payload_reg.qp_type : lookup_context_reg.qp_type;

    function automatic logic command_supported(input csr_cmd_e command_id);
        begin
            unique case (command_id)
                CSR_CMD_CREATE_QP,
                CSR_CMD_MODIFY_QP,
                CSR_CMD_QUERY_QP,
                CSR_CMD_DESTROY_QP,
                CSR_CMD_QP_TO_ERROR: command_supported = 1'b1;
                default:             command_supported = 1'b0;
            endcase
        end
    endfunction

    function automatic logic owner_function_valid(input logic [VF_ID_W-1:0] owner_function);
        begin
            return owner_function < VF_ID_W'(SRIOV_FUNCTION_COUNT);
        end
    endfunction

    function automatic logic legal_create_state(input qp_state_e state);
        begin
            return (state == QP_STATE_RESET) || (state == QP_STATE_INIT);
        end
    endfunction

    function automatic qp_lifecycle_error_e table_status_to_error(input qp_table_status_e status);
        begin
            unique case (status)
                QP_TABLE_STATUS_MISS:       return QP_LC_ERR_NOT_FOUND;
                QP_TABLE_STATUS_PERMISSION: return QP_LC_ERR_PERMISSION;
                QP_TABLE_STATUS_ALIAS:      return QP_LC_ERR_DUPLICATE_QPN;
                QP_TABLE_STATUS_FULL:       return QP_LC_ERR_TABLE_FULL;
                default:                    return QP_LC_ERR_TABLE_ERROR;
            endcase
        end
    endfunction

    function automatic qp_lifecycle_error_e state_validate_to_lifecycle_error(
        input qp_state_validate_error_e status
    );
        begin
            unique case (status)
                QP_STATE_VAL_ERR_MISSING_ATTR: return QP_LC_ERR_MISSING_ATTR;
                QP_STATE_VAL_ERR_TRANSITION,
                QP_STATE_VAL_ERR_QP_TYPE:      return QP_LC_ERR_STATE_TRANSITION;
                default:                       return QP_LC_ERR_BAD_STATE;
            endcase
        end
    endfunction

    function automatic qp_context_t build_create_context(
        input logic [QP_ID_W-1:0]   qpn,
        input logic [VF_ID_W-1:0]   owner_function,
        input qp_context_t          payload
    );
        qp_context_t ctx;
        begin
            ctx = payload;
            ctx.valid = 1'b1;
            ctx.owner_func = owner_function;
            ctx.qpn = qpn;
            ctx.sq_producer = '0;
            ctx.sq_consumer = '0;
            ctx.rq_producer = '0;
            ctx.rq_consumer = '0;
            ctx.error_state = 1'b0;
            ctx.error_code = 16'h0000;
            return ctx;
        end
    endfunction

    function automatic qp_context_t apply_modify_mask(
        input qp_context_t current_ctx,
        input qp_context_t payload,
        input logic [31:0] mask
    );
        qp_context_t next_ctx;
        begin
            next_ctx = current_ctx;

            if ((mask & QP_MOD_MASK_STATE) != 32'h0) begin
                next_ctx.state = payload.state;
            end
            if ((mask & QP_MOD_MASK_TYPE) != 32'h0) begin
                next_ctx.qp_type = payload.qp_type;
            end
            if ((mask & QP_MOD_MASK_PD) != 32'h0) begin
                next_ctx.pd_id = payload.pd_id;
            end
            if ((mask & QP_MOD_MASK_CQ) != 32'h0) begin
                next_ctx.send_cqn = payload.send_cqn;
                next_ctx.recv_cqn = payload.recv_cqn;
            end
            if ((mask & QP_MOD_MASK_QUEUE_ADDR) != 32'h0) begin
                next_ctx.sq_base = payload.sq_base;
                next_ctx.rq_base = payload.rq_base;
            end
            if ((mask & QP_MOD_MASK_QUEUE_DEPTH) != 32'h0) begin
                next_ctx.sq_depth = payload.sq_depth;
                next_ctx.rq_depth = payload.rq_depth;
            end
            if ((mask & QP_MOD_MASK_QUEUE_INDEX) != 32'h0) begin
                next_ctx.sq_producer = payload.sq_producer;
                next_ctx.sq_consumer = payload.sq_consumer;
                next_ctx.rq_producer = payload.rq_producer;
                next_ctx.rq_consumer = payload.rq_consumer;
            end
            if ((mask & QP_MOD_MASK_PSN) != 32'h0) begin
                next_ctx.sq_psn = payload.sq_psn;
                next_ctx.rq_psn = payload.rq_psn;
                next_ctx.last_acked_psn = payload.last_acked_psn;
            end
            if ((mask & QP_MOD_MASK_RETRY) != 32'h0) begin
                next_ctx.retry_count = payload.retry_count;
                next_ctx.rnr_retry_count = payload.rnr_retry_count;
            end
            if ((mask & QP_MOD_MASK_REMOTE_QPN) != 32'h0) begin
                next_ctx.remote_qpn = payload.remote_qpn;
            end
            if ((mask & QP_MOD_MASK_KEYS) != 32'h0) begin
                next_ctx.pkey = payload.pkey;
                next_ctx.qkey = payload.qkey;
            end
            if ((mask & QP_MOD_MASK_AH) != 32'h0) begin
                next_ctx.ah_id = payload.ah_id;
            end
            if ((mask & QP_MOD_MASK_ERROR) != 32'h0) begin
                next_ctx.error_state = payload.error_state;
                next_ctx.error_code = payload.error_code;
            end

            next_ctx.valid = current_ctx.valid;
            next_ctx.owner_func = current_ctx.owner_func;
            next_ctx.qpn = current_ctx.qpn;
            return next_ctx;
        end
    endfunction

    function automatic qp_context_t build_error_context(
        input qp_context_t current_ctx,
        input logic [15:0] error_code
    );
        qp_context_t next_ctx;
        begin
            next_ctx = current_ctx;
            next_ctx.state = QP_STATE_ERR;
            next_ctx.error_state = 1'b1;
            next_ctx.error_code = error_code;
            return next_ctx;
        end
    endfunction

    qp_state_validator state_validator (
        .validate_valid(state_validate_valid),
        .current_state(lookup_context_reg.state),
        .requested_state(cmd_payload_reg.state),
        .qp_type(state_validate_qp_type),
        .modify_mask(cmd_modify_mask_reg),
        .validate_allowed(state_validate_allowed),
        .validate_error_code(state_validate_error_code),
        .required_attr_mask(state_required_attr_mask),
        .missing_attr_mask(state_missing_attr_mask)
    );

    qp_context_table context_table (
        .clk(clk),
        .rst_n(rst_n),

        .lookup_valid(1'b0),
        .lookup_ready(),
        .lookup_qpn('0),
        .lookup_function_id('0),
        .lookup_pf_bypass(1'b0),
        .lookup_rsp_valid(),
        .lookup_rsp_ready(1'b1),
        .lookup_hit(),
        .lookup_miss(),
        .lookup_status(),
        .lookup_context(),

        .context_write_valid(table_write_valid),
        .context_write_ready(table_write_ready),
        .context_write_qpn(cmd_qpn_reg),
        .context_write_function_id(cmd_owner_function_reg),
        .context_write_pf_bypass(cmd_admin_bypass_reg),
        .context_write_use_index(1'b0),
        .context_write_index('0),
        .context_write_data(update_context_reg),
        .context_write_rsp_valid(table_write_rsp_valid),
        .context_write_rsp_ready(state_reg == QP_LC_STATE_UPDATE),
        .context_write_status(table_write_status),

        .context_read_valid(table_read_valid),
        .context_read_ready(table_read_ready),
        .context_read_qpn(cmd_qpn_reg),
        .context_read_function_id(cmd_owner_function_reg),
        .context_read_pf_bypass((cmd_id_reg == CSR_CMD_CREATE_QP) ? 1'b1 : cmd_admin_bypass_reg),
        .context_read_rsp_valid(table_read_rsp_valid),
        .context_read_rsp_ready(state_reg == QP_LC_STATE_LOOKUP),
        .context_read_hit(table_read_hit),
        .context_read_status(table_read_status),
        .context_read_data(table_read_data),

        .sq_pi_update_valid(1'b0),
        .sq_pi_update_ready(),
        .sq_pi_update_qpn('0),
        .sq_pi_update_function_id('0),
        .sq_pi_update_new_pi('0),
        .sq_pi_update_error(1'b0),
        .sq_pi_update_rsp_valid(),
        .sq_pi_update_rsp_ready(1'b1),
        .sq_pi_update_status(),

        .rq_pi_update_valid(1'b0),
        .rq_pi_update_ready(),
        .rq_pi_update_qpn('0),
        .rq_pi_update_function_id('0),
        .rq_pi_update_new_pi('0),
        .rq_pi_update_error(1'b0),
        .rq_pi_update_rsp_valid(),
        .rq_pi_update_rsp_ready(1'b1),
        .rq_pi_update_status()
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= QP_LC_STATE_IDLE;
            cmd_id_reg <= CSR_CMD_NOP;
            cmd_qpn_reg <= '0;
            cmd_owner_function_reg <= '0;
            cmd_admin_bypass_reg <= 1'b0;
            cmd_payload_reg <= '0;
            cmd_modify_mask_reg <= 32'h0000_0000;
            cmd_sequence_reg <= 16'h0000;
            cmd_error_code_reg <= 16'h0000;
            lookup_context_reg <= '0;
            lookup_status_reg <= QP_TABLE_STATUS_MISS;
            update_context_reg <= '0;
            error_code_next_reg <= QP_LC_ERR_NONE;
            lookup_issued_reg <= 1'b0;
            update_issued_reg <= 1'b0;
            cleanup_req_issued_reg <= 1'b0;
            cmd_rsp_valid <= 1'b0;
            cmd_rsp_sequence <= 16'h0000;
            cmd_status <= QP_LC_STATUS_IDLE;
            cmd_rsp_error_code <= QP_LC_ERR_NONE;
            cmd_rsp_qp_context <= '0;
        end else begin
            if (rsp_fire) begin
                cmd_rsp_valid <= 1'b0;
                if (state_reg == QP_LC_STATE_DONE || state_reg == QP_LC_STATE_ERROR) begin
                    state_reg <= QP_LC_STATE_IDLE;
                    cmd_status <= QP_LC_STATUS_IDLE;
                    cmd_rsp_error_code <= QP_LC_ERR_NONE;
                end
            end

            unique case (state_reg)
                QP_LC_STATE_IDLE: begin
                    lookup_issued_reg <= 1'b0;
                    update_issued_reg <= 1'b0;
                    cleanup_req_issued_reg <= 1'b0;

                    if (cmd_fire) begin
                        cmd_id_reg <= cmd_id;
                        cmd_qpn_reg <= cmd_qpn;
                        cmd_owner_function_reg <= cmd_owner_function;
                        cmd_admin_bypass_reg <= cmd_admin_bypass;
                        cmd_payload_reg <= cmd_qp_context;
                        cmd_modify_mask_reg <= cmd_modify_mask;
                        cmd_sequence_reg <= cmd_sequence;
                        cmd_error_code_reg <= cmd_error_code;
                        cmd_rsp_sequence <= cmd_sequence;
                        cmd_rsp_qp_context <= '0;
                        cmd_status <= QP_LC_STATUS_BUSY;
                        cmd_rsp_error_code <= QP_LC_ERR_NONE;

                        if (!command_supported(cmd_id)) begin
                            error_code_next_reg <= QP_LC_ERR_INVALID_CMD;
                            state_reg <= QP_LC_STATE_ERROR;
                        end else if (!owner_function_valid(cmd_owner_function)) begin
                            error_code_next_reg <= QP_LC_ERR_INVALID_OWNER;
                            state_reg <= QP_LC_STATE_ERROR;
                        end else begin
                            state_reg <= QP_LC_STATE_LOOKUP;
                        end
                    end
                end

                QP_LC_STATE_LOOKUP: begin
                    if (table_read_valid && table_read_ready) begin
                        lookup_issued_reg <= 1'b1;
                    end

                    if (table_read_rsp_valid) begin
                        lookup_context_reg <= table_read_data;
                        lookup_status_reg <= table_read_status;
                        lookup_issued_reg <= 1'b0;
                        state_reg <= QP_LC_STATE_EXECUTE;
                    end
                end

                QP_LC_STATE_EXECUTE: begin
                    unique case (cmd_id_reg)
                        CSR_CMD_CREATE_QP: begin
                            if (lookup_status_reg == QP_TABLE_STATUS_OK) begin
                                error_code_next_reg <= QP_LC_ERR_DUPLICATE_QPN;
                                state_reg <= QP_LC_STATE_ERROR;
                            end else if (lookup_status_reg != QP_TABLE_STATUS_MISS) begin
                                error_code_next_reg <= table_status_to_error(lookup_status_reg);
                                state_reg <= QP_LC_STATE_ERROR;
                            end else if (!legal_create_state(cmd_payload_reg.state)) begin
                                error_code_next_reg <= QP_LC_ERR_BAD_STATE;
                                state_reg <= QP_LC_STATE_ERROR;
                            end else begin
                                update_context_reg <= build_create_context(cmd_qpn_reg,
                                                                           cmd_owner_function_reg,
                                                                           cmd_payload_reg);
                                state_reg <= QP_LC_STATE_UPDATE;
                            end
                        end

                        CSR_CMD_MODIFY_QP: begin
                            if (lookup_status_reg != QP_TABLE_STATUS_OK) begin
                                error_code_next_reg <= table_status_to_error(lookup_status_reg);
                                state_reg <= QP_LC_STATE_ERROR;
                            end else if (state_validate_valid && !state_validate_allowed) begin
                                error_code_next_reg <= state_validate_to_lifecycle_error(state_validate_error_code);
                                state_reg <= QP_LC_STATE_ERROR;
                            end else begin
                                update_context_reg <= apply_modify_mask(lookup_context_reg,
                                                                        cmd_payload_reg,
                                                                        cmd_modify_mask_reg);
                                state_reg <= QP_LC_STATE_UPDATE;
                            end
                        end

                        CSR_CMD_QUERY_QP: begin
                            if (lookup_status_reg != QP_TABLE_STATUS_OK) begin
                                error_code_next_reg <= table_status_to_error(lookup_status_reg);
                                state_reg <= QP_LC_STATE_ERROR;
                            end else begin
                                cmd_rsp_qp_context <= lookup_context_reg;
                                cmd_status <= QP_LC_STATUS_SUCCESS;
                                cmd_rsp_error_code <= QP_LC_ERR_NONE;
                                cmd_rsp_valid <= 1'b1;
                                state_reg <= QP_LC_STATE_DONE;
                            end
                        end

                        CSR_CMD_DESTROY_QP: begin
                            if (lookup_status_reg != QP_TABLE_STATUS_OK) begin
                                error_code_next_reg <= table_status_to_error(lookup_status_reg);
                                state_reg <= QP_LC_STATE_ERROR;
                            end else begin
                                cleanup_req_issued_reg <= 1'b0;
                                state_reg <= QP_LC_STATE_CLEANUP;
                            end
                        end

                        CSR_CMD_QP_TO_ERROR: begin
                            if (lookup_status_reg != QP_TABLE_STATUS_OK) begin
                                error_code_next_reg <= table_status_to_error(lookup_status_reg);
                                state_reg <= QP_LC_STATE_ERROR;
                            end else begin
                                cleanup_req_issued_reg <= 1'b0;
                                state_reg <= QP_LC_STATE_CLEANUP;
                            end
                        end

                        default: begin
                            error_code_next_reg <= QP_LC_ERR_INVALID_CMD;
                            state_reg <= QP_LC_STATE_ERROR;
                        end
                    endcase
                end

                QP_LC_STATE_UPDATE: begin
                    if (table_write_valid && table_write_ready) begin
                        update_issued_reg <= 1'b1;
                    end

                    if (table_write_rsp_valid) begin
                        update_issued_reg <= 1'b0;
                        if (table_write_status == QP_TABLE_STATUS_OK) begin
                            cmd_rsp_qp_context <= update_context_reg;
                            cmd_status <= QP_LC_STATUS_SUCCESS;
                            cmd_rsp_error_code <= QP_LC_ERR_NONE;
                            cmd_rsp_valid <= 1'b1;
                            state_reg <= QP_LC_STATE_DONE;
                        end else begin
                            error_code_next_reg <= table_status_to_error(table_write_status);
                            state_reg <= QP_LC_STATE_ERROR;
                        end
                    end
                end

                QP_LC_STATE_CLEANUP: begin
                    if (cleanup_destroy_fire || cleanup_error_fire) begin
                        cleanup_req_issued_reg <= 1'b1;
                    end

                    if (cleanup_done_fire) begin
                        cleanup_req_issued_reg <= 1'b0;
                        if (cleanup_done_error_code == QP_CLEAN_ERR_NONE) begin
                            cmd_rsp_qp_context <= cleanup_done_context;
                            cmd_status <= QP_LC_STATUS_SUCCESS;
                            cmd_rsp_error_code <= QP_LC_ERR_NONE;
                            cmd_rsp_valid <= 1'b1;
                            state_reg <= QP_LC_STATE_DONE;
                        end else begin
                            unique case (cleanup_done_error_code)
                                QP_CLEAN_ERR_LOOKUP_MISS,
                                QP_CLEAN_ERR_ALREADY_DESTROYED: error_code_next_reg <= QP_LC_ERR_NOT_FOUND;
                                QP_CLEAN_ERR_PERMISSION:        error_code_next_reg <= QP_LC_ERR_PERMISSION;
                                default:                       error_code_next_reg <= QP_LC_ERR_TABLE_ERROR;
                            endcase
                            state_reg <= QP_LC_STATE_ERROR;
                        end
                    end
                end

                QP_LC_STATE_DONE: begin
                    // 等待 rsp_fire 后回到 IDLE。
                end

                QP_LC_STATE_ERROR: begin
                    if (!cmd_rsp_valid) begin
                        cmd_status <= QP_LC_STATUS_FAILED;
                        cmd_rsp_error_code <= error_code_next_reg;
                        cmd_rsp_qp_context <= '0;
                        cmd_rsp_valid <= 1'b1;
                    end
                end

                default: begin
                    error_code_next_reg <= QP_LC_ERR_TABLE_ERROR;
                    state_reg <= QP_LC_STATE_ERROR;
                end
            endcase
        end
    end

    logic unused_table_read_hit;
    assign unused_table_read_hit = table_read_hit;
    logic [31:0] unused_state_required_attr_mask;
    assign unused_state_required_attr_mask = state_required_attr_mask;
    logic [31:0] unused_state_missing_attr_mask;
    assign unused_state_missing_attr_mask = state_missing_attr_mask;

endmodule : qp_lifecycle_manager
