// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// PCIe endpoint wrapper 接口定义。
//
// 本文件只定义 PCIe hard IP 与 SmartNIC 内部逻辑之间的信号边界，
// 不实现配置空间、TLP 解析、BAR 路由、DMA 调度、MSI-X 表或 SR-IOV 策略。

`timescale 1ns/1ps

import smartnic_pkg::*;

module pcie_endpoint_wrapper #(
    parameter int TLP_DATA_W = PCIE_TLP_DATA_W,
    parameter int TLP_KEEP_W = PCIE_TLP_KEEP_W,
    parameter int TLP_USER_W = PCIE_TLP_USER_W
) (
    // ------------------------------------------------------------------
    // 时钟和复位
    // ------------------------------------------------------------------
    input  logic                         pcie_clk,              // PCIe user clock，所有 wrapper 接口默认同步到该时钟。
    input  logic                         pcie_rst_n,            // 低有效同步/异步复位，具体复位策略由顶层集成决定。

    // ------------------------------------------------------------------
    // PCIe configuration interface
    // ------------------------------------------------------------------
    output logic                         cfg_req_valid,         // wrapper 向配置空间模块发起配置访问请求。
    input  logic                         cfg_req_ready,         // 配置空间模块可接收新的配置访问请求。
    output logic                         cfg_req_write,         // 1 表示配置写，0 表示配置读。
    output logic [VF_ID_W-1:0]           cfg_req_func_id,       // 发起配置访问的 PF/VF function 标识。
    output logic [PCIE_REQ_ID_W-1:0]     cfg_req_requester_id,  // PCIe requester ID，用于记录访问来源。
    output logic [PCIE_CFG_ADDR_W-1:0]   cfg_req_addr,          // 配置空间 dword 地址。
    output logic [PCIE_CFG_DATA_W-1:0]   cfg_req_wdata,         // 配置写数据。
    output logic [PCIE_CFG_BE_W-1:0]     cfg_req_be,            // 配置写 byte enable。
    input  logic                         cfg_rsp_valid,         // 配置空间模块返回响应。
    output logic                         cfg_rsp_ready,         // wrapper 可接收配置响应。
    input  logic [PCIE_CFG_DATA_W-1:0]   cfg_rsp_rdata,         // 配置读返回数据。
    input  pcie_cfg_status_e             cfg_rsp_status,        // 配置访问完成状态。

    // ------------------------------------------------------------------
    // inbound TLP interface：PCIe hard IP 到 SmartNIC 内部
    // ------------------------------------------------------------------
    input  logic                         pcie_rx_valid,         // PCIe hard IP 输出的入站 TLP beat 有效。
    output logic                         pcie_rx_ready,         // wrapper 可接收入站 TLP beat。
    input  logic [TLP_DATA_W-1:0]        pcie_rx_data,          // 入站 TLP 数据。
    input  logic [TLP_KEEP_W-1:0]        pcie_rx_keep,          // 入站 TLP dword 有效掩码。
    input  logic                         pcie_rx_last,          // 入站 TLP 最后一个 beat。
    input  logic [TLP_USER_W-1:0]        pcie_rx_user,          // hard IP 提供的入站 sideband 元数据。

    output logic                         ib_tlp_valid,          // wrapper 转发给内部模块的入站 TLP beat 有效。
    input  logic                         ib_tlp_ready,          // 内部模块可接收入站 TLP beat。
    output logic [TLP_DATA_W-1:0]        ib_tlp_data,           // 入站 TLP 数据，暂不解析字段。
    output logic [TLP_KEEP_W-1:0]        ib_tlp_keep,           // 入站 TLP dword 有效掩码。
    output logic                         ib_tlp_last,           // 入站 TLP 最后一个 beat。
    output logic [TLP_USER_W-1:0]        ib_tlp_user,           // 入站 TLP sideband 元数据。
    output pcie_tlp_type_e               ib_tlp_type,           // 入站 TLP 类型占位，后续由解析器填写。
    output logic [PCIE_BAR_W-1:0]        ib_tlp_bar,            // 命中的 BAR 编号占位，后续供 BAR decoder 使用。
    output logic [VF_ID_W-1:0]           ib_tlp_func_id,        // 入站访问关联的 PF/VF function。
    output logic [PCIE_REQ_ID_W-1:0]     ib_tlp_requester_id,   // 入站 TLP 的 requester ID。

    // ------------------------------------------------------------------
    // outbound TLP interface：SmartNIC 内部到 PCIe hard IP
    // ------------------------------------------------------------------
    input  logic                         ob_tlp_valid,          // 内部模块提交的出站 TLP beat 有效。
    output logic                         ob_tlp_ready,          // wrapper 可接收出站 TLP beat。
    input  logic [TLP_DATA_W-1:0]        ob_tlp_data,           // 出站 TLP 数据。
    input  logic [TLP_KEEP_W-1:0]        ob_tlp_keep,           // 出站 TLP dword 有效掩码。
    input  logic                         ob_tlp_last,           // 出站 TLP 最后一个 beat。
    input  logic [TLP_USER_W-1:0]        ob_tlp_user,           // 出站 TLP sideband 元数据。
    input  pcie_tlp_type_e               ob_tlp_type,           // 出站 TLP 类型提示，例如 completion、DMA write、MSI-X message。
    input  logic [VF_ID_W-1:0]           ob_tlp_func_id,        // 出站 TLP 所属 PF/VF function。

    output logic                         pcie_tx_valid,         // 送往 PCIe hard IP 的出站 TLP beat 有效。
    input  logic                         pcie_tx_ready,         // PCIe hard IP 可接收出站 TLP beat。
    output logic [TLP_DATA_W-1:0]        pcie_tx_data,          // 送往 PCIe hard IP 的出站 TLP 数据。
    output logic [TLP_KEEP_W-1:0]        pcie_tx_keep,          // 出站 TLP dword 有效掩码。
    output logic                         pcie_tx_last,          // 出站 TLP 最后一个 beat。
    output logic [TLP_USER_W-1:0]        pcie_tx_user,          // 送往 hard IP 的出站 sideband 元数据。

    // ------------------------------------------------------------------
    // DMA request interface：DMA engine 到 PCIe wrapper
    // ------------------------------------------------------------------
    input  logic                         dma_req_valid,         // DMA engine 发起 PCIe memory read/write 请求。
    output logic                         dma_req_ready,         // wrapper 可接收新的 DMA 请求。
    input  logic                         dma_req_write,         // 1 表示 host memory write，0 表示 host memory read。
    input  logic [VF_ID_W-1:0]           dma_req_func_id,       // DMA 请求所属 PF/VF function。
    input  logic [PCIE_TAG_W-1:0]        dma_req_tag,           // DMA 请求 tag，用于匹配 completion。
    input  logic [ADDR_W-1:0]            dma_req_addr,          // 主机物理/DMA 地址。
    input  logic [DMA_LEN_W-1:0]         dma_req_len,           // DMA 传输字节数。
    input  logic [PCIE_TC_W-1:0]         dma_req_tc,            // PCIe traffic class。
    input  logic [PCIE_ATTR_W-1:0]       dma_req_attr,          // PCIe attributes，例如 relaxed ordering/no snoop。

    input  logic                         dma_wdata_valid,       // DMA write payload beat 有效。
    output logic                         dma_wdata_ready,       // wrapper 可接收 DMA write payload beat。
    input  logic [TLP_DATA_W-1:0]        dma_wdata,             // DMA write payload 数据。
    input  logic [TLP_KEEP_W-1:0]        dma_wdata_keep,        // DMA write payload dword 有效掩码。
    input  logic                         dma_wdata_last,        // DMA write payload 最后一个 beat。

    // ------------------------------------------------------------------
    // DMA completion interface：PCIe wrapper 到 DMA engine
    // ------------------------------------------------------------------
    output logic                         dma_cpl_valid,         // DMA read completion 或 DMA 错误响应有效。
    input  logic                         dma_cpl_ready,         // DMA engine 可接收 completion。
    output logic [PCIE_TAG_W-1:0]        dma_cpl_tag,           // 与原始 DMA 请求匹配的 tag。
    output logic [DMA_LEN_W-1:0]         dma_cpl_len,           // 本次 completion 覆盖的字节数。
    output logic [TLP_DATA_W-1:0]        dma_cpl_data,          // DMA read completion 数据。
    output logic [TLP_KEEP_W-1:0]        dma_cpl_keep,          // DMA read completion dword 有效掩码。
    output logic                         dma_cpl_last,          // 当前 DMA completion 的最后一个 beat。
    output logic                         dma_cpl_error,         // PCIe completion 错误或 wrapper 检测到的 DMA 错误。

    // ------------------------------------------------------------------
    // MSI-X request interface：内部事件到 PCIe wrapper
    // ------------------------------------------------------------------
    input  logic                         msix_req_valid,        // 内部模块请求发送 MSI-X 中断。
    output logic                         msix_req_ready,        // wrapper 可接收 MSI-X 请求。
    input  logic [VF_ID_W-1:0]           msix_req_func_id,      // 中断所属 PF/VF function。
    input  logic [CQ_VECTOR_W-1:0]       msix_req_vector,       // 请求触发的 MSI-X vector 编号。
    input  logic [63:0]                  msix_req_msg_addr,     // MSI-X message address，后续由 MSI-X 表模块提供。
    input  logic [31:0]                  msix_req_msg_data,     // MSI-X message data，后续由 MSI-X 表模块提供。
    input  logic                         msix_req_masked,       // vector 当前是否被屏蔽；真正屏蔽逻辑后续实现。

    // ------------------------------------------------------------------
    // function identity interface：PCIe wrapper 到内部隔离逻辑
    // ------------------------------------------------------------------
    output logic                         func_id_valid,         // 当前 function identity 信息有效。
    output logic [VF_ID_W-1:0]           func_id,               // 当前访问或上下文对应的 PF/VF function。
    output logic                         func_is_pf,            // 当前 function 是否为 PF。
    output logic                         func_is_vf,            // 当前 function 是否为 VF。
    output logic [15:0]                  func_pcie_id,          // PCIe BDF/function 编码，供 SR-IOV guard 后续使用。
    output logic [15:0]                  func_vf_num            // VF 编号；PF 访问时可为 0。
);

    // 2.1 阶段只定义接口边界。
    // 后续 2.2 到 2.6 会逐步接入配置空间、BAR 路由、MSI-X 表和 SR-IOV 隔离逻辑。

endmodule : pcie_endpoint_wrapper
