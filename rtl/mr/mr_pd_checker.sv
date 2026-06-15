// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// MR Protection Domain checker 最小实现。
//
// 本模块位于 key direction check 和 access_flags check 之后，负责确认发起访问的
// QP PD 与 MR PD 一致。当前阶段调用方直接提供 QP PD；按 QPN 查询 QP context 的
// 接口留给后续 top/control pipeline 集成。

`timescale 1ns/1ps

import smartnic_pkg::*;

module mr_pd_checker (
    input  logic                   clk,                         // PD checker 时钟。
    input  logic                   rst_n,                       // 低有效复位。

    // ------------------------------------------------------------------
    // PD check request
    // ------------------------------------------------------------------
    input  logic                   pd_check_valid,              // PD check 请求有效。
    output logic                   pd_check_ready,              // 本模块可接收请求。
    input  mr_operation_e          pd_check_operation,          // 访问操作类型。
    input  logic                   pd_check_is_remote,          // 1 表示远端路径，0 表示本地路径。
    input  mr_entry_t              pd_check_mr_entry,           // access checker 传入的 MR entry。
    input  logic [PD_ID_W-1:0]     pd_check_qp_pd_id,           // QP context 中的 PD。
    input  logic                   pd_check_qp_pd_valid,        // QP PD 是否有效。
    input  logic [PD_ID_W-1:0]     pd_check_mr_pd_id,           // MR PD，可直接使用 MR entry.pd_id。
    input  logic [QP_ID_W-1:0]     pd_check_qpn,                // QPN，后续 QP context lookup 预留。
    input  logic [VF_ID_W-1:0]     pd_check_owner_function,     // 发起访问的 function / QP owner。
    input  logic [ADDR_W-1:0]      pd_check_va,                 // 访问 VA，当前仅透传语义预留。
    input  logic [DMA_LEN_W-1:0]   pd_check_len,                // 访问长度，当前仅透传语义预留。
    input  logic [ADDR_W-1:0]      pd_check_physical_addr,      // access checker 计算出的 PA。
    input  logic [PD_ID_W-1:0]     pd_parent_pd_id,             // MW parent PD 预留。
    input  logic                   pd_parent_pd_valid,          // parent PD 是否有效。

    // ------------------------------------------------------------------
    // PD check response
    // ------------------------------------------------------------------
    output logic                   pd_check_resp_valid,         // PD check 响应有效。
    input  logic                   pd_check_resp_ready,         // 下游已接收响应。
    output logic                   pd_check_allowed,            // PD 和基础 owner 检查通过。
    output logic [ADDR_W-1:0]      pd_check_physical_addr_out,  // 透明传递的 PA。
    output mr_entry_t              pd_check_mr_entry_out,       // 透明传递的 MR entry。
    output mr_pd_check_error_e     pd_check_error_code          // PD check 错误码。
);

    logic req_fire;
    logic resp_fire;
    logic operation_known;
    logic operation_remote;
    logic owner_ok;
    logic pd_match;
    logic mw_parent_pd_ok;
    logic allowed_next;
    mr_pd_check_error_e error_next;

    assign pd_check_ready = !pd_check_resp_valid || pd_check_resp_ready;
    assign req_fire = pd_check_valid && pd_check_ready;
    assign resp_fire = pd_check_resp_valid && pd_check_resp_ready;

    assign owner_ok = (pd_check_mr_entry.owner_function == pd_check_owner_function);
    assign pd_match = (pd_check_qp_pd_id == pd_check_mr_pd_id) &&
                      (pd_check_mr_entry.pd_id == pd_check_mr_pd_id);
    assign mw_parent_pd_ok = !pd_check_mr_entry.memory_window ||
                             !pd_parent_pd_valid ||
                             (pd_parent_pd_id == pd_check_mr_pd_id);

    function automatic logic op_is_remote(input mr_operation_e operation);
        begin
            unique case (operation)
                MR_OP_REMOTE_RDMA_READ,
                MR_OP_REMOTE_RDMA_WRITE,
                MR_OP_REMOTE_ATOMIC: return 1'b1;
                default:             return 1'b0;
            endcase
        end
    endfunction

    always_comb begin
        operation_known = 1'b1;
        operation_remote = op_is_remote(pd_check_operation);

        unique case (pd_check_operation)
            MR_OP_LOCAL_DMA_READ,
            MR_OP_LOCAL_DMA_WRITE,
            MR_OP_LOCAL_RECV_WRITE,
            MR_OP_REMOTE_RDMA_READ,
            MR_OP_REMOTE_RDMA_WRITE,
            MR_OP_REMOTE_ATOMIC,
            MR_OP_MW_BIND: operation_known = 1'b1;
            default:       operation_known = 1'b0;
        endcase
    end

    always_comb begin
        allowed_next = 1'b0;
        error_next = MR_PD_CHECK_ERR_NONE;

        if (!pd_check_mr_entry.valid) begin
            error_next = MR_PD_CHECK_ERR_INVALID_ENTRY;
        end else if (pd_check_mr_entry.pending_deregister || pd_check_mr_entry.invalidating) begin
            error_next = MR_PD_CHECK_ERR_PENDING;
        end else if (!owner_ok) begin
            error_next = MR_PD_CHECK_ERR_PERMISSION;
        end else if (!pd_check_qp_pd_valid) begin
            error_next = MR_PD_CHECK_ERR_MISSING_QP_PD;
        end else if (!operation_known || (operation_remote != pd_check_is_remote &&
                                          pd_check_operation != MR_OP_MW_BIND)) begin
            error_next = MR_PD_CHECK_ERR_INVALID_OPERATION;
        end else if (!pd_match) begin
            error_next = MR_PD_CHECK_ERR_PD_MISMATCH;
        end else if (!mw_parent_pd_ok) begin
            error_next = MR_PD_CHECK_ERR_MW_PARENT_PD;
        end else begin
            allowed_next = 1'b1;
            error_next = MR_PD_CHECK_ERR_NONE;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pd_check_resp_valid <= 1'b0;
            pd_check_allowed <= 1'b0;
            pd_check_physical_addr_out <= '0;
            pd_check_mr_entry_out <= '0;
            pd_check_error_code <= MR_PD_CHECK_ERR_NONE;
        end else begin
            if (resp_fire) begin
                pd_check_resp_valid <= 1'b0;
            end

            if (req_fire) begin
                pd_check_resp_valid <= 1'b1;
                pd_check_allowed <= allowed_next;
                pd_check_physical_addr_out <= allowed_next ? pd_check_physical_addr : '0;
                pd_check_mr_entry_out <= allowed_next ? pd_check_mr_entry : '0;
                pd_check_error_code <= error_next;
            end
        end
    end

    // 当前阶段保留 qpn/va/len 输入，后续可用 qpn 发起 QP context lookup。
    logic unused_inputs;
    assign unused_inputs = ^{pd_check_qpn, pd_check_va, pd_check_len};

endmodule : mr_pd_checker
