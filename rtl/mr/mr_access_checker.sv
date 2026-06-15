// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// MR access permission checker 最小实现。
//
// 本模块位于 key direction check 之后，负责检查 mr_entry_t.access_flags 是否允许
// 本次 local/remote/MW 操作，并重新执行基础 entry、pending、owner 和 VA bounds
// 检查。PD 详细规则、Memory Window bind/unbind 和 QP error invalidation 留给后续阶段。

`timescale 1ns/1ps

import smartnic_pkg::*;

module mr_access_checker (
    input  logic                     clk,                           // access checker 时钟。
    input  logic                     rst_n,                         // 低有效复位。

    // ------------------------------------------------------------------
    // Access check request
    // ------------------------------------------------------------------
    input  logic                     access_check_valid,            // access check 请求有效。
    output logic                     access_check_ready,            // 本模块可接收请求。
    input  mr_operation_e            access_check_operation,        // 访问操作类型。
    input  mr_entry_t                access_check_entry,            // key checker / MR table 返回的 MR entry。
    input  logic [ADDR_W-1:0]        access_check_va,               // 访问虚拟地址。
    input  logic [DMA_LEN_W-1:0]     access_check_len,              // 访问长度。
    input  logic                     access_check_is_remote,        // 1 表示远端访问路径，0 表示本地访问路径。
    input  logic [VF_ID_W-1:0]       access_check_owner_function,   // 发起访问的 function / QP owner。
    input  logic [PD_ID_W-1:0]       access_check_pd_id,            // 发起访问的 PD，详细规则留给 6.6。
    input  logic [5:0]               access_parent_permission_mask, // MW parent 权限上限预留。
    input  logic                     access_parent_permission_valid,// parent mask 是否有效，当前仅用于 MW 预留检查。

    // ------------------------------------------------------------------
    // Access check response
    // ------------------------------------------------------------------
    output logic                     access_check_resp_valid,       // access check 响应有效。
    input  logic                     access_check_resp_ready,       // 下游已接收响应。
    output logic                     access_allowed,                // 权限与基础合法性检查均通过。
    output logic [ADDR_W-1:0]        access_physical_addr,          // 转换后的物理/DMA 地址。
    output logic [5:0]               access_flags_used,             // 本次 operation 消耗的权限 bit。
    output mr_access_check_error_e   access_error_code              // access check 详细错误码。
);

    logic req_fire;
    logic resp_fire;
    logic [5:0] required_flags;
    logic operation_known;
    logic operation_remote;
    logic [ADDR_W-1:0] access_len_ext;
    logic [ADDR_W-1:0] access_end;
    logic [ADDR_W-1:0] mr_end;
    logic access_overflow;
    logic mr_overflow;
    logic bounds_ok;
    logic owner_ok;
    logic remote_direction_ok;
    logic flags_ok;
    logic mw_parent_ok;
    logic [ADDR_W-1:0] physical_addr_next;
    mr_access_check_error_e error_next;
    logic allowed_next;

    assign access_check_ready = !access_check_resp_valid || access_check_resp_ready;
    assign req_fire = access_check_valid && access_check_ready;
    assign resp_fire = access_check_resp_valid && access_check_resp_ready;

    assign access_len_ext = ADDR_W'(access_check_len);
    assign access_end = access_check_va + access_len_ext;
    assign mr_end = access_check_entry.virtual_base_addr + ADDR_W'(access_check_entry.length);
    assign access_overflow = (access_end < access_check_va);
    assign mr_overflow = (mr_end < access_check_entry.virtual_base_addr);
    assign bounds_ok = !access_overflow &&
                       !mr_overflow &&
                       (access_check_va >= access_check_entry.virtual_base_addr) &&
                       (access_end <= mr_end);
    assign owner_ok = (access_check_entry.owner_function == access_check_owner_function);
    assign remote_direction_ok = (operation_remote == access_check_is_remote) ||
                                 (access_check_operation == MR_OP_MW_BIND);
    assign flags_ok = ((access_check_entry.access_flags & required_flags) == required_flags);
    assign mw_parent_ok = !access_check_entry.memory_window ||
                          !access_parent_permission_valid ||
                          ((required_flags & ~access_parent_permission_mask) == '0);
    assign physical_addr_next = access_check_entry.physical_base_addr +
                                (access_check_va - access_check_entry.virtual_base_addr);

    always_comb begin
        required_flags = '0;
        operation_known = 1'b1;
        operation_remote = 1'b0;

        unique case (access_check_operation)
            MR_OP_LOCAL_DMA_READ: begin
                required_flags = MR_ACCESS_LOCAL_READ;
                operation_remote = 1'b0;
            end
            MR_OP_LOCAL_DMA_WRITE,
            MR_OP_LOCAL_RECV_WRITE: begin
                required_flags = MR_ACCESS_LOCAL_WRITE;
                operation_remote = 1'b0;
            end
            MR_OP_REMOTE_RDMA_READ: begin
                required_flags = MR_ACCESS_REMOTE_READ;
                operation_remote = 1'b1;
            end
            MR_OP_REMOTE_RDMA_WRITE: begin
                required_flags = MR_ACCESS_REMOTE_WRITE;
                operation_remote = 1'b1;
            end
            MR_OP_REMOTE_ATOMIC: begin
                required_flags = MR_ACCESS_REMOTE_ATOMIC;
                operation_remote = 1'b1;
            end
            MR_OP_MW_BIND: begin
                required_flags = MR_ACCESS_MW_BIND;
                operation_remote = 1'b0;
            end
            default: begin
                required_flags = '0;
                operation_known = 1'b0;
                operation_remote = 1'b0;
            end
        endcase
    end

    always_comb begin
        allowed_next = 1'b0;
        error_next = MR_ACCESS_ERR_NONE;

        if (!access_check_entry.valid) begin
            error_next = MR_ACCESS_ERR_INVALID_ENTRY;
        end else if (access_check_entry.pending_deregister) begin
            error_next = MR_ACCESS_ERR_PENDING;
        end else if (!owner_ok) begin
            error_next = MR_ACCESS_ERR_PERMISSION;
        end else if ((access_check_len == '0) || (access_check_entry.length == '0)) begin
            error_next = MR_ACCESS_ERR_LENGTH;
        end else if (!operation_known || !remote_direction_ok) begin
            error_next = MR_ACCESS_ERR_UNKNOWN_OPERATION;
        end else if (access_overflow || mr_overflow) begin
            error_next = MR_ACCESS_ERR_ADDR_OVERFLOW;
        end else if (!bounds_ok) begin
            error_next = MR_ACCESS_ERR_BOUNDS;
        end else if (!flags_ok) begin
            error_next = MR_ACCESS_ERR_ACCESS_DENIED;
        end else if (!mw_parent_ok) begin
            error_next = MR_ACCESS_ERR_MW_PARENT;
        end else begin
            allowed_next = 1'b1;
            error_next = MR_ACCESS_ERR_NONE;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            access_check_resp_valid <= 1'b0;
            access_allowed <= 1'b0;
            access_physical_addr <= '0;
            access_flags_used <= '0;
            access_error_code <= MR_ACCESS_ERR_NONE;
        end else begin
            if (resp_fire) begin
                access_check_resp_valid <= 1'b0;
            end

            if (req_fire) begin
                access_check_resp_valid <= 1'b1;
                access_allowed <= allowed_next;
                access_physical_addr <= allowed_next ? physical_addr_next : '0;
                access_flags_used <= required_flags;
                access_error_code <= error_next;
            end
        end
    end

endmodule : mr_access_checker
