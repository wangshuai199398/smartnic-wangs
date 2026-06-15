// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// MR table 最小实现。
//
// 本模块保存 MR/MW 表项，支持 lkey/rkey 查找、VA->PA 范围检查、整项读写
// 和 refcount 更新。当前阶段不处理注册命令、不解析 pinned page list、不做
// access_flags/PD 的完整权限规则，也不实现 Memory Window bind。

`timescale 1ns/1ps

import smartnic_pkg::*;

module mr_table (
    input  logic                         clk,                     // MR table 时钟。
    input  logic                         rst_n,                   // 低有效复位。

    // ------------------------------------------------------------------
    // Key lookup interface
    // ------------------------------------------------------------------
    input  logic                         lookup_valid,            // key lookup 请求有效。
    output logic                         lookup_ready,            // 本模块可接收 lookup。
    input  logic [KEY_W-1:0]             lookup_key,              // lkey 或 rkey。
    input  logic                         lookup_is_remote,        // 1 使用 rkey，0 使用 lkey。
    input  logic [VF_ID_W-1:0]           lookup_owner_function,   // 发起 lookup 的 function。
    input  logic [PD_ID_W-1:0]           lookup_pd_id,            // 发起 lookup 的 PD。
    input  logic                         lookup_admin_bypass,     // PF/管理路径权限绕过预留。
    output logic                         lookup_rsp_valid,        // lookup 响应有效。
    input  logic                         lookup_rsp_ready,        // 下游已接收 lookup 响应。
    output logic                         lookup_hit,              // lookup 命中且允许。
    output mr_entry_t                    lookup_entry,            // 命中的 MR entry。
    output mr_table_status_e             lookup_error_code,       // lookup 状态/错误码。

    // ------------------------------------------------------------------
    // Address range check and VA->PA translation
    // ------------------------------------------------------------------
    input  logic                         check_valid,             // 地址检查请求有效。
    output logic                         check_ready,             // 本模块可接收地址检查。
    input  logic [KEY_W-1:0]             check_key,               // lkey 或 rkey。
    input  logic [ADDR_W-1:0]            check_va,                // 要访问的虚拟地址。
    input  logic [DMA_LEN_W-1:0]         check_len,               // 要访问的字节数。
    input  logic                         check_is_remote,         // 1 使用 rkey，0 使用 lkey。
    input  logic [VF_ID_W-1:0]           check_owner_function,    // 发起检查的 function。
    input  logic [PD_ID_W-1:0]           check_pd_id,             // 发起检查的 PD。
    input  logic                         check_admin_bypass,      // PF/管理路径权限绕过预留。
    output logic                         check_rsp_valid,         // 地址检查响应有效。
    input  logic                         check_rsp_ready,         // 下游已接收地址检查响应。
    output logic                         check_hit,               // 地址检查命中且范围合法。
    output mr_entry_t                    check_entry,             // 地址检查命中的 MR entry。
    output logic [ADDR_W-1:0]            check_pa,                // 转换后的物理/DMA 地址。
    output mr_table_status_e             check_error_code,        // 地址检查状态/错误码。

    // ------------------------------------------------------------------
    // Minimal entry write interface
    // ------------------------------------------------------------------
    input  logic                         entry_write_valid,       // MR entry 写请求有效。
    output logic                         entry_write_ready,       // 本模块可接收写请求。
    input  logic                         entry_write_use_index,   // 1 使用显式 slot 写入。
    input  logic [MR_TABLE_INDEX_W-1:0]  entry_write_index,       // 显式写入的表 slot。
    input  logic [KEY_W-1:0]             entry_write_key,         // 按 key 覆盖已有表项时使用。
    input  logic                         entry_write_is_remote,   // entry_write_key 选择 rkey/lkey。
    input  logic [VF_ID_W-1:0]           entry_write_owner_function,// 发起写入的 function。
    input  logic                         entry_write_admin_bypass,// PF/管理路径权限绕过预留。
    input  mr_entry_t                    entry_write_data,        // 要写入的完整 MR entry。
    output logic                         entry_write_rsp_valid,   // 写响应有效。
    input  logic                         entry_write_rsp_ready,   // 下游已接收写响应。
    output mr_table_status_e             entry_write_status,      // 写操作状态。

    // ------------------------------------------------------------------
    // Minimal entry read interface
    // ------------------------------------------------------------------
    input  logic                         entry_read_valid,        // MR entry 读请求有效。
    output logic                         entry_read_ready,        // 本模块可接收读请求。
    input  logic [KEY_W-1:0]             entry_read_key,          // lkey 或 rkey。
    input  logic                         entry_read_is_remote,    // 1 使用 rkey，0 使用 lkey。
    input  logic [VF_ID_W-1:0]           entry_read_owner_function,// 发起读取的 function。
    input  logic [PD_ID_W-1:0]           entry_read_pd_id,        // 发起读取的 PD。
    input  logic                         entry_read_admin_bypass, // PF/管理路径权限绕过预留。
    output logic                         entry_read_rsp_valid,    // 读响应有效。
    input  logic                         entry_read_rsp_ready,    // 下游已接收读响应。
    output logic                         entry_read_hit,          // 读取命中且允许。
    output mr_entry_t                    entry_read_data,         // 读取到的 MR entry。
    output mr_table_status_e             entry_read_status,       // 读操作状态。

    // ------------------------------------------------------------------
    // Refcount update interface
    // ------------------------------------------------------------------
    input  logic                         ref_inc_valid,           // refcount +1 请求。
    input  logic                         ref_dec_valid,           // refcount -1 请求。
    output logic                         ref_update_ready,        // 本模块可接收 refcount 更新。
    input  logic [KEY_W-1:0]             ref_key,                 // lkey 或 rkey。
    input  logic                         ref_is_remote,           // 1 使用 rkey，0 使用 lkey。
    input  logic [VF_ID_W-1:0]           ref_owner_function,      // 发起更新的 function。
    input  logic                         ref_admin_bypass,        // PF/管理路径权限绕过预留。
    output logic                         ref_update_rsp_valid,    // refcount 更新响应有效。
    input  logic                         ref_update_rsp_ready,    // 下游已接收 refcount 响应。
    output mr_table_status_e             ref_update_status,       // refcount 更新状态。
    output logic [MR_REFCOUNT_W-1:0]     refcount_out,            // 更新后的 refcount。
    output logic                         refcount_zero            // 更新后 refcount 是否为 0。
);

    mr_entry_t table [MR_TABLE_DEPTH]; // 原型阶段使用寄存器数组表达 MR 表。

    logic lookup_fire;
    logic lookup_rsp_fire;
    logic check_fire;
    logic check_rsp_fire;
    logic entry_write_fire;
    logic entry_write_rsp_fire;
    logic entry_read_fire;
    logic entry_read_rsp_fire;
    logic ref_update_fire;
    logic ref_update_rsp_fire;

    logic lookup_found;
    logic lookup_alias;
    logic [MR_TABLE_INDEX_W-1:0] lookup_match_index;
    logic check_found;
    logic check_alias;
    logic [MR_TABLE_INDEX_W-1:0] check_match_index;
    logic read_found;
    logic read_alias;
    logic [MR_TABLE_INDEX_W-1:0] read_match_index;
    logic write_found;
    logic write_free_found;
    logic write_lkey_alias;
    logic write_rkey_alias;
    logic [MR_TABLE_INDEX_W-1:0] write_match_index;
    logic [MR_TABLE_INDEX_W-1:0] write_free_index;
    logic [MR_TABLE_INDEX_W-1:0] write_target_index;
    mr_table_status_e write_status_next;
    mr_entry_t write_data_next;
    logic ref_found;
    logic ref_alias;
    logic [MR_TABLE_INDEX_W-1:0] ref_match_index;

    assign lookup_ready = !lookup_rsp_valid || lookup_rsp_ready;
    assign check_ready = !check_rsp_valid || check_rsp_ready;
    assign entry_write_ready = !entry_write_rsp_valid || entry_write_rsp_ready;
    assign entry_read_ready = !entry_read_rsp_valid || entry_read_rsp_ready;
    assign ref_update_ready = !ref_update_rsp_valid || ref_update_rsp_ready;

    assign lookup_fire = lookup_valid && lookup_ready;
    assign lookup_rsp_fire = lookup_rsp_valid && lookup_rsp_ready;
    assign check_fire = check_valid && check_ready;
    assign check_rsp_fire = check_rsp_valid && check_rsp_ready;
    assign entry_write_fire = entry_write_valid && entry_write_ready;
    assign entry_write_rsp_fire = entry_write_rsp_valid && entry_write_rsp_ready;
    assign entry_read_fire = entry_read_valid && entry_read_ready;
    assign entry_read_rsp_fire = entry_read_rsp_valid && entry_read_rsp_ready;
    assign ref_update_fire = (ref_inc_valid || ref_dec_valid) && ref_update_ready;
    assign ref_update_rsp_fire = ref_update_rsp_valid && ref_update_rsp_ready;

    function automatic logic key_matches(
        input mr_entry_t entry,
        input logic [KEY_W-1:0] key,
        input logic is_remote
    );
        begin
            return entry.valid && (is_remote ? (entry.rkey == key) : (entry.lkey == key));
        end
    endfunction

    function automatic logic owner_allowed(
        input mr_entry_t entry,
        input logic [VF_ID_W-1:0] function_id,
        input logic admin_bypass
    );
        begin
            return admin_bypass || (entry.owner_function == function_id);
        end
    endfunction

    function automatic mr_table_status_e status_for_access(
        input logic found,
        input logic alias,
        input mr_entry_t entry,
        input logic [VF_ID_W-1:0] function_id,
        input logic admin_bypass,
        input logic block_pending
    );
        begin
            if (alias) begin
                return MR_TABLE_STATUS_ALIAS;
            end
            if (!found) begin
                return MR_TABLE_STATUS_MISS;
            end
            if (!owner_allowed(entry, function_id, admin_bypass)) begin
                return MR_TABLE_STATUS_PERMISSION;
            end
            if (block_pending && (entry.pending_deregister || entry.invalidating)) begin
                return MR_TABLE_STATUS_PENDING;
            end
            return MR_TABLE_STATUS_OK;
        end
    endfunction

    function automatic mr_table_status_e check_bounds_status(
        input mr_entry_t entry,
        input logic [ADDR_W-1:0] va,
        input logic [DMA_LEN_W-1:0] len
    );
        logic [ADDR_W-1:0] access_end;
        logic [ADDR_W-1:0] mr_end;
        logic [ADDR_W-1:0] len_ext;
        logic access_overflow;
        logic mr_overflow;
        begin
            len_ext = ADDR_W'(len);
            access_end = va + len_ext;
            mr_end = entry.virtual_base_addr + ADDR_W'(entry.length);
            access_overflow = (access_end < va);
            mr_overflow = (mr_end < entry.virtual_base_addr);

            if (len == '0 || entry.length == '0) begin
                return MR_TABLE_STATUS_LENGTH;
            end
            if (access_overflow || mr_overflow ||
                (va < entry.virtual_base_addr) ||
                (access_end > mr_end)) begin
                return MR_TABLE_STATUS_BOUNDS;
            end
            return MR_TABLE_STATUS_OK;
        end
    endfunction

    always_comb begin
        lookup_found = 1'b0;
        lookup_alias = 1'b0;
        lookup_match_index = '0;
        check_found = 1'b0;
        check_alias = 1'b0;
        check_match_index = '0;
        read_found = 1'b0;
        read_alias = 1'b0;
        read_match_index = '0;
        write_found = 1'b0;
        write_free_found = 1'b0;
        write_lkey_alias = 1'b0;
        write_rkey_alias = 1'b0;
        write_match_index = '0;
        write_free_index = '0;
        ref_found = 1'b0;
        ref_alias = 1'b0;
        ref_match_index = '0;

        for (int unsigned i = 0; i < MR_TABLE_DEPTH; i++) begin
            if (key_matches(table[i], lookup_key, lookup_is_remote)) begin
                if (!lookup_found) begin
                    lookup_found = 1'b1;
                    lookup_match_index = MR_TABLE_INDEX_W'(i);
                end else begin
                    lookup_alias = 1'b1;
                end
            end

            if (key_matches(table[i], check_key, check_is_remote)) begin
                if (!check_found) begin
                    check_found = 1'b1;
                    check_match_index = MR_TABLE_INDEX_W'(i);
                end else begin
                    check_alias = 1'b1;
                end
            end

            if (key_matches(table[i], entry_read_key, entry_read_is_remote)) begin
                if (!read_found) begin
                    read_found = 1'b1;
                    read_match_index = MR_TABLE_INDEX_W'(i);
                end else begin
                    read_alias = 1'b1;
                end
            end

            if (key_matches(table[i], entry_write_key, entry_write_is_remote)) begin
                if (!write_found) begin
                    write_found = 1'b1;
                    write_match_index = MR_TABLE_INDEX_W'(i);
                end
            end

            if (entry_write_data.valid && table[i].valid &&
                (!entry_write_use_index || (MR_TABLE_INDEX_W'(i) != entry_write_index)) &&
                (entry_write_use_index || !key_matches(table[i],
                                                       entry_write_key,
                                                       entry_write_is_remote))) begin
                if (table[i].lkey == entry_write_data.lkey) begin
                    write_lkey_alias = 1'b1;
                end
                if (table[i].rkey == entry_write_data.rkey) begin
                    write_rkey_alias = 1'b1;
                end
            end

            if (!table[i].valid && !write_free_found) begin
                write_free_found = 1'b1;
                write_free_index = MR_TABLE_INDEX_W'(i);
            end

            if (key_matches(table[i], ref_key, ref_is_remote)) begin
                if (!ref_found) begin
                    ref_found = 1'b1;
                    ref_match_index = MR_TABLE_INDEX_W'(i);
                end else begin
                    ref_alias = 1'b1;
                end
            end
        end
    end

    always_comb begin
        write_target_index = entry_write_use_index ? entry_write_index :
                             (write_found ? write_match_index : write_free_index);
        write_data_next = entry_write_data;
        write_status_next = MR_TABLE_STATUS_OK;

        if (entry_write_data.valid &&
            (entry_write_data.owner_function != entry_write_owner_function) &&
            !entry_write_admin_bypass) begin
            write_status_next = MR_TABLE_STATUS_PERMISSION;
        end else if (write_lkey_alias || write_rkey_alias) begin
            write_status_next = MR_TABLE_STATUS_ALIAS;
        end else if (!entry_write_data.valid && !write_found && !entry_write_use_index) begin
            write_status_next = MR_TABLE_STATUS_MISS;
        end else if (!entry_write_use_index && entry_write_data.valid &&
                     !write_found && !write_free_found) begin
            write_status_next = MR_TABLE_STATUS_FULL;
        end else if (table[write_target_index].valid &&
                     !owner_allowed(table[write_target_index],
                                    entry_write_owner_function,
                                    entry_write_admin_bypass)) begin
            write_status_next = MR_TABLE_STATUS_PERMISSION;
        end else if (entry_write_data.valid && (entry_write_data.length == '0)) begin
            write_status_next = MR_TABLE_STATUS_LENGTH;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lookup_rsp_valid <= 1'b0;
            lookup_hit <= 1'b0;
            lookup_entry <= '0;
            lookup_error_code <= MR_TABLE_STATUS_MISS;
            check_rsp_valid <= 1'b0;
            check_hit <= 1'b0;
            check_entry <= '0;
            check_pa <= '0;
            check_error_code <= MR_TABLE_STATUS_MISS;
            entry_write_rsp_valid <= 1'b0;
            entry_write_status <= MR_TABLE_STATUS_MISS;
            entry_read_rsp_valid <= 1'b0;
            entry_read_hit <= 1'b0;
            entry_read_data <= '0;
            entry_read_status <= MR_TABLE_STATUS_MISS;
            ref_update_rsp_valid <= 1'b0;
            ref_update_status <= MR_TABLE_STATUS_MISS;
            refcount_out <= '0;
            refcount_zero <= 1'b1;

            for (int unsigned i = 0; i < MR_TABLE_DEPTH; i++) begin
                table[i] <= '0;
            end
        end else begin
            if (lookup_rsp_fire) lookup_rsp_valid <= 1'b0;
            if (check_rsp_fire) check_rsp_valid <= 1'b0;
            if (entry_write_rsp_fire) entry_write_rsp_valid <= 1'b0;
            if (entry_read_rsp_fire) entry_read_rsp_valid <= 1'b0;
            if (ref_update_rsp_fire) ref_update_rsp_valid <= 1'b0;

            if (lookup_fire) begin
                lookup_rsp_valid <= 1'b1;
                lookup_error_code <= status_for_access(lookup_found,
                                                       lookup_alias,
                                                       table[lookup_match_index],
                                                       lookup_owner_function,
                                                       lookup_admin_bypass,
                                                       1'b1);
                lookup_hit <= (status_for_access(lookup_found,
                                                 lookup_alias,
                                                 table[lookup_match_index],
                                                 lookup_owner_function,
                                                 lookup_admin_bypass,
                                                 1'b1) == MR_TABLE_STATUS_OK);
                lookup_entry <= (lookup_found && !lookup_alias) ? table[lookup_match_index] : '0;
            end

            if (check_fire) begin
                check_rsp_valid <= 1'b1;
                check_error_code <= status_for_access(check_found,
                                                      check_alias,
                                                      table[check_match_index],
                                                      check_owner_function,
                                                      check_admin_bypass,
                                                      1'b1);
                check_hit <= 1'b0;
                check_entry <= '0;
                check_pa <= '0;

                if (status_for_access(check_found,
                                      check_alias,
                                      table[check_match_index],
                                      check_owner_function,
                                      check_admin_bypass,
                                      1'b1) == MR_TABLE_STATUS_OK) begin
                    check_error_code <= check_bounds_status(table[check_match_index],
                                                           check_va,
                                                           check_len);
                    if (check_bounds_status(table[check_match_index],
                                            check_va,
                                            check_len) == MR_TABLE_STATUS_OK) begin
                        check_hit <= 1'b1;
                        check_entry <= table[check_match_index];
                        check_pa <= table[check_match_index].physical_base_addr +
                                    (check_va - table[check_match_index].virtual_base_addr);
                    end
                end
            end

            if (entry_write_fire) begin
                entry_write_rsp_valid <= 1'b1;
                entry_write_status <= write_status_next;

                if (write_status_next == MR_TABLE_STATUS_OK) begin
                    table[write_target_index] <= write_data_next;
                end
            end

            if (entry_read_fire) begin
                entry_read_rsp_valid <= 1'b1;
                entry_read_status <= status_for_access(read_found,
                                                       read_alias,
                                                       table[read_match_index],
                                                       entry_read_owner_function,
                                                       entry_read_admin_bypass,
                                                       1'b0);
                entry_read_hit <= (status_for_access(read_found,
                                                     read_alias,
                                                     table[read_match_index],
                                                     entry_read_owner_function,
                                                     entry_read_admin_bypass,
                                                     1'b0) == MR_TABLE_STATUS_OK);
                entry_read_data <= (read_found && !read_alias) ? table[read_match_index] : '0;
            end

            if (ref_update_fire) begin
                ref_update_rsp_valid <= 1'b1;
                ref_update_status <= status_for_access(ref_found,
                                                       ref_alias,
                                                       table[ref_match_index],
                                                       ref_owner_function,
                                                       ref_admin_bypass,
                                                       1'b0);
                refcount_out <= (ref_found && !ref_alias) ? table[ref_match_index].refcount : '0;
                refcount_zero <= !ref_found || ref_alias ||
                                 (table[ref_match_index].refcount == '0);

                if (status_for_access(ref_found,
                                      ref_alias,
                                      table[ref_match_index],
                                      ref_owner_function,
                                      ref_admin_bypass,
                                      1'b0) == MR_TABLE_STATUS_OK) begin
                    if (ref_inc_valid && ref_dec_valid) begin
                        ref_update_status <= MR_TABLE_STATUS_INVALID;
                    end else if (ref_inc_valid && (table[ref_match_index].refcount == '1)) begin
                        ref_update_status <= MR_TABLE_STATUS_REF_OVER;
                    end else if (ref_dec_valid && (table[ref_match_index].refcount == '0)) begin
                        ref_update_status <= MR_TABLE_STATUS_REF_UNDER;
                    end else if (ref_inc_valid) begin
                        table[ref_match_index].refcount <= table[ref_match_index].refcount + 1'b1;
                        refcount_out <= table[ref_match_index].refcount + 1'b1;
                        refcount_zero <= 1'b0;
                    end else if (ref_dec_valid) begin
                        table[ref_match_index].refcount <= table[ref_match_index].refcount - 1'b1;
                        refcount_out <= table[ref_match_index].refcount - 1'b1;
                        refcount_zero <= ((table[ref_match_index].refcount - 1'b1) == '0);
                    end
                end
            end
        end
    end

endmodule : mr_table
