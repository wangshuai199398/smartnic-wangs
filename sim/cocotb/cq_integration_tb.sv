// SPDX-License-Identifier: MIT
//
// CQ integration Cocotb stub top。
//
// 这个 testbench 只提供 Cocotb 可驱动的时钟/复位句柄。5.6 阶段的
// integration test 使用 Python mock/stub 串起 CQ 子模块接口语义，不实例化
// 完整 DMA Engine、PCIe TLP 或 RoCEv2 transport。

`timescale 1ns/1ps

module cq_integration_tb;
    logic clk;
    logic rst_n;
endmodule : cq_integration_tb
