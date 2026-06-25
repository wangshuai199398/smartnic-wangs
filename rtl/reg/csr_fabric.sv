// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// BAR2 CSR interconnect fabric。
//
// 本模块接收 PCIe BAR2 CSR read/write 请求，将其转发到一个且仅一个内部
// 寄存器块，并在下一拍返回读数据或错误状态。真实 QP/CQ/MR/AH 资源命令
// 仍通过各 manager 后续控制接口实现；当前阶段只固定 CSR 互联和时序。

`timescale 1ns/1ps

import smartnic_pkg::*;

module csr_fabric (
    input  logic                           clk,                 // CSR fabric 时钟。
    input  logic                           rst_n,               // 低有效复位。

    // ------------------------------------------------------------------
    // PCIe BAR2 MMIO request/response
    // ------------------------------------------------------------------
    input  logic                           csr_req_valid,       // BAR2 CSR 请求有效。
    output logic                           csr_req_ready,       // fabric 可接收请求。
    input  logic                           csr_req_write,       // 1 写，0 读。
    input  logic [PCIE_BAR_OFFSET_W-1:0]   csr_req_addr,        // BAR2 内 byte offset。
    input  logic [PCIE_BAR_DATA_W-1:0]     csr_req_wdata,       // 写数据。
    input  logic [PCIE_BAR_BE_W-1:0]       csr_req_be,          // 写 byte enable。
    input  logic [VF_ID_W-1:0]             csr_req_func_id,     // 发起访问的 PF/VF function。
    output logic                           csr_rsp_valid,       // CSR 响应有效。
    input  logic                           csr_rsp_ready,       // 上游可接收 CSR 响应。
    output logic [PCIE_BAR_DATA_W-1:0]     csr_rsp_rdata,       // 读响应数据。
    output pcie_bar_rsp_status_e           csr_rsp_status,      // 响应状态。
    output logic [VF_ID_W-1:0]             csr_rsp_func_id,     // 响应对应的 PF/VF function。

    // ------------------------------------------------------------------
    // QP register block
    // ------------------------------------------------------------------
    output logic                           qp_csr_wr_en,
    output logic                           qp_csr_rd_en,
    output logic [PCIE_BAR_OFFSET_W-1:0]   qp_csr_addr,
    output logic [PCIE_BAR_DATA_W-1:0]     qp_csr_wdata,
    output logic [PCIE_BAR_BE_W-1:0]       qp_csr_be,
    output logic [VF_ID_W-1:0]             qp_csr_func_id,
    input  logic [PCIE_BAR_DATA_W-1:0]     qp_csr_rdata,

    // ------------------------------------------------------------------
    // CQ register block
    // ------------------------------------------------------------------
    output logic                           cq_csr_wr_en,
    output logic                           cq_csr_rd_en,
    output logic [PCIE_BAR_OFFSET_W-1:0]   cq_csr_addr,
    output logic [PCIE_BAR_DATA_W-1:0]     cq_csr_wdata,
    output logic [PCIE_BAR_BE_W-1:0]       cq_csr_be,
    output logic [VF_ID_W-1:0]             cq_csr_func_id,
    input  logic [PCIE_BAR_DATA_W-1:0]     cq_csr_rdata,

    // ------------------------------------------------------------------
    // MR register block
    // ------------------------------------------------------------------
    output logic                           mr_csr_wr_en,
    output logic                           mr_csr_rd_en,
    output logic [PCIE_BAR_OFFSET_W-1:0]   mr_csr_addr,
    output logic [PCIE_BAR_DATA_W-1:0]     mr_csr_wdata,
    output logic [PCIE_BAR_BE_W-1:0]       mr_csr_be,
    output logic [VF_ID_W-1:0]             mr_csr_func_id,
    input  logic [PCIE_BAR_DATA_W-1:0]     mr_csr_rdata,

    // ------------------------------------------------------------------
    // AH table register block
    // ------------------------------------------------------------------
    output logic                           ah_csr_wr_en,
    output logic                           ah_csr_rd_en,
    output logic [PCIE_BAR_OFFSET_W-1:0]   ah_csr_addr,
    output logic [PCIE_BAR_DATA_W-1:0]     ah_csr_wdata,
    output logic [PCIE_BAR_BE_W-1:0]       ah_csr_be,
    output logic [VF_ID_W-1:0]             ah_csr_func_id,
    input  logic [PCIE_BAR_DATA_W-1:0]     ah_csr_rdata,

    // ------------------------------------------------------------------
    // MSI-X control register block
    // ------------------------------------------------------------------
    output logic                           msix_csr_wr_en,
    output logic                           msix_csr_rd_en,
    output logic [PCIE_BAR_OFFSET_W-1:0]   msix_csr_addr,
    output logic [PCIE_BAR_DATA_W-1:0]     msix_csr_wdata,
    output logic [PCIE_BAR_BE_W-1:0]       msix_csr_be,
    output logic [VF_ID_W-1:0]             msix_csr_func_id,
    input  logic [PCIE_BAR_DATA_W-1:0]     msix_csr_rdata,

    // ------------------------------------------------------------------
    // SR-IOV control register block
    // ------------------------------------------------------------------
    output logic                           sriov_csr_wr_en,
    output logic                           sriov_csr_rd_en,
    output logic [PCIE_BAR_OFFSET_W-1:0]   sriov_csr_addr,
    output logic [PCIE_BAR_DATA_W-1:0]     sriov_csr_wdata,
    output logic [PCIE_BAR_BE_W-1:0]       sriov_csr_be,
    output logic [VF_ID_W-1:0]             sriov_csr_func_id,
    input  logic [PCIE_BAR_DATA_W-1:0]     sriov_csr_rdata,

    // ------------------------------------------------------------------
    // Congestion/DCQCN control register block
    // ------------------------------------------------------------------
    output logic                           congestion_csr_wr_en,
    output logic                           congestion_csr_rd_en,
    output logic [PCIE_BAR_OFFSET_W-1:0]   congestion_csr_addr,
    output logic [PCIE_BAR_DATA_W-1:0]     congestion_csr_wdata,
    output logic [PCIE_BAR_BE_W-1:0]       congestion_csr_be,
    output logic [VF_ID_W-1:0]             congestion_csr_func_id,
    input  logic [PCIE_BAR_DATA_W-1:0]     congestion_csr_rdata
);

    csr_block_id_e decode_block_id;
    logic [PCIE_BAR_OFFSET_W-1:0] decode_block_addr;
    logic decode_hit;
    csr_decode_status_e decode_status;
    logic req_fire;
    logic rsp_fire;
    pcie_bar_rsp_status_e next_status;
    logic [PCIE_BAR_DATA_W-1:0] selected_rdata;

    csr_decode u_csr_decode (
        .csr_addr(csr_req_addr),
        .csr_block_id(decode_block_id),
        .csr_block_addr(decode_block_addr),
        .csr_hit(decode_hit),
        .csr_status(decode_status)
    );

    assign csr_req_ready = !csr_rsp_valid || csr_rsp_ready;
    assign req_fire = csr_req_valid && csr_req_ready;
    assign rsp_fire = csr_rsp_valid && csr_rsp_ready;

    always_comb begin
        next_status = PCIE_BAR_RSP_OK;

        unique case (decode_status)
            CSR_DECODE_OK:         next_status = PCIE_BAR_RSP_OK;
            CSR_DECODE_MISALIGNED: next_status = PCIE_BAR_RSP_MISALIGNED;
            default:               next_status = PCIE_BAR_RSP_BAD_OFFSET;
        endcase
    end

    always_comb begin
        selected_rdata = '0;

        unique case (decode_block_id)
            CSR_BLOCK_QP:         selected_rdata = qp_csr_rdata;
            CSR_BLOCK_CQ:         selected_rdata = cq_csr_rdata;
            CSR_BLOCK_MR:         selected_rdata = mr_csr_rdata;
            CSR_BLOCK_AH:         selected_rdata = ah_csr_rdata;
            CSR_BLOCK_MSIX:       selected_rdata = msix_csr_rdata;
            CSR_BLOCK_SRIOV:      selected_rdata = sriov_csr_rdata;
            CSR_BLOCK_CONGESTION: selected_rdata = congestion_csr_rdata;
            default:              selected_rdata = '0;
        endcase
    end

    always_comb begin
        qp_csr_wr_en = 1'b0;
        qp_csr_rd_en = 1'b0;
        cq_csr_wr_en = 1'b0;
        cq_csr_rd_en = 1'b0;
        mr_csr_wr_en = 1'b0;
        mr_csr_rd_en = 1'b0;
        ah_csr_wr_en = 1'b0;
        ah_csr_rd_en = 1'b0;
        msix_csr_wr_en = 1'b0;
        msix_csr_rd_en = 1'b0;
        sriov_csr_wr_en = 1'b0;
        sriov_csr_rd_en = 1'b0;
        congestion_csr_wr_en = 1'b0;
        congestion_csr_rd_en = 1'b0;

        if (req_fire && decode_hit) begin
            unique case (decode_block_id)
                CSR_BLOCK_QP: begin
                    qp_csr_wr_en = csr_req_write;
                    qp_csr_rd_en = !csr_req_write;
                end
                CSR_BLOCK_CQ: begin
                    cq_csr_wr_en = csr_req_write;
                    cq_csr_rd_en = !csr_req_write;
                end
                CSR_BLOCK_MR: begin
                    mr_csr_wr_en = csr_req_write;
                    mr_csr_rd_en = !csr_req_write;
                end
                CSR_BLOCK_AH: begin
                    ah_csr_wr_en = csr_req_write;
                    ah_csr_rd_en = !csr_req_write;
                end
                CSR_BLOCK_MSIX: begin
                    msix_csr_wr_en = csr_req_write;
                    msix_csr_rd_en = !csr_req_write;
                end
                CSR_BLOCK_SRIOV: begin
                    sriov_csr_wr_en = csr_req_write;
                    sriov_csr_rd_en = !csr_req_write;
                end
                CSR_BLOCK_CONGESTION: begin
                    congestion_csr_wr_en = csr_req_write;
                    congestion_csr_rd_en = !csr_req_write;
                end
                default: begin
                end
            endcase
        end
    end

    assign qp_csr_addr = decode_block_addr;
    assign cq_csr_addr = decode_block_addr;
    assign mr_csr_addr = decode_block_addr;
    assign ah_csr_addr = decode_block_addr;
    assign msix_csr_addr = decode_block_addr;
    assign sriov_csr_addr = decode_block_addr;
    assign congestion_csr_addr = decode_block_addr;

    assign qp_csr_wdata = csr_req_wdata;
    assign cq_csr_wdata = csr_req_wdata;
    assign mr_csr_wdata = csr_req_wdata;
    assign ah_csr_wdata = csr_req_wdata;
    assign msix_csr_wdata = csr_req_wdata;
    assign sriov_csr_wdata = csr_req_wdata;
    assign congestion_csr_wdata = csr_req_wdata;

    assign qp_csr_be = csr_req_be;
    assign cq_csr_be = csr_req_be;
    assign mr_csr_be = csr_req_be;
    assign ah_csr_be = csr_req_be;
    assign msix_csr_be = csr_req_be;
    assign sriov_csr_be = csr_req_be;
    assign congestion_csr_be = csr_req_be;

    assign qp_csr_func_id = csr_req_func_id;
    assign cq_csr_func_id = csr_req_func_id;
    assign mr_csr_func_id = csr_req_func_id;
    assign ah_csr_func_id = csr_req_func_id;
    assign msix_csr_func_id = csr_req_func_id;
    assign sriov_csr_func_id = csr_req_func_id;
    assign congestion_csr_func_id = csr_req_func_id;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            csr_rsp_valid <= 1'b0;
            csr_rsp_rdata <= '0;
            csr_rsp_status <= PCIE_BAR_RSP_OK;
            csr_rsp_func_id <= '0;
        end else begin
            if (rsp_fire) begin
                csr_rsp_valid <= 1'b0;
            end

            if (req_fire) begin
                csr_rsp_valid <= 1'b1;
                csr_rsp_rdata <= csr_req_write ? '0 : selected_rdata;
                csr_rsp_status <= next_status;
                csr_rsp_func_id <= csr_req_func_id;
            end
        end
    end

endmodule : csr_fabric
