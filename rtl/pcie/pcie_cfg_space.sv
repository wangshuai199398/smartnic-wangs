// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// PCIe Type 0 configuration space 最小实现。
//
// 本模块只提供可枚举、可读写的配置空间框架。它不实现 BAR decoder、
// CSR mailbox、MSI-X table/PBA、SR-IOV VF 资源分配或 AER/ATS 的真实协议行为。

`timescale 1ns/1ps

import smartnic_pkg::*;

module pcie_cfg_space (
    input  logic                         clk,                 // 配置空间访问时钟。
    input  logic                         rst_n,               // 低有效复位。

    input  logic                         cfg_req_valid,       // 配置访问请求有效。
    output logic                         cfg_req_ready,       // 配置空间可接收请求。
    input  logic                         cfg_req_write,       // 1 表示写，0 表示读。
    input  logic [VF_ID_W-1:0]           cfg_req_func_id,     // 发起访问的 PF/VF function，占位保留。
    input  logic [PCIE_REQ_ID_W-1:0]     cfg_req_requester_id,// 发起访问的 requester ID，占位保留。
    input  logic [PCIE_CFG_ADDR_W-1:0]   cfg_req_addr,        // 配置空间 dword 地址。
    input  logic [PCIE_CFG_DATA_W-1:0]   cfg_req_wdata,       // 配置写数据。
    input  logic [PCIE_CFG_BE_W-1:0]     cfg_req_be,          // 配置写 byte enable。

    output logic                         cfg_rsp_valid,       // 配置响应有效。
    input  logic                         cfg_rsp_ready,       // 下游已接收响应。
    output logic [PCIE_CFG_DATA_W-1:0]   cfg_rsp_rdata,       // 配置读返回数据。
    output pcie_cfg_status_e             cfg_rsp_status,      // 配置访问状态。

    output logic [15:0]                  cfg_command,         // Type 0 command register 当前值。
    output logic [15:0]                  cfg_status,          // Type 0 status register 当前值。
    output logic [31:0]                  cfg_bar0,            // BAR0 当前值，后续供 BAR decoder 使用。
    output logic [31:0]                  cfg_bar2,            // BAR2 当前值，后续供 BAR decoder 使用。
    output logic [31:0]                  cfg_bar4,            // BAR4 当前值，后续供 MSI-X 区域使用。
    output logic                         cfg_mem_space_en,    // command.memory_space enable。
    output logic                         cfg_bus_master_en,   // command.bus_master enable。
    output logic                         cfg_msix_enable,     // MSI-X capability 中的 enable 位。
    output logic                         cfg_sriov_enable     // SR-IOV control 中的 VF enable 位。
);

    localparam int CFG_VENDOR_DEVICE_DW = 12'h000; // 0x000 vendor_id/device_id。
    localparam int CFG_COMMAND_STATUS_DW = 12'h001; // 0x004 command/status。
    localparam int CFG_CLASS_REV_DW      = 12'h002; // 0x008 revision/class code。
    localparam int CFG_HEADER_DW         = 12'h003; // 0x00c header/cache/latency。
    localparam int CFG_BAR0_DW           = 12'h004; // 0x010 BAR0。
    localparam int CFG_BAR1_DW           = 12'h005; // 0x014 BAR1，BAR0 高 32 位预留。
    localparam int CFG_BAR2_DW           = 12'h006; // 0x018 BAR2。
    localparam int CFG_BAR3_DW           = 12'h007; // 0x01c BAR3。
    localparam int CFG_BAR4_DW           = 12'h008; // 0x020 BAR4。
    localparam int CFG_BAR5_DW           = 12'h009; // 0x024 BAR5。
    localparam int CFG_CAP_PTR_DW        = 12'h00d; // 0x034 capability pointer。
    localparam int CFG_SUBSYS_DW         = 12'h00b; // 0x02c subsystem vendor/subsystem ID。
    localparam int CFG_INT_DW            = 12'h00f; // 0x03c interrupt line/pin。

    localparam int CAP_PCIE_DW           = PCIE_CAP_PTR_PCIE[7:2];  // PCIe capability header。
    localparam int CAP_MSIX_DW           = PCIE_CAP_PTR_MSIX[7:2];  // MSI-X capability header。
    localparam int EXT_CAP_AER_DW        = PCIE_EXT_CAP_PTR_AER[11:2]; // AER extended capability header。
    localparam int EXT_CAP_ATS_DW        = PCIE_EXT_CAP_PTR_ATS[11:2]; // ATS extended capability header。
    localparam int EXT_CAP_SRIOV_DW      = PCIE_EXT_CAP_PTR_SRIOV[11:2]; // SR-IOV extended capability header。

    logic [15:0] command_reg;      // Type 0 command register。
    logic [15:0] status_reg;       // Type 0 status register。
    logic [31:0] bar0_reg;         // BAR0 register。
    logic [31:0] bar1_reg;         // BAR1 register，作为 BAR0 64-bit 高位占位。
    logic [31:0] bar2_reg;         // BAR2 register。
    logic [31:0] bar3_reg;         // BAR3 register，占位。
    logic [31:0] bar4_reg;         // BAR4 register。
    logic [31:0] bar5_reg;         // BAR5 register，占位。
    logic [15:0] pcie_devctl_reg;  // PCIe capability device control，占位可写。
    logic [15:0] pcie_lnkctl_reg;  // PCIe capability link control，占位可写。
    logic [15:0] msix_msg_ctl_reg; // MSI-X message control。
    logic [15:0] sriov_ctrl_reg;   // SR-IOV control。
    logic [15:0] sriov_num_vfs_reg;// SR-IOV number of VFs，占位可写。
    logic [15:0] ats_ctrl_reg;     // ATS control，占位可写。

    logic req_fire;                // 请求握手成功。
    logic rsp_fire;                // 响应握手成功。
    logic [31:0] read_data_next;   // 当前请求对应的读数据。

    assign cfg_req_ready = !cfg_rsp_valid || cfg_rsp_ready;
    assign req_fire = cfg_req_valid && cfg_req_ready;
    assign rsp_fire = cfg_rsp_valid && cfg_rsp_ready;

    assign cfg_command = command_reg;
    assign cfg_status = status_reg;
    assign cfg_bar0 = bar0_reg;
    assign cfg_bar2 = bar2_reg;
    assign cfg_bar4 = bar4_reg;
    assign cfg_mem_space_en = command_reg[1];
    assign cfg_bus_master_en = command_reg[2];
    assign cfg_msix_enable = msix_msg_ctl_reg[15];
    assign cfg_sriov_enable = sriov_ctrl_reg[0];

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

        unique case (cfg_req_addr)
            CFG_VENDOR_DEVICE_DW: read_data_next = {SMARTNIC_DEVICE_ID, SMARTNIC_VENDOR_ID};
            CFG_COMMAND_STATUS_DW: read_data_next = {status_reg, command_reg};
            CFG_CLASS_REV_DW:      read_data_next = {SMARTNIC_CLASS_CODE, SMARTNIC_REVISION_ID};
            CFG_HEADER_DW:         read_data_next = 32'h0000_0000; // Type 0 header，single function，占位。
            CFG_BAR0_DW:           read_data_next = bar0_reg;
            CFG_BAR1_DW:           read_data_next = bar1_reg;
            CFG_BAR2_DW:           read_data_next = bar2_reg;
            CFG_BAR3_DW:           read_data_next = bar3_reg;
            CFG_BAR4_DW:           read_data_next = bar4_reg;
            CFG_BAR5_DW:           read_data_next = bar5_reg;
            CFG_SUBSYS_DW:         read_data_next = {SMARTNIC_SUBSYS_ID, SMARTNIC_SUBSYS_VENDOR_ID};
            CFG_CAP_PTR_DW:        read_data_next = {24'h000000, PCIE_CAP_PTR_PCIE};
            CFG_INT_DW:            read_data_next = 32'h0000_0100; // interrupt pin INTA，占位。

            CAP_PCIE_DW:           read_data_next = {8'h00, 4'h0, 4'h2, PCIE_CAP_PTR_MSIX, PCIE_CAP_ID_PCIE};
            CAP_PCIE_DW + 1:       read_data_next = 32'h0000_0000; // PCIe capability register，占位。
            CAP_PCIE_DW + 2:       read_data_next = {16'h0000, pcie_devctl_reg};
            CAP_PCIE_DW + 4:       read_data_next = {16'h0000, pcie_lnkctl_reg};

            CAP_MSIX_DW:           read_data_next = {msix_msg_ctl_reg, 8'h00, PCIE_CAP_ID_MSIX};
            CAP_MSIX_DW + 1:       read_data_next = 32'h0000_0004; // table BIR=BAR4，offset=0 占位。
            CAP_MSIX_DW + 2:       read_data_next = 32'h0000_0804; // PBA BIR=BAR4，offset=0x800 占位。

            EXT_CAP_AER_DW:        read_data_next = {PCIE_EXT_CAP_PTR_ATS, 4'h1, PCIE_EXT_CAP_ID_AER};
            EXT_CAP_AER_DW + 1:    read_data_next = 32'h0000_0000; // AER uncorrectable error status，占位。
            EXT_CAP_AER_DW + 2:    read_data_next = 32'h0000_0000; // AER uncorrectable error mask，占位。
            EXT_CAP_AER_DW + 4:    read_data_next = 32'h0000_0000; // AER correctable error status，占位。

            EXT_CAP_ATS_DW:        read_data_next = {PCIE_EXT_CAP_PTR_SRIOV, 4'h1, PCIE_EXT_CAP_ID_ATS};
            EXT_CAP_ATS_DW + 1:    read_data_next = {16'h0000, ats_ctrl_reg};

            EXT_CAP_SRIOV_DW:      read_data_next = {12'h000, 4'h1, PCIE_EXT_CAP_ID_SRIOV};
            EXT_CAP_SRIOV_DW + 2:  read_data_next = {16'h0000, sriov_ctrl_reg};
            EXT_CAP_SRIOV_DW + 4:  read_data_next = {16'd0, sriov_num_vfs_reg};

            default:               read_data_next = 32'h0000_0000;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            command_reg      <= 16'h0000;
            status_reg       <= 16'h0010; // capabilities list present。
            bar0_reg         <= PCIE_BAR0_RESET;
            bar1_reg         <= 32'h0000_0000;
            bar2_reg         <= PCIE_BAR2_RESET;
            bar3_reg         <= 32'h0000_0000;
            bar4_reg         <= PCIE_BAR4_RESET;
            bar5_reg         <= 32'h0000_0000;
            pcie_devctl_reg  <= 16'h0000;
            pcie_lnkctl_reg  <= 16'h0000;
            msix_msg_ctl_reg <= 16'h0000;
            sriov_ctrl_reg   <= 16'h0000;
            sriov_num_vfs_reg<= 16'h0000;
            ats_ctrl_reg     <= 16'h0000;
            cfg_rsp_valid    <= 1'b0;
            cfg_rsp_rdata    <= 32'h0000_0000;
            cfg_rsp_status   <= PCIE_CFG_RSP_OK;
        end else begin
            if (rsp_fire) begin
                cfg_rsp_valid <= 1'b0;
            end

            if (req_fire) begin
                cfg_rsp_valid  <= 1'b1;
                cfg_rsp_rdata  <= read_data_next;
                cfg_rsp_status <= PCIE_CFG_RSP_OK;

                if (cfg_req_write) begin
                    unique case (cfg_req_addr)
                        CFG_COMMAND_STATUS_DW: begin
                            if (cfg_req_be[0]) command_reg[7:0]  <= cfg_req_wdata[7:0];
                            if (cfg_req_be[1]) command_reg[15:8] <= cfg_req_wdata[15:8];
                            if (cfg_req_be[2]) status_reg[7:0]   <= cfg_req_wdata[23:16];
                            if (cfg_req_be[3]) status_reg[15:8]  <= cfg_req_wdata[31:24];
                        end
                        CFG_BAR0_DW:      bar0_reg <= apply_be32(bar0_reg, cfg_req_wdata, cfg_req_be);
                        CFG_BAR1_DW:      bar1_reg <= apply_be32(bar1_reg, cfg_req_wdata, cfg_req_be);
                        CFG_BAR2_DW:      bar2_reg <= apply_be32(bar2_reg, cfg_req_wdata, cfg_req_be);
                        CFG_BAR3_DW:      bar3_reg <= apply_be32(bar3_reg, cfg_req_wdata, cfg_req_be);
                        CFG_BAR4_DW:      bar4_reg <= apply_be32(bar4_reg, cfg_req_wdata, cfg_req_be);
                        CFG_BAR5_DW:      bar5_reg <= apply_be32(bar5_reg, cfg_req_wdata, cfg_req_be);
                        CAP_PCIE_DW + 2: begin
                            if (cfg_req_be[0]) pcie_devctl_reg[7:0]  <= cfg_req_wdata[7:0];
                            if (cfg_req_be[1]) pcie_devctl_reg[15:8] <= cfg_req_wdata[15:8];
                        end
                        CAP_PCIE_DW + 4: begin
                            if (cfg_req_be[0]) pcie_lnkctl_reg[7:0]  <= cfg_req_wdata[7:0];
                            if (cfg_req_be[1]) pcie_lnkctl_reg[15:8] <= cfg_req_wdata[15:8];
                        end
                        CAP_MSIX_DW: begin
                            if (cfg_req_be[0]) msix_msg_ctl_reg[7:0]  <= cfg_req_wdata[7:0];
                            if (cfg_req_be[1]) msix_msg_ctl_reg[15:8] <= cfg_req_wdata[15:8];
                        end
                        EXT_CAP_SRIOV_DW + 2: begin
                            if (cfg_req_be[0]) sriov_ctrl_reg[7:0]  <= cfg_req_wdata[7:0];
                            if (cfg_req_be[1]) sriov_ctrl_reg[15:8] <= cfg_req_wdata[15:8];
                        end
                        EXT_CAP_SRIOV_DW + 4: begin
                            if (cfg_req_be[0]) sriov_num_vfs_reg[7:0]  <= cfg_req_wdata[7:0];
                            if (cfg_req_be[1]) sriov_num_vfs_reg[15:8] <= cfg_req_wdata[15:8];
                        end
                        EXT_CAP_ATS_DW + 1: begin
                            if (cfg_req_be[0]) ats_ctrl_reg[7:0]  <= cfg_req_wdata[7:0];
                            if (cfg_req_be[1]) ats_ctrl_reg[15:8] <= cfg_req_wdata[15:8];
                        end
                        default: begin
                            // 只读或尚未实现的配置寄存器忽略写入。
                        end
                    endcase
                end
            end
        end
    end

endmodule : pcie_cfg_space
