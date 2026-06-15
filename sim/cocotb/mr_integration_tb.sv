// SPDX-License-Identifier: MIT
//
// MR integration Cocotb stub top。
//
// 这个 testbench 只提供 Cocotb 可驱动的时钟/复位句柄。6.8 阶段的
// integration test 使用 Python mock/stub 串起 MR 注册、保护检查、
// refcount drain 和 Memory Window 子路径，不实例化完整 DMA/IOMMU/RoCEv2。

`timescale 1ns/1ps

module mr_integration_tb;
    logic clk;
    logic rst_n;
endmodule : mr_integration_tb
