// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// DMA host memory write path 最小实现。
//
// 本模块接收已经通过 MR 保护检查的 protected segment，以及来自 RQ/transport
// 的 payload stream，为 Recv buffer write 和 RDMA Read response delivery 生成
// PCIe/DMA write request。当前阶段不做 PMTU/4KB split、公平仲裁或 completion error propagation。

`timescale 1ns/1ps

import smartnic_pkg::*;

module dma_host_write_path (
    input  logic                         clk,                         // host write path 时钟。
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
    // Payload input from transport/RQ
    // ------------------------------------------------------------------
    input  logic                         write_payload_valid,          // payload 有效。
    output logic                         write_payload_ready,          // 本模块可接收 payload。
    input  logic [15:0]                  write_payload_desc_id,        // payload 关联 descriptor ID。
    input  logic [QP_ID_W-1:0]           write_payload_qpn,            // payload 关联 QPN。
    input  logic [VF_ID_W-1:0]           write_payload_owner_function, // payload 所属 function。
    input  mr_operation_e                write_payload_operation,      // payload operation。
    input  logic [DMA_PAYLOAD_DATA_W-1:0] write_payload_data,          // payload 数据。
    input  logic [15:0]                  write_payload_len,            // payload 有效字节数。
    input  logic [DMA_BYTE_OFFSET_W-1:0] write_payload_byte_offset,    // WR payload 内偏移。
    input  logic                         write_payload_last,           // 当前 payload 是否为最后一拍。
    input  logic                         write_payload_error,          // 上游 payload 已出错。

    // ------------------------------------------------------------------
    // PCIe/DMA write request
    // ------------------------------------------------------------------
    output logic                         pcie_write_req_valid,         // write request 有效。
    input  logic                         pcie_write_req_ready,         // 下游可接收 write request。
    output logic [ADDR_W-1:0]            pcie_write_req_addr,          // write 地址。
    output logic [DMA_PAYLOAD_DATA_W-1:0] pcie_write_req_data,         // write 数据。
    output logic [15:0]                  pcie_write_req_len,           // write 有效字节数。
    output logic [DMA_PAYLOAD_KEEP_W-1:0] pcie_write_req_byte_enable,  // write byte enable。
    output logic [DMA_WRITE_TAG_W-1:0]   pcie_write_req_tag,           // write tag。
    output logic [VF_ID_W-1:0]           pcie_write_req_owner_function,// write 所属 function。
    output logic [15:0]                  pcie_write_req_desc_id,       // 关联 descriptor ID。
    output logic [QP_ID_W-1:0]           pcie_write_req_qpn,           // 关联 QPN。
    output logic [DMA_SGE_COUNT_W-1:0]   pcie_write_req_segment_index, // 关联 segment index。

    // ------------------------------------------------------------------
    // PCIe/DMA write completion
    // ------------------------------------------------------------------
    input  logic                         pcie_write_cpl_valid,         // write completion 有效。
    output logic                         pcie_write_cpl_ready,         // 本模块可接收 completion。
    input  logic [DMA_WRITE_TAG_W-1:0]   pcie_write_cpl_tag,           // completion tag。
    input  logic [1:0]                   pcie_write_cpl_status,        // completion status，0 表示成功。
    input  logic                         pcie_write_cpl_error,         // completion 错误。

    // ------------------------------------------------------------------
    // Write done / completion event seed
    // ------------------------------------------------------------------
    output logic                         write_done_valid,             // write done 有效。
    input  logic                         write_done_ready,             // 下游可接收 write done。
    output logic [15:0]                  write_done_desc_id,           // descriptor ID。
    output logic [QP_ID_W-1:0]           write_done_qpn,               // QPN。
    output logic [VF_ID_W-1:0]           write_done_owner_function,    // owner function。
    output mr_operation_e                write_done_operation,         // operation。
    output logic [1:0]                   write_done_status,            // 0 成功，非 0 预留。
    output dma_host_write_error_e        write_done_error_code,        // write path 错误码。
    output logic [DMA_LEN_W-1:0]         write_done_byte_len,          // 已写入字节数。
    output logic                         write_done_last,              // 是否为该 WQE/WR 的最后 write。
    output logic [DMA_SGE_COUNT_W-1:0]   write_done_segment_index,     // segment index。

    // ------------------------------------------------------------------
    // MR refcount release
    // ------------------------------------------------------------------
    output logic                         mr_ref_dec_valid,             // segment 完成或出错后释放 refcount。
    input  logic                         mr_ref_dec_ready,             // 下游可接收 ref_dec。
    output mr_ref_token_t                mr_ref_dec_token,             // 需要释放的 MR/MW token。
    output logic [15:0]                  mr_ref_dec_desc_id,           // descriptor ID。
    output logic [DMA_SGE_COUNT_W-1:0]   mr_ref_dec_segment_index,     // segment index。

    // ------------------------------------------------------------------
    // Error output
    // ------------------------------------------------------------------
    output logic                         host_write_error_valid,       // host write path 错误有效。
    input  logic                         host_write_error_ready,       // 下游已接收错误。
    output logic [15:0]                  host_write_error_desc_id,     // 错误 descriptor ID。
    output logic [QP_ID_W-1:0]           host_write_error_qpn,         // 错误 QPN。
    output logic [DMA_SGE_COUNT_W-1:0]   host_write_error_segment_index,// 错误 segment index。
    output dma_host_write_error_e        host_write_error_code,        // host write path 错误码。

    output dma_host_write_state_e        debug_state                   // 调试观察 FSM 状态。
);

    localparam logic [31:0] DMA_HW_TIMEOUT_CYCLES = 32'd1024;

    dma_host_write_state_e state_reg;
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

    logic [DMA_PAYLOAD_DATA_W-1:0] payload_data_reg;
    logic [15:0] payload_len_reg;
    logic [DMA_BYTE_OFFSET_W-1:0] payload_byte_offset_reg;
    logic payload_last_reg;
    logic [15:0] payload_desc_id_reg;
    logic [QP_ID_W-1:0] payload_qpn_reg;
    logic [VF_ID_W-1:0] payload_owner_function_reg;
    mr_operation_e payload_operation_reg;
    logic payload_error_reg;
    logic [DMA_LEN_W-1:0] bytes_written_reg;
    logic [ADDR_W-1:0] current_write_addr_reg;
    logic [DMA_WRITE_TAG_W-1:0] current_tag_reg;
    logic [6:0] beat_index_reg;
    logic [31:0] timeout_counter_reg;
    dma_host_write_error_e error_code_reg;

    logic segment_fire;
    logic payload_fire;
    logic req_fire;
    logic cpl_fire;
    logic done_fire;
    logic ref_dec_fire;
    logic error_fire;
    logic operation_supported;
    logic payload_matches_segment;
    logic [DMA_BYTE_OFFSET_W-1:0] payload_offset_in_segment;
    logic payload_before_segment;
    logic [DMA_LEN_W-1:0] payload_end_offset;
    logic payload_bounds_error;
    logic [ADDR_W-1:0] write_addr_next;
    logic [ADDR_W-1:0] write_end_addr_next;
    logic write_addr_overflow;
    logic beat_too_large;
    logic segment_complete_after_payload;

    assign debug_state = state_reg;
    assign protected_segment_ready = (state_reg == DMA_HW_STATE_IDLE) &&
                                     !write_done_valid &&
                                     !host_write_error_valid;
    assign segment_fire = protected_segment_valid && protected_segment_ready;

    assign write_payload_ready = (state_reg == DMA_HW_STATE_WAIT_PAYLOAD);
    assign payload_fire = write_payload_valid && write_payload_ready;

    always_comb begin
        operation_supported = 1'b0;
        unique case (operation_reg)
            MR_OP_LOCAL_DMA_WRITE,
            MR_OP_LOCAL_RECV_WRITE,
            MR_OP_REMOTE_RDMA_WRITE: operation_supported = 1'b1;
            default:                 operation_supported = 1'b0;
        endcase
    end

    assign payload_matches_segment = (payload_desc_id_reg == desc_id_reg) &&
                                     (payload_qpn_reg == qpn_reg) &&
                                     (payload_owner_function_reg == owner_function_reg) &&
                                     (payload_operation_reg == operation_reg);
    assign payload_before_segment = (payload_byte_offset_reg < base_byte_offset_reg);
    assign payload_offset_in_segment = payload_byte_offset_reg - base_byte_offset_reg;
    assign payload_end_offset = DMA_LEN_W'(payload_offset_in_segment) +
                                DMA_LEN_W'(payload_len_reg);
    assign payload_bounds_error = payload_before_segment ||
                                  (payload_end_offset > segment_len_reg);
    assign write_addr_next = base_pa_reg + ADDR_W'(payload_offset_in_segment);
    assign write_end_addr_next = write_addr_next + ADDR_W'(payload_len_reg);
    assign write_addr_overflow = (write_addr_next < base_pa_reg) ||
                                 (write_end_addr_next < write_addr_next);
    assign beat_too_large = (payload_len_reg > 16'(DMA_MAX_WRITE_BYTES)) ||
                            ((write_addr_next[$clog2(DMA_MAX_WRITE_BYTES)-1:0] +
                              payload_len_reg) > 16'(DMA_MAX_WRITE_BYTES));
    assign segment_complete_after_payload = (payload_end_offset >= segment_len_reg) ||
                                            payload_last_reg;

    function automatic logic [DMA_WRITE_TAG_W-1:0] make_write_tag(
        input logic [15:0] desc_id,
        input logic [DMA_SGE_COUNT_W-1:0] segment_index,
        input logic [6:0] beat_index
    );
        dma_write_tag_t tag;
        begin
            tag.desc_id = desc_id;
            tag.segment_index = segment_index;
            tag.beat_index = beat_index;
            return tag;
        end
    endfunction

    function automatic logic [DMA_PAYLOAD_KEEP_W-1:0] make_byte_enable(
        input logic [$clog2(DMA_MAX_WRITE_BYTES)-1:0] addr_low,
        input logic [15:0] len
    );
        logic [DMA_PAYLOAD_KEEP_W-1:0] mask;
        begin
            mask = '0;
            for (int i = 0; i < DMA_PAYLOAD_KEEP_W; i++) begin
                if ((i >= addr_low) && (i < (addr_low + len))) begin
                    mask[i] = 1'b1;
                end
            end
            return mask;
        end
    endfunction

    assign pcie_write_req_valid = (state_reg == DMA_HW_STATE_ISSUE_WRITE_REQ);
    assign pcie_write_req_addr = current_write_addr_reg;
    assign pcie_write_req_data = payload_data_reg;
    assign pcie_write_req_len = payload_len_reg;
    assign pcie_write_req_byte_enable = make_byte_enable(current_write_addr_reg[$clog2(DMA_MAX_WRITE_BYTES)-1:0],
                                                         payload_len_reg);
    assign pcie_write_req_tag = current_tag_reg;
    assign pcie_write_req_owner_function = owner_function_reg;
    assign pcie_write_req_desc_id = desc_id_reg;
    assign pcie_write_req_qpn = qpn_reg;
    assign pcie_write_req_segment_index = segment_index_reg;
    assign req_fire = pcie_write_req_valid && pcie_write_req_ready;

    assign pcie_write_cpl_ready = (state_reg == DMA_HW_STATE_WAIT_WRITE_CPL);
    assign cpl_fire = pcie_write_cpl_valid && pcie_write_cpl_ready;

    assign write_done_desc_id = desc_id_reg;
    assign write_done_qpn = qpn_reg;
    assign write_done_owner_function = owner_function_reg;
    assign write_done_operation = operation_reg;
    assign write_done_status = (error_code_reg == DMA_HW_ERR_NONE) ? 2'd0 : 2'd1;
    assign write_done_error_code = error_code_reg;
    assign write_done_byte_len = bytes_written_reg + DMA_LEN_W'(payload_len_reg);
    assign write_done_last = segment_complete_after_payload && segment_is_last_reg;
    assign write_done_segment_index = segment_index_reg;
    assign done_fire = write_done_valid && write_done_ready;

    assign mr_ref_dec_token = ref_token_reg;
    assign mr_ref_dec_desc_id = desc_id_reg;
    assign mr_ref_dec_segment_index = segment_index_reg;
    assign mr_ref_dec_valid = (state_reg == DMA_HW_STATE_RELEASE_REF);
    assign ref_dec_fire = mr_ref_dec_valid && mr_ref_dec_ready;

    assign host_write_error_desc_id = desc_id_reg;
    assign host_write_error_qpn = qpn_reg;
    assign host_write_error_segment_index = segment_index_reg;
    assign host_write_error_code = error_code_reg;
    assign error_fire = host_write_error_valid && host_write_error_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= DMA_HW_STATE_IDLE;
            desc_id_reg <= '0;
            qpn_reg <= '0;
            owner_function_reg <= '0;
            pd_id_reg <= '0;
            operation_reg <= MR_OP_LOCAL_RECV_WRITE;
            segment_index_reg <= '0;
            base_pa_reg <= '0;
            segment_len_reg <= '0;
            base_byte_offset_reg <= '0;
            segment_is_last_reg <= 1'b0;
            ref_token_reg <= '0;
            segment_flags_reg <= '0;
            payload_data_reg <= '0;
            payload_len_reg <= '0;
            payload_byte_offset_reg <= '0;
            payload_last_reg <= 1'b0;
            payload_desc_id_reg <= '0;
            payload_qpn_reg <= '0;
            payload_owner_function_reg <= '0;
            payload_operation_reg <= MR_OP_LOCAL_RECV_WRITE;
            payload_error_reg <= 1'b0;
            bytes_written_reg <= '0;
            current_write_addr_reg <= '0;
            current_tag_reg <= '0;
            beat_index_reg <= '0;
            timeout_counter_reg <= '0;
            error_code_reg <= DMA_HW_ERR_NONE;
            write_done_valid <= 1'b0;
            host_write_error_valid <= 1'b0;
        end else begin
            unique case (state_reg)
                DMA_HW_STATE_IDLE: begin
                    error_code_reg <= DMA_HW_ERR_NONE;
                    timeout_counter_reg <= '0;
                    if (done_fire) begin
                        write_done_valid <= 1'b0;
                    end
                    if (error_fire) begin
                        host_write_error_valid <= 1'b0;
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
                        bytes_written_reg <= '0;
                        beat_index_reg <= '0;
                        state_reg <= DMA_HW_STATE_ACCEPT_SEGMENT;
                    end
                end

                DMA_HW_STATE_ACCEPT_SEGMENT: begin
                    if (!operation_supported) begin
                        error_code_reg <= DMA_HW_ERR_UNSUPPORTED_OP;
                        state_reg <= DMA_HW_STATE_RELEASE_REF;
                    end else if (segment_len_reg == '0) begin
                        error_code_reg <= DMA_HW_ERR_ZERO_SEGMENT_LEN;
                        state_reg <= DMA_HW_STATE_RELEASE_REF;
                    end else begin
                        state_reg <= DMA_HW_STATE_WAIT_PAYLOAD;
                    end
                end

                DMA_HW_STATE_WAIT_PAYLOAD: begin
                    if (payload_fire) begin
                        payload_data_reg <= write_payload_data;
                        payload_len_reg <= write_payload_len;
                        payload_byte_offset_reg <= write_payload_byte_offset;
                        payload_last_reg <= write_payload_last;
                        payload_desc_id_reg <= write_payload_desc_id;
                        payload_qpn_reg <= write_payload_qpn;
                        payload_owner_function_reg <= write_payload_owner_function;
                        payload_operation_reg <= write_payload_operation;
                        payload_error_reg <= write_payload_error;
                        state_reg <= DMA_HW_STATE_VALIDATE_WRITE;
                    end
                end

                DMA_HW_STATE_VALIDATE_WRITE: begin
                    if (payload_error_reg) begin
                        error_code_reg <= DMA_HW_ERR_PAYLOAD_ERROR;
                        state_reg <= DMA_HW_STATE_RELEASE_REF;
                    end else if (!payload_matches_segment) begin
                        error_code_reg <= DMA_HW_ERR_PAYLOAD_MISMATCH;
                        state_reg <= DMA_HW_STATE_RELEASE_REF;
                    end else if (payload_len_reg == '0) begin
                        error_code_reg <= DMA_HW_ERR_ZERO_PAYLOAD_LEN;
                        state_reg <= DMA_HW_STATE_RELEASE_REF;
                    end else if (payload_bounds_error || beat_too_large) begin
                        error_code_reg <= DMA_HW_ERR_BOUNDS;
                        state_reg <= DMA_HW_STATE_RELEASE_REF;
                    end else if (write_addr_overflow) begin
                        error_code_reg <= DMA_HW_ERR_ADDR_OVERFLOW;
                        state_reg <= DMA_HW_STATE_RELEASE_REF;
                    end else begin
                        current_write_addr_reg <= write_addr_next;
                        current_tag_reg <= make_write_tag(desc_id_reg, segment_index_reg, beat_index_reg);
                        timeout_counter_reg <= '0;
                        state_reg <= DMA_HW_STATE_ISSUE_WRITE_REQ;
                    end
                end

                DMA_HW_STATE_ISSUE_WRITE_REQ: begin
                    if (req_fire) begin
                        timeout_counter_reg <= '0;
                        state_reg <= DMA_HW_STATE_WAIT_WRITE_CPL;
                    end else begin
                        timeout_counter_reg <= timeout_counter_reg + 32'd1;
                        if (timeout_counter_reg >= DMA_HW_TIMEOUT_CYCLES) begin
                            error_code_reg <= DMA_HW_ERR_REQ_TIMEOUT;
                            state_reg <= DMA_HW_STATE_RELEASE_REF;
                        end
                    end
                end

                DMA_HW_STATE_WAIT_WRITE_CPL: begin
                    if (cpl_fire) begin
                        if (pcie_write_cpl_tag != current_tag_reg) begin
                            error_code_reg <= DMA_HW_ERR_TAG_MISMATCH;
                            state_reg <= DMA_HW_STATE_RELEASE_REF;
                        end else if (pcie_write_cpl_error || (pcie_write_cpl_status != 2'd0)) begin
                            error_code_reg <= DMA_HW_ERR_CPL_ERROR;
                            state_reg <= DMA_HW_STATE_RELEASE_REF;
                        end else begin
                            error_code_reg <= DMA_HW_ERR_NONE;
                            write_done_valid <= 1'b1;
                            state_reg <= DMA_HW_STATE_EMIT_DONE;
                        end
                    end
                end

                DMA_HW_STATE_EMIT_DONE: begin
                    if (done_fire) begin
                        write_done_valid <= 1'b0;
                        bytes_written_reg <= bytes_written_reg + DMA_LEN_W'(payload_len_reg);
                        if (segment_complete_after_payload) begin
                            state_reg <= DMA_HW_STATE_RELEASE_REF;
                        end else begin
                            beat_index_reg <= beat_index_reg + 7'd1;
                            state_reg <= DMA_HW_STATE_WAIT_PAYLOAD;
                        end
                    end
                end

                DMA_HW_STATE_RELEASE_REF: begin
                    if (ref_dec_fire) begin
                        if (error_code_reg == DMA_HW_ERR_NONE) begin
                            state_reg <= DMA_HW_STATE_DONE;
                        end else begin
                            host_write_error_valid <= 1'b1;
                            state_reg <= DMA_HW_STATE_ERROR;
                        end
                    end
                end

                DMA_HW_STATE_DONE: begin
                    state_reg <= DMA_HW_STATE_IDLE;
                end

                DMA_HW_STATE_ERROR: begin
                    if (error_fire) begin
                        host_write_error_valid <= 1'b0;
                        state_reg <= DMA_HW_STATE_IDLE;
                    end
                end

                default: begin
                    state_reg <= DMA_HW_STATE_IDLE;
                    write_done_valid <= 1'b0;
                    host_write_error_valid <= 1'b0;
                    error_code_reg <= DMA_HW_ERR_NONE;
                    timeout_counter_reg <= '0;
                end
            endcase
        end
    end

    // 当前阶段保留 PD 和 flags，后续 completion/error path 可消费。
    logic unused_inputs;
    assign unused_inputs = ^{pd_id_reg, segment_flags_reg};

endmodule : dma_host_write_path
