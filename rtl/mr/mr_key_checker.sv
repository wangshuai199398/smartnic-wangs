// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// MR key direction checker 最小实现。
//
// 本模块把 MR lookup/check 变成方向敏感入口：本地 DMA/Recv path 必须使用
// lkey，远端 RDMA/Atomic path 必须使用 rkey。方向正确后再调用 mr_table 的
// address check 接口完成 lookup、pending_deregister 拒绝和 VA bounds 检查。
// access_flags、完整 PD 规则和 Memory Window bind 留给后续 6.5/6.6/6.7。

`timescale 1ns/1ps

import smartnic_pkg::*;

module mr_key_checker (
    input  logic                     clk,                         // key checker 时钟。
    input  logic                     rst_n,                       // 低有效复位。

    // ------------------------------------------------------------------
    // Key check request
    // ------------------------------------------------------------------
    input  logic                     key_check_valid,             // key check 请求有效。
    output logic                     key_check_ready,             // 本模块可接收请求。
    input  logic [KEY_W-1:0]         key_check_key,               // 待检查的 lkey 或 rkey。
    input  logic                     key_check_is_remote,         // 1 表示请求 key 是 rkey，0 表示 lkey。
    input  mr_operation_e            key_check_operation,         // 本次访问来源/操作类型。
    input  logic [VF_ID_W-1:0]       key_check_owner_function,    // 发起访问的 function。
    input  logic [PD_ID_W-1:0]       key_check_pd_id,             // 发起访问的 PD，完整校验留给 6.6。
    input  logic [ADDR_W-1:0]        key_check_va,                // 访问虚拟地址。
    input  logic [DMA_LEN_W-1:0]     key_check_len,               // 访问长度。

    // ------------------------------------------------------------------
    // Key check response
    // ------------------------------------------------------------------
    output logic                     key_check_resp_valid,        // key check 响应有效。
    input  logic                     key_check_resp_ready,        // 下游已接收响应。
    output logic                     key_check_allowed,           // 方向、lookup 和 bounds 均通过。
    output mr_entry_t                key_check_entry,             // 命中的 MR entry。
    output logic [ADDR_W-1:0]        key_check_physical_addr,     // 转换后的物理/DMA 地址。
    output mr_key_check_error_e      key_check_error_code,        // key check 详细错误码。

    // ------------------------------------------------------------------
    // MR table address check interface
    // ------------------------------------------------------------------
    output logic                     mr_check_valid,              // 发往 mr_table 的 check 请求。
    input  logic                     mr_check_ready,              // mr_table 可接收 check。
    output logic [KEY_W-1:0]         mr_check_key,                // 发往 mr_table 的 key。
    output logic [ADDR_W-1:0]        mr_check_va,                 // 发往 mr_table 的 VA。
    output logic [DMA_LEN_W-1:0]     mr_check_len,                // 发往 mr_table 的长度。
    output logic                     mr_check_is_remote,          // 1 使用 rkey lookup，0 使用 lkey lookup。
    output logic [VF_ID_W-1:0]       mr_check_owner_function,     // 发往 mr_table 的 function。
    output logic [PD_ID_W-1:0]       mr_check_pd_id,              // 发往 mr_table 的 PD。
    output logic                     mr_check_admin_bypass,       // 当前阶段不使用 admin bypass。
    input  logic                     mr_check_rsp_valid,          // mr_table check 响应有效。
    output logic                     mr_check_rsp_ready,          // 本模块可接收 mr_table 响应。
    input  logic                     mr_check_hit,                // mr_table check 命中且范围合法。
    input  mr_entry_t                mr_check_entry,              // mr_table 返回的 entry。
    input  logic [ADDR_W-1:0]        mr_check_pa,                 // mr_table 返回的 PA。
    input  mr_table_status_e         mr_check_error_code          // mr_table 返回状态。
);

    typedef enum logic [1:0] {
        KEY_CHECK_IDLE       = 2'd0,
        KEY_CHECK_WAIT_TABLE = 2'd1,
        KEY_CHECK_RESPOND    = 2'd2
    } key_check_state_e;

    key_check_state_e state_reg;
    logic [KEY_W-1:0] key_reg;
    logic is_remote_reg;
    logic [VF_ID_W-1:0] owner_function_reg;
    logic [PD_ID_W-1:0] pd_id_reg;
    logic [ADDR_W-1:0] va_reg;
    logic [DMA_LEN_W-1:0] len_reg;
    mr_entry_t entry_reg;
    logic [ADDR_W-1:0] physical_addr_reg;
    logic allowed_reg;
    mr_key_check_error_e error_reg;
    logic check_issued_reg;

    logic req_fire;
    logic resp_fire;
    logic table_fire;
    logic table_rsp_fire;

    assign key_check_ready = (state_reg == KEY_CHECK_IDLE);
    assign req_fire = key_check_valid && key_check_ready;
    assign key_check_resp_valid = (state_reg == KEY_CHECK_RESPOND);
    assign resp_fire = key_check_resp_valid && key_check_resp_ready;
    assign key_check_allowed = allowed_reg;
    assign key_check_entry = entry_reg;
    assign key_check_physical_addr = physical_addr_reg;
    assign key_check_error_code = error_reg;

    assign mr_check_valid = (state_reg == KEY_CHECK_WAIT_TABLE) && !check_issued_reg;
    assign mr_check_key = key_reg;
    assign mr_check_va = va_reg;
    assign mr_check_len = len_reg;
    assign mr_check_is_remote = is_remote_reg;
    assign mr_check_owner_function = owner_function_reg;
    assign mr_check_pd_id = pd_id_reg;
    assign mr_check_admin_bypass = 1'b0;
    assign mr_check_rsp_ready = (state_reg == KEY_CHECK_WAIT_TABLE);
    assign table_fire = mr_check_valid && mr_check_ready;
    assign table_rsp_fire = mr_check_rsp_valid && mr_check_rsp_ready;

    function automatic logic operation_is_remote(input mr_operation_e operation);
        begin
            unique case (operation)
                MR_OP_REMOTE_RDMA_READ,
                MR_OP_REMOTE_RDMA_WRITE,
                MR_OP_REMOTE_ATOMIC: return 1'b1;
                default:             return 1'b0;
            endcase
        end
    endfunction

    function automatic logic operation_is_valid(input mr_operation_e operation);
        begin
            unique case (operation)
                MR_OP_LOCAL_DMA_READ,
                MR_OP_LOCAL_DMA_WRITE,
                MR_OP_LOCAL_RECV_WRITE,
                MR_OP_REMOTE_RDMA_READ,
                MR_OP_REMOTE_RDMA_WRITE,
                MR_OP_REMOTE_ATOMIC,
                MR_OP_MW_BIND: return 1'b1;
                default:       return 1'b0;
            endcase
        end
    endfunction

    function automatic mr_key_check_error_e table_status_to_error(input mr_table_status_e status);
        begin
            unique case (status)
                MR_TABLE_STATUS_OK:         return MR_KEY_CHECK_ERR_NONE;
                MR_TABLE_STATUS_MISS:       return MR_KEY_CHECK_ERR_LOOKUP_MISS;
                MR_TABLE_STATUS_PERMISSION: return MR_KEY_CHECK_ERR_PERMISSION;
                MR_TABLE_STATUS_PENDING:    return MR_KEY_CHECK_ERR_PENDING;
                MR_TABLE_STATUS_LENGTH:     return MR_KEY_CHECK_ERR_LENGTH;
                MR_TABLE_STATUS_BOUNDS:     return MR_KEY_CHECK_ERR_BOUNDS;
                default:                    return MR_KEY_CHECK_ERR_TABLE;
            endcase
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= KEY_CHECK_IDLE;
            key_reg <= '0;
            is_remote_reg <= 1'b0;
            owner_function_reg <= '0;
            pd_id_reg <= '0;
            va_reg <= '0;
            len_reg <= '0;
            entry_reg <= '0;
            physical_addr_reg <= '0;
            allowed_reg <= 1'b0;
            error_reg <= MR_KEY_CHECK_ERR_NONE;
            check_issued_reg <= 1'b0;
        end else begin
            unique case (state_reg)
                KEY_CHECK_IDLE: begin
                    allowed_reg <= 1'b0;
                    entry_reg <= '0;
                    physical_addr_reg <= '0;
                    error_reg <= MR_KEY_CHECK_ERR_NONE;
                    check_issued_reg <= 1'b0;

                    if (req_fire) begin
                        key_reg <= key_check_key;
                        is_remote_reg <= key_check_is_remote;
                        owner_function_reg <= key_check_owner_function;
                        pd_id_reg <= key_check_pd_id;
                        va_reg <= key_check_va;
                        len_reg <= key_check_len;

                        if (key_check_key == '0) begin
                            error_reg <= MR_KEY_CHECK_ERR_INVALID_KEY;
                            state_reg <= KEY_CHECK_RESPOND;
                        end else if (!operation_is_valid(key_check_operation)) begin
                            error_reg <= MR_KEY_CHECK_ERR_INVALID_OPERATION;
                            state_reg <= KEY_CHECK_RESPOND;
                        end else if (!operation_is_remote(key_check_operation) &&
                                     key_check_is_remote) begin
                            error_reg <= MR_KEY_CHECK_ERR_LOCAL_KEY_REQUIRED;
                            state_reg <= KEY_CHECK_RESPOND;
                        end else if (operation_is_remote(key_check_operation) &&
                                     !key_check_is_remote) begin
                            error_reg <= MR_KEY_CHECK_ERR_REMOTE_KEY_REQUIRED;
                            state_reg <= KEY_CHECK_RESPOND;
                        end else begin
                            state_reg <= KEY_CHECK_WAIT_TABLE;
                        end
                    end
                end

                KEY_CHECK_WAIT_TABLE: begin
                    if (table_fire) begin
                        check_issued_reg <= 1'b1;
                    end

                    if (table_rsp_fire) begin
                        check_issued_reg <= 1'b0;
                        allowed_reg <= mr_check_hit &&
                                       (mr_check_error_code == MR_TABLE_STATUS_OK);
                        entry_reg <= (mr_check_hit &&
                                      (mr_check_error_code == MR_TABLE_STATUS_OK)) ?
                                     mr_check_entry : '0;
                        physical_addr_reg <= (mr_check_hit &&
                                              (mr_check_error_code == MR_TABLE_STATUS_OK)) ?
                                             mr_check_pa : '0;
                        error_reg <= (!mr_check_hit &&
                                      (mr_check_error_code == MR_TABLE_STATUS_OK)) ?
                                     MR_KEY_CHECK_ERR_LOOKUP_MISS :
                                     table_status_to_error(mr_check_error_code);
                        state_reg <= KEY_CHECK_RESPOND;
                    end
                end

                KEY_CHECK_RESPOND: begin
                    if (resp_fire) begin
                        state_reg <= KEY_CHECK_IDLE;
                    end
                end

                default: begin
                    allowed_reg <= 1'b0;
                    entry_reg <= '0;
                    physical_addr_reg <= '0;
                    error_reg <= MR_KEY_CHECK_ERR_TABLE;
                    check_issued_reg <= 1'b0;
                    state_reg <= KEY_CHECK_RESPOND;
                end
            endcase
        end
    end

endmodule : mr_key_checker
