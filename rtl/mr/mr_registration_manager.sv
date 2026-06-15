// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// MR registration manager 最小实现。
//
// 本模块处理 REGISTER_MR 控制命令：校验请求字段，fetch 第一个 pinned
// scatter-gather entry，构造 mr_entry_t，并通过 mr_table 写接口注册 MR。
// 当前阶段只支持单段/线性 SG list，不实现真实 DMA fetch、不做 IOMMU/PD 复杂规则。

`timescale 1ns/1ps

import smartnic_pkg::*;

module mr_registration_manager (
    input  logic                         clk,                         // 注册管理器时钟。
    input  logic                         rst_n,                       // 低有效复位。

    // ------------------------------------------------------------------
    // REGISTER_MR command request
    // ------------------------------------------------------------------
    input  logic                         reg_req_valid,               // REGISTER_MR 请求有效。
    output logic                         reg_req_ready,               // 本模块可接收 REGISTER_MR 请求。
    input  logic [VF_ID_W-1:0]           reg_req_owner_function,      // MR 所属 PF/VF function。
    input  logic                         reg_req_function_enabled,    // owner function 是否启用。
    input  logic [PD_ID_W-1:0]           reg_req_pd_id,               // Protection Domain ID。
    input  logic [ADDR_W-1:0]            reg_req_virtual_base_addr,   // 用户 VA 起始地址。
    input  logic [DMA_LEN_W-1:0]         reg_req_length,              // MR 覆盖长度。
    input  logic [PAGE_SHIFT_W-1:0]      reg_req_page_size,           // 页大小 log2(bytes)。
    input  logic [5:0]                   reg_req_access_flags,        // MR access flags。
    input  logic [ADDR_W-1:0]            reg_req_sg_list_base_addr,   // pinned SG list 起始 DMA 地址。
    input  logic [SGE_COUNT_W-1:0]       reg_req_sg_entry_count,      // SG entry 数量。
    input  logic [KEY_W-1:0]             reg_req_lkey,                // 由驱动分配的 lkey。
    input  logic [KEY_W-1:0]             reg_req_rkey,                // 由驱动分配的 rkey。
    input  logic [31:0]                  reg_req_cmd_sequence,        // mailbox/admin command sequence。

    // ------------------------------------------------------------------
    // REGISTER_MR command response
    // ------------------------------------------------------------------
    output logic                         reg_resp_valid,              // 注册响应有效。
    input  logic                         reg_resp_ready,              // 上游已接收注册响应。
    output mr_table_status_e             reg_resp_status,             // 注册状态。
    output mr_registration_error_e        reg_resp_error_code,         // 注册详细错误码。
    output logic [KEY_W-1:0]             reg_resp_lkey,               // 注册成功返回的 lkey。
    output logic [KEY_W-1:0]             reg_resp_rkey,               // 注册成功返回的 rkey。
    output logic [MR_TABLE_INDEX_W-1:0]  reg_resp_mr_index,           // 写入的 MR table slot。
    output logic [31:0]                  reg_resp_cmd_sequence,       // 返回请求 sequence。

    // ------------------------------------------------------------------
    // SG entry fetch interface
    // ------------------------------------------------------------------
    output logic                         sg_fetch_valid,              // SG entry fetch 请求有效。
    input  logic                         sg_fetch_ready,              // 下游 fetch path 可接收请求。
    output logic [ADDR_W-1:0]            sg_fetch_addr,               // 要读取的 SG entry 地址。
    output logic [DMA_LEN_W-1:0]         sg_fetch_len,                // 读取长度，当前固定 SG_ENTRY_BYTES。
    output logic [VF_ID_W-1:0]           sg_fetch_owner_function,     // fetch 所属 function。
    input  logic                         sg_fetch_resp_valid,         // SG entry fetch 响应有效。
    input  sg_entry_t                    sg_fetch_resp_data,          // fetch 返回的第一个 SG entry。
    input  logic                         sg_fetch_resp_error,         // fetch 失败。

    // ------------------------------------------------------------------
    // MR table write interface
    // ------------------------------------------------------------------
    output logic                         mr_entry_write_valid,        // MR table 写请求有效。
    input  logic                         mr_entry_write_ready,        // MR table 可接收写请求。
    output logic                         mr_entry_write_use_index,    // 使用显式 slot 写入。
    output logic [MR_TABLE_INDEX_W-1:0]  mr_entry_write_index,        // 要写入的 MR table slot。
    output logic [KEY_W-1:0]             mr_entry_write_key,          // lkey，用于 table alias 检查。
    output logic                         mr_entry_write_is_remote,    // 0 表示 entry_write_key 是 lkey。
    output logic [VF_ID_W-1:0]           mr_entry_write_owner_function,// 写入所属 function。
    output logic                         mr_entry_write_admin_bypass, // 当前阶段不使用 admin bypass。
    output mr_entry_t                    mr_entry_write_data,         // 要写入的 MR entry。
    input  logic                         mr_entry_write_rsp_valid,    // MR table 写响应有效。
    output logic                         mr_entry_write_rsp_ready,    // 本模块可接收写响应。
    input  mr_table_status_e             mr_entry_write_status,       // MR table 写状态。

    // ------------------------------------------------------------------
    // Debug/status
    // ------------------------------------------------------------------
    output mr_registration_state_e        debug_state                 // 当前注册 FSM 状态。
);

    mr_registration_state_e state_reg;
    mr_registration_error_e error_reg;
    mr_table_status_e status_reg;

    logic [VF_ID_W-1:0] owner_function_reg;
    logic [PD_ID_W-1:0] pd_id_reg;
    logic [ADDR_W-1:0] va_base_reg;
    logic [DMA_LEN_W-1:0] length_reg;
    logic [PAGE_SHIFT_W-1:0] page_size_reg;
    logic [5:0] access_flags_reg;
    logic [ADDR_W-1:0] sg_list_base_reg;
    logic [SGE_COUNT_W-1:0] sg_entry_count_reg;
    logic [KEY_W-1:0] lkey_reg;
    logic [KEY_W-1:0] rkey_reg;
    logic [31:0] cmd_sequence_reg;
    sg_entry_t sg_entry_reg;
    mr_entry_t mr_entry_reg;
    logic sg_fetch_issued_reg;
    logic [MR_TABLE_DEPTH-1:0] alloc_bitmap_reg;
    logic [MR_TABLE_INDEX_W-1:0] alloc_index_reg;

    logic reg_req_fire;
    logic reg_resp_fire;
    logic sg_fetch_fire;
    logic table_write_fire;
    logic table_write_rsp_fire;
    logic alloc_found;
    logic [MR_TABLE_INDEX_W-1:0] alloc_index_next;
    logic request_ok;
    logic sg_ok;
    mr_registration_error_e request_error_next;
    mr_registration_error_e sg_error_next;

    assign debug_state = state_reg;

    assign reg_req_ready = (state_reg == MR_REG_STATE_IDLE);
    assign reg_req_fire = reg_req_valid && reg_req_ready;
    assign reg_resp_valid = (state_reg == MR_REG_STATE_RESPOND) ||
                            (state_reg == MR_REG_STATE_ERROR);
    assign reg_resp_fire = reg_resp_valid && reg_resp_ready;
    assign reg_resp_status = status_reg;
    assign reg_resp_error_code = error_reg;
    assign reg_resp_lkey = lkey_reg;
    assign reg_resp_rkey = rkey_reg;
    assign reg_resp_mr_index = alloc_index_reg;
    assign reg_resp_cmd_sequence = cmd_sequence_reg;

    assign sg_fetch_valid = (state_reg == MR_REG_STATE_FETCH_SG) && !sg_fetch_issued_reg;
    assign sg_fetch_addr = sg_list_base_reg;
    assign sg_fetch_len = DMA_LEN_W'(SG_ENTRY_BYTES);
    assign sg_fetch_owner_function = owner_function_reg;
    assign sg_fetch_fire = sg_fetch_valid && sg_fetch_ready;

    assign mr_entry_write_valid = (state_reg == MR_REG_STATE_WRITE_TABLE);
    assign mr_entry_write_use_index = 1'b1;
    assign mr_entry_write_index = alloc_index_reg;
    assign mr_entry_write_key = lkey_reg;
    assign mr_entry_write_is_remote = 1'b0;
    assign mr_entry_write_owner_function = owner_function_reg;
    assign mr_entry_write_admin_bypass = 1'b0;
    assign mr_entry_write_data = mr_entry_reg;
    assign mr_entry_write_rsp_ready = (state_reg == MR_REG_STATE_WRITE_TABLE);
    assign table_write_fire = mr_entry_write_valid && mr_entry_write_ready;
    assign table_write_rsp_fire = mr_entry_write_rsp_valid && mr_entry_write_rsp_ready;

    function automatic logic page_size_supported(input logic [PAGE_SHIFT_W-1:0] page_size);
        begin
            return (page_size == PAGE_SHIFT_W'(12)) ||
                   (page_size == PAGE_SHIFT_W'(21)) ||
                   (page_size == PAGE_SHIFT_W'(30));
        end
    endfunction

    function automatic logic addr_aligned(
        input logic [ADDR_W-1:0]       addr,
        input logic [PAGE_SHIFT_W-1:0] page_size
    );
        logic [ADDR_W-1:0] mask;
        begin
            mask = (ADDR_W'(1) << page_size) - 1'b1;
            return (addr & mask) == '0;
        end
    endfunction

    function automatic logic addr_len_overflows(
        input logic [ADDR_W-1:0]    addr,
        input logic [DMA_LEN_W-1:0] len
    );
        logic [ADDR_W-1:0] sum;
        begin
            sum = addr + ADDR_W'(len);
            return sum < addr;
        end
    endfunction

    function automatic mr_table_status_e error_to_status(input mr_registration_error_e error_code);
        begin
            unique case (error_code)
                MR_REG_ERR_NONE:           return MR_TABLE_STATUS_OK;
                MR_REG_ERR_LENGTH:         return MR_TABLE_STATUS_LENGTH;
                MR_REG_ERR_TABLE_FULL:     return MR_TABLE_STATUS_FULL;
                MR_REG_ERR_ALIAS:          return MR_TABLE_STATUS_ALIAS;
                MR_REG_ERR_SG_FETCH,
                MR_REG_ERR_TABLE_WRITE:    return MR_TABLE_STATUS_MISS;
                default:                   return MR_TABLE_STATUS_INVALID;
            endcase
        end
    endfunction

    always_comb begin
        alloc_found = 1'b0;
        alloc_index_next = '0;
        for (int unsigned i = 0; i < MR_TABLE_DEPTH; i++) begin
            if (!alloc_bitmap_reg[i] && !alloc_found) begin
                alloc_found = 1'b1;
                alloc_index_next = MR_TABLE_INDEX_W'(i);
            end
        end
    end

    always_comb begin
        request_ok = 1'b0;
        request_error_next = MR_REG_ERR_NONE;

        if (length_reg == '0) begin
            request_error_next = MR_REG_ERR_LENGTH;
        end else if (!page_size_supported(page_size_reg)) begin
            request_error_next = MR_REG_ERR_PAGE_SIZE;
        end else if (!addr_aligned(va_base_reg, page_size_reg)) begin
            request_error_next = MR_REG_ERR_VA_ALIGN;
        end else if (sg_entry_count_reg == '0) begin
            request_error_next = MR_REG_ERR_SG_COUNT;
        end else if (sg_entry_count_reg > SGE_COUNT_W'(MR_REG_MAX_SG_ENTRIES)) begin
            request_error_next = MR_REG_ERR_UNSUPPORTED_SG;
        end else if ((access_flags_reg & ~MR_ACCESS_FLAGS_ALLOWED) != '0) begin
            request_error_next = MR_REG_ERR_ACCESS_FLAGS;
        end else if ((lkey_reg == '0) || (rkey_reg == '0)) begin
            request_error_next = MR_REG_ERR_KEY;
        end else begin
            request_ok = 1'b1;
        end
    end

    always_comb begin
        sg_ok = 1'b0;
        sg_error_next = MR_REG_ERR_NONE;

        if (sg_fetch_resp_error) begin
            sg_error_next = MR_REG_ERR_SG_FETCH;
        end else if (sg_entry_reg.page_size != page_size_reg) begin
            sg_error_next = MR_REG_ERR_PAGE_SIZE;
        end else if (!addr_aligned(sg_entry_reg.physical_base_addr, page_size_reg)) begin
            sg_error_next = MR_REG_ERR_PA_ALIGN;
        end else if (sg_entry_reg.length < length_reg) begin
            sg_error_next = MR_REG_ERR_LENGTH;
        end else if (addr_len_overflows(sg_entry_reg.physical_base_addr, length_reg)) begin
            sg_error_next = MR_REG_ERR_PA_OVERFLOW;
        end else begin
            sg_ok = 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= MR_REG_STATE_IDLE;
            error_reg <= MR_REG_ERR_NONE;
            status_reg <= MR_TABLE_STATUS_OK;
            owner_function_reg <= '0;
            pd_id_reg <= '0;
            va_base_reg <= '0;
            length_reg <= '0;
            page_size_reg <= '0;
            access_flags_reg <= '0;
            sg_list_base_reg <= '0;
            sg_entry_count_reg <= '0;
            lkey_reg <= '0;
            rkey_reg <= '0;
            cmd_sequence_reg <= '0;
            sg_entry_reg <= '0;
            mr_entry_reg <= '0;
            sg_fetch_issued_reg <= 1'b0;
            alloc_bitmap_reg <= '0;
            alloc_index_reg <= '0;
        end else begin
            unique case (state_reg)
                MR_REG_STATE_IDLE: begin
                    error_reg <= MR_REG_ERR_NONE;
                    status_reg <= MR_TABLE_STATUS_OK;
                    sg_fetch_issued_reg <= 1'b0;
                    if (reg_req_fire) begin
                        owner_function_reg <= reg_req_owner_function;
                        pd_id_reg <= reg_req_pd_id;
                        va_base_reg <= reg_req_virtual_base_addr;
                        length_reg <= reg_req_length;
                        page_size_reg <= reg_req_page_size;
                        access_flags_reg <= reg_req_access_flags;
                        sg_list_base_reg <= reg_req_sg_list_base_addr;
                        sg_entry_count_reg <= reg_req_sg_entry_count;
                        lkey_reg <= reg_req_lkey;
                        rkey_reg <= reg_req_rkey;
                        cmd_sequence_reg <= reg_req_cmd_sequence;
                        if (!reg_req_function_enabled) begin
                            error_reg <= MR_REG_ERR_FUNCTION;
                            status_reg <= MR_TABLE_STATUS_PERMISSION;
                            state_reg <= MR_REG_STATE_ERROR;
                        end else begin
                            state_reg <= MR_REG_STATE_VALIDATE_REQ;
                        end
                    end
                end

                MR_REG_STATE_VALIDATE_REQ: begin
                    if (!request_ok) begin
                        error_reg <= request_error_next;
                        status_reg <= error_to_status(request_error_next);
                        state_reg <= MR_REG_STATE_ERROR;
                    end else begin
                        state_reg <= MR_REG_STATE_ALLOC_ENTRY;
                    end
                end

                MR_REG_STATE_ALLOC_ENTRY: begin
                    if (!alloc_found) begin
                        error_reg <= MR_REG_ERR_TABLE_FULL;
                        status_reg <= MR_TABLE_STATUS_FULL;
                        state_reg <= MR_REG_STATE_ERROR;
                    end else begin
                        alloc_index_reg <= alloc_index_next;
                        state_reg <= MR_REG_STATE_FETCH_SG;
                    end
                end

                MR_REG_STATE_FETCH_SG: begin
                    if (sg_fetch_fire) begin
                        sg_fetch_issued_reg <= 1'b1;
                    end
                    if (sg_fetch_resp_valid) begin
                        sg_entry_reg <= sg_fetch_resp_data;
                        sg_fetch_issued_reg <= 1'b0;
                        state_reg <= MR_REG_STATE_VALIDATE_SG;
                    end
                end

                MR_REG_STATE_VALIDATE_SG: begin
                    if (!sg_ok) begin
                        error_reg <= sg_error_next;
                        status_reg <= error_to_status(sg_error_next);
                        state_reg <= MR_REG_STATE_ERROR;
                    end else begin
                        state_reg <= MR_REG_STATE_BUILD_ENTRY;
                    end
                end

                MR_REG_STATE_BUILD_ENTRY: begin
                    mr_entry_reg <= '0;
                    mr_entry_reg.valid <= 1'b1;
                    mr_entry_reg.mr_id <= MR_ID_W'(alloc_index_reg);
                    mr_entry_reg.lkey <= lkey_reg;
                    mr_entry_reg.rkey <= rkey_reg;
                    mr_entry_reg.virtual_base_addr <= va_base_reg;
                    mr_entry_reg.physical_base_addr <= sg_entry_reg.physical_base_addr;
                    mr_entry_reg.length <= length_reg;
                    mr_entry_reg.page_size <= page_size_reg;
                    mr_entry_reg.access_flags <= access_flags_reg;
                    mr_entry_reg.pd_id <= pd_id_reg;
                    mr_entry_reg.owner_function <= owner_function_reg;
                    mr_entry_reg.refcount <= '0;
                    mr_entry_reg.pending_deregister <= 1'b0;
                    mr_entry_reg.memory_window <= 1'b0;
                    mr_entry_reg.parent_mr_key <= '0;
                    mr_entry_reg.error_state <= 1'b0;
                    mr_entry_reg.error_code <= 16'h0000;
                    state_reg <= MR_REG_STATE_WRITE_TABLE;
                end

                MR_REG_STATE_WRITE_TABLE: begin
                    if (table_write_fire) begin
                        // 等待 mr_table 写响应。
                    end
                    if (table_write_rsp_fire) begin
                        status_reg <= mr_entry_write_status;
                        if (mr_entry_write_status == MR_TABLE_STATUS_OK) begin
                            error_reg <= MR_REG_ERR_NONE;
                            alloc_bitmap_reg[alloc_index_reg] <= 1'b1;
                            state_reg <= MR_REG_STATE_RESPOND;
                        end else begin
                            error_reg <= (mr_entry_write_status == MR_TABLE_STATUS_ALIAS) ?
                                         MR_REG_ERR_ALIAS : MR_REG_ERR_TABLE_WRITE;
                            state_reg <= MR_REG_STATE_ERROR;
                        end
                    end
                end

                MR_REG_STATE_RESPOND: begin
                    if (reg_resp_fire) begin
                        state_reg <= MR_REG_STATE_IDLE;
                    end
                end

                MR_REG_STATE_ERROR: begin
                    if (reg_resp_fire) begin
                        state_reg <= MR_REG_STATE_IDLE;
                    end
                end

                default: begin
                    error_reg <= MR_REG_ERR_TABLE_WRITE;
                    status_reg <= MR_TABLE_STATUS_INVALID;
                    state_reg <= MR_REG_STATE_ERROR;
                end
            endcase
        end
    end

endmodule : mr_registration_manager
