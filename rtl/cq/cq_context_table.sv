// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// CQ context table 最小实现。
//
// 本模块保存和查找 CQ 上下文，接收 CQ arm Doorbell handler 的 consumer
// index/armed 更新，以及 completion path 的 producer index 更新。当前阶段
// 不格式化 CQE，不写 host CQ buffer，也不生成 MSI-X 请求。

`timescale 1ns/1ps

import smartnic_pkg::*;

module cq_context_table (
    input  logic                         clk,                         // CQ context table 时钟。
    input  logic                         rst_n,                       // 低有效复位。

    // ------------------------------------------------------------------
    // Fast-path CQN lookup
    // ------------------------------------------------------------------
    input  logic                         lookup_valid,                // CQN 查找请求有效。
    output logic                         lookup_ready,                // 本模块可接收 CQN 查找请求。
    input  logic [CQ_ID_W-1:0]           lookup_cqn,                  // 要查找的 CQN tag。
    input  logic [VF_ID_W-1:0]           lookup_function_id,          // 发起查找的 PF/VF function。
    input  logic                         lookup_admin_bypass,         // PF/管理路径权限绕过预留。
    output logic                         lookup_rsp_valid,            // CQN 查找响应有效。
    input  logic                         lookup_rsp_ready,            // 下游已接收 CQN 查找响应。
    output logic                         lookup_hit,                  // 查找命中且权限允许。
    output logic                         lookup_miss,                 // 没有找到该 CQN。
    output cq_table_status_e             lookup_status,               // 查找状态。
    output cq_context_t                  lookup_context,              // 命中的 CQ context。

    // ------------------------------------------------------------------
    // Minimal context write interface
    // ------------------------------------------------------------------
    input  logic                         context_write_valid,         // CQ context 写请求有效。
    output logic                         context_write_ready,         // 本模块可接收写请求。
    input  logic [CQ_ID_W-1:0]           context_write_cqn,           // 要写入/覆盖的 CQN。
    input  logic [VF_ID_W-1:0]           context_write_function_id,   // 发起写入的 PF/VF function。
    input  logic                         context_write_admin_bypass,  // PF/管理路径权限绕过预留。
    input  logic                         context_write_use_index,     // 1 表示使用显式 slot 写入，便于测试 alias。
    input  logic [CQ_TABLE_INDEX_W-1:0]  context_write_index,         // 显式写入的表 slot。
    input  cq_context_t                  context_write_data,          // 要写入的完整 CQ context。
    output logic                         context_write_rsp_valid,     // 写响应有效。
    input  logic                         context_write_rsp_ready,     // 下游已接收写响应。
    output cq_table_status_e             context_write_status,        // 写操作状态。

    // ------------------------------------------------------------------
    // Minimal context read interface
    // ------------------------------------------------------------------
    input  logic                         context_read_valid,          // CQ context 读请求有效。
    output logic                         context_read_ready,          // 本模块可接收读请求。
    input  logic [CQ_ID_W-1:0]           context_read_cqn,            // 要读取的 CQN。
    input  logic [VF_ID_W-1:0]           context_read_function_id,    // 发起读取的 PF/VF function。
    input  logic                         context_read_admin_bypass,   // PF/管理路径权限绕过预留。
    output logic                         context_read_rsp_valid,      // 读响应有效。
    input  logic                         context_read_rsp_ready,      // 下游已接收读响应。
    output logic                         context_read_hit,            // 读取命中且权限允许。
    output cq_table_status_e             context_read_status,         // 读操作状态。
    output cq_context_t                  context_read_data,           // 读取到的 CQ context。

    // ------------------------------------------------------------------
    // CQ arm Doorbell update
    // ------------------------------------------------------------------
    input  logic                         cq_arm_valid,                // CQ arm 更新请求有效。
    output logic                         cq_arm_ready,                // 本模块可接收 CQ arm 更新。
    input  logic [CQ_ID_W-1:0]           cq_arm_cqn,                  // 要 arm 的 CQN。
    input  logic [VF_ID_W-1:0]           cq_arm_function_id,          // CQ arm 所属 function。
    input  logic [QUEUE_IDX_W-1:0]       cq_arm_consumer_index,       // 软件提交的 CQ consumer index。
    input  logic                         cq_arm_armed,                // 置位 armed 标志。
    input  logic                         cq_arm_solicited_only,       // 设置 solicited_only 标志。
    input  logic                         cq_arm_error,                // 上游 Doorbell handler 已报告错误。
    output logic                         cq_arm_rsp_valid,            // CQ arm 更新响应有效。
    input  logic                         cq_arm_rsp_ready,            // 下游已接收 CQ arm 响应。
    output cq_table_status_e             cq_arm_status,               // CQ arm 更新状态。

    // ------------------------------------------------------------------
    // Completion producer update
    // ------------------------------------------------------------------
    input  logic                         completion_update_valid,      // completion producer 更新有效。
    output logic                         completion_update_ready,      // 本模块可接收 producer 更新。
    input  logic [CQ_ID_W-1:0]           completion_update_cqn,        // 要更新 PI 的 CQN。
    input  logic [VF_ID_W-1:0]           completion_update_owner_function,// 更新所属 function。
    input  logic [QUEUE_IDX_W-1:0]       completion_update_new_pi,     // 新的 CQ producer index。
    output logic                         completion_update_rsp_valid,  // producer 更新响应有效。
    input  logic                         completion_update_rsp_ready,  // 下游已接收 producer 更新响应。
    output cq_table_status_e             completion_update_status,     // producer 更新状态。

    // ------------------------------------------------------------------
    // Overflow flag control
    // ------------------------------------------------------------------
    input  logic                         overflow_set_valid,          // 设置 CQ overflow 标志。
    output logic                         overflow_set_ready,          // 本模块可接收 overflow set。
    input  logic [CQ_ID_W-1:0]           overflow_set_cqn,            // 要设置 overflow 的 CQN。
    input  logic [VF_ID_W-1:0]           overflow_set_function_id,    // 请求所属 function。
    output logic                         overflow_set_rsp_valid,      // overflow set 响应有效。
    input  logic                         overflow_set_rsp_ready,      // 下游已接收响应。
    output cq_table_status_e             overflow_set_status,         // overflow set 状态。

    input  logic                         overflow_clear_valid,        // 清除 CQ overflow 标志。
    output logic                         overflow_clear_ready,        // 本模块可接收 overflow clear。
    input  logic [CQ_ID_W-1:0]           overflow_clear_cqn,          // 要清除 overflow 的 CQN。
    input  logic [VF_ID_W-1:0]           overflow_clear_function_id,  // 请求所属 function。
    output logic                         overflow_clear_rsp_valid,    // overflow clear 响应有效。
    input  logic                         overflow_clear_rsp_ready,    // 下游已接收响应。
    output cq_table_status_e             overflow_clear_status        // overflow clear 状态。
);

    cq_context_t table [CQ_TABLE_DEPTH]; // 原型阶段使用寄存器数组表达 CQ context 表。

    logic lookup_fire;
    logic lookup_rsp_fire;
    logic context_write_fire;
    logic context_write_rsp_fire;
    logic context_read_fire;
    logic context_read_rsp_fire;
    logic cq_arm_fire;
    logic cq_arm_rsp_fire;
    logic completion_update_fire;
    logic completion_update_rsp_fire;
    logic overflow_set_fire;
    logic overflow_set_rsp_fire;
    logic overflow_clear_fire;
    logic overflow_clear_rsp_fire;

    logic lookup_found;
    logic lookup_alias;
    logic [CQ_TABLE_INDEX_W-1:0] lookup_match_index;
    logic read_found;
    logic read_alias;
    logic [CQ_TABLE_INDEX_W-1:0] read_match_index;
    logic write_found;
    logic write_alias;
    logic write_free_found;
    logic [CQ_TABLE_INDEX_W-1:0] write_match_index;
    logic [CQ_TABLE_INDEX_W-1:0] write_free_index;
    logic [CQ_TABLE_INDEX_W-1:0] write_target_index;
    cq_table_status_e write_status_next;
    cq_context_t write_data_next;
    logic arm_found;
    logic arm_alias;
    logic [CQ_TABLE_INDEX_W-1:0] arm_match_index;
    logic completion_found;
    logic completion_alias;
    logic [CQ_TABLE_INDEX_W-1:0] completion_match_index;
    logic overflow_set_found;
    logic overflow_set_alias;
    logic [CQ_TABLE_INDEX_W-1:0] overflow_set_match_index;
    logic overflow_clear_found;
    logic overflow_clear_alias;
    logic [CQ_TABLE_INDEX_W-1:0] overflow_clear_match_index;

    assign lookup_ready = !lookup_rsp_valid || lookup_rsp_ready;
    assign context_write_ready = !context_write_rsp_valid || context_write_rsp_ready;
    assign context_read_ready = !context_read_rsp_valid || context_read_rsp_ready;
    assign cq_arm_ready = !cq_arm_rsp_valid || cq_arm_rsp_ready;
    assign completion_update_ready = !completion_update_rsp_valid || completion_update_rsp_ready;
    assign overflow_set_ready = !overflow_set_rsp_valid || overflow_set_rsp_ready;
    assign overflow_clear_ready = !overflow_clear_rsp_valid || overflow_clear_rsp_ready;

    assign lookup_fire = lookup_valid && lookup_ready;
    assign lookup_rsp_fire = lookup_rsp_valid && lookup_rsp_ready;
    assign context_write_fire = context_write_valid && context_write_ready;
    assign context_write_rsp_fire = context_write_rsp_valid && context_write_rsp_ready;
    assign context_read_fire = context_read_valid && context_read_ready;
    assign context_read_rsp_fire = context_read_rsp_valid && context_read_rsp_ready;
    assign cq_arm_fire = cq_arm_valid && cq_arm_ready;
    assign cq_arm_rsp_fire = cq_arm_rsp_valid && cq_arm_rsp_ready;
    assign completion_update_fire = completion_update_valid && completion_update_ready;
    assign completion_update_rsp_fire = completion_update_rsp_valid && completion_update_rsp_ready;
    assign overflow_set_fire = overflow_set_valid && overflow_set_ready;
    assign overflow_set_rsp_fire = overflow_set_rsp_valid && overflow_set_rsp_ready;
    assign overflow_clear_fire = overflow_clear_valid && overflow_clear_ready;
    assign overflow_clear_rsp_fire = overflow_clear_rsp_valid && overflow_clear_rsp_ready;

    function automatic logic owner_allowed(
        input cq_context_t          ctx,
        input logic [VF_ID_W-1:0]   function_id,
        input logic                 admin_bypass
    );
        begin
            return admin_bypass || (ctx.owner_function == function_id);
        end
    endfunction

    function automatic cq_table_status_e lookup_status_for(
        input logic                  found,
        input logic                  alias,
        input cq_context_t           ctx,
        input logic [VF_ID_W-1:0]    function_id,
        input logic                  admin_bypass
    );
        begin
            if (alias) begin
                return CQ_TABLE_STATUS_ALIAS;
            end
            if (!found) begin
                return CQ_TABLE_STATUS_MISS;
            end
            if (!owner_allowed(ctx, function_id, admin_bypass)) begin
                return CQ_TABLE_STATUS_PERMISSION;
            end
            return CQ_TABLE_STATUS_OK;
        end
    endfunction

    always_comb begin
        lookup_found = 1'b0;
        lookup_alias = 1'b0;
        lookup_match_index = '0;

        for (int unsigned i = 0; i < CQ_TABLE_DEPTH; i++) begin
            if (table[i].valid && (table[i].cqn == lookup_cqn)) begin
                if (!lookup_found) begin
                    lookup_found = 1'b1;
                    lookup_match_index = CQ_TABLE_INDEX_W'(i);
                end else begin
                    lookup_alias = 1'b1;
                end
            end
        end
    end

    always_comb begin
        read_found = 1'b0;
        read_alias = 1'b0;
        read_match_index = '0;

        for (int unsigned i = 0; i < CQ_TABLE_DEPTH; i++) begin
            if (table[i].valid && (table[i].cqn == context_read_cqn)) begin
                if (!read_found) begin
                    read_found = 1'b1;
                    read_match_index = CQ_TABLE_INDEX_W'(i);
                end else begin
                    read_alias = 1'b1;
                end
            end
        end
    end

    always_comb begin
        write_found = 1'b0;
        write_alias = 1'b0;
        write_free_found = 1'b0;
        write_match_index = '0;
        write_free_index = '0;

        for (int unsigned i = 0; i < CQ_TABLE_DEPTH; i++) begin
            if (table[i].valid && (table[i].cqn == context_write_cqn)) begin
                if (!write_found) begin
                    write_found = 1'b1;
                    write_match_index = CQ_TABLE_INDEX_W'(i);
                end else begin
                    write_alias = 1'b1;
                end
            end

            if (!table[i].valid && !write_free_found) begin
                write_free_found = 1'b1;
                write_free_index = CQ_TABLE_INDEX_W'(i);
            end
        end
    end

    always_comb begin
        write_target_index = context_write_use_index ? context_write_index :
                             (write_found ? write_match_index : write_free_index);
        write_data_next = context_write_data;
        write_data_next.cqn = context_write_cqn;
        write_status_next = CQ_TABLE_STATUS_OK;

        if (context_write_data.valid &&
            (context_write_data.cqn != context_write_cqn)) begin
            write_status_next = CQ_TABLE_STATUS_INVALID;
        end else if (write_alias ||
                     (context_write_use_index && context_write_data.valid &&
                      write_found && (write_match_index != context_write_index))) begin
            write_status_next = CQ_TABLE_STATUS_ALIAS;
        end else if (!context_write_data.valid && !write_found && !context_write_use_index) begin
            write_status_next = CQ_TABLE_STATUS_MISS;
        end else if (!context_write_use_index && context_write_data.valid &&
                     !write_found && !write_free_found) begin
            write_status_next = CQ_TABLE_STATUS_FULL;
        end else if (table[write_target_index].valid &&
                     !owner_allowed(table[write_target_index],
                                    context_write_function_id,
                                    context_write_admin_bypass)) begin
            write_status_next = CQ_TABLE_STATUS_PERMISSION;
        end else if (context_write_data.valid &&
                     !context_write_admin_bypass &&
                     (context_write_data.owner_function != context_write_function_id)) begin
            write_status_next = CQ_TABLE_STATUS_PERMISSION;
        end
    end

    always_comb begin
        arm_found = 1'b0;
        arm_alias = 1'b0;
        arm_match_index = '0;
        completion_found = 1'b0;
        completion_alias = 1'b0;
        completion_match_index = '0;
        overflow_set_found = 1'b0;
        overflow_set_alias = 1'b0;
        overflow_set_match_index = '0;
        overflow_clear_found = 1'b0;
        overflow_clear_alias = 1'b0;
        overflow_clear_match_index = '0;

        for (int unsigned i = 0; i < CQ_TABLE_DEPTH; i++) begin
            if (table[i].valid && (table[i].cqn == cq_arm_cqn)) begin
                if (!arm_found) begin
                    arm_found = 1'b1;
                    arm_match_index = CQ_TABLE_INDEX_W'(i);
                end else begin
                    arm_alias = 1'b1;
                end
            end
            if (table[i].valid && (table[i].cqn == completion_update_cqn)) begin
                if (!completion_found) begin
                    completion_found = 1'b1;
                    completion_match_index = CQ_TABLE_INDEX_W'(i);
                end else begin
                    completion_alias = 1'b1;
                end
            end
            if (table[i].valid && (table[i].cqn == overflow_set_cqn)) begin
                if (!overflow_set_found) begin
                    overflow_set_found = 1'b1;
                    overflow_set_match_index = CQ_TABLE_INDEX_W'(i);
                end else begin
                    overflow_set_alias = 1'b1;
                end
            end
            if (table[i].valid && (table[i].cqn == overflow_clear_cqn)) begin
                if (!overflow_clear_found) begin
                    overflow_clear_found = 1'b1;
                    overflow_clear_match_index = CQ_TABLE_INDEX_W'(i);
                end else begin
                    overflow_clear_alias = 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lookup_rsp_valid <= 1'b0;
            lookup_hit <= 1'b0;
            lookup_miss <= 1'b0;
            lookup_status <= CQ_TABLE_STATUS_MISS;
            lookup_context <= '0;
            context_write_rsp_valid <= 1'b0;
            context_write_status <= CQ_TABLE_STATUS_MISS;
            context_read_rsp_valid <= 1'b0;
            context_read_hit <= 1'b0;
            context_read_status <= CQ_TABLE_STATUS_MISS;
            context_read_data <= '0;
            cq_arm_rsp_valid <= 1'b0;
            cq_arm_status <= CQ_TABLE_STATUS_MISS;
            completion_update_rsp_valid <= 1'b0;
            completion_update_status <= CQ_TABLE_STATUS_MISS;
            overflow_set_rsp_valid <= 1'b0;
            overflow_set_status <= CQ_TABLE_STATUS_MISS;
            overflow_clear_rsp_valid <= 1'b0;
            overflow_clear_status <= CQ_TABLE_STATUS_MISS;

            for (int unsigned i = 0; i < CQ_TABLE_DEPTH; i++) begin
                table[i] <= '0;
            end
        end else begin
            if (lookup_rsp_fire) lookup_rsp_valid <= 1'b0;
            if (context_write_rsp_fire) context_write_rsp_valid <= 1'b0;
            if (context_read_rsp_fire) context_read_rsp_valid <= 1'b0;
            if (cq_arm_rsp_fire) cq_arm_rsp_valid <= 1'b0;
            if (completion_update_rsp_fire) completion_update_rsp_valid <= 1'b0;
            if (overflow_set_rsp_fire) overflow_set_rsp_valid <= 1'b0;
            if (overflow_clear_rsp_fire) overflow_clear_rsp_valid <= 1'b0;

            if (lookup_fire) begin
                lookup_rsp_valid <= 1'b1;
                lookup_status <= lookup_status_for(lookup_found,
                                                   lookup_alias,
                                                   table[lookup_match_index],
                                                   lookup_function_id,
                                                   lookup_admin_bypass);
                lookup_hit <= lookup_found && !lookup_alias &&
                              owner_allowed(table[lookup_match_index],
                                            lookup_function_id,
                                            lookup_admin_bypass);
                lookup_miss <= !lookup_found;
                lookup_context <= (lookup_found && !lookup_alias) ? table[lookup_match_index] : '0;
            end

            if (context_write_fire) begin
                context_write_rsp_valid <= 1'b1;
                context_write_status <= write_status_next;

                if (write_status_next == CQ_TABLE_STATUS_OK) begin
                    table[write_target_index] <= write_data_next;
                end
            end

            if (context_read_fire) begin
                context_read_rsp_valid <= 1'b1;
                context_read_status <= lookup_status_for(read_found,
                                                         read_alias,
                                                         table[read_match_index],
                                                         context_read_function_id,
                                                         context_read_admin_bypass);
                context_read_hit <= read_found && !read_alias &&
                                    owner_allowed(table[read_match_index],
                                                  context_read_function_id,
                                                  context_read_admin_bypass);
                context_read_data <= (read_found && !read_alias) ? table[read_match_index] : '0;
            end

            if (cq_arm_fire) begin
                cq_arm_rsp_valid <= 1'b1;

                if (cq_arm_error) begin
                    cq_arm_status <= CQ_TABLE_STATUS_INVALID;
                end else if (arm_alias) begin
                    cq_arm_status <= CQ_TABLE_STATUS_ALIAS;
                end else if (!arm_found) begin
                    cq_arm_status <= CQ_TABLE_STATUS_MISS;
                end else if (!owner_allowed(table[arm_match_index], cq_arm_function_id, 1'b0)) begin
                    cq_arm_status <= CQ_TABLE_STATUS_PERMISSION;
                end else begin
                    cq_arm_status <= CQ_TABLE_STATUS_OK;
                    table[arm_match_index].consumer_index <= cq_arm_consumer_index;
                    table[arm_match_index].armed <= cq_arm_armed;
                    table[arm_match_index].solicited_only <= cq_arm_solicited_only;
                end
            end

            if (completion_update_fire) begin
                completion_update_rsp_valid <= 1'b1;

                if (completion_alias) begin
                    completion_update_status <= CQ_TABLE_STATUS_ALIAS;
                end else if (!completion_found) begin
                    completion_update_status <= CQ_TABLE_STATUS_MISS;
                end else if (!owner_allowed(table[completion_match_index],
                                            completion_update_owner_function,
                                            1'b0)) begin
                    completion_update_status <= CQ_TABLE_STATUS_PERMISSION;
                end else begin
                    completion_update_status <= CQ_TABLE_STATUS_OK;
                    table[completion_match_index].producer_index <= completion_update_new_pi;
                end
            end

            if (overflow_set_fire) begin
                overflow_set_rsp_valid <= 1'b1;

                if (overflow_set_alias) begin
                    overflow_set_status <= CQ_TABLE_STATUS_ALIAS;
                end else if (!overflow_set_found) begin
                    overflow_set_status <= CQ_TABLE_STATUS_MISS;
                end else if (!owner_allowed(table[overflow_set_match_index],
                                            overflow_set_function_id,
                                            1'b0)) begin
                    overflow_set_status <= CQ_TABLE_STATUS_PERMISSION;
                end else begin
                    overflow_set_status <= CQ_TABLE_STATUS_OK;
                    table[overflow_set_match_index].overflow <= 1'b1;
                end
            end

            if (overflow_clear_fire) begin
                overflow_clear_rsp_valid <= 1'b1;

                if (overflow_clear_alias) begin
                    overflow_clear_status <= CQ_TABLE_STATUS_ALIAS;
                end else if (!overflow_clear_found) begin
                    overflow_clear_status <= CQ_TABLE_STATUS_MISS;
                end else if (!owner_allowed(table[overflow_clear_match_index],
                                            overflow_clear_function_id,
                                            1'b0)) begin
                    overflow_clear_status <= CQ_TABLE_STATUS_PERMISSION;
                end else begin
                    overflow_clear_status <= CQ_TABLE_STATUS_OK;
                    table[overflow_clear_match_index].overflow <= 1'b0;
                end
            end
        end
    end

endmodule : cq_context_table
