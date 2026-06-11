// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// SQ Doorbell payload parser 最小实现。
//
// 本模块只处理 DB_TYPE_SQ Doorbell，解析 payload 并产生 QP SQ producer
// index 更新事件。它不读取 SQ WQE，不执行 RDMA 操作，也不调度 QP。

`timescale 1ns/1ps

import smartnic_pkg::*;

module sq_doorbell_handler (
    input  logic                         clk,                         // SQ Doorbell handler 时钟。
    input  logic                         rst_n,                       // 低有效复位。

    // ------------------------------------------------------------------
    // Doorbell event after decoder and access check
    // ------------------------------------------------------------------
    input  logic                         sq_db_valid,                 // 有一个 Doorbell 事件需要处理。
    output logic                         sq_db_ready,                 // 本模块可接收 Doorbell 事件。
    input  doorbell_type_e               doorbell_type,               // Doorbell 类型；本模块只接受 DB_TYPE_SQ。
    input  logic [QP_ID_W-1:0]           qpn,                         // 目标 QP 编号。
    input  logic [QUEUE_IDX_W-1:0]       queue_index,                 // decoder 从 payload 低位透传的队列索引。
    input  logic [PCIE_BAR_DATA_W-1:0]   raw_payload,                 // BAR0 写入的原始 SQ Doorbell payload。
    input  logic [VF_ID_W-1:0]           owner_function,              // 发起 Doorbell 的 PF/VF function。
    input  logic                         access_allowed,              // 3.2 权限检查是否允许访问。
    input  logic                         access_error,                // 3.2 权限检查是否报告错误。
    input  sriov_access_status_e         access_error_code,           // 3.2 权限检查的错误码，当前阶段只透传为未使用输入。

    // ------------------------------------------------------------------
    // Minimal QP context information
    // ------------------------------------------------------------------
    input  logic                         qpn_valid,                   // QP context 是否有效；后续由 QP manager 提供。
    input  logic [QUEUE_IDX_W-1:0]       current_sq_producer_index,   // 当前已记录的 SQ producer index。

    // ------------------------------------------------------------------
    // QP producer index update event
    // ------------------------------------------------------------------
    output logic                         qp_update_valid,             // QP producer index 更新事件有效。
    input  logic                         qp_update_ready,             // 下游 QP manager 可接收更新事件。
    output logic [QP_ID_W-1:0]           qp_update_qpn,               // 需要更新的 QPN。
    output logic [VF_ID_W-1:0]           qp_update_function_id,       // 该更新所属 PF/VF function。
    output logic [QUEUE_IDX_W-1:0]       qp_update_new_sq_pi,         // 新的 SQ producer index。
    output logic                         qp_update_wraparound,        // new_sq_pi 小于旧值，表示 PI 发生回绕。
    output logic                         qp_update_error,             // 该 Doorbell 是否处理失败。
    output doorbell_error_e              qp_update_error_code,        // Doorbell 处理错误码。
    output logic [DB_SEQUENCE_W-1:0]     qp_update_doorbell_sequence, // 解析出的 Doorbell sequence。
    output logic [DB_FLAGS_W-1:0]        qp_update_flags              // 解析出的 SQ Doorbell flags。
);

    sq_doorbell_payload_t payload;             // 按公共格式解释 raw_payload。
    logic input_fire;                           // 输入 Doorbell 握手成功。
    logic update_fire;                          // 输出更新事件握手成功。
    logic flags_valid;                          // flags 是否只包含当前阶段允许的 bit。
    logic payload_index_matches;                // decoder 透传索引是否与 payload 中 PI 一致。
    logic next_error;                           // 当前 Doorbell 是否应标记为错误。
    doorbell_error_e next_error_code;           // 当前 Doorbell 的错误码。

    assign payload = sq_doorbell_payload_t'(raw_payload);
    assign input_fire = sq_db_valid && sq_db_ready;
    assign update_fire = qp_update_valid && qp_update_ready;
    assign sq_db_ready = !qp_update_valid || qp_update_ready;

    assign flags_valid = ((payload.flags & ~SQ_DB_FLAGS_ALLOWED) == '0);
    assign payload_index_matches = (queue_index == payload.new_sq_producer_index);

    always_comb begin
        next_error = 1'b0;
        next_error_code = DB_ERR_NONE;

        if (doorbell_type != DB_TYPE_SQ) begin
            next_error = 1'b1;
            next_error_code = DB_ERR_NOT_SQ;
        end else if (!access_allowed || access_error) begin
            next_error = 1'b1;
            next_error_code = DB_ERR_ACCESS_DENIED;
        end else if (!qpn_valid) begin
            next_error = 1'b1;
            next_error_code = DB_ERR_INVALID_QPN;
        end else if (!flags_valid || !payload_index_matches) begin
            next_error = 1'b1;
            next_error_code = DB_ERR_BAD_PAYLOAD;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            qp_update_valid <= 1'b0;
            qp_update_qpn <= '0;
            qp_update_function_id <= '0;
            qp_update_new_sq_pi <= '0;
            qp_update_wraparound <= 1'b0;
            qp_update_error <= 1'b0;
            qp_update_error_code <= DB_ERR_NONE;
            qp_update_doorbell_sequence <= '0;
            qp_update_flags <= '0;
        end else begin
            if (update_fire) begin
                qp_update_valid <= 1'b0;
            end

            if (input_fire) begin
                qp_update_valid <= 1'b1;
                qp_update_qpn <= qpn;
                qp_update_function_id <= owner_function;
                qp_update_new_sq_pi <= payload.new_sq_producer_index;
                qp_update_wraparound <= (payload.new_sq_producer_index < current_sq_producer_index);
                qp_update_error <= next_error;
                qp_update_error_code <= next_error_code;
                qp_update_doorbell_sequence <= payload.doorbell_sequence;
                qp_update_flags <= payload.flags;
            end
        end
    end

    // 当前阶段只需要知道权限是否失败，不细分 SR-IOV 错误码；保留输入便于后续统计。
    sriov_access_status_e unused_access_error_code;
    assign unused_access_error_code = access_error_code;

endmodule : sq_doorbell_handler
