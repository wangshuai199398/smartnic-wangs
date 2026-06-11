// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// SR-IOV PF/VF function identity 和资源窗口检查框架。
//
// 本模块只做 function 身份识别和资源窗口权限判断。它不创建 VF，不实现
// SR-IOV capability 配置，也不实现真实资源分配算法。

`timescale 1ns/1ps

import smartnic_pkg::*;

module pcie_function_manager (
    input  logic                         clk,                    // function manager 时钟。
    input  logic                         rst_n,                  // 低有效复位。

    // ------------------------------------------------------------------
    // PF/VF enable/trust control
    // ------------------------------------------------------------------
    input  logic                         pf_enable,              // PF 是否启用；通常复位后由上层置 1。
    input  logic                         pf_trusted,             // PF 是否受信；通常始终为 1。
    input  logic [SRIOV_MAX_VF-1:0]      vf_enable_mask,         // 每个 VF 的启用位，bit0 对应 VF0/function_id 1。
    input  logic [SRIOV_MAX_VF-1:0]      vf_trusted_mask,        // 每个 VF 的受信位，bit0 对应 VF0/function_id 1。

    // ------------------------------------------------------------------
    // Function identity query
    // ------------------------------------------------------------------
    input  logic                         query_valid,            // 身份查询请求有效。
    output logic                         query_ready,            // 本模块可接收身份查询。
    input  logic                         query_by_requester_id,  // 1 表示按 requester_id 查询，0 表示按 function_id 查询。
    input  logic [PCIE_REQ_ID_W-1:0]     query_requester_id,     // PCIe requester ID。
    input  logic [VF_ID_W-1:0]           query_function_id,      // 软件/上游给出的 function ID。

    output logic                         query_rsp_valid,        // 身份查询响应有效。
    input  logic                         query_rsp_ready,        // 下游已接收身份查询响应。
    output logic                         query_hit,              // 1 表示查询命中合法 function。
    output sriov_function_identity_t     query_identity,         // 查询得到的 PF/VF 身份。
    output sriov_resource_window_t       query_window,           // 查询得到的资源窗口。

    // ------------------------------------------------------------------
    // Per-function access check
    // ------------------------------------------------------------------
    input  logic                         access_valid,           // 访问检查请求有效。
    output logic                         access_ready,           // 本模块可接收访问检查。
    input  logic                         access_by_requester_id, // 1 表示按 requester_id 识别访问来源。
    input  logic [PCIE_REQ_ID_W-1:0]     access_requester_id,    // 访问 TLP 携带的 requester ID。
    input  logic [VF_ID_W-1:0]           access_function_id,     // 访问所属 function ID。
    input  sriov_access_type_e           access_type,            // 要检查的访问类型。
    input  logic                         access_write,           // 1 表示写访问，0 表示读访问。
    input  logic [QP_ID_W-1:0]           access_qp_id,           // QP 资源访问时的 QP 编号。
    input  logic [CQ_ID_W-1:0]           access_cq_id,           // CQ 资源访问时的 CQ 编号。
    input  logic [MR_ID_W-1:0]           access_mr_id,           // MR 资源访问时的 MR handle。
    input  logic [PCIE_BAR_OFFSET_W-1:0] access_bar_offset,      // BAR0/BAR2/BAR4 访问 offset。
    input  logic [CQ_VECTOR_W-1:0]       access_msix_vector,     // MSI-X 访问对应的 vector 编号。

    output logic                         access_rsp_valid,       // 访问检查响应有效。
    input  logic                         access_rsp_ready,       // 下游已接收访问检查响应。
    output logic                         access_allowed,         // 1 表示访问允许继续。
    output sriov_access_status_e         access_status,          // 访问检查状态。
    output sriov_function_identity_t     access_identity,        // 发起访问的 PF/VF 身份。
    output sriov_resource_window_t       access_window           // 发起访问的资源窗口。
);

    logic query_fire;                  // 身份查询握手成功。
    logic query_rsp_fire;              // 身份查询响应握手成功。
    logic access_fire;                 // 访问检查握手成功。
    logic access_rsp_fire;             // 访问检查响应握手成功。
    logic [VF_ID_W-1:0] query_func_id; // 解析后的查询 function ID。
    logic [VF_ID_W-1:0] access_func_id;// 解析后的访问 function ID。

    sriov_function_identity_t query_identity_next; // 当前查询的组合身份结果。
    sriov_resource_window_t query_window_next;     // 当前查询的组合资源窗口。
    sriov_function_identity_t access_identity_next;// 当前访问的组合身份结果。
    sriov_resource_window_t access_window_next;    // 当前访问的组合资源窗口。
    sriov_access_status_e access_status_next;      // 当前访问的组合检查状态。

    assign query_ready = !query_rsp_valid || query_rsp_ready;
    assign access_ready = !access_rsp_valid || access_rsp_ready;
    assign query_fire = query_valid && query_ready;
    assign access_fire = access_valid && access_ready;
    assign query_rsp_fire = query_rsp_valid && query_rsp_ready;
    assign access_rsp_fire = access_rsp_valid && access_rsp_ready;

    assign query_func_id = query_by_requester_id ? requester_to_function(query_requester_id) :
                                                   query_function_id;
    assign access_func_id = access_by_requester_id ? requester_to_function(access_requester_id) :
                                                     access_function_id;

    assign query_identity_next = make_identity(query_func_id, query_requester_id);
    assign query_window_next = make_window(query_func_id);
    assign access_identity_next = make_identity(access_func_id, access_requester_id);
    assign access_window_next = make_window(access_func_id);
    assign access_status_next = check_access(access_identity_next,
                                             access_window_next,
                                             access_type,
                                             access_write,
                                             access_qp_id,
                                             access_cq_id,
                                             access_mr_id,
                                             access_bar_offset,
                                             access_msix_vector);

    function automatic logic [VF_ID_W-1:0] requester_to_function(
        input logic [PCIE_REQ_ID_W-1:0] requester_id
    );
        begin
            // 原型阶段用 requester_id 低位直接表示 function_id。
            // 真实 PCIe 集成时这里会替换成 bus/device/function 到 PF/VF 的映射表。
            return requester_id[VF_ID_W-1:0];
        end
    endfunction

    function automatic logic function_id_valid(
        input logic [VF_ID_W-1:0] function_id
    );
        begin
            return function_id < VF_ID_W'(SRIOV_FUNCTION_COUNT);
        end
    endfunction

    function automatic sriov_function_identity_t make_identity(
        input logic [VF_ID_W-1:0]       function_id,
        input logic [PCIE_REQ_ID_W-1:0] requester_id
    );
        sriov_function_identity_t identity;
        int unsigned vf_slot;
        begin
            identity = '0;
            identity.function_id = function_id;
            identity.requester_id = requester_id;
            identity.is_pf = (function_id == SRIOV_PF_FUNCTION_ID);
            identity.pf_id = 8'd0;

            if (identity.is_pf) begin
                identity.vf_id = '0;
                identity.enabled = pf_enable;
                identity.trusted = pf_trusted;
            end else if (function_id_valid(function_id)) begin
                vf_slot = function_id - 1;
                identity.vf_id = VF_ID_W'(vf_slot);
                identity.enabled = vf_enable_mask[vf_slot];
                identity.trusted = vf_trusted_mask[vf_slot];
            end

            return identity;
        end
    endfunction

    function automatic sriov_resource_window_t make_window(
        input logic [VF_ID_W-1:0] function_id
    );
        sriov_resource_window_t window;
        int unsigned vf_slot;
        begin
            window = '0;

            if (function_id == SRIOV_PF_FUNCTION_ID) begin
                window.qp_base = '0;
                window.qp_limit = '1;
                window.cq_base = '0;
                window.cq_limit = '1;
                window.mr_base = '0;
                window.mr_limit = '1;
                window.doorbell_base = '0;
                window.doorbell_limit = PCIE_BAR0_SIZE - 1;
                window.msix_vector_base = '0;
                window.msix_vector_limit = CQ_VECTOR_W'(PCIE_MSIX_VECTOR_COUNT - 1);
            end else if (function_id_valid(function_id)) begin
                vf_slot = function_id - 1;
                window.qp_base = QP_ID_W'(vf_slot) * SRIOV_QP_WINDOW_SIZE;
                window.qp_limit = window.qp_base + SRIOV_QP_WINDOW_SIZE - 1;
                window.cq_base = CQ_ID_W'(vf_slot) * SRIOV_CQ_WINDOW_SIZE;
                window.cq_limit = window.cq_base + SRIOV_CQ_WINDOW_SIZE - 1;
                window.mr_base = MR_ID_W'(vf_slot) * SRIOV_MR_WINDOW_SIZE;
                window.mr_limit = window.mr_base + SRIOV_MR_WINDOW_SIZE - 1;
                window.doorbell_base = PCIE_BAR_OFFSET_W'(vf_slot) * SRIOV_DOORBELL_WINDOW_SIZE;
                window.doorbell_limit = window.doorbell_base + SRIOV_DOORBELL_WINDOW_SIZE - 1;
                window.msix_vector_base = CQ_VECTOR_W'(vf_slot);
                window.msix_vector_limit = window.msix_vector_base + SRIOV_MSIX_VECTOR_WINDOW_SIZE - 1;
            end

            return window;
        end
    endfunction

    function automatic logic in_qp_window(
        input logic [QP_ID_W-1:0] id,
        input sriov_resource_window_t window
    );
        begin
            return (id >= window.qp_base) && (id <= window.qp_limit);
        end
    endfunction

    function automatic logic in_cq_window(
        input logic [CQ_ID_W-1:0] id,
        input sriov_resource_window_t window
    );
        begin
            return (id >= window.cq_base) && (id <= window.cq_limit);
        end
    endfunction

    function automatic logic in_mr_window(
        input logic [MR_ID_W-1:0] id,
        input sriov_resource_window_t window
    );
        begin
            return (id >= window.mr_base) && (id <= window.mr_limit);
        end
    endfunction

    function automatic logic in_doorbell_window(
        input logic [PCIE_BAR_OFFSET_W-1:0] offset,
        input sriov_resource_window_t window
    );
        begin
            return (offset >= window.doorbell_base) && (offset <= window.doorbell_limit);
        end
    endfunction

    function automatic logic in_msix_window(
        input logic [CQ_VECTOR_W-1:0] vector,
        input sriov_resource_window_t window
    );
        begin
            return (vector >= window.msix_vector_base) && (vector <= window.msix_vector_limit);
        end
    endfunction

    function automatic sriov_access_status_e check_access(
        input sriov_function_identity_t identity,
        input sriov_resource_window_t   window,
        input sriov_access_type_e       access_kind,
        input logic                     is_write,
        input logic [QP_ID_W-1:0]       qp_id,
        input logic [CQ_ID_W-1:0]       cq_id,
        input logic [MR_ID_W-1:0]       mr_id,
        input logic [PCIE_BAR_OFFSET_W-1:0] bar_offset,
        input logic [CQ_VECTOR_W-1:0]   msix_vector
    );
        begin
            if (!function_id_valid(identity.function_id)) begin
                return SRIOV_ACCESS_BAD_FUNCTION;
            end

            if (!identity.enabled) begin
                return SRIOV_ACCESS_DISABLED;
            end

            unique case (access_kind)
                SRIOV_ACCESS_BAR0_DOORBELL: begin
                    if (!in_doorbell_window(bar_offset, window)) begin
                        return SRIOV_ACCESS_OUT_OF_RANGE;
                    end
                end
                SRIOV_ACCESS_BAR2_CSR: begin
                    if (!identity.is_pf && !identity.trusted) begin
                        return SRIOV_ACCESS_PF_ONLY;
                    end
                    if (!identity.is_pf && is_write &&
                        !((bar_offset >= CSR_MAILBOX_BASE) &&
                          (bar_offset < (CSR_MAILBOX_BASE + CSR_MAILBOX_SIZE)))) begin
                        return SRIOV_ACCESS_PF_ONLY;
                    end
                end
                SRIOV_ACCESS_BAR4_MSIX: begin
                    if (!in_msix_window(msix_vector, window)) begin
                        return SRIOV_ACCESS_OUT_OF_RANGE;
                    end
                end
                SRIOV_ACCESS_QP: begin
                    if (!in_qp_window(qp_id, window)) begin
                        return SRIOV_ACCESS_OUT_OF_RANGE;
                    end
                end
                SRIOV_ACCESS_CQ: begin
                    if (!in_cq_window(cq_id, window)) begin
                        return SRIOV_ACCESS_OUT_OF_RANGE;
                    end
                end
                SRIOV_ACCESS_MR: begin
                    if (!in_mr_window(mr_id, window)) begin
                        return SRIOV_ACCESS_OUT_OF_RANGE;
                    end
                end
                default: begin
                    return SRIOV_ACCESS_DENIED;
                end
            endcase

            return SRIOV_ACCESS_OK;
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            query_rsp_valid <= 1'b0;
            query_hit <= 1'b0;
            query_identity <= '0;
            query_window <= '0;
            access_rsp_valid <= 1'b0;
            access_allowed <= 1'b0;
            access_status <= SRIOV_ACCESS_DENIED;
            access_identity <= '0;
            access_window <= '0;
        end else begin
            if (query_rsp_fire) begin
                query_rsp_valid <= 1'b0;
            end

            if (access_rsp_fire) begin
                access_rsp_valid <= 1'b0;
            end

            if (query_fire) begin
                query_rsp_valid <= 1'b1;
                query_hit <= function_id_valid(query_func_id);
                query_identity <= query_identity_next;
                query_window <= query_window_next;
            end

            if (access_fire) begin
                access_rsp_valid <= 1'b1;
                access_allowed <= (access_status_next == SRIOV_ACCESS_OK);
                access_status <= access_status_next;
                access_identity <= access_identity_next;
                access_window <= access_window_next;
            end
        end
    end

endmodule : pcie_function_manager
