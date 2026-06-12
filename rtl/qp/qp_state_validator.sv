// SPDX-License-Identifier: MIT
// Copyright (c) 2026
//
// QP 状态迁移校验器。
//
// 本模块只实现 4.3 阶段需要的基础 IBTA 风格状态迁移表和必需属性 mask
// 检查。它不检查真实 CQ/PD/AH 是否存在，不处理路径迁移，也不执行 retry
// 逻辑；这些内容会在后续 QP/CQ/MR/transport 阶段继续补充。

`timescale 1ns/1ps

import smartnic_pkg::*;

module qp_state_validator (
    input  logic                         validate_valid,      // 状态迁移校验请求有效。
    input  qp_state_e                    current_state,       // 当前 QP state。
    input  qp_state_e                    requested_state,     // 请求切换到的 QP state。
    input  qp_type_e                     qp_type,             // QP 类型，当前区分 RC/UD 的属性需求。
    input  logic [31:0]                  modify_mask,         // 本次 MODIFY_QP 携带的字段 mask。
    output logic                         validate_allowed,    // 1 表示迁移合法且属性齐备。
    output qp_state_validate_error_e     validate_error_code, // 状态迁移校验错误码。
    output logic [31:0]                  required_attr_mask,   // 当前迁移需要的属性集合。
    output logic [31:0]                  missing_attr_mask     // modify_mask 中缺失的必需属性集合。
);

    logic transition_allowed;     // 只看状态图时，该迁移是否允许。
    logic [31:0] provided_attrs;  // 从 modify_mask 映射得到的属性集合。

    always_comb begin
        provided_attrs = 32'h0000_0000;

        if ((modify_mask & QP_MOD_MASK_PD) != 32'h0) begin
            provided_attrs |= QP_ATTR_MASK_PD;
        end
        if ((modify_mask & QP_MOD_MASK_CQ) != 32'h0) begin
            provided_attrs |= QP_ATTR_MASK_CQ;
        end
        if ((modify_mask & QP_MOD_MASK_QUEUE_ADDR) != 32'h0) begin
            provided_attrs |= QP_ATTR_MASK_QUEUE_ADDR;
        end
        if ((modify_mask & QP_MOD_MASK_QUEUE_DEPTH) != 32'h0) begin
            provided_attrs |= QP_ATTR_MASK_QUEUE_DEPTH;
        end
        if ((modify_mask & QP_MOD_MASK_REMOTE_QPN) != 32'h0) begin
            provided_attrs |= QP_ATTR_MASK_REMOTE_QPN;
        end
        if ((modify_mask & QP_MOD_MASK_PSN) != 32'h0) begin
            provided_attrs |= QP_ATTR_MASK_RQ_PSN;
            provided_attrs |= QP_ATTR_MASK_SQ_PSN;
        end
        if ((modify_mask & QP_MOD_MASK_AH) != 32'h0) begin
            provided_attrs |= QP_ATTR_MASK_AH;
        end
        if ((modify_mask & QP_MOD_MASK_RETRY) != 32'h0) begin
            provided_attrs |= QP_ATTR_MASK_RETRY;
        end
    end

    always_comb begin
        transition_allowed = 1'b0;

        if (current_state == requested_state) begin
            transition_allowed = 1'b1;
        end else if (requested_state == QP_STATE_ERR) begin
            transition_allowed = 1'b1;
        end else begin
            unique case (current_state)
                QP_STATE_RESET: begin
                    transition_allowed = (requested_state == QP_STATE_INIT) ||
                                         (requested_state == QP_STATE_RESET);
                end
                QP_STATE_INIT: begin
                    transition_allowed = (requested_state == QP_STATE_RTR);
                end
                QP_STATE_RTR: begin
                    transition_allowed = (requested_state == QP_STATE_RTS);
                end
                QP_STATE_RTS: begin
                    transition_allowed = (requested_state == QP_STATE_SQD) ||
                                         (requested_state == QP_STATE_SQE);
                end
                QP_STATE_SQD: begin
                    transition_allowed = (requested_state == QP_STATE_RTS);
                end
                QP_STATE_SQE: begin
                    transition_allowed = (requested_state == QP_STATE_RTS);
                end
                QP_STATE_ERR: begin
                    transition_allowed = (requested_state == QP_STATE_RESET);
                end
                default: begin
                    transition_allowed = 1'b0;
                end
            endcase
        end
    end

    always_comb begin
        required_attr_mask = 32'h0000_0000;

        if (current_state == QP_STATE_RESET && requested_state == QP_STATE_INIT) begin
            required_attr_mask = QP_ATTR_MASK_PD |
                                 QP_ATTR_MASK_CQ |
                                 QP_ATTR_MASK_QUEUE_ADDR |
                                 QP_ATTR_MASK_QUEUE_DEPTH;
        end else if (current_state == QP_STATE_INIT && requested_state == QP_STATE_RTR) begin
            unique case (qp_type)
                QP_TYPE_RC: begin
                    required_attr_mask = QP_ATTR_MASK_REMOTE_QPN |
                                         QP_ATTR_MASK_RQ_PSN |
                                         QP_ATTR_MASK_AH;
                end
                QP_TYPE_UD: begin
                    required_attr_mask = QP_ATTR_MASK_AH;
                end
                QP_TYPE_UC: begin
                    // UC 后续如果启用，可在这里补充 UC 特有的 RTR 属性要求。
                    required_attr_mask = QP_ATTR_MASK_REMOTE_QPN |
                                         QP_ATTR_MASK_RQ_PSN |
                                         QP_ATTR_MASK_AH;
                end
                default: begin
                    required_attr_mask = 32'h0000_0000;
                end
            endcase
        end else if (current_state == QP_STATE_RTR && requested_state == QP_STATE_RTS) begin
            unique case (qp_type)
                QP_TYPE_RC: begin
                    required_attr_mask = QP_ATTR_MASK_SQ_PSN |
                                         QP_ATTR_MASK_RETRY;
                end
                QP_TYPE_UD: begin
                    required_attr_mask = QP_ATTR_MASK_SQ_PSN;
                end
                QP_TYPE_UC: begin
                    // UC 不需要 RC ACK retry，但当前阶段仍要求 SQ PSN。
                    required_attr_mask = QP_ATTR_MASK_SQ_PSN;
                end
                default: begin
                    required_attr_mask = 32'h0000_0000;
                end
            endcase
        end
    end

    always_comb begin
        missing_attr_mask = required_attr_mask & ~provided_attrs;
        validate_allowed = 1'b0;
        validate_error_code = QP_STATE_VAL_ERR_NONE;

        if (!validate_valid) begin
            validate_allowed = 1'b0;
            validate_error_code = QP_STATE_VAL_ERR_NONE;
        end else if ((qp_type != QP_TYPE_RC) &&
                     (qp_type != QP_TYPE_UC) &&
                     (qp_type != QP_TYPE_UD)) begin
            validate_allowed = 1'b0;
            validate_error_code = QP_STATE_VAL_ERR_QP_TYPE;
        end else if (!transition_allowed) begin
            validate_allowed = 1'b0;
            validate_error_code = QP_STATE_VAL_ERR_TRANSITION;
        end else if (missing_attr_mask != 32'h0000_0000) begin
            validate_allowed = 1'b0;
            validate_error_code = QP_STATE_VAL_ERR_MISSING_ATTR;
        end else begin
            validate_allowed = 1'b1;
            validate_error_code = QP_STATE_VAL_ERR_NONE;
        end
    end

endmodule : qp_state_validator
