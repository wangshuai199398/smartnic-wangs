// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// DMA host memory read path 最小实现。
//
// 本模块接收已经通过 MR 保护检查的 protected segment，为 Send 和 RDMA Write
// payload 生成 PCIe/DMA read 请求，并把 read response 直接转换成 transport
// payload stream。当前阶段不做 host write、PMTU/4KB split、公平仲裁或 CQE 错误传播。

`timescale 1ns/1ps

import smartnic_pkg::*;

module dma_host_read_path (
    input  logic                         clk,                         // host read path 时钟。
    input  logic                         rst_n,                       // 低有效复位。

    // ------------------------------------------------------------------
    // Protected segment input from dma_mr_integration
    // ------------------------------------------------------------------
    input  logic                         protected_segment_valid,      // protected segment 有效。
    output logic                         protected_segment_ready,      // 本模块可接收 protected segment。
    input  logic [15:0]                  protected_segment_desc_id,    // 来源 descriptor ID。
    input  logic [QP_ID_W-1:0]           protected_segment_qpn,        // segment 所属 QPN。
    input  logic [VF_ID_W-1:0]           protected_segment_owner_function, // 所属 function。
    input  logic [PD_ID_W-1:0]           protected_segment_pd_id,      // 已校验 PD。
    input  mr_operation_e                protected_segment_operation,  // 已校验 operation。
    input  logic [DMA_SGE_COUNT_W-1:0]   protected_segment_index,      // segment index。
    input  logic [ADDR_W-1:0]            protected_segment_pa,         // 已翻译 PA。
    input  logic [DMA_LEN_W-1:0]         protected_segment_len,        // segment 长度。
    input  logic [DMA_BYTE_OFFSET_W-1:0] protected_segment_byte_offset,// WR payload 内偏移。
    input  logic                         protected_segment_is_last,    // 是否为 WQE 最后一段。
    input  mr_ref_token_t                protected_segment_mr_refcount_token, // refcount token。
    input  logic [15:0]                  protected_segment_flags,      // segment flags。

    // ------------------------------------------------------------------
    // PCIe/DMA read request
    // ------------------------------------------------------------------
    output logic                         pcie_read_req_valid,          // read request 有效。
    input  logic                         pcie_read_req_ready,          // 下游可接收 read request。
    output logic [ADDR_W-1:0]            pcie_read_req_addr,           // read 地址。
    output logic [15:0]                  pcie_read_req_len,            // read 长度。
    output logic [DMA_READ_TAG_W-1:0]    pcie_read_req_tag,            // read tag。
    output logic [VF_ID_W-1:0]           pcie_read_req_owner_function, // read 所属 function。
    output logic [15:0]                  pcie_read_req_desc_id,        // 关联 descriptor ID。
    output logic [QP_ID_W-1:0]           pcie_read_req_qpn,            // 关联 QPN。
    output logic [DMA_SGE_COUNT_W-1:0]   pcie_read_req_segment_index,  // 关联 segment index。

    // ------------------------------------------------------------------
    // PCIe/DMA read response
    // ------------------------------------------------------------------
    input  logic                         pcie_read_resp_valid,         // read response 有效。
    output logic                         pcie_read_resp_ready,         // 本模块可接收 read response。
    input  logic [DMA_READ_TAG_W-1:0]    pcie_read_resp_tag,           // response tag。
    input  logic [DMA_PAYLOAD_DATA_W-1:0] pcie_read_resp_data,         // response payload data。
    input  logic [15:0]                  pcie_read_resp_len,           // response 有效字节数。
    input  logic                         pcie_read_resp_error,         // response 错误。
    input  logic                         pcie_read_resp_last,          // 当前 response 是否为 read 最后一拍。

    // ------------------------------------------------------------------
    // Payload stream to transport
    // ------------------------------------------------------------------
    output logic                         payload_valid,                // payload stream 有效。
    input  logic                         payload_ready,                // transport 可接收 payload。
    output logic [15:0]                  payload_desc_id,              // 来源 descriptor ID。
    output logic [QP_ID_W-1:0]           payload_qpn,                  // payload 所属 QPN。
    output logic [VF_ID_W-1:0]           payload_owner_function,       // payload 所属 function。
    output mr_operation_e                payload_operation,            // payload operation。
    output logic [DMA_PAYLOAD_DATA_W-1:0] payload_data,                // payload 数据。
    output logic [15:0]                  payload_len,                  // 本拍有效字节数。
    output logic [DMA_BYTE_OFFSET_W-1:0] payload_byte_offset,          // WR payload 内偏移。
    output logic [DMA_SGE_COUNT_W-1:0]   payload_segment_index,        // 来源 segment index。
    output logic                         payload_segment_last,         // 当前 segment 最后一拍。
    output logic                         payload_wqe_last,             // 当前 WQE 最后一拍。
    output dma_host_read_error_e         payload_error_code,           // payload 错误码，正常为 NONE。

    // ------------------------------------------------------------------
    // MR refcount release
    // ------------------------------------------------------------------
    output logic                         mr_ref_dec_valid,             // read 完成或出错后释放 refcount。
    input  logic                         mr_ref_dec_ready,             // 下游可接收 ref_dec。
    output mr_ref_token_t                mr_ref_dec_token,             // 需要释放的 MR/MW token。
    output logic [15:0]                  mr_ref_dec_desc_id,           // 关联 descriptor ID。
    output logic [DMA_SGE_COUNT_W-1:0]   mr_ref_dec_segment_index,     // 关联 segment index。

    // ------------------------------------------------------------------
    // Error output
    // ------------------------------------------------------------------
    output logic                         host_read_error_valid,        // host read path 错误有效。
    input  logic                         host_read_error_ready,        // 下游已接收错误。
    output logic [15:0]                  host_read_error_desc_id,      // 错误 descriptor ID。
    output logic [QP_ID_W-1:0]           host_read_error_qpn,          // 错误 QPN。
    output logic [DMA_SGE_COUNT_W-1:0]   host_read_error_segment_index,// 错误 segment index。
    output dma_host_read_error_e         host_read_error_code,         // host read path 错误码。

    output dma_host_read_state_e         debug_state                   // 调试观察 FSM 状态。
);

    localparam logic [31:0] DMA_HR_TIMEOUT_CYCLES = 32'd1024;

    dma_host_read_state_e state_reg;
    logic [15:0] desc_id_reg;
    logic [QP_ID_W-1:0] qpn_reg;
    logic [VF_ID_W-1:0] owner_function_reg;
    logic [PD_ID_W-1:0] pd_id_reg;
    mr_operation_e operation_reg;
    logic [DMA_SGE_COUNT_W-1:0] segment_index_reg;
    logic [ADDR_W-1:0] base_pa_reg;
    logic [DMA_LEN_W-1:0] segment_len_reg;
    logic [DMA_BYTE_OFFSET_W-1:0] base_byte_offset_reg;
    logic segment_is_last_reg;
    mr_ref_token_t ref_token_reg;
    logic [15:0] segment_flags_reg;

    logic [DMA_LEN_W-1:0] bytes_completed_reg;
    logic [15:0] current_read_len_reg;
    logic [ADDR_W-1:0] current_read_addr_reg;
    logic [DMA_READ_TAG_W-1:0] current_tag_reg;
    logic [6:0] chunk_index_reg;
    logic [31:0] timeout_counter_reg;
    dma_host_read_error_e error_code_reg;

    logic [DMA_PAYLOAD_DATA_W-1:0] payload_data_reg;
    logic [15:0] payload_len_reg;
    logic payload_segment_last_reg;
    logic payload_wqe_last_reg;
    logic [DMA_BYTE_OFFSET_W-1:0] payload_byte_offset_reg;

    logic segment_fire;
    logic req_fire;
    logic resp_fire;
    logic payload_fire;
    logic ref_dec_fire;
    logic error_fire;
    logic [ADDR_W-1:0] segment_end_addr;
    logic segment_addr_overflow;
    logic operation_supported;
    logic [DMA_LEN_W-1:0] remaining_len;
    logic [DMA_LEN_W-1:0] next_bytes_completed;
    logic chunk_is_segment_last;

    assign debug_state = state_reg;
    assign protected_segment_ready = (state_reg == DMA_HR_STATE_IDLE) &&
                                     !payload_valid &&
                                     !host_read_error_valid;
    assign segment_fire = protected_segment_valid && protected_segment_ready;

    assign segment_end_addr = base_pa_reg + ADDR_W'(segment_len_reg);
    assign segment_addr_overflow = (segment_end_addr < base_pa_reg);
    assign remaining_len = segment_len_reg - bytes_completed_reg;
    assign chunk_is_segment_last = (remaining_len <= DMA_LEN_W'(DMA_MAX_READ_BYTES));
    assign next_bytes_completed = bytes_completed_reg + DMA_LEN_W'(current_read_len_reg);

    always_comb begin
        operation_supported = 1'b0;
        unique case (operation_reg)
            MR_OP_LOCAL_DMA_READ: operation_supported = 1'b1;
            default:              operation_supported = 1'b0;
        endcase
    end

    function automatic logic [15:0] calc_chunk_len(input logic [DMA_LEN_W-1:0] remaining);
        begin
            if (remaining > DMA_LEN_W'(DMA_MAX_READ_BYTES)) begin
                return 16'(DMA_MAX_READ_BYTES);
            end
            return 16'(remaining);
        end
    endfunction

    function automatic logic [DMA_READ_TAG_W-1:0] make_read_tag(
        input logic [15:0] desc_id,
        input logic [DMA_SGE_COUNT_W-1:0] segment_index,
        input logic [6:0] chunk_index
    );
        dma_read_tag_t tag;
        begin
            tag.desc_id = desc_id;
            tag.segment_index = segment_index;
            tag.chunk_index = chunk_index;
            return tag;
        end
    endfunction

    assign pcie_read_req_valid = (state_reg == DMA_HR_STATE_ISSUE_READ_REQ);
    assign pcie_read_req_addr = current_read_addr_reg;
    assign pcie_read_req_len = current_read_len_reg;
    assign pcie_read_req_tag = current_tag_reg;
    assign pcie_read_req_owner_function = owner_function_reg;
    assign pcie_read_req_desc_id = desc_id_reg;
    assign pcie_read_req_qpn = qpn_reg;
    assign pcie_read_req_segment_index = segment_index_reg;
    assign req_fire = pcie_read_req_valid && pcie_read_req_ready;

    assign pcie_read_resp_ready = (state_reg == DMA_HR_STATE_WAIT_READ_RESP) &&
                                  !payload_valid;
    assign resp_fire = pcie_read_resp_valid && pcie_read_resp_ready;

    assign payload_desc_id = desc_id_reg;
    assign payload_qpn = qpn_reg;
    assign payload_owner_function = owner_function_reg;
    assign payload_operation = operation_reg;
    assign payload_data = payload_data_reg;
    assign payload_len = payload_len_reg;
    assign payload_byte_offset = payload_byte_offset_reg;
    assign payload_segment_index = segment_index_reg;
    assign payload_segment_last = payload_segment_last_reg;
    assign payload_wqe_last = payload_wqe_last_reg;
    assign payload_error_code = error_code_reg;
    assign payload_fire = payload_valid && payload_ready;

    assign mr_ref_dec_token = ref_token_reg;
    assign mr_ref_dec_desc_id = desc_id_reg;
    assign mr_ref_dec_segment_index = segment_index_reg;
    assign mr_ref_dec_valid = (state_reg == DMA_HR_STATE_RELEASE_REF);
    assign ref_dec_fire = mr_ref_dec_valid && mr_ref_dec_ready;

    assign host_read_error_desc_id = desc_id_reg;
    assign host_read_error_qpn = qpn_reg;
    assign host_read_error_segment_index = segment_index_reg;
    assign host_read_error_code = error_code_reg;
    assign error_fire = host_read_error_valid && host_read_error_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= DMA_HR_STATE_IDLE;
            desc_id_reg <= '0;
            qpn_reg <= '0;
            owner_function_reg <= '0;
            pd_id_reg <= '0;
            operation_reg <= MR_OP_LOCAL_DMA_READ;
            segment_index_reg <= '0;
            base_pa_reg <= '0;
            segment_len_reg <= '0;
            base_byte_offset_reg <= '0;
            segment_is_last_reg <= 1'b0;
            ref_token_reg <= '0;
            segment_flags_reg <= '0;
            bytes_completed_reg <= '0;
            current_read_len_reg <= '0;
            current_read_addr_reg <= '0;
            current_tag_reg <= '0;
            chunk_index_reg <= '0;
            timeout_counter_reg <= '0;
            error_code_reg <= DMA_HR_ERR_NONE;
            payload_valid <= 1'b0;
            payload_data_reg <= '0;
            payload_len_reg <= '0;
            payload_segment_last_reg <= 1'b0;
            payload_wqe_last_reg <= 1'b0;
            payload_byte_offset_reg <= '0;
            host_read_error_valid <= 1'b0;
        end else begin
            unique case (state_reg)
                DMA_HR_STATE_IDLE: begin
                    error_code_reg <= DMA_HR_ERR_NONE;
                    timeout_counter_reg <= '0;
                    if (payload_fire) begin
                        payload_valid <= 1'b0;
                    end
                    if (error_fire) begin
                        host_read_error_valid <= 1'b0;
                    end

                    if (segment_fire) begin
                        desc_id_reg <= protected_segment_desc_id;
                        qpn_reg <= protected_segment_qpn;
                        owner_function_reg <= protected_segment_owner_function;
                        pd_id_reg <= protected_segment_pd_id;
                        operation_reg <= protected_segment_operation;
                        segment_index_reg <= protected_segment_index;
                        base_pa_reg <= protected_segment_pa;
                        segment_len_reg <= protected_segment_len;
                        base_byte_offset_reg <= protected_segment_byte_offset;
                        segment_is_last_reg <= protected_segment_is_last;
                        ref_token_reg <= protected_segment_mr_refcount_token;
                        segment_flags_reg <= protected_segment_flags;
                        bytes_completed_reg <= '0;
                        chunk_index_reg <= '0;
                        state_reg <= DMA_HR_STATE_ACCEPT_SEGMENT;
                    end
                end

                DMA_HR_STATE_ACCEPT_SEGMENT: begin
                    state_reg <= DMA_HR_STATE_VALIDATE;
                end

                DMA_HR_STATE_VALIDATE: begin
                    if (!operation_supported) begin
                        error_code_reg <= DMA_HR_ERR_UNSUPPORTED_OP;
                        state_reg <= DMA_HR_STATE_RELEASE_REF;
                    end else if (segment_len_reg == '0) begin
                        error_code_reg <= DMA_HR_ERR_ZERO_LENGTH;
                        state_reg <= DMA_HR_STATE_RELEASE_REF;
                    end else if (base_pa_reg == '0) begin
                        error_code_reg <= DMA_HR_ERR_ADDR_INVALID;
                        state_reg <= DMA_HR_STATE_RELEASE_REF;
                    end else if (segment_addr_overflow) begin
                        error_code_reg <= DMA_HR_ERR_ADDR_OVERFLOW;
                        state_reg <= DMA_HR_STATE_RELEASE_REF;
                    end else begin
                        current_read_addr_reg <= base_pa_reg;
                        current_read_len_reg <= calc_chunk_len(segment_len_reg);
                        current_tag_reg <= make_read_tag(desc_id_reg, segment_index_reg, '0);
                        timeout_counter_reg <= '0;
                        state_reg <= DMA_HR_STATE_ISSUE_READ_REQ;
                    end
                end

                DMA_HR_STATE_ISSUE_READ_REQ: begin
                    if (req_fire) begin
                        timeout_counter_reg <= '0;
                        state_reg <= DMA_HR_STATE_WAIT_READ_RESP;
                    end else begin
                        timeout_counter_reg <= timeout_counter_reg + 32'd1;
                        if (timeout_counter_reg >= DMA_HR_TIMEOUT_CYCLES) begin
                            error_code_reg <= DMA_HR_ERR_REQ_TIMEOUT;
                            state_reg <= DMA_HR_STATE_RELEASE_REF;
                        end
                    end
                end

                DMA_HR_STATE_WAIT_READ_RESP: begin
                    if (resp_fire) begin
                        if (pcie_read_resp_tag != current_tag_reg) begin
                            error_code_reg <= DMA_HR_ERR_TAG_MISMATCH;
                            state_reg <= DMA_HR_STATE_RELEASE_REF;
                        end else if (pcie_read_resp_error) begin
                            error_code_reg <= DMA_HR_ERR_RESP_ERROR;
                            state_reg <= DMA_HR_STATE_RELEASE_REF;
                        end else if ((pcie_read_resp_len != current_read_len_reg) ||
                                     !pcie_read_resp_last) begin
                            error_code_reg <= DMA_HR_ERR_LEN_MISMATCH;
                            state_reg <= DMA_HR_STATE_RELEASE_REF;
                        end else begin
                            payload_data_reg <= pcie_read_resp_data;
                            payload_len_reg <= pcie_read_resp_len;
                            payload_byte_offset_reg <= base_byte_offset_reg +
                                                       DMA_BYTE_OFFSET_W'(bytes_completed_reg);
                            payload_segment_last_reg <= chunk_is_segment_last;
                            payload_wqe_last_reg <= chunk_is_segment_last &&
                                                    segment_is_last_reg;
                            error_code_reg <= DMA_HR_ERR_NONE;
                            payload_valid <= 1'b1;
                            timeout_counter_reg <= '0;
                            state_reg <= DMA_HR_STATE_EMIT_PAYLOAD;
                        end
                    end
                end

                DMA_HR_STATE_EMIT_PAYLOAD: begin
                    if (payload_fire) begin
                        payload_valid <= 1'b0;
                        bytes_completed_reg <= next_bytes_completed;
                        if (payload_segment_last_reg) begin
                            state_reg <= DMA_HR_STATE_RELEASE_REF;
                        end else begin
                            current_read_addr_reg <= base_pa_reg + ADDR_W'(next_bytes_completed);
                            current_read_len_reg <= calc_chunk_len(segment_len_reg - next_bytes_completed);
                            chunk_index_reg <= chunk_index_reg + 7'd1;
                            current_tag_reg <= make_read_tag(desc_id_reg,
                                                             segment_index_reg,
                                                             chunk_index_reg + 7'd1);
                            timeout_counter_reg <= '0;
                            state_reg <= DMA_HR_STATE_ISSUE_READ_REQ;
                        end
                    end else begin
                        timeout_counter_reg <= timeout_counter_reg + 32'd1;
                        if (timeout_counter_reg >= DMA_HR_TIMEOUT_CYCLES) begin
                            payload_valid <= 1'b0;
                            error_code_reg <= DMA_HR_ERR_PAYLOAD_STALL;
                            state_reg <= DMA_HR_STATE_RELEASE_REF;
                        end
                    end
                end

                DMA_HR_STATE_RELEASE_REF: begin
                    if (ref_dec_fire) begin
                        if (error_code_reg == DMA_HR_ERR_NONE) begin
                            state_reg <= DMA_HR_STATE_DONE;
                        end else begin
                            host_read_error_valid <= 1'b1;
                            state_reg <= DMA_HR_STATE_ERROR;
                        end
                    end
                end

                DMA_HR_STATE_DONE: begin
                    state_reg <= DMA_HR_STATE_IDLE;
                end

                DMA_HR_STATE_ERROR: begin
                    if (error_fire) begin
                        host_read_error_valid <= 1'b0;
                        state_reg <= DMA_HR_STATE_IDLE;
                    end
                end

                default: begin
                    state_reg <= DMA_HR_STATE_IDLE;
                    payload_valid <= 1'b0;
                    host_read_error_valid <= 1'b0;
                    error_code_reg <= DMA_HR_ERR_NONE;
                    timeout_counter_reg <= '0;
                end
            endcase
        end
    end

    // 当前阶段保留 PD 和 flags，后续 transport packetizer 可使用 flags 扩展语义。
    logic unused_inputs;
    assign unused_inputs = ^{pd_id_reg, segment_flags_reg};

endmodule : dma_host_read_path
