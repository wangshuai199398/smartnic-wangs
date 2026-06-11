// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// CQ arm Doorbell payload parser 最小实现。
//
// 本模块只处理 DB_TYPE_CQ_ARM Doorbell，解析 consumer index 和
// solicited-only 标志，并产生 CQ arm 更新事件。它不生成 CQE，不触发
// 真实 MSI-X 中断，也不实现 completion 写回。

`timescale 1ns/1ps

import smartnic_pkg::*;

module cq_arm_doorbell_handler (
    input  logic                         clk,                    // CQ arm Doorbell handler 时钟。
    input  logic                         rst_n,                  // 低有效复位。

    // ------------------------------------------------------------------
    // Doorbell event after decoder and access check
    // ------------------------------------------------------------------
    input  logic                         cq_db_valid,            // 有一个 Doorbell 事件需要处理。
    output logic                         cq_db_ready,            // 本模块可接收 Doorbell 事件。
    input  doorbell_type_e               doorbell_type,          // Doorbell 类型；本模块只接受 DB_TYPE_CQ_ARM。
    input  logic [CQ_ID_W-1:0]           cqn,                    // 目标 CQ 编号。
    input  logic [QUEUE_IDX_W-1:0]       queue_index,            // decoder 从 payload 低位透传的 consumer index。
    input  logic [PCIE_BAR_DATA_W-1:0]   raw_payload,            // BAR0 写入的原始 CQ arm Doorbell payload。
    input  logic [VF_ID_W-1:0]           owner_function,         // 发起 Doorbell 的 PF/VF function。
    input  logic                         access_allowed,         // 3.2 权限检查是否允许访问。
    input  logic                         access_error,           // 3.2 权限检查是否报告错误。
    input  sriov_access_status_e         access_error_code,      // 3.2 权限检查的错误码，当前阶段只透传为未使用输入。

    // ------------------------------------------------------------------
    // Minimal CQ context information
    // ------------------------------------------------------------------
    input  logic                         cqn_valid,              // CQ context 是否有效；后续由 CQ manager 提供。

    // ------------------------------------------------------------------
    // CQ arm update event
    // ------------------------------------------------------------------
    output logic                         cq_arm_valid,           // CQ arm 更新事件有效。
    input  logic                         cq_arm_ready,           // 下游 CQ manager 可接收更新事件。
    output logic [CQ_ID_W-1:0]           cq_arm_cqn,             // 需要 arm 的 CQN。
    output logic [VF_ID_W-1:0]           cq_arm_function_id,     // 该更新所属 PF/VF function。
    output logic [QUEUE_IDX_W-1:0]       cq_arm_consumer_index,  // 软件提交的 CQ consumer index。
    output logic                         cq_arm_solicited_only,  // 只对 solicited completion 触发通知。
    output logic                         cq_arm_armed,           // 置 1 表示 CQ 进入 armed 状态。
    output logic                         cq_arm_error,           // 该 Doorbell 是否处理失败。
    output doorbell_error_e              cq_arm_error_code,      // Doorbell 处理错误码。
    output logic [DB_SEQUENCE_W-1:0]     cq_arm_sequence,        // 解析出的 arm sequence。
    output logic [DB_FLAGS_W-1:0]        cq_arm_flags            // 解析出的 CQ arm flags。
);

    cq_arm_doorbell_payload_t payload;   // 按公共格式解释 raw_payload。
    logic input_fire;                    // 输入 Doorbell 握手成功。
    logic update_fire;                   // 输出 arm 事件握手成功。
    logic flags_valid;                   // flags 是否只包含当前阶段允许的 bit。
    logic payload_index_matches;         // decoder 透传索引是否与 payload 中 consumer index 一致。
    logic next_error;                    // 当前 Doorbell 是否应标记为错误。
    doorbell_error_e next_error_code;    // 当前 Doorbell 的错误码。

    assign payload = cq_arm_doorbell_payload_t'(raw_payload);
    assign input_fire = cq_db_valid && cq_db_ready;
    assign update_fire = cq_arm_valid && cq_arm_ready;
    assign cq_db_ready = !cq_arm_valid || cq_arm_ready;

    assign flags_valid = ((payload.flags & ~CQ_ARM_DB_FLAGS_ALLOWED) == '0);
    assign payload_index_matches = (queue_index == payload.consumer_index);

    always_comb begin
        next_error = 1'b0;
        next_error_code = DB_ERR_NONE;

        if (doorbell_type != DB_TYPE_CQ_ARM) begin
            next_error = 1'b1;
            next_error_code = DB_ERR_NOT_CQ_ARM;
        end else if (!access_allowed || access_error) begin
            next_error = 1'b1;
            next_error_code = DB_ERR_ACCESS_DENIED;
        end else if (!cqn_valid) begin
            next_error = 1'b1;
            next_error_code = DB_ERR_INVALID_CQN;
        end else if (!flags_valid || !payload_index_matches) begin
            next_error = 1'b1;
            next_error_code = DB_ERR_BAD_PAYLOAD;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cq_arm_valid <= 1'b0;
            cq_arm_cqn <= '0;
            cq_arm_function_id <= '0;
            cq_arm_consumer_index <= '0;
            cq_arm_solicited_only <= 1'b0;
            cq_arm_armed <= 1'b0;
            cq_arm_error <= 1'b0;
            cq_arm_error_code <= DB_ERR_NONE;
            cq_arm_sequence <= '0;
            cq_arm_flags <= '0;
        end else begin
            if (update_fire) begin
                cq_arm_valid <= 1'b0;
            end

            if (input_fire) begin
                cq_arm_valid <= 1'b1;
                cq_arm_cqn <= cqn;
                cq_arm_function_id <= owner_function;
                cq_arm_consumer_index <= payload.consumer_index;
                cq_arm_solicited_only <= |(payload.flags & CQ_ARM_DB_FLAG_SOLICITED_ONLY);
                cq_arm_armed <= !next_error;
                cq_arm_error <= next_error;
                cq_arm_error_code <= next_error_code;
                cq_arm_sequence <= payload.arm_sequence;
                cq_arm_flags <= payload.flags;
            end
        end
    end

    // 当前阶段只需要知道权限是否失败，不细分 SR-IOV 错误码；保留输入便于后续统计。
    sriov_access_status_e unused_access_error_code;
    assign unused_access_error_code = access_error_code;

endmodule : cq_arm_doorbell_handler
