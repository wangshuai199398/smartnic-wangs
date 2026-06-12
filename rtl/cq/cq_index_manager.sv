// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// CQ producer/consumer index manager 最小实现。
//
// 本模块只计算 CQ ring 的 producer/consumer 下一状态、empty/full/overflow
// 标志和基础错误码。full 判断采用 reserved-one-entry 方案：
// next_producer_index == consumer_index 表示 CQ full，从而避免和 empty
// producer_index == consumer_index 混淆。

`timescale 1ns/1ps

import smartnic_pkg::*;

module cq_index_manager (
    input  logic                         cq_index_req_valid,     // index 计算请求有效。
    input  logic [CQ_ID_W-1:0]           cq_index_req_cqn,       // 请求对应 CQN，当前阶段仅透传/调试预留。
    input  logic [VF_ID_W-1:0]           cq_index_req_owner_function,// 请求所属 function，当前阶段仅透传/调试预留。
    input  logic [QUEUE_IDX_W-1:0]       current_producer_index, // 当前 CQ producer index。
    input  logic [QUEUE_IDX_W-1:0]       current_consumer_index, // 当前 CQ consumer index。
    input  logic [QUEUE_DEPTH_W-1:0]     cq_depth,               // CQ ring 深度。
    input  logic                         current_overflow,       // CQ context 中已保存的 overflow 标志。
    input  logic                         cqe_write_commit,       // 一个 CQE write 已成功提交。
    input  logic                         cq_arm_consumer_update, // CQ arm 提交了新的 consumer index。
    input  logic [QUEUE_IDX_W-1:0]       cq_arm_consumer_index,  // CQ arm 提交的新 consumer index。
    input  logic                         overflow_clear_valid,   // 清除 overflow 标志。

    output logic [QUEUE_IDX_W-1:0]       next_producer_index,    // 下一 producer index。
    output logic [QUEUE_IDX_W-1:0]       next_consumer_index,    // 下一 consumer index。
    output logic                         cq_has_space,           // CQ 当前是否可写入一个 CQE。
    output logic                         cq_empty,               // producer_index == consumer_index。
    output logic                         cq_full,                // reserved slot 方案下 CQ full。
    output logic                         cq_overflow,            // 当前或本次提交导致 overflow。
    output cq_index_error_e              index_error_code        // index 计算错误码。
);

    logic depth_valid;
    logic producer_in_range;
    logic consumer_in_range;
    logic arm_consumer_in_range;
    logic [QUEUE_IDX_W-1:0] producer_plus_one;
    logic [QUEUE_IDX_W-1:0] candidate_consumer_index;
    logic candidate_overflow;

    assign depth_valid = (cq_depth != '0);
    assign producer_in_range = depth_valid && (current_producer_index < cq_depth);
    assign consumer_in_range = depth_valid && (current_consumer_index < cq_depth);
    assign arm_consumer_in_range = !cq_arm_consumer_update ||
                                   (depth_valid && (cq_arm_consumer_index < cq_depth));

    assign producer_plus_one = (!depth_valid || !producer_in_range) ? '0 :
                               ((current_producer_index + 1'b1) == cq_depth) ?
                               '0 : (current_producer_index + 1'b1);
    assign candidate_consumer_index = cq_arm_consumer_update ? cq_arm_consumer_index :
                                      current_consumer_index;

    assign cq_empty = cq_index_req_valid &&
                      depth_valid &&
                      producer_in_range &&
                      consumer_in_range &&
                      (current_producer_index == current_consumer_index);

    assign cq_full = cq_index_req_valid &&
                     depth_valid &&
                     producer_in_range &&
                     consumer_in_range &&
                     (producer_plus_one == current_consumer_index);

    assign candidate_overflow = (current_overflow && !overflow_clear_valid) ||
                                (cqe_write_commit && cq_full);

    always_comb begin
        next_producer_index = current_producer_index;
        next_consumer_index = current_consumer_index;
        cq_has_space = 1'b0;
        cq_overflow = candidate_overflow;
        index_error_code = CQ_INDEX_ERR_NONE;

        if (!cq_index_req_valid) begin
            cq_overflow = current_overflow && !overflow_clear_valid;
        end else if (!depth_valid) begin
            index_error_code = CQ_INDEX_ERR_DEPTH_ZERO;
        end else if (!producer_in_range) begin
            index_error_code = CQ_INDEX_ERR_PROD_RANGE;
        end else if (!consumer_in_range) begin
            index_error_code = CQ_INDEX_ERR_CONS_RANGE;
        end else if (!arm_consumer_in_range) begin
            index_error_code = CQ_INDEX_ERR_ARM_RANGE;
        end else if (cqe_write_commit && cq_full) begin
            index_error_code = CQ_INDEX_ERR_OVERFLOW;
            cq_overflow = 1'b1;
        end

        if (cq_index_req_valid &&
            (index_error_code == CQ_INDEX_ERR_NONE) &&
            arm_consumer_in_range) begin
            next_consumer_index = candidate_consumer_index;
        end

        if (cq_index_req_valid &&
            (index_error_code == CQ_INDEX_ERR_NONE) &&
            cqe_write_commit &&
            !cq_full &&
            !cq_overflow) begin
            next_producer_index = producer_plus_one;
        end

        if (cq_index_req_valid &&
            (index_error_code == CQ_INDEX_ERR_NONE) &&
            !cq_full &&
            !cq_overflow) begin
            cq_has_space = 1'b1;
        end
    end

    // 当前阶段 CQN/function 只作为接口完整性和后续统计预留。
    logic [CQ_ID_W-1:0] unused_cqn;
    logic [VF_ID_W-1:0] unused_owner_function;
    assign unused_cqn = cq_index_req_cqn;
    assign unused_owner_function = cq_index_req_owner_function;

endmodule : cq_index_manager
