// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// Memory Window bind/unbind/invalidation 控制框架。
//
// 本模块实现最小 MW 管理协议：bind 从 parent MR 派生 MW entry，unbind 设置
// invalidating/pending 并等待 refcount drain，QP error invalidation 通过预留扫描
// 接口查找绑定到指定 QPN 的 MW。当前阶段不区分 IBTA Type1/Type2 MW，不实现
// remote invalidate opcode，也不生成真实 QP async event。

`timescale 1ns/1ps

import smartnic_pkg::*;

module mr_memory_window_manager (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic                         mw_bind_req_valid,
    output logic                         mw_bind_req_ready,
    input  logic [VF_ID_W-1:0]           mw_bind_req_owner_function,
    input  logic [PD_ID_W-1:0]           mw_bind_req_pd_id,
    input  logic [QP_ID_W-1:0]           mw_bind_req_qpn,
    input  logic [KEY_W-1:0]             mw_bind_req_parent_lkey,
    input  logic [KEY_W-1:0]             mw_bind_req_mw_rkey,
    input  logic [ADDR_W-1:0]            mw_bind_req_virtual_base_addr,
    input  logic [DMA_LEN_W-1:0]         mw_bind_req_length,
    input  logic [5:0]                   mw_bind_req_access_flags,
    input  logic [31:0]                  mw_bind_req_cmd_sequence,

    input  logic                         mw_unbind_req_valid,
    output logic                         mw_unbind_req_ready,
    input  logic [VF_ID_W-1:0]           mw_unbind_req_owner_function,
    input  logic [PD_ID_W-1:0]           mw_unbind_req_pd_id,
    input  logic [KEY_W-1:0]             mw_unbind_req_mw_rkey,
    input  logic [31:0]                  mw_unbind_req_cmd_sequence,

    input  logic                         qp_error_invalidate_valid,
    output logic                         qp_error_invalidate_ready,
    input  logic [QP_ID_W-1:0]           qp_error_qpn,
    input  logic [VF_ID_W-1:0]           qp_error_owner_function,
    input  logic [PD_ID_W-1:0]           qp_error_pd_id,
    input  logic [15:0]                  qp_error_reason,

    output logic                         mw_resp_valid,
    input  logic                         mw_resp_ready,
    output mr_table_status_e             mw_resp_status,
    output mw_error_e                    mw_resp_error_code,
    output logic [KEY_W-1:0]             mw_resp_mw_rkey,
    output logic [31:0]                  mw_resp_cmd_sequence,

    output logic                         mr_entry_read_valid,
    input  logic                         mr_entry_read_ready,
    output logic [KEY_W-1:0]             mr_entry_read_key,
    output logic                         mr_entry_read_is_remote,
    output logic [VF_ID_W-1:0]           mr_entry_read_owner_function,
    output logic [PD_ID_W-1:0]           mr_entry_read_pd_id,
    output logic                         mr_entry_read_admin_bypass,
    input  logic                         mr_entry_read_rsp_valid,
    output logic                         mr_entry_read_rsp_ready,
    input  logic                         mr_entry_read_hit,
    input  mr_entry_t                    mr_entry_read_data,
    input  mr_table_status_e             mr_entry_read_status,

    output logic                         mr_entry_write_valid,
    input  logic                         mr_entry_write_ready,
    output logic                         mr_entry_write_use_index,
    output logic [MR_TABLE_INDEX_W-1:0]  mr_entry_write_index,
    output logic [KEY_W-1:0]             mr_entry_write_key,
    output logic                         mr_entry_write_is_remote,
    output logic [VF_ID_W-1:0]           mr_entry_write_owner_function,
    output logic                         mr_entry_write_admin_bypass,
    output mr_entry_t                    mr_entry_write_data,
    input  logic                         mr_entry_write_rsp_valid,
    output logic                         mr_entry_write_rsp_ready,
    input  mr_table_status_e             mr_entry_write_status,

    // QP error invalidation 扫描预留接口。后续 top 可将其连接到 MR table 扫描器。
    output logic                         mw_scan_req_valid,
    input  logic                         mw_scan_req_ready,
    output logic [QP_ID_W-1:0]           mw_scan_qpn,
    output logic [VF_ID_W-1:0]           mw_scan_owner_function,
    output logic [PD_ID_W-1:0]           mw_scan_pd_id,
    input  logic                         mw_scan_rsp_valid,
    output logic                         mw_scan_rsp_ready,
    input  logic                         mw_scan_hit,
    input  mr_entry_t                    mw_scan_entry,
    input  logic                         mw_scan_done,

    output mw_state_e                    debug_state
);

    typedef enum logic [1:0] {
        MW_REQ_BIND,
        MW_REQ_UNBIND,
        MW_REQ_QP_ERROR
    } mw_req_kind_e;

    mw_state_e state_reg;
    mw_req_kind_e req_kind_reg;
    mw_error_e error_reg;
    mr_table_status_e status_reg;
    mr_entry_t parent_reg;
    mr_entry_t mw_entry_reg;
    mr_entry_t write_entry_reg;
    logic [VF_ID_W-1:0] owner_reg;
    logic [PD_ID_W-1:0] pd_reg;
    logic [QP_ID_W-1:0] qpn_reg;
    logic [KEY_W-1:0] parent_lkey_reg;
    logic [KEY_W-1:0] mw_rkey_reg;
    logic [ADDR_W-1:0] va_reg;
    logic [DMA_LEN_W-1:0] len_reg;
    logic [5:0] flags_reg;
    logic [31:0] seq_reg;
    logic [31:0] timeout_reg;
    logic read_issued_reg;
    logic write_issued_reg;
    logic scan_issued_reg;

    logic bind_fire;
    logic unbind_fire;
    logic qp_error_fire;
    logic resp_fire;
    logic read_fire;
    logic read_rsp_fire;
    logic write_fire;
    logic write_rsp_fire;
    logic scan_fire;
    logic scan_rsp_fire;
    logic [ADDR_W-1:0] bind_end;
    logic [ADDR_W-1:0] parent_end;
    logic bind_overflow;
    logic parent_overflow;
    logic [5:0] mw_remote_flags;

    assign debug_state = state_reg;
    assign mw_bind_req_ready = (state_reg == MW_STATE_IDLE);
    assign mw_unbind_req_ready = (state_reg == MW_STATE_IDLE);
    assign qp_error_invalidate_ready = (state_reg == MW_STATE_IDLE);
    assign bind_fire = mw_bind_req_valid && mw_bind_req_ready;
    assign unbind_fire = mw_unbind_req_valid && mw_unbind_req_ready;
    assign qp_error_fire = qp_error_invalidate_valid && qp_error_invalidate_ready;

    assign mw_resp_valid = (state_reg == MW_STATE_RESPOND) || (state_reg == MW_STATE_ERROR);
    assign resp_fire = mw_resp_valid && mw_resp_ready;
    assign mw_resp_status = status_reg;
    assign mw_resp_error_code = error_reg;
    assign mw_resp_mw_rkey = mw_rkey_reg;
    assign mw_resp_cmd_sequence = seq_reg;

    assign mr_entry_read_valid = ((state_reg == MW_STATE_LOOKUP_PARENT_MR) ||
                                  (state_reg == MW_STATE_CHECK_ALIAS) ||
                                  (state_reg == MW_STATE_LOOKUP_MW) ||
                                  (state_reg == MW_STATE_WAIT_REFCOUNT_ZERO)) &&
                                 !read_issued_reg;
    assign mr_entry_read_key = (state_reg == MW_STATE_LOOKUP_PARENT_MR) ? parent_lkey_reg : mw_rkey_reg;
    assign mr_entry_read_is_remote = (state_reg != MW_STATE_LOOKUP_PARENT_MR);
    assign mr_entry_read_owner_function = owner_reg;
    assign mr_entry_read_pd_id = pd_reg;
    assign mr_entry_read_admin_bypass = 1'b0;
    assign mr_entry_read_rsp_ready = (state_reg == MW_STATE_LOOKUP_PARENT_MR) ||
                                     (state_reg == MW_STATE_CHECK_ALIAS) ||
                                     (state_reg == MW_STATE_LOOKUP_MW) ||
                                     (state_reg == MW_STATE_WAIT_REFCOUNT_ZERO);
    assign read_fire = mr_entry_read_valid && mr_entry_read_ready;
    assign read_rsp_fire = mr_entry_read_rsp_valid && mr_entry_read_rsp_ready;

    assign mr_entry_write_valid = ((state_reg == MW_STATE_WRITE_MW_ENTRY) ||
                                   (state_reg == MW_STATE_MARK_INVALIDATING) ||
                                   (state_reg == MW_STATE_CLEAR_MW_ENTRY)) &&
                                  !write_issued_reg;
    assign mr_entry_write_use_index = 1'b0;
    assign mr_entry_write_index = '0;
    assign mr_entry_write_key = mw_rkey_reg;
    assign mr_entry_write_is_remote = 1'b1;
    assign mr_entry_write_owner_function = owner_reg;
    assign mr_entry_write_admin_bypass = 1'b0;
    assign mr_entry_write_data = write_entry_reg;
    assign mr_entry_write_rsp_ready = (state_reg == MW_STATE_WRITE_MW_ENTRY) ||
                                      (state_reg == MW_STATE_MARK_INVALIDATING) ||
                                      (state_reg == MW_STATE_CLEAR_MW_ENTRY);
    assign write_fire = mr_entry_write_valid && mr_entry_write_ready;
    assign write_rsp_fire = mr_entry_write_rsp_valid && mr_entry_write_rsp_ready;

    assign mw_scan_req_valid = (state_reg == MW_STATE_QP_SCAN) && !scan_issued_reg;
    assign mw_scan_qpn = qpn_reg;
    assign mw_scan_owner_function = owner_reg;
    assign mw_scan_pd_id = pd_reg;
    assign mw_scan_rsp_ready = (state_reg == MW_STATE_QP_SCAN);
    assign scan_fire = mw_scan_req_valid && mw_scan_req_ready;
    assign scan_rsp_fire = mw_scan_rsp_valid && mw_scan_rsp_ready;

    assign bind_end = va_reg + ADDR_W'(len_reg);
    assign parent_end = parent_reg.virtual_base_addr + ADDR_W'(parent_reg.length);
    assign bind_overflow = (bind_end < va_reg);
    assign parent_overflow = (parent_end < parent_reg.virtual_base_addr);
    assign mw_remote_flags = flags_reg & (MR_ACCESS_REMOTE_READ |
                                          MR_ACCESS_REMOTE_WRITE |
                                          MR_ACCESS_REMOTE_ATOMIC |
                                          MR_ACCESS_MW_BIND);

    function automatic mr_entry_t make_mw_entry(
        input mr_entry_t parent,
        input logic [ADDR_W-1:0] va,
        input logic [DMA_LEN_W-1:0] len,
        input logic [5:0] flags,
        input logic [KEY_W-1:0] mw_rkey,
        input logic [QP_ID_W-1:0] qpn
    );
        begin
            make_mw_entry = '0;
            make_mw_entry.valid = 1'b1;
            make_mw_entry.mr_id = parent.mr_id;
            make_mw_entry.lkey = '0;
            make_mw_entry.rkey = mw_rkey;
            make_mw_entry.virtual_base_addr = va;
            make_mw_entry.physical_base_addr = parent.physical_base_addr +
                                               (va - parent.virtual_base_addr);
            make_mw_entry.length = len;
            make_mw_entry.page_size = parent.page_size;
            make_mw_entry.access_flags = flags;
            make_mw_entry.pd_id = parent.pd_id;
            make_mw_entry.owner_function = parent.owner_function;
            make_mw_entry.refcount = '0;
            make_mw_entry.pending_deregister = 1'b0;
            make_mw_entry.memory_window = 1'b1;
            make_mw_entry.invalidating = 1'b0;
            make_mw_entry.bound_qpn = qpn;
            make_mw_entry.parent_mr_key = parent.lkey;
            make_mw_entry.error_state = 1'b0;
            make_mw_entry.error_code = 16'h0000;
        end
    endfunction

    function automatic mr_entry_t make_invalidating(input mr_entry_t entry);
        begin
            make_invalidating = entry;
            make_invalidating.pending_deregister = 1'b1;
            make_invalidating.invalidating = 1'b1;
        end
    endfunction

    function automatic mr_entry_t make_cleared(input mr_entry_t entry);
        begin
            make_cleared = entry;
            make_cleared.valid = 1'b0;
            make_cleared.access_flags = '0;
            make_cleared.refcount = '0;
            make_cleared.pending_deregister = 1'b0;
            make_cleared.invalidating = 1'b0;
        end
    endfunction

    task automatic set_error(input mw_error_e err, input mr_table_status_e status);
        begin
            error_reg <= err;
            status_reg <= status;
            state_reg <= MW_STATE_ERROR;
        end
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= MW_STATE_IDLE;
            req_kind_reg <= MW_REQ_BIND;
            error_reg <= MW_ERR_NONE;
            status_reg <= MR_TABLE_STATUS_OK;
            parent_reg <= '0;
            mw_entry_reg <= '0;
            write_entry_reg <= '0;
            owner_reg <= '0;
            pd_reg <= '0;
            qpn_reg <= '0;
            parent_lkey_reg <= '0;
            mw_rkey_reg <= '0;
            va_reg <= '0;
            len_reg <= '0;
            flags_reg <= '0;
            seq_reg <= '0;
            timeout_reg <= 32'd0;
            read_issued_reg <= 1'b0;
            write_issued_reg <= 1'b0;
            scan_issued_reg <= 1'b0;
        end else begin
            unique case (state_reg)
                MW_STATE_IDLE: begin
                    error_reg <= MW_ERR_NONE;
                    status_reg <= MR_TABLE_STATUS_OK;
                    read_issued_reg <= 1'b0;
                    write_issued_reg <= 1'b0;
                    scan_issued_reg <= 1'b0;
                    timeout_reg <= 32'd0;
                    if (bind_fire) begin
                        req_kind_reg <= MW_REQ_BIND;
                        owner_reg <= mw_bind_req_owner_function;
                        pd_reg <= mw_bind_req_pd_id;
                        qpn_reg <= mw_bind_req_qpn;
                        parent_lkey_reg <= mw_bind_req_parent_lkey;
                        mw_rkey_reg <= mw_bind_req_mw_rkey;
                        va_reg <= mw_bind_req_virtual_base_addr;
                        len_reg <= mw_bind_req_length;
                        flags_reg <= mw_bind_req_access_flags;
                        seq_reg <= mw_bind_req_cmd_sequence;
                        if (mw_bind_req_mw_rkey == '0) begin
                            set_error(MW_ERR_RKEY, MR_TABLE_STATUS_INVALID);
                        end else if (mw_bind_req_length == '0) begin
                            set_error(MW_ERR_LENGTH, MR_TABLE_STATUS_LENGTH);
                        end else begin
                            state_reg <= MW_STATE_LOOKUP_PARENT_MR;
                        end
                    end else if (unbind_fire) begin
                        req_kind_reg <= MW_REQ_UNBIND;
                        owner_reg <= mw_unbind_req_owner_function;
                        pd_reg <= mw_unbind_req_pd_id;
                        mw_rkey_reg <= mw_unbind_req_mw_rkey;
                        seq_reg <= mw_unbind_req_cmd_sequence;
                        state_reg <= MW_STATE_LOOKUP_MW;
                    end else if (qp_error_fire) begin
                        req_kind_reg <= MW_REQ_QP_ERROR;
                        owner_reg <= qp_error_owner_function;
                        pd_reg <= qp_error_pd_id;
                        qpn_reg <= qp_error_qpn;
                        seq_reg <= {16'h0000, qp_error_reason};
                        state_reg <= MW_STATE_QP_SCAN;
                    end
                end

                MW_STATE_LOOKUP_PARENT_MR: begin
                    if (read_fire) read_issued_reg <= 1'b1;
                    if (read_rsp_fire) begin
                        read_issued_reg <= 1'b0;
                        if (!mr_entry_read_hit || mr_entry_read_status == MR_TABLE_STATUS_MISS) begin
                            set_error(MW_ERR_PARENT_MISS, MR_TABLE_STATUS_MISS);
                        end else if (mr_entry_read_status != MR_TABLE_STATUS_OK) begin
                            set_error(MW_ERR_TABLE, mr_entry_read_status);
                        end else begin
                            parent_reg <= mr_entry_read_data;
                            state_reg <= MW_STATE_VALIDATE_PARENT;
                        end
                    end
                end

                MW_STATE_VALIDATE_PARENT: begin
                    if (!parent_reg.valid) begin
                        set_error(MW_ERR_PARENT_MISS, MR_TABLE_STATUS_MISS);
                    end else if (parent_reg.pending_deregister || parent_reg.invalidating) begin
                        set_error(MW_ERR_PARENT_PENDING, MR_TABLE_STATUS_PENDING);
                    end else if (parent_reg.memory_window) begin
                        set_error(MW_ERR_PARENT_IS_MW, MR_TABLE_STATUS_INVALID);
                    end else if (parent_reg.owner_function != owner_reg) begin
                        set_error(MW_ERR_OWNER, MR_TABLE_STATUS_PERMISSION);
                    end else if (parent_reg.pd_id != pd_reg) begin
                        set_error(MW_ERR_PD, MR_TABLE_STATUS_INVALID);
                    end else begin
                        state_reg <= MW_STATE_VALIDATE_RANGE;
                    end
                end

                MW_STATE_VALIDATE_RANGE: begin
                    if (bind_overflow || parent_overflow ||
                        (va_reg < parent_reg.virtual_base_addr) ||
                        (bind_end > parent_end)) begin
                        set_error(MW_ERR_RANGE, MR_TABLE_STATUS_BOUNDS);
                    end else begin
                        state_reg <= MW_STATE_VALIDATE_PERMISSION_SUBSET;
                    end
                end

                MW_STATE_VALIDATE_PERMISSION_SUBSET: begin
                    if ((flags_reg & ~MR_ACCESS_FLAGS_ALLOWED) != '0 ||
                        (flags_reg & MR_ACCESS_MW_BIND) != '0) begin
                        set_error(MW_ERR_UNSUPPORTED_FLAGS, MR_TABLE_STATUS_INVALID);
                    end else if ((mw_remote_flags & ~parent_reg.access_flags) != '0) begin
                        set_error(MW_ERR_PERMISSION_SUBSET, MR_TABLE_STATUS_PERMISSION);
                    end else begin
                        state_reg <= MW_STATE_CHECK_ALIAS;
                    end
                end

                MW_STATE_CHECK_ALIAS: begin
                    if (read_fire) read_issued_reg <= 1'b1;
                    if (read_rsp_fire) begin
                        read_issued_reg <= 1'b0;
                        if (mr_entry_read_hit && mr_entry_read_status == MR_TABLE_STATUS_OK) begin
                            set_error(MW_ERR_ALIAS, MR_TABLE_STATUS_ALIAS);
                        end else if (mr_entry_read_status == MR_TABLE_STATUS_MISS) begin
                            state_reg <= MW_STATE_BUILD_MW_ENTRY;
                        end else begin
                            set_error(MW_ERR_TABLE, mr_entry_read_status);
                        end
                    end
                end

                MW_STATE_BUILD_MW_ENTRY: begin
                    write_entry_reg <= make_mw_entry(parent_reg, va_reg, len_reg,
                                                     flags_reg, mw_rkey_reg, qpn_reg);
                    state_reg <= MW_STATE_WRITE_MW_ENTRY;
                end

                MW_STATE_WRITE_MW_ENTRY: begin
                    if (write_fire) write_issued_reg <= 1'b1;
                    if (write_rsp_fire) begin
                        write_issued_reg <= 1'b0;
                        if (mr_entry_write_status == MR_TABLE_STATUS_OK) begin
                            state_reg <= MW_STATE_RESPOND;
                        end else if (mr_entry_write_status == MR_TABLE_STATUS_ALIAS) begin
                            set_error(MW_ERR_ALIAS, MR_TABLE_STATUS_ALIAS);
                        end else begin
                            set_error(MW_ERR_TABLE, mr_entry_write_status);
                        end
                    end
                end

                MW_STATE_LOOKUP_MW: begin
                    if (read_fire) read_issued_reg <= 1'b1;
                    if (read_rsp_fire) begin
                        read_issued_reg <= 1'b0;
                        if (!mr_entry_read_hit || mr_entry_read_status == MR_TABLE_STATUS_MISS) begin
                            set_error(MW_ERR_MW_MISS, MR_TABLE_STATUS_MISS);
                        end else if (mr_entry_read_status != MR_TABLE_STATUS_OK) begin
                            set_error(MW_ERR_TABLE, mr_entry_read_status);
                        end else begin
                            mw_entry_reg <= mr_entry_read_data;
                            state_reg <= MW_STATE_CHECK_PERMISSION;
                        end
                    end
                end

                MW_STATE_CHECK_PERMISSION: begin
                    if (!mw_entry_reg.memory_window) begin
                        set_error(MW_ERR_NOT_MW, MR_TABLE_STATUS_INVALID);
                    end else if (mw_entry_reg.owner_function != owner_reg) begin
                        set_error(MW_ERR_OWNER, MR_TABLE_STATUS_PERMISSION);
                    end else if (mw_entry_reg.pd_id != pd_reg) begin
                        set_error(MW_ERR_PD, MR_TABLE_STATUS_INVALID);
                    end else begin
                        write_entry_reg <= make_invalidating(mw_entry_reg);
                        state_reg <= MW_STATE_MARK_INVALIDATING;
                    end
                end

                MW_STATE_MARK_INVALIDATING: begin
                    if (write_fire) write_issued_reg <= 1'b1;
                    if (write_rsp_fire) begin
                        write_issued_reg <= 1'b0;
                        if (mr_entry_write_status != MR_TABLE_STATUS_OK) begin
                            set_error(MW_ERR_TABLE, mr_entry_write_status);
                        end else if (mw_entry_reg.refcount == '0) begin
                            write_entry_reg <= make_cleared(mw_entry_reg);
                            state_reg <= MW_STATE_CLEAR_MW_ENTRY;
                        end else begin
                            timeout_reg <= 32'd0;
                            state_reg <= MW_STATE_WAIT_REFCOUNT_ZERO;
                        end
                    end
                end

                MW_STATE_WAIT_REFCOUNT_ZERO: begin
                    timeout_reg <= timeout_reg + 32'd1;
                    if (timeout_reg >= MR_DEREG_TIMEOUT_CYCLES) begin
                        set_error(MW_ERR_TIMEOUT, MR_TABLE_STATUS_INVALID);
                    end else begin
                        if (read_fire) read_issued_reg <= 1'b1;
                        if (read_rsp_fire) begin
                            read_issued_reg <= 1'b0;
                            if (!mr_entry_read_hit) begin
                                set_error(MW_ERR_MW_MISS, MR_TABLE_STATUS_MISS);
                            end else if (mr_entry_read_data.refcount == '0) begin
                                mw_entry_reg <= mr_entry_read_data;
                                write_entry_reg <= make_cleared(mr_entry_read_data);
                                state_reg <= MW_STATE_CLEAR_MW_ENTRY;
                            end
                        end
                    end
                end

                MW_STATE_CLEAR_MW_ENTRY: begin
                    if (write_fire) write_issued_reg <= 1'b1;
                    if (write_rsp_fire) begin
                        write_issued_reg <= 1'b0;
                        if (mr_entry_write_status == MR_TABLE_STATUS_OK) begin
                            state_reg <= MW_STATE_RESPOND;
                        end else begin
                            set_error(MW_ERR_TABLE, mr_entry_write_status);
                        end
                    end
                end

                MW_STATE_QP_SCAN: begin
                    timeout_reg <= timeout_reg + 32'd1;
                    if (timeout_reg >= MR_DEREG_TIMEOUT_CYCLES) begin
                        set_error(MW_ERR_TIMEOUT, MR_TABLE_STATUS_INVALID);
                    end else begin
                        if (scan_fire) scan_issued_reg <= 1'b1;
                        if (scan_rsp_fire) begin
                            scan_issued_reg <= 1'b0;
                            if (mw_scan_hit) begin
                                mw_entry_reg <= mw_scan_entry;
                                mw_rkey_reg <= mw_scan_entry.rkey;
                                write_entry_reg <= make_invalidating(mw_scan_entry);
                                state_reg <= MW_STATE_MARK_INVALIDATING;
                            end else if (mw_scan_done) begin
                                state_reg <= MW_STATE_RESPOND;
                            end
                        end
                    end
                end

                MW_STATE_RESPOND,
                MW_STATE_ERROR: begin
                    if (resp_fire) state_reg <= MW_STATE_IDLE;
                end

                default: begin
                    set_error(MW_ERR_TABLE, MR_TABLE_STATUS_INVALID);
                end
            endcase
        end
    end

endmodule : mr_memory_window_manager
