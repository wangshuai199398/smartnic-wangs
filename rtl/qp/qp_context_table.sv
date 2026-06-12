// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// QP context table 最小实现。
//
// 本模块只保存和查找 QP 上下文，并接收 SQ/RQ Doorbell handler 产生的
// producer index 更新。它不执行 QP create/modify/destroy 命令，不校验 IBTA
// 状态迁移，不读取 WQE，也不调度 SQ/RQ engine。

`timescale 1ns/1ps

import smartnic_pkg::*;

module qp_context_table (
    input  logic                         clk,                     // QP context table 时钟。
    input  logic                         rst_n,                   // 低有效复位。

    // ------------------------------------------------------------------
    // Fast-path QPN lookup
    // ------------------------------------------------------------------
    input  logic                         lookup_valid,            // QPN 查找请求有效。
    output logic                         lookup_ready,            // 本模块可接收 QPN 查找请求。
    input  logic [QP_ID_W-1:0]           lookup_qpn,              // 要查找的 QPN tag。
    input  logic [VF_ID_W-1:0]           lookup_function_id,      // 发起查找的 PF/VF function。
    input  logic                         lookup_pf_bypass,        // PF/管理路径权限绕过预留。
    output logic                         lookup_rsp_valid,        // QPN 查找响应有效。
    input  logic                         lookup_rsp_ready,        // 下游已接收 QPN 查找响应。
    output logic                         lookup_hit,              // 查找命中且权限允许。
    output logic                         lookup_miss,             // 没有找到该 QPN。
    output qp_table_status_e             lookup_status,           // 查找状态。
    output qp_context_t                  lookup_context,          // 命中的 QP context。

    // ------------------------------------------------------------------
    // Minimal context write interface
    // ------------------------------------------------------------------
    input  logic                         context_write_valid,     // QP context 写请求有效。
    output logic                         context_write_ready,     // 本模块可接收写请求。
    input  logic [QP_ID_W-1:0]           context_write_qpn,       // 要写入/覆盖的 QPN。
    input  logic [VF_ID_W-1:0]           context_write_function_id,// 发起写入的 PF/VF function。
    input  logic                         context_write_pf_bypass,  // PF/管理路径权限绕过预留。
    input  logic                         context_write_use_index,  // 1 表示使用显式表 slot 写入，便于测试 alias。
    input  logic [QP_TABLE_INDEX_W-1:0]  context_write_index,      // 显式写入的表 slot。
    input  qp_context_t                  context_write_data,       // 要写入的完整 QP context。
    output logic                         context_write_rsp_valid,  // 写响应有效。
    input  logic                         context_write_rsp_ready,  // 下游已接收写响应。
    output qp_table_status_e             context_write_status,     // 写操作状态。

    // ------------------------------------------------------------------
    // Minimal context read interface
    // ------------------------------------------------------------------
    input  logic                         context_read_valid,      // QP context 读请求有效。
    output logic                         context_read_ready,      // 本模块可接收读请求。
    input  logic [QP_ID_W-1:0]           context_read_qpn,        // 要读取的 QPN。
    input  logic [VF_ID_W-1:0]           context_read_function_id, // 发起读取的 PF/VF function。
    input  logic                         context_read_pf_bypass,   // PF/管理路径权限绕过预留。
    output logic                         context_read_rsp_valid,   // 读响应有效。
    input  logic                         context_read_rsp_ready,   // 下游已接收读响应。
    output logic                         context_read_hit,         // 读取命中且权限允许。
    output qp_table_status_e             context_read_status,      // 读操作状态。
    output qp_context_t                  context_read_data,        // 读取到的 QP context。

    // ------------------------------------------------------------------
    // SQ Doorbell producer index update
    // ------------------------------------------------------------------
    input  logic                         sq_pi_update_valid,      // SQ producer index 更新请求有效。
    output logic                         sq_pi_update_ready,      // 本模块可接收 SQ PI 更新。
    input  logic [QP_ID_W-1:0]           sq_pi_update_qpn,        // 要更新 SQ PI 的 QPN。
    input  logic [VF_ID_W-1:0]           sq_pi_update_function_id, // 更新所属 PF/VF function。
    input  logic [QUEUE_IDX_W-1:0]       sq_pi_update_new_pi,     // 新的 SQ producer index。
    input  logic                         sq_pi_update_error,      // 上游 SQ Doorbell handler 已报告错误。
    output logic                         sq_pi_update_rsp_valid,  // SQ PI 更新响应有效。
    input  logic                         sq_pi_update_rsp_ready,  // 下游已接收 SQ PI 更新响应。
    output qp_table_status_e             sq_pi_update_status,     // SQ PI 更新状态。

    // ------------------------------------------------------------------
    // RQ Doorbell producer index update
    // ------------------------------------------------------------------
    input  logic                         rq_pi_update_valid,      // RQ producer index 更新请求有效。
    output logic                         rq_pi_update_ready,      // 本模块可接收 RQ PI 更新。
    input  logic [QP_ID_W-1:0]           rq_pi_update_qpn,        // 要更新 RQ PI 的 QPN。
    input  logic [VF_ID_W-1:0]           rq_pi_update_function_id, // 更新所属 PF/VF function。
    input  logic [QUEUE_IDX_W-1:0]       rq_pi_update_new_pi,     // 新的 RQ producer index。
    input  logic                         rq_pi_update_error,      // 上游 RQ Doorbell handler 已报告错误。
    output logic                         rq_pi_update_rsp_valid,  // RQ PI 更新响应有效。
    input  logic                         rq_pi_update_rsp_ready,  // 下游已接收 RQ PI 更新响应。
    output qp_table_status_e             rq_pi_update_status      // RQ PI 更新状态。
);

    qp_context_t table [QP_TABLE_DEPTH]; // 原型阶段使用寄存器数组表达 QP context 表。

    logic lookup_fire;
    logic lookup_rsp_fire;
    logic context_write_fire;
    logic context_write_rsp_fire;
    logic context_read_fire;
    logic context_read_rsp_fire;
    logic sq_pi_update_fire;
    logic sq_pi_update_rsp_fire;
    logic rq_pi_update_fire;
    logic rq_pi_update_rsp_fire;

    logic lookup_found;
    logic lookup_alias;
    logic [QP_TABLE_INDEX_W-1:0] lookup_match_index;
    logic read_found;
    logic read_alias;
    logic [QP_TABLE_INDEX_W-1:0] read_match_index;
    logic write_found;
    logic write_alias;
    logic write_free_found;
    logic [QP_TABLE_INDEX_W-1:0] write_match_index;
    logic [QP_TABLE_INDEX_W-1:0] write_free_index;
    logic [QP_TABLE_INDEX_W-1:0] write_target_index;
    qp_table_status_e write_status_next;
    qp_context_t write_data_next;
    logic sq_found;
    logic sq_alias;
    logic [QP_TABLE_INDEX_W-1:0] sq_match_index;
    logic rq_found;
    logic rq_alias;
    logic [QP_TABLE_INDEX_W-1:0] rq_match_index;

    assign lookup_ready = !lookup_rsp_valid || lookup_rsp_ready;
    assign context_write_ready = !context_write_rsp_valid || context_write_rsp_ready;
    assign context_read_ready = !context_read_rsp_valid || context_read_rsp_ready;
    assign sq_pi_update_ready = !sq_pi_update_rsp_valid || sq_pi_update_rsp_ready;
    assign rq_pi_update_ready = !rq_pi_update_rsp_valid || rq_pi_update_rsp_ready;

    assign lookup_fire = lookup_valid && lookup_ready;
    assign lookup_rsp_fire = lookup_rsp_valid && lookup_rsp_ready;
    assign context_write_fire = context_write_valid && context_write_ready;
    assign context_write_rsp_fire = context_write_rsp_valid && context_write_rsp_ready;
    assign context_read_fire = context_read_valid && context_read_ready;
    assign context_read_rsp_fire = context_read_rsp_valid && context_read_rsp_ready;
    assign sq_pi_update_fire = sq_pi_update_valid && sq_pi_update_ready;
    assign sq_pi_update_rsp_fire = sq_pi_update_rsp_valid && sq_pi_update_rsp_ready;
    assign rq_pi_update_fire = rq_pi_update_valid && rq_pi_update_ready;
    assign rq_pi_update_rsp_fire = rq_pi_update_rsp_valid && rq_pi_update_rsp_ready;

    function automatic logic owner_allowed(
        input qp_context_t          ctx,
        input logic [VF_ID_W-1:0]   function_id,
        input logic                 pf_bypass
    );
        begin
            return pf_bypass || (ctx.owner_func == function_id);
        end
    endfunction

    function automatic qp_table_status_e lookup_status_for(
        input logic                  found,
        input logic                  alias,
        input qp_context_t           ctx,
        input logic [VF_ID_W-1:0]    function_id,
        input logic                  pf_bypass
    );
        begin
            if (alias) begin
                return QP_TABLE_STATUS_ALIAS;
            end

            if (!found) begin
                return QP_TABLE_STATUS_MISS;
            end

            if (!owner_allowed(ctx, function_id, pf_bypass)) begin
                return QP_TABLE_STATUS_PERMISSION;
            end

            return QP_TABLE_STATUS_OK;
        end
    endfunction

    always_comb begin
        lookup_found = 1'b0;
        lookup_alias = 1'b0;
        lookup_match_index = '0;

        for (int unsigned i = 0; i < QP_TABLE_DEPTH; i++) begin
            if (table[i].valid && (table[i].qpn == lookup_qpn)) begin
                if (!lookup_found) begin
                    lookup_found = 1'b1;
                    lookup_match_index = QP_TABLE_INDEX_W'(i);
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

        for (int unsigned i = 0; i < QP_TABLE_DEPTH; i++) begin
            if (table[i].valid && (table[i].qpn == context_read_qpn)) begin
                if (!read_found) begin
                    read_found = 1'b1;
                    read_match_index = QP_TABLE_INDEX_W'(i);
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

        for (int unsigned i = 0; i < QP_TABLE_DEPTH; i++) begin
            if (table[i].valid && (table[i].qpn == context_write_qpn)) begin
                if (!write_found) begin
                    write_found = 1'b1;
                    write_match_index = QP_TABLE_INDEX_W'(i);
                end else begin
                    write_alias = 1'b1;
                end
            end

            if (!table[i].valid && !write_free_found) begin
                write_free_found = 1'b1;
                write_free_index = QP_TABLE_INDEX_W'(i);
            end
        end
    end

    always_comb begin
        write_target_index = context_write_use_index ? context_write_index :
                             (write_found ? write_match_index : write_free_index);
        write_data_next = context_write_data;
        write_data_next.qpn = context_write_qpn;
        write_status_next = QP_TABLE_STATUS_OK;

        if (context_write_data.valid &&
            (context_write_data.qpn != context_write_qpn)) begin
            write_status_next = QP_TABLE_STATUS_INVALID;
        end else if (write_alias ||
                     (context_write_use_index && context_write_data.valid &&
                      write_found && (write_match_index != context_write_index))) begin
            write_status_next = QP_TABLE_STATUS_ALIAS;
        end else if (!context_write_data.valid && !write_found && !context_write_use_index) begin
            write_status_next = QP_TABLE_STATUS_MISS;
        end else if (!context_write_use_index && context_write_data.valid &&
                     !write_found && !write_free_found) begin
            write_status_next = QP_TABLE_STATUS_FULL;
        end else if (table[write_target_index].valid &&
                     !owner_allowed(table[write_target_index],
                                    context_write_function_id,
                                    context_write_pf_bypass)) begin
            write_status_next = QP_TABLE_STATUS_PERMISSION;
        end else if (context_write_data.valid &&
                     !context_write_pf_bypass &&
                     (context_write_data.owner_func != context_write_function_id)) begin
            write_status_next = QP_TABLE_STATUS_PERMISSION;
        end
    end

    always_comb begin
        sq_found = 1'b0;
        sq_alias = 1'b0;
        sq_match_index = '0;

        for (int unsigned i = 0; i < QP_TABLE_DEPTH; i++) begin
            if (table[i].valid && (table[i].qpn == sq_pi_update_qpn)) begin
                if (!sq_found) begin
                    sq_found = 1'b1;
                    sq_match_index = QP_TABLE_INDEX_W'(i);
                end else begin
                    sq_alias = 1'b1;
                end
            end
        end
    end

    always_comb begin
        rq_found = 1'b0;
        rq_alias = 1'b0;
        rq_match_index = '0;

        for (int unsigned i = 0; i < QP_TABLE_DEPTH; i++) begin
            if (table[i].valid && (table[i].qpn == rq_pi_update_qpn)) begin
                if (!rq_found) begin
                    rq_found = 1'b1;
                    rq_match_index = QP_TABLE_INDEX_W'(i);
                end else begin
                    rq_alias = 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lookup_rsp_valid <= 1'b0;
            lookup_hit <= 1'b0;
            lookup_miss <= 1'b0;
            lookup_status <= QP_TABLE_STATUS_MISS;
            lookup_context <= '0;
            context_write_rsp_valid <= 1'b0;
            context_write_status <= QP_TABLE_STATUS_MISS;
            context_read_rsp_valid <= 1'b0;
            context_read_hit <= 1'b0;
            context_read_status <= QP_TABLE_STATUS_MISS;
            context_read_data <= '0;
            sq_pi_update_rsp_valid <= 1'b0;
            sq_pi_update_status <= QP_TABLE_STATUS_MISS;
            rq_pi_update_rsp_valid <= 1'b0;
            rq_pi_update_status <= QP_TABLE_STATUS_MISS;

            for (int unsigned i = 0; i < QP_TABLE_DEPTH; i++) begin
                table[i] <= '0;
            end
        end else begin
            if (lookup_rsp_fire) begin
                lookup_rsp_valid <= 1'b0;
            end

            if (context_write_rsp_fire) begin
                context_write_rsp_valid <= 1'b0;
            end

            if (context_read_rsp_fire) begin
                context_read_rsp_valid <= 1'b0;
            end

            if (sq_pi_update_rsp_fire) begin
                sq_pi_update_rsp_valid <= 1'b0;
            end

            if (rq_pi_update_rsp_fire) begin
                rq_pi_update_rsp_valid <= 1'b0;
            end

            if (lookup_fire) begin
                lookup_rsp_valid <= 1'b1;
                lookup_status <= lookup_status_for(lookup_found,
                                                   lookup_alias,
                                                   table[lookup_match_index],
                                                   lookup_function_id,
                                                   lookup_pf_bypass);
                lookup_hit <= lookup_found && !lookup_alias &&
                              owner_allowed(table[lookup_match_index],
                                            lookup_function_id,
                                            lookup_pf_bypass);
                lookup_miss <= !lookup_found;
                lookup_context <= (lookup_found && !lookup_alias) ? table[lookup_match_index] : '0;
            end

            if (context_write_fire) begin
                context_write_rsp_valid <= 1'b1;
                context_write_status <= write_status_next;

                if (write_status_next == QP_TABLE_STATUS_OK) begin
                    table[write_target_index] <= write_data_next;
                end
            end

            if (context_read_fire) begin
                context_read_rsp_valid <= 1'b1;
                context_read_status <= lookup_status_for(read_found,
                                                         read_alias,
                                                         table[read_match_index],
                                                         context_read_function_id,
                                                         context_read_pf_bypass);
                context_read_hit <= read_found && !read_alias &&
                                    owner_allowed(table[read_match_index],
                                                  context_read_function_id,
                                                  context_read_pf_bypass);
                context_read_data <= (read_found && !read_alias) ? table[read_match_index] : '0;
            end

            if (sq_pi_update_fire) begin
                sq_pi_update_rsp_valid <= 1'b1;

                if (sq_pi_update_error) begin
                    sq_pi_update_status <= QP_TABLE_STATUS_INVALID;
                end else if (sq_alias) begin
                    sq_pi_update_status <= QP_TABLE_STATUS_ALIAS;
                end else if (!sq_found) begin
                    sq_pi_update_status <= QP_TABLE_STATUS_MISS;
                end else if (!owner_allowed(table[sq_match_index], sq_pi_update_function_id, 1'b0)) begin
                    sq_pi_update_status <= QP_TABLE_STATUS_PERMISSION;
                end else begin
                    sq_pi_update_status <= QP_TABLE_STATUS_OK;
                    table[sq_match_index].sq_producer <= sq_pi_update_new_pi;
                end
            end

            if (rq_pi_update_fire) begin
                rq_pi_update_rsp_valid <= 1'b1;

                if (rq_pi_update_error) begin
                    rq_pi_update_status <= QP_TABLE_STATUS_INVALID;
                end else if (rq_alias) begin
                    rq_pi_update_status <= QP_TABLE_STATUS_ALIAS;
                end else if (!rq_found) begin
                    rq_pi_update_status <= QP_TABLE_STATUS_MISS;
                end else if (!owner_allowed(table[rq_match_index], rq_pi_update_function_id, 1'b0)) begin
                    rq_pi_update_status <= QP_TABLE_STATUS_PERMISSION;
                end else begin
                    rq_pi_update_status <= QP_TABLE_STATUS_OK;
                    table[rq_match_index].rq_producer <= rq_pi_update_new_pi;
                end
            end
        end
    end

endmodule : qp_context_table
