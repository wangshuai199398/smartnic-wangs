// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// MSI-X table/PBA 和中断调节最小实现。
//
// 本模块实现 BAR4 可访问的 MSI-X table、PBA pending bit array 和基础中断调节。
// 它只输出 msix_msg_valid/address/data，不生成真实 PCIe MSI-X TLP。

`timescale 1ns/1ps

import smartnic_pkg::*;

module pcie_msix (
    input  logic                         clk,                 // MSI-X 逻辑时钟。
    input  logic                         rst_n,               // 低有效复位。

    // ------------------------------------------------------------------
    // BAR4 MSI-X table/PBA read/write request
    // ------------------------------------------------------------------
    input  logic                         msix_req_valid,      // BAR4 MSI-X 请求有效。
    output logic                         msix_req_ready,      // MSI-X block 可接收请求。
    input  logic                         msix_req_write,      // 1 表示写，0 表示读。
    input  logic [PCIE_BAR_OFFSET_W-1:0] msix_req_offset,     // BAR4 内 byte offset。
    input  logic [PCIE_BAR_DATA_W-1:0]   msix_req_wdata,      // 写数据。
    input  logic [PCIE_BAR_BE_W-1:0]     msix_req_be,         // byte enable。
    input  logic [VF_ID_W-1:0]           msix_req_func_id,    // 发起访问的 PF/VF function，占位保留。
    input  logic                         msix_req_is_pba,     // 来自 BAR decoder 的 PBA 窗口提示。

    output logic                         msix_rsp_valid,      // BAR4 响应有效。
    input  logic                         msix_rsp_ready,      // 上游可接收响应。
    output logic [PCIE_BAR_DATA_W-1:0]   msix_rsp_rdata,      // BAR4 读返回数据。
    output pcie_bar_rsp_status_e         msix_rsp_status,     // BAR4 访问状态。

    // ------------------------------------------------------------------
    // Internal interrupt request inputs
    // ------------------------------------------------------------------
    input  logic                         cq_interrupt_req,    // CQ completion 中断请求。
    input  logic                         admin_interrupt_req, // admin/mailbox 中断请求。
    input  logic                         error_interrupt_req, // error/asynchronous event 中断请求。

    // ------------------------------------------------------------------
    // MSI-X message output
    // ------------------------------------------------------------------
    output logic                         msix_msg_valid,      // 有一条 MSI-X message 等待 PCIe 发送。
    input  logic                         msix_msg_ready,      // 下游 PCIe message 发送路径可接收。
    output logic [63:0]                  msix_msg_addr,       // MSI-X message address。
    output logic [31:0]                  msix_msg_data,       // MSI-X message data。
    output logic [PCIE_MSIX_VECTOR_ID_W-1:0] msix_msg_vector  // 触发的 vector 编号。
);

    msix_table_entry_t table [PCIE_MSIX_VECTOR_COUNT]; // MSI-X table。
    logic [PCIE_MSIX_VECTOR_COUNT-1:0] pending_bits;   // PBA pending bits。
    logic moderation_enable;                           // 中断调节使能。
    logic [15:0] moderation_timer;                     // 中断调节 timer 阈值。
    logic [15:0] moderation_count;                     // 中断调节 count 阈值。
    logic [15:0] moderation_timer_cnt;                 // 当前 timer 计数。
    logic [15:0] moderation_event_cnt;                 // 当前 pending 事件计数。
    logic req_fire;                                    // BAR4 请求握手。
    logic rsp_fire;                                    // BAR4 响应握手。
    logic msg_fire;                                    // MSI-X message 握手。
    logic [31:0] read_data_next;                       // 当前读返回数据。
    pcie_bar_rsp_status_e status_next;                 // 当前请求状态。
    logic request_hits_table;                          // offset 命中 table。
    logic request_hits_pba;                            // offset 命中 PBA。
    logic request_hits_moderation;                     // offset 命中调节寄存器。
    logic [PCIE_MSIX_VECTOR_ID_W-1:0] table_index;      // table entry 索引。
    logic [1:0] table_dword;                           // entry 内 dword 索引。
    logic moderation_release;                          // 调节条件已满足。
    logic [PCIE_MSIX_VECTOR_ID_W-1:0] selected_vector;  // 当前仲裁出的 vector。
    logic selected_vector_valid;                       // 有可发送 vector。

    assign msix_req_ready = !msix_rsp_valid || msix_rsp_ready;
    assign req_fire = msix_req_valid && msix_req_ready;
    assign rsp_fire = msix_rsp_valid && msix_rsp_ready;
    assign msg_fire = msix_msg_valid && msix_msg_ready;

    assign request_hits_table = (msix_req_offset >= PCIE_MSIX_TABLE_OFFSET) &&
                                (msix_req_offset < (PCIE_MSIX_TABLE_OFFSET +
                                                    (PCIE_MSIX_VECTOR_COUNT * PCIE_MSIX_ENTRY_SIZE)));
    assign request_hits_pba = msix_req_is_pba ||
                              ((msix_req_offset >= PCIE_MSIX_PBA_OFFSET) &&
                               (msix_req_offset < (PCIE_MSIX_PBA_OFFSET + PCIE_MSIX_PBA_SIZE)));
    assign request_hits_moderation = (msix_req_offset == PCIE_MSIX_MODERATION_OFFSET) ||
                                     (msix_req_offset == PCIE_MSIX_MOD_TIMER_OFFSET) ||
                                     (msix_req_offset == PCIE_MSIX_MOD_COUNT_OFFSET);
    assign table_index = (msix_req_offset - PCIE_MSIX_TABLE_OFFSET) >> 4;
    assign table_dword = msix_req_offset[3:2];

    function automatic logic [31:0] apply_be32(
        input logic [31:0] old_value,
        input logic [31:0] new_value,
        input logic [3:0]  byte_en
    );
        logic [31:0] merged;
        begin
            merged = old_value;
            if (byte_en[0]) merged[7:0]   = new_value[7:0];
            if (byte_en[1]) merged[15:8]  = new_value[15:8];
            if (byte_en[2]) merged[23:16] = new_value[23:16];
            if (byte_en[3]) merged[31:24] = new_value[31:24];
            return merged;
        end
    endfunction

    always_comb begin
        read_data_next = 32'h0000_0000;
        status_next = PCIE_BAR_RSP_OK;

        if (request_hits_table) begin
            unique case (table_dword)
                2'd0: read_data_next = table[table_index].msg_addr_low;
                2'd1: read_data_next = table[table_index].msg_addr_high;
                2'd2: read_data_next = table[table_index].msg_data;
                2'd3: read_data_next = table[table_index].vector_ctrl;
                default: read_data_next = 32'h0000_0000;
            endcase
        end else if (request_hits_pba) begin
            read_data_next = {{(32-PCIE_MSIX_VECTOR_COUNT){1'b0}}, pending_bits};
        end else if (request_hits_moderation) begin
            unique case (msix_req_offset)
                PCIE_MSIX_MODERATION_OFFSET: read_data_next = {31'h00000000, moderation_enable};
                PCIE_MSIX_MOD_TIMER_OFFSET:  read_data_next = {16'h0000, moderation_timer};
                PCIE_MSIX_MOD_COUNT_OFFSET:  read_data_next = {16'h0000, moderation_count};
                default:                     read_data_next = 32'h0000_0000;
            endcase
        end else begin
            status_next = PCIE_BAR_RSP_BAD_OFFSET;
        end
    end

    always_comb begin
        selected_vector = '0;
        selected_vector_valid = 1'b0;

        for (int i = 0; i < PCIE_MSIX_VECTOR_COUNT; i++) begin
            if (!selected_vector_valid && pending_bits[i] && !table[i].vector_ctrl[0]) begin
                selected_vector = PCIE_MSIX_VECTOR_ID_W'(i);
                selected_vector_valid = 1'b1;
            end
        end
    end

    assign moderation_release = !moderation_enable ||
                                (moderation_count == 16'd0) ||
                                (moderation_event_cnt >= moderation_count) ||
                                ((moderation_timer != 16'd0) &&
                                 (moderation_timer_cnt >= moderation_timer));

    assign msix_msg_valid = selected_vector_valid && moderation_release;
    assign msix_msg_addr = {table[selected_vector].msg_addr_high,
                            table[selected_vector].msg_addr_low};
    assign msix_msg_data = table[selected_vector].msg_data;
    assign msix_msg_vector = selected_vector;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < PCIE_MSIX_VECTOR_COUNT; i++) begin
                table[i].msg_addr_low <= 32'h0000_0000;
                table[i].msg_addr_high <= 32'h0000_0000;
                table[i].msg_data <= 32'h0000_0000;
                table[i].vector_ctrl <= 32'h0000_0001; // 复位后默认 mask。
            end
            pending_bits <= '0;
            moderation_enable <= 1'b0;
            moderation_timer <= 16'd0;
            moderation_count <= 16'd0;
            moderation_timer_cnt <= 16'd0;
            moderation_event_cnt <= 16'd0;
            msix_rsp_valid <= 1'b0;
            msix_rsp_rdata <= 32'h0000_0000;
            msix_rsp_status <= PCIE_BAR_RSP_OK;
        end else begin
            if (rsp_fire) begin
                msix_rsp_valid <= 1'b0;
            end

            if (cq_interrupt_req) begin
                pending_bits[PCIE_MSIX_CQ_VECTOR] <= 1'b1;
            end
            if (admin_interrupt_req) begin
                pending_bits[PCIE_MSIX_ADMIN_VECTOR] <= 1'b1;
            end
            if (error_interrupt_req) begin
                pending_bits[PCIE_MSIX_ERROR_VECTOR] <= 1'b1;
            end

            if (cq_interrupt_req || admin_interrupt_req || error_interrupt_req) begin
                moderation_event_cnt <= moderation_event_cnt + 16'd1;
            end

            if (|pending_bits && moderation_enable && (moderation_timer != 16'd0)) begin
                moderation_timer_cnt <= moderation_timer_cnt + 16'd1;
            end else if (!moderation_enable || !(|pending_bits)) begin
                moderation_timer_cnt <= 16'd0;
            end

            if (msg_fire) begin
                pending_bits[selected_vector] <= 1'b0;
                moderation_event_cnt <= 16'd0;
                moderation_timer_cnt <= 16'd0;
            end

            if (req_fire) begin
                msix_rsp_valid <= 1'b1;
                msix_rsp_rdata <= read_data_next;
                msix_rsp_status <= status_next;

                if (msix_req_write && (status_next == PCIE_BAR_RSP_OK)) begin
                    if (request_hits_table) begin
                        unique case (table_dword)
                            2'd0: table[table_index].msg_addr_low <= apply_be32(table[table_index].msg_addr_low,
                                                                                msix_req_wdata,
                                                                                msix_req_be);
                            2'd1: table[table_index].msg_addr_high <= apply_be32(table[table_index].msg_addr_high,
                                                                                 msix_req_wdata,
                                                                                 msix_req_be);
                            2'd2: table[table_index].msg_data <= apply_be32(table[table_index].msg_data,
                                                                            msix_req_wdata,
                                                                            msix_req_be);
                            2'd3: table[table_index].vector_ctrl <= apply_be32(table[table_index].vector_ctrl,
                                                                               msix_req_wdata,
                                                                               msix_req_be);
                            default: begin
                            end
                        endcase
                    end else if (request_hits_pba) begin
                        pending_bits <= pending_bits & ~msix_req_wdata[PCIE_MSIX_VECTOR_COUNT-1:0];
                    end else if (request_hits_moderation) begin
                        unique case (msix_req_offset)
                            PCIE_MSIX_MODERATION_OFFSET: begin
                                if (msix_req_be[0]) moderation_enable <= msix_req_wdata[0];
                            end
                            PCIE_MSIX_MOD_TIMER_OFFSET: begin
                                if (msix_req_be[0]) moderation_timer[7:0] <= msix_req_wdata[7:0];
                                if (msix_req_be[1]) moderation_timer[15:8] <= msix_req_wdata[15:8];
                            end
                            PCIE_MSIX_MOD_COUNT_OFFSET: begin
                                if (msix_req_be[0]) moderation_count[7:0] <= msix_req_wdata[7:0];
                                if (msix_req_be[1]) moderation_count[15:8] <= msix_req_wdata[15:8];
                            end
                            default: begin
                            end
                        endcase
                    end
                end
            end
        end
    end

endmodule : pcie_msix
