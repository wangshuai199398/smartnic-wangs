// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// MR deregistration manager 最小实现。
//
// 本模块处理 DEREGISTER_MR 控制命令：查找 MR、检查 owner/PD、写回
// pending_deregister，等待 refcount drain 到 0，最后清除 MR entry。当前阶段
// 不取消真实 DMA，不处理 Memory Window 级联失效，也不实现复杂 PF force 策略。

`timescale 1ns/1ps

import smartnic_pkg::*;

module mr_deregistration_manager (
    input  logic                         clk,                         // 注销管理器时钟。
    input  logic                         rst_n,                       // 低有效复位。

    // ------------------------------------------------------------------
    // DEREGISTER_MR command request
    // ------------------------------------------------------------------
    input  logic                         dereg_req_valid,             // DEREGISTER_MR 请求有效。
    output logic                         dereg_req_ready,             // 本模块可接收请求。
    input  logic [VF_ID_W-1:0]           dereg_req_owner_function,    // 发起注销的 function。
    input  logic [KEY_W-1:0]             dereg_req_key,               // lkey 或 rkey。
    input  logic                         dereg_req_is_remote_key,     // 1 表示 key 为 rkey，0 表示 lkey。
    input  logic [PD_ID_W-1:0]           dereg_req_pd_id,             // 发起注销的 PD。
    input  logic                         dereg_req_force,             // PF/admin force 预留，当前不实现复杂策略。
    input  logic [31:0]                  dereg_req_cmd_sequence,      // mailbox/admin command sequence。

    // ------------------------------------------------------------------
    // DEREGISTER_MR command response
    // ------------------------------------------------------------------
    output logic                         dereg_resp_valid,            // 注销响应有效。
    input  logic                         dereg_resp_ready,            // 上游已接收注销响应。
    output mr_table_status_e             dereg_resp_status,           // 注销状态。
    output mr_deregistration_error_e     dereg_resp_error_code,       // 注销详细错误码。
    output logic [KEY_W-1:0]             dereg_resp_key,              // 返回请求 key。
    output logic [31:0]                  dereg_resp_cmd_sequence,     // 返回请求 sequence。

    // ------------------------------------------------------------------
    // MR table read interface
    // ------------------------------------------------------------------
    output logic                         mr_entry_read_valid,         // MR table read 请求有效。
    input  logic                         mr_entry_read_ready,         // MR table 可接收 read。
    output logic [KEY_W-1:0]             mr_entry_read_key,           // 要读取的 lkey/rkey。
    output logic                         mr_entry_read_is_remote,     // read key 类型。
    output logic [VF_ID_W-1:0]           mr_entry_read_owner_function,// read 所属 function。
    output logic [PD_ID_W-1:0]           mr_entry_read_pd_id,         // read 所属 PD。
    output logic                         mr_entry_read_admin_bypass,  // 当前阶段不使用 admin bypass。
    input  logic                         mr_entry_read_rsp_valid,     // MR table read 响应有效。
    output logic                         mr_entry_read_rsp_ready,     // 本模块可接收 read 响应。
    input  logic                         mr_entry_read_hit,           // read 命中。
    input  mr_entry_t                    mr_entry_read_data,          // read 返回 entry。
    input  mr_table_status_e             mr_entry_read_status,        // read 返回状态。

    // ------------------------------------------------------------------
    // MR table write interface
    // ------------------------------------------------------------------
    output logic                         mr_entry_write_valid,        // MR table write 请求有效。
    input  logic                         mr_entry_write_ready,        // MR table 可接收 write。
    output logic                         mr_entry_write_use_index,    // 使用 key 覆盖，不使用显式 slot。
    output logic [MR_TABLE_INDEX_W-1:0]  mr_entry_write_index,        // 未使用，置零。
    output logic [KEY_W-1:0]             mr_entry_write_key,          // 用于覆盖的 lkey/rkey。
    output logic                         mr_entry_write_is_remote,    // write key 类型。
    output logic [VF_ID_W-1:0]           mr_entry_write_owner_function,// write 所属 function。
    output logic                         mr_entry_write_admin_bypass, // 当前阶段不使用 admin bypass。
    output mr_entry_t                    mr_entry_write_data,         // 要写回的 MR entry。
    input  logic                         mr_entry_write_rsp_valid,    // MR table write 响应有效。
    output logic                         mr_entry_write_rsp_ready,    // 本模块可接收 write 响应。
    input  mr_table_status_e             mr_entry_write_status,       // MR table write 状态。

    // ------------------------------------------------------------------
    // Debug/status
    // ------------------------------------------------------------------
    output mr_deregistration_state_e     debug_state                 // 当前注销 FSM 状态。
);

    mr_deregistration_state_e state_reg;
    mr_deregistration_error_e error_reg;
    mr_table_status_e status_reg;
    mr_entry_t entry_reg;
    mr_entry_t write_entry_reg;
    logic [VF_ID_W-1:0] owner_function_reg;
    logic [KEY_W-1:0] key_reg;
    logic is_remote_key_reg;
    logic [PD_ID_W-1:0] pd_id_reg;
    logic [31:0] cmd_sequence_reg;
    logic [31:0] timeout_counter_reg;
    logic read_issued_reg;
    logic write_issued_reg;

    logic req_fire;
    logic resp_fire;
    logic read_fire;
    logic read_rsp_fire;
    logic write_fire;
    logic write_rsp_fire;

    assign debug_state = state_reg;

    assign dereg_req_ready = (state_reg == MR_DEREG_STATE_IDLE);
    assign req_fire = dereg_req_valid && dereg_req_ready;
    assign dereg_resp_valid = (state_reg == MR_DEREG_STATE_RESPOND) ||
                              (state_reg == MR_DEREG_STATE_ERROR);
    assign resp_fire = dereg_resp_valid && dereg_resp_ready;
    assign dereg_resp_status = status_reg;
    assign dereg_resp_error_code = error_reg;
    assign dereg_resp_key = key_reg;
    assign dereg_resp_cmd_sequence = cmd_sequence_reg;

    assign mr_entry_read_valid = ((state_reg == MR_DEREG_STATE_LOOKUP) ||
                                  (state_reg == MR_DEREG_STATE_WAIT_ZERO)) &&
                                 !read_issued_reg;
    assign mr_entry_read_key = key_reg;
    assign mr_entry_read_is_remote = is_remote_key_reg;
    assign mr_entry_read_owner_function = owner_function_reg;
    assign mr_entry_read_pd_id = pd_id_reg;
    assign mr_entry_read_admin_bypass = 1'b0 && dereg_req_force;
    assign mr_entry_read_rsp_ready = (state_reg == MR_DEREG_STATE_LOOKUP) ||
                                     (state_reg == MR_DEREG_STATE_WAIT_ZERO);
    assign read_fire = mr_entry_read_valid && mr_entry_read_ready;
    assign read_rsp_fire = mr_entry_read_rsp_valid && mr_entry_read_rsp_ready;

    assign mr_entry_write_valid = ((state_reg == MR_DEREG_STATE_MARK_PENDING) ||
                                   (state_reg == MR_DEREG_STATE_CLEAR_ENTRY)) &&
                                  !write_issued_reg;
    assign mr_entry_write_use_index = 1'b0;
    assign mr_entry_write_index = '0;
    assign mr_entry_write_key = key_reg;
    assign mr_entry_write_is_remote = is_remote_key_reg;
    assign mr_entry_write_owner_function = owner_function_reg;
    assign mr_entry_write_admin_bypass = 1'b0 && dereg_req_force;
    assign mr_entry_write_data = write_entry_reg;
    assign mr_entry_write_rsp_ready = (state_reg == MR_DEREG_STATE_MARK_PENDING) ||
                                      (state_reg == MR_DEREG_STATE_CLEAR_ENTRY);
    assign write_fire = mr_entry_write_valid && mr_entry_write_ready;
    assign write_rsp_fire = mr_entry_write_rsp_valid && mr_entry_write_rsp_ready;

    function automatic mr_entry_t make_pending_entry(input mr_entry_t entry);
        begin
            make_pending_entry = entry;
            make_pending_entry.pending_deregister = 1'b1;
        end
    endfunction

    function automatic mr_entry_t make_cleared_entry(input mr_entry_t entry);
        begin
            make_cleared_entry = entry;
            make_cleared_entry.valid = 1'b0;
            make_cleared_entry.access_flags = '0;
            make_cleared_entry.refcount = '0;
            make_cleared_entry.pending_deregister = 1'b0;
            make_cleared_entry.error_state = 1'b0;
            make_cleared_entry.error_code = 16'h0000;
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= MR_DEREG_STATE_IDLE;
            error_reg <= MR_DEREG_ERR_NONE;
            status_reg <= MR_TABLE_STATUS_OK;
            entry_reg <= '0;
            write_entry_reg <= '0;
            owner_function_reg <= '0;
            key_reg <= '0;
            is_remote_key_reg <= 1'b0;
            pd_id_reg <= '0;
            cmd_sequence_reg <= '0;
            timeout_counter_reg <= 32'd0;
            read_issued_reg <= 1'b0;
            write_issued_reg <= 1'b0;
        end else begin
            unique case (state_reg)
                MR_DEREG_STATE_IDLE: begin
                    error_reg <= MR_DEREG_ERR_NONE;
                    status_reg <= MR_TABLE_STATUS_OK;
                    read_issued_reg <= 1'b0;
                    write_issued_reg <= 1'b0;
                    timeout_counter_reg <= 32'd0;
                    if (req_fire) begin
                        owner_function_reg <= dereg_req_owner_function;
                        key_reg <= dereg_req_key;
                        is_remote_key_reg <= dereg_req_is_remote_key;
                        pd_id_reg <= dereg_req_pd_id;
                        cmd_sequence_reg <= dereg_req_cmd_sequence;
                        if (dereg_req_key == '0) begin
                            error_reg <= MR_DEREG_ERR_INVALID_KEY;
                            status_reg <= MR_TABLE_STATUS_INVALID;
                            state_reg <= MR_DEREG_STATE_ERROR;
                        end else begin
                            state_reg <= MR_DEREG_STATE_LOOKUP;
                        end
                    end
                end

                MR_DEREG_STATE_LOOKUP: begin
                    if (read_fire) begin
                        read_issued_reg <= 1'b1;
                    end
                    if (read_rsp_fire) begin
                        read_issued_reg <= 1'b0;
                        if (!mr_entry_read_hit ||
                            (mr_entry_read_status == MR_TABLE_STATUS_MISS)) begin
                            error_reg <= MR_DEREG_ERR_LOOKUP_MISS;
                            status_reg <= MR_TABLE_STATUS_MISS;
                            state_reg <= MR_DEREG_STATE_ERROR;
                        end else if (mr_entry_read_status == MR_TABLE_STATUS_PERMISSION) begin
                            error_reg <= MR_DEREG_ERR_PERMISSION;
                            status_reg <= MR_TABLE_STATUS_PERMISSION;
                            state_reg <= MR_DEREG_STATE_ERROR;
                        end else if (mr_entry_read_status != MR_TABLE_STATUS_OK) begin
                            error_reg <= MR_DEREG_ERR_TABLE_WRITE;
                            status_reg <= mr_entry_read_status;
                            state_reg <= MR_DEREG_STATE_ERROR;
                        end else begin
                            entry_reg <= mr_entry_read_data;
                            state_reg <= MR_DEREG_STATE_CHECK;
                        end
                    end
                end

                MR_DEREG_STATE_CHECK: begin
                    // force_reg 预留给 PF/admin；当前仍执行 owner/PD 基础检查。
                    if (entry_reg.pending_deregister) begin
                        error_reg <= MR_DEREG_ERR_PENDING;
                        status_reg <= MR_TABLE_STATUS_PENDING;
                        state_reg <= MR_DEREG_STATE_ERROR;
                    end else if (entry_reg.owner_function != owner_function_reg) begin
                        error_reg <= MR_DEREG_ERR_PERMISSION;
                        status_reg <= MR_TABLE_STATUS_PERMISSION;
                        state_reg <= MR_DEREG_STATE_ERROR;
                    end else if (entry_reg.pd_id != pd_id_reg) begin
                        error_reg <= MR_DEREG_ERR_PD_MISMATCH;
                        status_reg <= MR_TABLE_STATUS_INVALID;
                        state_reg <= MR_DEREG_STATE_ERROR;
                    end else begin
                        write_entry_reg <= make_pending_entry(entry_reg);
                        write_issued_reg <= 1'b0;
                        state_reg <= MR_DEREG_STATE_MARK_PENDING;
                    end
                end

                MR_DEREG_STATE_MARK_PENDING: begin
                    if (write_fire) begin
                        write_issued_reg <= 1'b1;
                    end
                    if (write_rsp_fire) begin
                        write_issued_reg <= 1'b0;
                        if (mr_entry_write_status != MR_TABLE_STATUS_OK) begin
                            error_reg <= MR_DEREG_ERR_TABLE_WRITE;
                            status_reg <= mr_entry_write_status;
                            state_reg <= MR_DEREG_STATE_ERROR;
                        end else if (entry_reg.refcount == '0) begin
                            write_entry_reg <= make_cleared_entry(entry_reg);
                            state_reg <= MR_DEREG_STATE_CLEAR_ENTRY;
                        end else begin
                            timeout_counter_reg <= 32'd0;
                            read_issued_reg <= 1'b0;
                            state_reg <= MR_DEREG_STATE_WAIT_ZERO;
                        end
                    end
                end

                MR_DEREG_STATE_WAIT_ZERO: begin
                    timeout_counter_reg <= timeout_counter_reg + 32'd1;
                    if (timeout_counter_reg >= MR_DEREG_TIMEOUT_CYCLES) begin
                        error_reg <= MR_DEREG_ERR_TIMEOUT;
                        status_reg <= MR_TABLE_STATUS_INVALID;
                        read_issued_reg <= 1'b0;
                        state_reg <= MR_DEREG_STATE_ERROR;
                    end else begin
                        if (read_fire) begin
                            read_issued_reg <= 1'b1;
                        end
                        if (read_rsp_fire) begin
                            read_issued_reg <= 1'b0;
                            if (!mr_entry_read_hit ||
                                (mr_entry_read_status == MR_TABLE_STATUS_MISS)) begin
                                error_reg <= MR_DEREG_ERR_LOOKUP_MISS;
                                status_reg <= MR_TABLE_STATUS_MISS;
                                state_reg <= MR_DEREG_STATE_ERROR;
                            end else if (mr_entry_read_status != MR_TABLE_STATUS_OK) begin
                                error_reg <= MR_DEREG_ERR_TABLE_WRITE;
                                status_reg <= mr_entry_read_status;
                                state_reg <= MR_DEREG_STATE_ERROR;
                            end else if (!mr_entry_read_data.pending_deregister) begin
                                error_reg <= MR_DEREG_ERR_REFCOUNT;
                                status_reg <= MR_TABLE_STATUS_INVALID;
                                state_reg <= MR_DEREG_STATE_ERROR;
                            end else if (mr_entry_read_data.refcount == '0) begin
                                entry_reg <= mr_entry_read_data;
                                write_entry_reg <= make_cleared_entry(mr_entry_read_data);
                                write_issued_reg <= 1'b0;
                                state_reg <= MR_DEREG_STATE_CLEAR_ENTRY;
                            end
                        end
                    end
                end

                MR_DEREG_STATE_CLEAR_ENTRY: begin
                    if (write_fire) begin
                        write_issued_reg <= 1'b1;
                    end
                    if (write_rsp_fire) begin
                        write_issued_reg <= 1'b0;
                        if (mr_entry_write_status != MR_TABLE_STATUS_OK) begin
                            error_reg <= MR_DEREG_ERR_TABLE_WRITE;
                            status_reg <= mr_entry_write_status;
                            state_reg <= MR_DEREG_STATE_ERROR;
                        end else begin
                            error_reg <= MR_DEREG_ERR_NONE;
                            status_reg <= MR_TABLE_STATUS_OK;
                            state_reg <= MR_DEREG_STATE_RESPOND;
                        end
                    end
                end

                MR_DEREG_STATE_RESPOND: begin
                    if (resp_fire) begin
                        state_reg <= MR_DEREG_STATE_IDLE;
                    end
                end

                MR_DEREG_STATE_ERROR: begin
                    if (resp_fire) begin
                        state_reg <= MR_DEREG_STATE_IDLE;
                    end
                end

                default: begin
                    error_reg <= MR_DEREG_ERR_TABLE_WRITE;
                    status_reg <= MR_TABLE_STATUS_INVALID;
                    state_reg <= MR_DEREG_STATE_ERROR;
                end
            endcase
        end
    end

endmodule : mr_deregistration_manager
