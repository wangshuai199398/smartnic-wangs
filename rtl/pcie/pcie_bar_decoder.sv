// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// PCIe BAR decoder 最小实现。
//
// 本模块只根据 BAR number 和 BAR offset 把入站 memory read/write 请求转发到
// Doorbell、CSR 或 MSI-X 目标窗口。它不解析 Doorbell payload，不实现 CSR mailbox，
// 也不实现 MSI-X table/PBA 的真实寄存器行为。

`timescale 1ns/1ps

import smartnic_pkg::*;

module pcie_bar_decoder (
    input  logic                           clk,                  // BAR decoder 访问时钟。
    input  logic                           rst_n,                // 低有效复位。

    // ------------------------------------------------------------------
    // inbound memory read/write request
    // ------------------------------------------------------------------
    input  logic                           bar_req_valid,        // 入站 BAR memory 请求有效。
    output logic                           bar_req_ready,        // decoder 可接收该请求。
    input  logic                           bar_req_write,        // 1 表示 Memory Write，0 表示 Memory Read。
    input  logic [PCIE_BAR_W-1:0]          bar_req_bar,          // 命中的 BAR 编号。
    input  logic [PCIE_BAR_OFFSET_W-1:0]   bar_req_offset,       // BAR 内 byte offset。
    input  logic [PCIE_BAR_DATA_W-1:0]     bar_req_wdata,        // 写请求数据。
    input  logic [PCIE_BAR_BE_W-1:0]       bar_req_be,           // 写请求 byte enable。
    input  logic [VF_ID_W-1:0]             bar_req_func_id,      // 发起访问的 PF/VF function。
    input  logic [PCIE_REQ_ID_W-1:0]       bar_req_requester_id, // PCIe requester ID，用于后续隔离/完成响应。

    // ------------------------------------------------------------------
    // BAR0 Doorbell aperture request
    // ------------------------------------------------------------------
    output logic                           doorbell_req_valid,   // BAR0 Doorbell 请求有效。
    input  logic                           doorbell_req_ready,   // Doorbell path 可接收请求。
    output logic                           doorbell_req_write,   // Doorbell 请求读写方向。
    output logic [PCIE_BAR_OFFSET_W-1:0]   doorbell_req_offset,  // BAR0 内 Doorbell offset。
    output logic [PCIE_BAR_DATA_W-1:0]     doorbell_req_wdata,   // Doorbell 写数据，后续 3.x 解析。
    output logic [PCIE_BAR_BE_W-1:0]       doorbell_req_be,      // Doorbell 写 byte enable。
    output logic [VF_ID_W-1:0]             doorbell_req_func_id, // Doorbell 所属 PF/VF function。

    // ------------------------------------------------------------------
    // BAR2 CSR space request
    // ------------------------------------------------------------------
    output logic                           csr_req_valid,        // BAR2 CSR 请求有效。
    input  logic                           csr_req_ready,        // CSR block 可接收请求。
    output logic                           csr_req_write,        // CSR 请求读写方向。
    output logic [PCIE_BAR_OFFSET_W-1:0]   csr_req_offset,       // BAR2 内 CSR offset。
    output logic [PCIE_BAR_DATA_W-1:0]     csr_req_wdata,        // CSR 写数据，后续 2.4 使用。
    output logic [PCIE_BAR_BE_W-1:0]       csr_req_be,           // CSR 写 byte enable。
    output logic [VF_ID_W-1:0]             csr_req_func_id,      // CSR 访问所属 PF/VF function。

    // ------------------------------------------------------------------
    // BAR4 MSI-X table/PBA request
    // ------------------------------------------------------------------
    output logic                           msix_req_valid,       // BAR4 MSI-X 请求有效。
    input  logic                           msix_req_ready,       // MSI-X block 可接收请求。
    output logic                           msix_req_write,       // MSI-X 请求读写方向。
    output logic [PCIE_BAR_OFFSET_W-1:0]   msix_req_offset,      // BAR4 内 MSI-X offset。
    output logic [PCIE_BAR_DATA_W-1:0]     msix_req_wdata,       // MSI-X 写数据，后续 2.5 使用。
    output logic [PCIE_BAR_BE_W-1:0]       msix_req_be,          // MSI-X 写 byte enable。
    output logic [VF_ID_W-1:0]             msix_req_func_id,     // MSI-X 访问所属 PF/VF function。
    output logic                           msix_req_is_pba,      // 1 表示 offset 落在 PBA 窗口，0 表示 table 窗口。

    // ------------------------------------------------------------------
    // completion/error response
    // ------------------------------------------------------------------
    output logic                           bar_rsp_valid,        // BAR decoder 完成响应有效。
    input  logic                           bar_rsp_ready,        // 上游可接收完成响应。
    output logic [PCIE_BAR_DATA_W-1:0]     bar_rsp_rdata,        // 读响应数据；当前阶段路由成功时返回 0。
    output pcie_bar_rsp_status_e           bar_rsp_status,       // BAR 访问状态。
    output logic [VF_ID_W-1:0]             bar_rsp_func_id,      // 响应对应的 PF/VF function。
    output logic [PCIE_REQ_ID_W-1:0]       bar_rsp_requester_id  // 响应对应的 requester ID。
);

    logic route_doorbell;        // 请求目标是 BAR0 Doorbell aperture。
    logic route_csr;             // 请求目标是 BAR2 CSR space。
    logic route_msix;            // 请求目标是 BAR4 MSI-X table/PBA。
    logic offset_in_range;       // offset 位于目标 BAR 的合法窗口内。
    logic dword_aligned;         // offset 是否 dword 对齐。
    logic msix_in_table;         // offset 是否位于 MSI-X table 窗口。
    logic msix_in_pba;           // offset 是否位于 MSI-X PBA 窗口。
    logic msix_in_moderation;    // offset 是否位于 MSI-X 调节控制窗口。
    logic route_supported;       // BAR 编号是否受支持。
    logic route_valid;           // 请求可被路由到某个下游目标。
    logic target_ready;          // 被选中的下游目标是否 ready。
    logic req_fire;              // 当前请求握手成功。
    logic rsp_fire;              // 当前响应握手成功。

    assign route_doorbell = (bar_req_bar == PCIE_BAR0_ID);
    assign route_csr      = (bar_req_bar == PCIE_BAR2_ID);
    assign route_msix     = (bar_req_bar == PCIE_BAR4_ID);
    assign route_supported = route_doorbell || route_csr || route_msix;

    assign dword_aligned = (bar_req_offset[1:0] == 2'b00);
    assign msix_in_table = (bar_req_offset >= PCIE_MSIX_TABLE_OFFSET) &&
                           (bar_req_offset < (PCIE_MSIX_TABLE_OFFSET + PCIE_MSIX_TABLE_SIZE));
    assign msix_in_pba   = (bar_req_offset >= PCIE_MSIX_PBA_OFFSET) &&
                           (bar_req_offset < (PCIE_MSIX_PBA_OFFSET + PCIE_MSIX_PBA_SIZE));
    assign msix_in_moderation = (bar_req_offset >= PCIE_MSIX_MODERATION_OFFSET) &&
                                (bar_req_offset < (PCIE_MSIX_MODERATION_OFFSET +
                                                   PCIE_MSIX_MODERATION_SIZE));

    always_comb begin
        offset_in_range = 1'b0;

        unique case (1'b1)
            route_doorbell: offset_in_range = (bar_req_offset < PCIE_BAR0_SIZE);
            route_csr:      offset_in_range = (bar_req_offset < PCIE_BAR2_SIZE);
            route_msix:     offset_in_range = (bar_req_offset < PCIE_BAR4_SIZE) &&
                                               (msix_in_table ||
                                                msix_in_pba ||
                                                msix_in_moderation);
            default:        offset_in_range = 1'b0;
        endcase
    end

    assign route_valid = route_supported && offset_in_range && dword_aligned;

    always_comb begin
        target_ready = 1'b1;

        if (route_valid) begin
            unique case (1'b1)
                route_doorbell: target_ready = doorbell_req_ready;
                route_csr:      target_ready = csr_req_ready;
                route_msix:     target_ready = msix_req_ready;
                default:        target_ready = 1'b1;
            endcase
        end
    end

    assign bar_req_ready = (!bar_rsp_valid || bar_rsp_ready) &&
                           (!route_valid || target_ready);
    assign req_fire = bar_req_valid && bar_req_ready;
    assign rsp_fire = bar_rsp_valid && bar_rsp_ready;

    assign doorbell_req_valid = req_fire && route_valid && route_doorbell;
    assign doorbell_req_write = bar_req_write;
    assign doorbell_req_offset = bar_req_offset;
    assign doorbell_req_wdata = bar_req_wdata;
    assign doorbell_req_be = bar_req_be;
    assign doorbell_req_func_id = bar_req_func_id;

    assign csr_req_valid = req_fire && route_valid && route_csr;
    assign csr_req_write = bar_req_write;
    assign csr_req_offset = bar_req_offset;
    assign csr_req_wdata = bar_req_wdata;
    assign csr_req_be = bar_req_be;
    assign csr_req_func_id = bar_req_func_id;

    assign msix_req_valid = req_fire && route_valid && route_msix;
    assign msix_req_write = bar_req_write;
    assign msix_req_offset = bar_req_offset;
    assign msix_req_wdata = bar_req_wdata;
    assign msix_req_be = bar_req_be;
    assign msix_req_func_id = bar_req_func_id;
    assign msix_req_is_pba = msix_in_pba;

    function automatic pcie_bar_rsp_status_e decode_status(
        input logic supported,
        input logic in_range,
        input logic aligned
    );
        begin
            if (!supported) begin
                return PCIE_BAR_RSP_UNSUPPORTED;
            end
            if (!aligned) begin
                return PCIE_BAR_RSP_MISALIGNED;
            end
            if (!in_range) begin
                return PCIE_BAR_RSP_BAD_OFFSET;
            end
            return PCIE_BAR_RSP_OK;
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bar_rsp_valid <= 1'b0;
            bar_rsp_rdata <= '0;
            bar_rsp_status <= PCIE_BAR_RSP_OK;
            bar_rsp_func_id <= '0;
            bar_rsp_requester_id <= '0;
        end else begin
            if (rsp_fire) begin
                bar_rsp_valid <= 1'b0;
            end

            if (req_fire) begin
                bar_rsp_valid <= 1'b1;
                bar_rsp_rdata <= '0;
                bar_rsp_status <= decode_status(route_supported, offset_in_range, dword_aligned);
                bar_rsp_func_id <= bar_req_func_id;
                bar_rsp_requester_id <= bar_req_requester_id;
            end
        end
    end

endmodule : pcie_bar_decoder
