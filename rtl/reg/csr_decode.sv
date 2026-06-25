// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// BAR2 CSR 地址解码器。
//
// 本模块只把 BAR2 内 offset 映射到内部 CSR 子窗口，不保存寄存器状态，
// 也不执行 QP/CQ/MR/AH 等业务命令。命中后的 block_addr 是目标窗口内
// 的相对 offset，供 csr_fabric 转发给对应寄存器块。

`timescale 1ns/1ps

import smartnic_pkg::*;

module csr_decode (
    input  logic [PCIE_BAR_OFFSET_W-1:0] csr_addr,       // BAR2 内 byte offset。
    output csr_block_id_e                csr_block_id,   // 解码得到的 CSR 目标块。
    output logic [PCIE_BAR_OFFSET_W-1:0] csr_block_addr, // 目标块内相对 byte offset。
    output logic                         csr_hit,        // 1 表示命中一个合法目标块。
    output csr_decode_status_e           csr_status      // 解码状态，用于 fabric 生成响应。
);

    logic aligned; // 当前阶段只支持 32-bit 对齐 CSR 访问。

    assign aligned = (csr_addr[1:0] == 2'b00);

    function automatic logic in_window(
        input logic [PCIE_BAR_OFFSET_W-1:0] addr,
        input logic [PCIE_BAR_OFFSET_W-1:0] base,
        input logic [PCIE_BAR_OFFSET_W-1:0] size
    );
        begin
            return (addr >= base) && (addr < (base + size));
        end
    endfunction

    always_comb begin
        csr_block_id = CSR_BLOCK_NONE;
        csr_block_addr = '0;
        csr_hit = 1'b0;
        csr_status = aligned ? CSR_DECODE_BAD_OFFSET : CSR_DECODE_MISALIGNED;

        if (aligned) begin
            if (in_window(csr_addr, CSR_QP_BASE, CSR_QP_SIZE)) begin
                csr_block_id = CSR_BLOCK_QP;
                csr_block_addr = csr_addr - CSR_QP_BASE;
                csr_hit = 1'b1;
                csr_status = CSR_DECODE_OK;
            end else if (in_window(csr_addr, CSR_CQ_BASE, CSR_CQ_SIZE)) begin
                csr_block_id = CSR_BLOCK_CQ;
                csr_block_addr = csr_addr - CSR_CQ_BASE;
                csr_hit = 1'b1;
                csr_status = CSR_DECODE_OK;
            end else if (in_window(csr_addr, CSR_MR_BASE, CSR_MR_SIZE)) begin
                csr_block_id = CSR_BLOCK_MR;
                csr_block_addr = csr_addr - CSR_MR_BASE;
                csr_hit = 1'b1;
                csr_status = CSR_DECODE_OK;
            end else if (in_window(csr_addr, CSR_AH_BASE, CSR_AH_SIZE)) begin
                csr_block_id = CSR_BLOCK_AH;
                csr_block_addr = csr_addr - CSR_AH_BASE;
                csr_hit = 1'b1;
                csr_status = CSR_DECODE_OK;
            end else if (in_window(csr_addr, CSR_MSIX_BASE, CSR_MSIX_SIZE)) begin
                csr_block_id = CSR_BLOCK_MSIX;
                csr_block_addr = csr_addr - CSR_MSIX_BASE;
                csr_hit = 1'b1;
                csr_status = CSR_DECODE_OK;
            end else if (in_window(csr_addr, CSR_SRIOV_BASE, CSR_SRIOV_SIZE)) begin
                csr_block_id = CSR_BLOCK_SRIOV;
                csr_block_addr = csr_addr - CSR_SRIOV_BASE;
                csr_hit = 1'b1;
                csr_status = CSR_DECODE_OK;
            end else if (in_window(csr_addr, CSR_CONGESTION_BASE, CSR_CONGESTION_SIZE)) begin
                csr_block_id = CSR_BLOCK_CONGESTION;
                csr_block_addr = csr_addr - CSR_CONGESTION_BASE;
                csr_hit = 1'b1;
                csr_status = CSR_DECODE_OK;
            end
        end
    end

endmodule : csr_decode
