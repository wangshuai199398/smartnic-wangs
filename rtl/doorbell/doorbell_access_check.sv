// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// Doorbell per-function access check 最小实现。
//
// 本模块只检查 Doorbell 事件是否属于发起 PF/VF 的资源窗口。
// 它不解析 SQ/RQ/CQ payload，不更新 QP producer index，也不更新 CQ arm 状态。

`timescale 1ns/1ps

import smartnic_pkg::*;

module doorbell_access_check (
    input  logic                         clk,                  // Doorbell access check 时钟。
    input  logic                         rst_n,                // 低有效复位。

    // ------------------------------------------------------------------
    // Decoded Doorbell event
    // ------------------------------------------------------------------
    input  logic                         check_valid,          // 有一个 Doorbell 事件需要检查。
    output logic                         check_ready,          // 本模块可接收检查请求。
    input  doorbell_type_e               doorbell_type,        // SQ、RQ 或 CQ arm Doorbell 类型。
    input  logic [QP_ID_W-1:0]           qpn,                  // SQ/RQ Doorbell 的目标 QPN。
    input  logic [CQ_ID_W-1:0]           cqn,                  // CQ arm Doorbell 的目标 CQN。
    input  logic [QUEUE_IDX_W-1:0]       queue_index,          // 透传的队列索引，当前阶段不解析。
    input  logic [PCIE_BAR_DATA_W-1:0]   raw_payload,          // 透传的原始 payload，当前阶段不解析。
    input  logic [VF_ID_W-1:0]           owner_function,       // Doorbell decoder 看到的发起 function。

    // ------------------------------------------------------------------
    // Function identity/resource window from SR-IOV function manager
    // ------------------------------------------------------------------
    input  logic [PCIE_REQ_ID_W-1:0]     requester_id,         // 发起 TLP 的 requester ID。
    input  logic [VF_ID_W-1:0]           function_id,          // 当前访问解析出的 function ID。
    input  logic                         is_pf,                // 1 表示 PF，0 表示 VF。
    input  logic [VF_ID_W-1:0]           vf_id,                // VF 编号，PF 访问时为 0。
    input  logic                         function_enabled,     // 当前 function 是否启用。
    input  sriov_resource_window_t       resource_window,      // 当前 function 的 QP/CQ/Doorbell 资源窗口。

    // ------------------------------------------------------------------
    // Access check response
    // ------------------------------------------------------------------
    output logic                         check_rsp_valid,      // 检查响应有效。
    input  logic                         check_rsp_ready,      // 下游已接收检查响应。
    output logic                         access_allowed,       // 1 表示 Doorbell 可以继续进入后续 3.3/3.4/3.5。
    output logic                         access_error,         // 1 表示访问被拒绝。
    output sriov_access_status_e         error_code,           // 拒绝原因。
    output logic [VF_ID_W-1:0]           checked_function_id,  // 被检查的 function ID。
    output logic [QP_ID_W-1:0]           checked_resource_id   // 被检查的 QPN/CQN，统一用 QP_ID_W 表达。
);

    logic check_fire;                         // 检查请求握手成功。
    logic rsp_fire;                           // 检查响应握手成功。
    logic resource_is_qp;                     // 当前 Doorbell 检查 QP 资源。
    logic resource_is_cq;                     // 当前 Doorbell 检查 CQ 资源。
    logic owner_matches_function;             // Doorbell 所属 function 与解析出的 function 一致。
    logic resource_in_window;                 // QPN/CQN 落在该 function 资源窗口内。
    logic type_supported;                     // Doorbell 类型受支持。
    logic [QP_ID_W-1:0] resource_id_next;     // 当前请求对应的资源 ID。
    sriov_access_status_e status_next;        // 当前请求的权限检查结果。

    assign check_ready = !check_rsp_valid || check_rsp_ready;
    assign check_fire = check_valid && check_ready;
    assign rsp_fire = check_rsp_valid && check_rsp_ready;

    assign resource_is_qp = (doorbell_type == DB_TYPE_SQ) ||
                            (doorbell_type == DB_TYPE_RQ);
    assign resource_is_cq = (doorbell_type == DB_TYPE_CQ_ARM);
    assign type_supported = resource_is_qp || resource_is_cq;
    assign owner_matches_function = (owner_function == function_id);
    assign resource_id_next = resource_is_cq ? QP_ID_W'(cqn) : qpn;

    always_comb begin
        resource_in_window = 1'b0;

        if (resource_is_qp) begin
            resource_in_window = (qpn >= resource_window.qp_base) &&
                                 (qpn <= resource_window.qp_limit);
        end else if (resource_is_cq) begin
            resource_in_window = (cqn >= resource_window.cq_base) &&
                                 (cqn <= resource_window.cq_limit);
        end
    end

    always_comb begin
        if (!type_supported) begin
            status_next = SRIOV_ACCESS_DENIED;
        end else if (!function_enabled) begin
            status_next = SRIOV_ACCESS_DISABLED;
        end else if (!owner_matches_function) begin
            status_next = SRIOV_ACCESS_DENIED;
        end else if (!resource_in_window) begin
            status_next = SRIOV_ACCESS_OUT_OF_RANGE;
        end else begin
            status_next = SRIOV_ACCESS_OK;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            check_rsp_valid <= 1'b0;
            access_allowed <= 1'b0;
            access_error <= 1'b0;
            error_code <= SRIOV_ACCESS_DENIED;
            checked_function_id <= '0;
            checked_resource_id <= '0;
        end else begin
            if (rsp_fire) begin
                check_rsp_valid <= 1'b0;
            end

            if (check_fire) begin
                check_rsp_valid <= 1'b1;
                access_allowed <= (status_next == SRIOV_ACCESS_OK);
                access_error <= (status_next != SRIOV_ACCESS_OK);
                error_code <= status_next;
                checked_function_id <= function_id;
                checked_resource_id <= resource_id_next;
            end
        end
    end

    // 当前阶段保留这些输入用于接口稳定和波形调试，后续 payload 解析阶段会使用。
    logic [QUEUE_IDX_W-1:0] unused_queue_index;
    logic [PCIE_BAR_DATA_W-1:0] unused_raw_payload;
    logic [PCIE_REQ_ID_W-1:0] unused_requester_id;
    logic unused_is_pf;
    logic [VF_ID_W-1:0] unused_vf_id;

    assign unused_queue_index = queue_index;
    assign unused_raw_payload = raw_payload;
    assign unused_requester_id = requester_id;
    assign unused_is_pf = is_pf;
    assign unused_vf_id = vf_id;

endmodule : doorbell_access_check
