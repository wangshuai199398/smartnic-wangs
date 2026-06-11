// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// BAR0 Doorbell address decoder 最小实现。
//
// 本模块只根据 BAR0 offset 识别 SQ Doorbell、RQ Doorbell 和 CQ arm Doorbell。
// 它不解析完整 payload，不更新 QP producer index，也不更新 CQ consumer index。

`timescale 1ns/1ps

import smartnic_pkg::*;

module doorbell_decoder (
    input  logic                         clk,                  // Doorbell decoder 时钟。
    input  logic                         rst_n,                // 低有效复位。

    // ------------------------------------------------------------------
    // BAR0 Doorbell request from PCIe BAR decoder
    // ------------------------------------------------------------------
    input  logic                         db_req_valid,         // BAR0 Doorbell 请求有效。
    output logic                         db_req_ready,         // decoder 可接收请求。
    input  logic                         db_req_write,         // 1 表示写 Doorbell，0 表示读访问。
    input  logic [PCIE_BAR_OFFSET_W-1:0] db_req_offset,        // BAR0 内 byte offset。
    input  logic [PCIE_BAR_DATA_W-1:0]   db_req_wdata,         // Doorbell 原始写 payload。
    input  logic [PCIE_BAR_BE_W-1:0]     db_req_be,            // Doorbell 写 byte enable。
    input  logic [VF_ID_W-1:0]           db_req_func_id,       // 发起 Doorbell 的 PF/VF function。

    // ------------------------------------------------------------------
    // Decoded Doorbell event
    // ------------------------------------------------------------------
    output logic                         doorbell_valid,       // 解码出合法 Doorbell 事件。
    input  logic                         doorbell_ready,       // 下游可接收 Doorbell 事件。
    output doorbell_type_e               doorbell_type,        // SQ、RQ 或 CQ arm 类型。
    output logic [QP_ID_W-1:0]           qpn,                  // SQ/RQ Doorbell 对应 QPN。
    output logic [CQ_ID_W-1:0]           cqn,                  // CQ arm Doorbell 对应 CQN。
    output logic [QUEUE_IDX_W-1:0]       queue_index,          // 当前阶段从 payload 低位透传的队列索引。
    output logic [PCIE_BAR_DATA_W-1:0]   raw_payload,          // 原始 Doorbell payload。
    output logic [VF_ID_W-1:0]           owner_function,       // Doorbell 所属 PF/VF function。

    // ------------------------------------------------------------------
    // Decode response/status
    // ------------------------------------------------------------------
    output logic                         db_rsp_valid,         // 解码响应有效。
    input  logic                         db_rsp_ready,         // 上游/集成层可接收响应。
    output pcie_bar_rsp_status_e         db_rsp_status         // 解码状态。
);

    logic req_fire;                                      // 请求握手成功。
    logic rsp_fire;                                      // 响应握手成功。
    logic event_fire;                                    // 合法 Doorbell 事件被下游接收。
    logic dword_aligned;                                 // offset 是否 dword 对齐。
    logic page_in_range;                                 // offset 是否位于 BAR0 Doorbell aperture。
    logic write_strobe_valid;                            // 写 byte enable 是否至少覆盖一个 byte。
    logic [PCIE_BAR_OFFSET_W-1:0] page_offset;            // page 内 offset。
    logic [PCIE_BAR_OFFSET_W-DB_PAGE_SHIFT-1:0] page_id;  // page 编号，当前阶段映射为 QPN/CQN。
    doorbell_type_e decoded_type;                         // 当前 offset 解出的 Doorbell 类型。
    logic decoded_type_valid;                             // 当前 offset 是否为已知 Doorbell 类型。
    pcie_bar_rsp_status_e decode_status_next;             // 当前请求的解码状态。
    logic decode_ok;                                      // 当前请求是否成功解码。

    assign dword_aligned = (db_req_offset[1:0] == 2'b00);
    assign page_in_range = (db_req_offset < PCIE_BAR0_SIZE);
    assign write_strobe_valid = |db_req_be;
    assign page_offset = db_req_offset & (DB_PAGE_SIZE - 1);
    assign page_id = db_req_offset[PCIE_BAR_OFFSET_W-1:DB_PAGE_SHIFT];

    assign req_fire = db_req_valid && db_req_ready;
    assign rsp_fire = db_rsp_valid && db_rsp_ready;
    assign event_fire = doorbell_valid && doorbell_ready;

    always_comb begin
        decoded_type = DB_TYPE_NONE;
        decoded_type_valid = 1'b0;

        unique case (page_offset)
            DB_SQ_OFFSET: begin
                decoded_type = DB_TYPE_SQ;
                decoded_type_valid = 1'b1;
            end
            DB_RQ_OFFSET: begin
                decoded_type = DB_TYPE_RQ;
                decoded_type_valid = 1'b1;
            end
            DB_CQ_ARM_OFFSET: begin
                decoded_type = DB_TYPE_CQ_ARM;
                decoded_type_valid = 1'b1;
            end
            default: begin
                decoded_type = DB_TYPE_NONE;
                decoded_type_valid = 1'b0;
            end
        endcase
    end

    always_comb begin
        if (!page_in_range) begin
            decode_status_next = PCIE_BAR_RSP_BAD_OFFSET;
        end else if (!dword_aligned) begin
            decode_status_next = PCIE_BAR_RSP_MISALIGNED;
        end else if (!db_req_write || !write_strobe_valid) begin
            decode_status_next = PCIE_BAR_RSP_UNSUPPORTED;
        end else if (!decoded_type_valid) begin
            decode_status_next = PCIE_BAR_RSP_BAD_OFFSET;
        end else begin
            decode_status_next = PCIE_BAR_RSP_OK;
        end
    end

    assign decode_ok = (decode_status_next == PCIE_BAR_RSP_OK);
    assign db_req_ready = (!db_rsp_valid || db_rsp_ready) &&
                          (!doorbell_valid || doorbell_ready);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            doorbell_valid <= 1'b0;
            doorbell_type <= DB_TYPE_NONE;
            qpn <= '0;
            cqn <= '0;
            queue_index <= '0;
            raw_payload <= '0;
            owner_function <= '0;
            db_rsp_valid <= 1'b0;
            db_rsp_status <= PCIE_BAR_RSP_OK;
        end else begin
            if (event_fire) begin
                doorbell_valid <= 1'b0;
            end

            if (rsp_fire) begin
                db_rsp_valid <= 1'b0;
            end

            if (req_fire) begin
                db_rsp_valid <= 1'b1;
                db_rsp_status <= decode_status_next;

                if (decode_ok) begin
                    doorbell_valid <= 1'b1;
                    doorbell_type <= decoded_type;
                    raw_payload <= db_req_wdata;
                    queue_index <= db_req_wdata[QUEUE_IDX_W-1:0];
                    owner_function <= db_req_func_id;

                    if (decoded_type == DB_TYPE_CQ_ARM) begin
                        qpn <= '0;
                        cqn <= CQ_ID_W'(page_id);
                    end else begin
                        qpn <= QP_ID_W'(page_id);
                        cqn <= '0;
                    end
                end
            end
        end
    end

endmodule : doorbell_decoder
