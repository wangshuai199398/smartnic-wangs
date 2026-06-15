// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// DMA descriptor dispatcher 最小实现。
//
// 本模块把 SQ/RQ/CQE/fetch 来源的 dma_desc_t 统一收敛，并按 opcode 分发
// 到 host read、host write、CQE write 或 fetch 子路径。当前阶段不实现真实
// PCIe DMA、不做 MR permission check、不遍历 SGE，也不做公平仲裁。

`timescale 1ns/1ps

import smartnic_pkg::*;

module dma_descriptor_dispatcher (
    input  logic                  clk,                    // DMA dispatcher 时钟。
    input  logic                  rst_n,                  // 低有效复位。

    // ------------------------------------------------------------------
    // Input sources
    // ------------------------------------------------------------------
    input  logic                  sq_dma_req_valid,       // SQ engine Send/RDMA Read/Write 请求有效。
    output logic                  sq_dma_req_ready,       // dispatcher 可接收 SQ 请求。
    input  dma_desc_t             sq_dma_req,             // SQ 转换后的 DMA descriptor。

    input  logic                  rq_dma_req_valid,       // RQ engine Recv buffer write 请求有效。
    output logic                  rq_dma_req_ready,       // dispatcher 可接收 RQ 请求。
    input  dma_desc_t             rq_dma_req,             // RQ 转换后的 DMA descriptor。

    input  logic                  cqe_dma_req_valid,      // CQE write path 请求有效。
    output logic                  cqe_dma_req_ready,      // dispatcher 可接收 CQE write 请求。
    input  dma_desc_t             cqe_dma_req,            // CQE write descriptor。

    input  logic                  wqe_fetch_req_valid,    // 后续 WQE fetch 请求有效。
    output logic                  wqe_fetch_req_ready,    // dispatcher 可接收 WQE fetch 请求。
    input  dma_desc_t             wqe_fetch_req,          // WQE fetch descriptor。

    input  logic                  sge_fetch_req_valid,    // 后续 SGE fetch 请求有效。
    output logic                  sge_fetch_req_ready,    // dispatcher 可接收 SGE fetch 请求。
    input  dma_desc_t             sge_fetch_req,          // SGE fetch descriptor。

    // ------------------------------------------------------------------
    // Routed outputs
    // ------------------------------------------------------------------
    output logic                  host_read_desc_valid,   // host read 子路径 descriptor 有效。
    input  logic                  host_read_desc_ready,   // host read 子路径可接收。
    output dma_desc_t             host_read_desc,         // host read descriptor。

    output logic                  host_write_desc_valid,  // host write 子路径 descriptor 有效。
    input  logic                  host_write_desc_ready,  // host write 子路径可接收。
    output dma_desc_t             host_write_desc,        // host write descriptor。

    output logic                  cqe_write_desc_valid,   // CQE write 子路径 descriptor 有效。
    input  logic                  cqe_write_desc_ready,   // CQE write 子路径可接收。
    output dma_desc_t             cqe_write_desc,         // CQE write descriptor。

    output logic                  fetch_desc_valid,       // WQE/SGE fetch 子路径 descriptor 有效。
    input  logic                  fetch_desc_ready,       // fetch 子路径可接收。
    output dma_desc_t             fetch_desc,             // fetch descriptor。

    // ------------------------------------------------------------------
    // Error and debug
    // ------------------------------------------------------------------
    output logic                  dma_error_valid,        // descriptor 校验/路由错误有效。
    output logic [15:0]           dma_error_desc_id,      // 出错 descriptor ID。
    output dma_dispatch_error_e   dma_error_code,         // 错误码。
    output dma_dispatch_state_e   debug_state             // 当前 dispatcher 状态。
);

    typedef enum logic [2:0] {
        SRC_NONE      = 3'd0, // 未选择 source。
        SRC_CQE       = 3'd1, // CQE write source。
        SRC_RQ        = 3'd2, // RQ write source。
        SRC_SQ        = 3'd3, // SQ source。
        SRC_WQE_FETCH = 3'd4, // WQE fetch source。
        SRC_SGE_FETCH = 3'd5  // SGE fetch source。
    } dma_source_e;

    typedef enum logic [2:0] {
        ROUTE_NONE       = 3'd0, // 无输出；NOP 或错误使用。
        ROUTE_HOST_READ  = 3'd1, // host read path。
        ROUTE_HOST_WRITE = 3'd2, // host write path。
        ROUTE_CQE_WRITE  = 3'd3, // CQE write path。
        ROUTE_FETCH      = 3'd4  // WQE/SGE fetch path。
    } dma_route_e;

    dma_dispatch_state_e state_reg;
    dma_desc_t desc_reg;
    dma_source_e source_reg;
    dma_route_e route_reg;
    dma_dispatch_error_e error_reg;

    dma_source_e selected_source;
    dma_desc_t selected_desc;
    logic selected_valid;
    logic selected_fire;
    logic owner_function_valid;
    logic desc_length_valid;
    logic opcode_supported;
    logic direction_matches;
    logic output_fire;
    dma_route_e route_next;
    dma_dispatch_error_e validate_error_next;

    assign debug_state = state_reg;
    assign owner_function_valid = (desc_reg.owner_function < VF_ID_W'(SRIOV_FUNCTION_COUNT));
    assign desc_length_valid = (desc_reg.length != '0) || (desc_reg.dma_opcode == DMA_OP_NOP);

    always_comb begin
        selected_source = SRC_NONE;
        selected_desc = '0;
        selected_valid = 1'b0;

        if (cqe_dma_req_valid) begin
            selected_source = SRC_CQE;
            selected_desc = cqe_dma_req;
            selected_valid = 1'b1;
        end else if (rq_dma_req_valid) begin
            selected_source = SRC_RQ;
            selected_desc = rq_dma_req;
            selected_valid = 1'b1;
        end else if (sq_dma_req_valid) begin
            selected_source = SRC_SQ;
            selected_desc = sq_dma_req;
            selected_valid = 1'b1;
        end else if (wqe_fetch_req_valid) begin
            selected_source = SRC_WQE_FETCH;
            selected_desc = wqe_fetch_req;
            selected_valid = 1'b1;
        end else if (sge_fetch_req_valid) begin
            selected_source = SRC_SGE_FETCH;
            selected_desc = sge_fetch_req;
            selected_valid = 1'b1;
        end
    end

    assign selected_fire = (state_reg == DMA_DISP_STATE_IDLE) && selected_valid;

    assign cqe_dma_req_ready = selected_fire && (selected_source == SRC_CQE);
    assign rq_dma_req_ready = selected_fire && (selected_source == SRC_RQ);
    assign sq_dma_req_ready = selected_fire && (selected_source == SRC_SQ);
    assign wqe_fetch_req_ready = selected_fire && (selected_source == SRC_WQE_FETCH);
    assign sge_fetch_req_ready = selected_fire && (selected_source == SRC_SGE_FETCH);

    always_comb begin
        route_next = ROUTE_NONE;
        validate_error_next = DMA_DISP_ERR_NONE;
        opcode_supported = 1'b1;
        direction_matches = 1'b1;

        unique case (desc_reg.dma_opcode)
            DMA_OP_SEND,
            DMA_OP_RDMA_WRITE: begin
                route_next = ROUTE_HOST_READ;
                direction_matches = (desc_reg.direction == DMA_DIR_HOST_READ);
            end

            DMA_OP_RECV,
            DMA_OP_RDMA_READ_RESP: begin
                route_next = ROUTE_HOST_WRITE;
                direction_matches = (desc_reg.direction == DMA_DIR_HOST_WRITE);
            end

            DMA_OP_CQE_WRITE: begin
                route_next = ROUTE_CQE_WRITE;
                direction_matches = (desc_reg.direction == DMA_DIR_CQE_WRITE);
            end

            DMA_OP_WQE_FETCH: begin
                route_next = ROUTE_FETCH;
                direction_matches = (desc_reg.direction == DMA_DIR_WQE_FETCH);
            end

            DMA_OP_SGE_FETCH: begin
                route_next = ROUTE_FETCH;
                direction_matches = (desc_reg.direction == DMA_DIR_SGE_FETCH);
            end

            DMA_OP_RDMA_READ_REQ: begin
                // 7.1 只保留 RDMA Read request descriptor；后续 transport path 接入。
                route_next = ROUTE_NONE;
                direction_matches = (desc_reg.direction == DMA_DIR_HOST_READ);
            end

            DMA_OP_NOP: begin
                route_next = ROUTE_NONE;
                direction_matches = 1'b1;
            end

            default: begin
                route_next = ROUTE_NONE;
                opcode_supported = 1'b0;
            end
        endcase

        if (!opcode_supported || (desc_reg.dma_opcode == DMA_OP_ERROR)) begin
            validate_error_next = DMA_DISP_ERR_UNSUPPORTED;
        end else if (!desc_length_valid) begin
            validate_error_next = DMA_DISP_ERR_LENGTH;
        end else if (!owner_function_valid) begin
            validate_error_next = DMA_DISP_ERR_FUNCTION;
        end else if (!direction_matches) begin
            validate_error_next = DMA_DISP_ERR_DIRECTION;
        end
    end

    assign host_read_desc_valid = (state_reg == DMA_DISP_STATE_WAIT_READY) &&
                                  (route_reg == ROUTE_HOST_READ);
    assign host_read_desc = desc_reg;

    assign host_write_desc_valid = (state_reg == DMA_DISP_STATE_WAIT_READY) &&
                                   (route_reg == ROUTE_HOST_WRITE);
    assign host_write_desc = desc_reg;

    assign cqe_write_desc_valid = (state_reg == DMA_DISP_STATE_WAIT_READY) &&
                                  (route_reg == ROUTE_CQE_WRITE);
    assign cqe_write_desc = desc_reg;

    assign fetch_desc_valid = (state_reg == DMA_DISP_STATE_WAIT_READY) &&
                              (route_reg == ROUTE_FETCH);
    assign fetch_desc = desc_reg;

    assign output_fire = ((route_reg == ROUTE_HOST_READ) && host_read_desc_valid && host_read_desc_ready) ||
                         ((route_reg == ROUTE_HOST_WRITE) && host_write_desc_valid && host_write_desc_ready) ||
                         ((route_reg == ROUTE_CQE_WRITE) && cqe_write_desc_valid && cqe_write_desc_ready) ||
                         ((route_reg == ROUTE_FETCH) && fetch_desc_valid && fetch_desc_ready) ||
                         ((route_reg == ROUTE_NONE) && (state_reg == DMA_DISP_STATE_WAIT_READY));

    assign dma_error_valid = (state_reg == DMA_DISP_STATE_ERROR);
    assign dma_error_desc_id = desc_reg.desc_id;
    assign dma_error_code = error_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= DMA_DISP_STATE_IDLE;
            desc_reg <= '0;
            source_reg <= SRC_NONE;
            route_reg <= ROUTE_NONE;
            error_reg <= DMA_DISP_ERR_NONE;
        end else begin
            unique case (state_reg)
                DMA_DISP_STATE_IDLE: begin
                    error_reg <= DMA_DISP_ERR_NONE;
                    route_reg <= ROUTE_NONE;

                    if (selected_fire) begin
                        desc_reg <= selected_desc;
                        source_reg <= selected_source;
                        state_reg <= DMA_DISP_STATE_SELECT_INPUT;
                    end
                end

                DMA_DISP_STATE_SELECT_INPUT: begin
                    state_reg <= DMA_DISP_STATE_VALIDATE;
                end

                DMA_DISP_STATE_VALIDATE: begin
                    error_reg <= validate_error_next;
                    route_reg <= route_next;
                    if (validate_error_next != DMA_DISP_ERR_NONE) begin
                        state_reg <= DMA_DISP_STATE_ERROR;
                    end else begin
                        state_reg <= DMA_DISP_STATE_ROUTE;
                    end
                end

                DMA_DISP_STATE_ROUTE: begin
                    state_reg <= DMA_DISP_STATE_WAIT_READY;
                end

                DMA_DISP_STATE_WAIT_READY: begin
                    if (output_fire) begin
                        state_reg <= DMA_DISP_STATE_DONE;
                    end
                end

                DMA_DISP_STATE_DONE: begin
                    state_reg <= DMA_DISP_STATE_IDLE;
                    source_reg <= SRC_NONE;
                    route_reg <= ROUTE_NONE;
                end

                DMA_DISP_STATE_ERROR: begin
                    state_reg <= DMA_DISP_STATE_DONE;
                end

                default: begin
                    state_reg <= DMA_DISP_STATE_IDLE;
                end
            endcase
        end
    end

    logic unused_desc_valid;
    assign unused_desc_valid = desc_reg.desc_valid;

endmodule : dma_descriptor_dispatcher
