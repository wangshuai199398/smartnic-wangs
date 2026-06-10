// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// PCIe BAR2 CSR mailbox 最小实现。
//
// 本模块实现 command_id、参数、GO/DONE、status、error_code、timeout_counter
// 和 owner_function 字段的寄存器协议。当前阶段只完成命令生命周期框架，
// 不创建 QP/CQ/MR，不访问资源表，也不修改真实 RDMA 状态。

`timescale 1ns/1ps

import smartnic_pkg::*;

module pcie_csr_mailbox (
    input  logic                         clk,                 // CSR mailbox 访问时钟。
    input  logic                         rst_n,               // 低有效复位。

    // ------------------------------------------------------------------
    // BAR2 CSR read/write request
    // ------------------------------------------------------------------
    input  logic                         csr_req_valid,       // BAR2 CSR 请求有效。
    output logic                         csr_req_ready,       // mailbox 可接收 CSR 请求。
    input  logic                         csr_req_write,       // 1 表示写，0 表示读。
    input  logic [PCIE_BAR_OFFSET_W-1:0] csr_req_offset,      // BAR2 内 byte offset。
    input  logic [PCIE_BAR_DATA_W-1:0]   csr_req_wdata,       // CSR 写数据。
    input  logic [PCIE_BAR_BE_W-1:0]     csr_req_be,          // CSR 写 byte enable。
    input  logic [VF_ID_W-1:0]           csr_req_func_id,     // 发起访问的 PF/VF function。

    output logic                         csr_rsp_valid,       // CSR 读写响应有效。
    input  logic                         csr_rsp_ready,       // 上游可接收响应。
    output logic [PCIE_BAR_DATA_W-1:0]   csr_rsp_rdata,       // CSR 读返回数据。
    output pcie_bar_rsp_status_e         csr_rsp_status,      // CSR 访问状态。

    // ------------------------------------------------------------------
    // Future resource-manager command pulse
    // ------------------------------------------------------------------
    output logic                         mailbox_cmd_valid,   // 命令被硬件接受的单周期脉冲。
    output csr_cmd_e                     mailbox_cmd_id,      // 被接受的 command_id。
    output logic [31:0]                  mailbox_arg0,        // 命令参数 0。
    output logic [31:0]                  mailbox_arg1,        // 命令参数 1。
    output logic [31:0]                  mailbox_arg2,        // 命令参数 2。
    output logic [31:0]                  mailbox_arg3,        // 命令参数 3。
    output logic [VF_ID_W-1:0]           mailbox_owner_function // 命令所属 PF/VF function。
);

    logic [15:0] command_id_reg;             // 软件写入的命令编号。
    logic [31:0] arg0_reg;                   // 参数 0。
    logic [31:0] arg1_reg;                   // 参数 1。
    logic [31:0] arg2_reg;                   // 参数 2。
    logic [31:0] arg3_reg;                   // 参数 3。
    logic [VF_ID_W-1:0] owner_function_reg;  // 命令归属 PF/VF function。
    logic [31:0] timeout_counter_reg;        // BUSY 状态计数器。
    csr_mailbox_state_e state_reg;           // mailbox 生命周期状态。
    csr_mailbox_status_e status_reg;         // 软件可见执行状态。
    csr_mailbox_error_e error_code_reg;      // 软件可见错误码。
    logic req_fire;                          // CSR 请求握手成功。
    logic rsp_fire;                          // CSR 响应握手成功。
    logic write_go;                          // 软件写 control.go=1。
    logic offset_supported;                  // offset 属于 mailbox 寄存器。
    logic [31:0] read_data_next;             // 当前读请求对应的数据。

    assign csr_req_ready = !csr_rsp_valid || csr_rsp_ready;
    assign req_fire = csr_req_valid && csr_req_ready;
    assign rsp_fire = csr_rsp_valid && csr_rsp_ready;

    assign mailbox_cmd_valid = (state_reg == CSR_MB_STATE_GO) && is_supported_command(command_id_reg);
    assign mailbox_cmd_id = csr_cmd_e'(command_id_reg);
    assign mailbox_arg0 = arg0_reg;
    assign mailbox_arg1 = arg1_reg;
    assign mailbox_arg2 = arg2_reg;
    assign mailbox_arg3 = arg3_reg;
    assign mailbox_owner_function = owner_function_reg;

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

    function automatic logic is_supported_command(input logic [15:0] cmd_id);
        begin
            unique case (cmd_id)
                CSR_CMD_NOP,
                CSR_CMD_CREATE_QP,
                CSR_CMD_DESTROY_QP,
                CSR_CMD_CREATE_CQ,
                CSR_CMD_DESTROY_CQ,
                CSR_CMD_REG_MR,
                CSR_CMD_DEREG_MR: is_supported_command = 1'b1;
                default:          is_supported_command = 1'b0;
            endcase
        end
    endfunction

    always_comb begin
        offset_supported = 1'b1;
        read_data_next = 32'h0000_0000;

        unique case (csr_req_offset)
            CSR_MB_COMMAND_ID_OFFSET:      read_data_next = {16'h0000, command_id_reg};
            CSR_MB_OWNER_FUNCTION_OFFSET:  read_data_next = {{(32-VF_ID_W){1'b0}}, owner_function_reg};
            CSR_MB_CONTROL_OFFSET:         read_data_next = {28'h0000000,
                                                             (state_reg == CSR_MB_STATE_ERROR),
                                                             (state_reg == CSR_MB_STATE_BUSY) ||
                                                             (state_reg == CSR_MB_STATE_GO),
                                                             (state_reg == CSR_MB_STATE_DONE) ||
                                                             (state_reg == CSR_MB_STATE_ERROR),
                                                             (state_reg == CSR_MB_STATE_GO) ||
                                                             (state_reg == CSR_MB_STATE_BUSY)};
            CSR_MB_STATUS_OFFSET:          read_data_next = {24'h000000, status_reg};
            CSR_MB_ERROR_CODE_OFFSET:      read_data_next = {16'h0000, error_code_reg};
            CSR_MB_TIMEOUT_COUNTER_OFFSET: read_data_next = timeout_counter_reg;
            CSR_MB_ARG0_OFFSET:            read_data_next = arg0_reg;
            CSR_MB_ARG1_OFFSET:            read_data_next = arg1_reg;
            CSR_MB_ARG2_OFFSET:            read_data_next = arg2_reg;
            CSR_MB_ARG3_OFFSET:            read_data_next = arg3_reg;
            default: begin
                offset_supported = 1'b0;
                read_data_next = 32'h0000_0000;
            end
        endcase
    end

    assign write_go = req_fire &&
                      csr_req_write &&
                      (csr_req_offset == CSR_MB_CONTROL_OFFSET) &&
                      csr_req_be[0] &&
                      csr_req_wdata[0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            command_id_reg <= CSR_CMD_NOP;
            arg0_reg <= 32'h0000_0000;
            arg1_reg <= 32'h0000_0000;
            arg2_reg <= 32'h0000_0000;
            arg3_reg <= 32'h0000_0000;
            owner_function_reg <= '0;
            timeout_counter_reg <= 32'h0000_0000;
            state_reg <= CSR_MB_STATE_IDLE;
            status_reg <= CSR_MB_STATUS_IDLE;
            error_code_reg <= CSR_MB_ERR_NONE;
            csr_rsp_valid <= 1'b0;
            csr_rsp_rdata <= 32'h0000_0000;
            csr_rsp_status <= PCIE_BAR_RSP_OK;
        end else begin
            if (rsp_fire) begin
                csr_rsp_valid <= 1'b0;
            end

            unique case (state_reg)
                CSR_MB_STATE_IDLE: begin
                    status_reg <= CSR_MB_STATUS_IDLE;
                    timeout_counter_reg <= 32'h0000_0000;
                end
                CSR_MB_STATE_GO: begin
                    if (is_supported_command(command_id_reg)) begin
                        state_reg <= CSR_MB_STATE_BUSY;
                        status_reg <= CSR_MB_STATUS_BUSY;
                        error_code_reg <= CSR_MB_ERR_NONE;
                        timeout_counter_reg <= 32'h0000_0000;
                    end else begin
                        state_reg <= CSR_MB_STATE_ERROR;
                        status_reg <= CSR_MB_STATUS_FAILED;
                        error_code_reg <= CSR_MB_ERR_INVALID_CMD;
                    end
                end
                CSR_MB_STATE_BUSY: begin
                    timeout_counter_reg <= timeout_counter_reg + 32'd1;
                    if (timeout_counter_reg >= CSR_MB_TIMEOUT_LIMIT) begin
                        state_reg <= CSR_MB_STATE_ERROR;
                        status_reg <= CSR_MB_STATUS_FAILED;
                        error_code_reg <= CSR_MB_ERR_TIMEOUT;
                    end else if (timeout_counter_reg >= CSR_MB_MIN_BUSY_CYCLES) begin
                        state_reg <= CSR_MB_STATE_DONE;
                        status_reg <= CSR_MB_STATUS_SUCCESS;
                        error_code_reg <= CSR_MB_ERR_NONE;
                    end
                end
                CSR_MB_STATE_DONE: begin
                    // 保持 done/status，直到软件写新的 command 或 go。
                end
                CSR_MB_STATE_ERROR: begin
                    // 保持 error_code，直到软件写新的 command 或 go。
                end
                default: begin
                    state_reg <= CSR_MB_STATE_ERROR;
                    status_reg <= CSR_MB_STATUS_FAILED;
                    error_code_reg <= CSR_MB_ERR_INVALID_CMD;
                end
            endcase

            if (req_fire) begin
                csr_rsp_valid <= 1'b1;
                csr_rsp_rdata <= read_data_next;
                csr_rsp_status <= offset_supported ? PCIE_BAR_RSP_OK : PCIE_BAR_RSP_BAD_OFFSET;

                if (csr_req_write && offset_supported) begin
                    unique case (csr_req_offset)
                        CSR_MB_COMMAND_ID_OFFSET: begin
                            if (csr_req_be[0]) command_id_reg[7:0] <= csr_req_wdata[7:0];
                            if (csr_req_be[1]) command_id_reg[15:8] <= csr_req_wdata[15:8];
                            state_reg <= CSR_MB_STATE_IDLE;
                            status_reg <= CSR_MB_STATUS_IDLE;
                            error_code_reg <= CSR_MB_ERR_NONE;
                        end
                        CSR_MB_OWNER_FUNCTION_OFFSET: begin
                            if (csr_req_be[0]) owner_function_reg[7:0] <= csr_req_wdata[7:0];
                            if (csr_req_be[1]) owner_function_reg[15:8] <= csr_req_wdata[15:8];
                        end
                        CSR_MB_ARG0_OFFSET: arg0_reg <= apply_be32(arg0_reg, csr_req_wdata, csr_req_be);
                        CSR_MB_ARG1_OFFSET: arg1_reg <= apply_be32(arg1_reg, csr_req_wdata, csr_req_be);
                        CSR_MB_ARG2_OFFSET: arg2_reg <= apply_be32(arg2_reg, csr_req_wdata, csr_req_be);
                        CSR_MB_ARG3_OFFSET: arg3_reg <= apply_be32(arg3_reg, csr_req_wdata, csr_req_be);
                        CSR_MB_CONTROL_OFFSET: begin
                            if (csr_req_be[0] && csr_req_wdata[0]) begin
                                if ((state_reg == CSR_MB_STATE_GO) ||
                                    (state_reg == CSR_MB_STATE_BUSY)) begin
                                    state_reg <= CSR_MB_STATE_ERROR;
                                    status_reg <= CSR_MB_STATUS_FAILED;
                                    error_code_reg <= CSR_MB_ERR_BUSY;
                                end else begin
                                    owner_function_reg <= csr_req_func_id;
                                    state_reg <= CSR_MB_STATE_GO;
                                    status_reg <= CSR_MB_STATUS_BUSY;
                                    error_code_reg <= CSR_MB_ERR_NONE;
                                    timeout_counter_reg <= 32'h0000_0000;
                                end
                            end
                        end
                        default: begin
                            // 只读寄存器忽略写入。
                        end
                    endcase
                end else if (csr_req_write && !offset_supported) begin
                    state_reg <= CSR_MB_STATE_ERROR;
                    status_reg <= CSR_MB_STATUS_FAILED;
                    error_code_reg <= CSR_MB_ERR_BAD_OFFSET;
                end
            end
        end
    end

endmodule : pcie_csr_mailbox
