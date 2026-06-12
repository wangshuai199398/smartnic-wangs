# SPDX-License-Identifier: MIT
"""QP state validator 最小行为测试。"""

import cocotb
from cocotb.triggers import Timer


QP_TYPE_RC = 0

QP_STATE_RESET = 0
QP_STATE_INIT = 1
QP_STATE_RTR = 2
QP_STATE_RTS = 3
QP_STATE_SQD = 4
QP_STATE_SQE = 5
QP_STATE_ERR = 6

QP_STATE_VAL_ERR_NONE = 0x0000
QP_STATE_VAL_ERR_TRANSITION = 0x0009
QP_STATE_VAL_ERR_MISSING_ATTR = 0x000A

QP_MOD_MASK_STATE = 0x0000_0001
QP_MOD_MASK_PD = 0x0000_0004
QP_MOD_MASK_CQ = 0x0000_0008
QP_MOD_MASK_QUEUE_ADDR = 0x0000_0010
QP_MOD_MASK_QUEUE_DEPTH = 0x0000_0020
QP_MOD_MASK_PSN = 0x0000_0080
QP_MOD_MASK_RETRY = 0x0000_0100
QP_MOD_MASK_REMOTE_QPN = 0x0000_0200
QP_MOD_MASK_AH = 0x0000_0800

QP_ATTR_MASK_PD = 0x0000_0001
QP_ATTR_MASK_CQ = 0x0000_0002
QP_ATTR_MASK_QUEUE_ADDR = 0x0000_0004
QP_ATTR_MASK_QUEUE_DEPTH = 0x0000_0008
QP_ATTR_MASK_REMOTE_QPN = 0x0000_0010
QP_ATTR_MASK_RQ_PSN = 0x0000_0020
QP_ATTR_MASK_AH = 0x0000_0040
QP_ATTR_MASK_SQ_PSN = 0x0000_0080
QP_ATTR_MASK_RETRY = 0x0000_0100

RESET_TO_INIT_MASK = (
    QP_MOD_MASK_STATE
    | QP_MOD_MASK_PD
    | QP_MOD_MASK_CQ
    | QP_MOD_MASK_QUEUE_ADDR
    | QP_MOD_MASK_QUEUE_DEPTH
)
INIT_TO_RTR_MASK = QP_MOD_MASK_STATE | QP_MOD_MASK_REMOTE_QPN | QP_MOD_MASK_PSN | QP_MOD_MASK_AH
RTR_TO_RTS_MASK = QP_MOD_MASK_STATE | QP_MOD_MASK_PSN | QP_MOD_MASK_RETRY


async def validate(dut, current, requested, modify_mask, qp_type=QP_TYPE_RC):
    dut.validate_valid.value = 1
    dut.current_state.value = current
    dut.requested_state.value = requested
    dut.qp_type.value = qp_type
    dut.modify_mask.value = modify_mask
    await Timer(1, units="ns")
    return {
        "allowed": int(dut.validate_allowed.value),
        "error": int(dut.validate_error_code.value),
        "required": int(dut.required_attr_mask.value),
        "missing": int(dut.missing_attr_mask.value),
    }


@cocotb.test()
async def reset_to_init_is_legal(dut):
    result = await validate(dut, QP_STATE_RESET, QP_STATE_INIT, RESET_TO_INIT_MASK)

    assert result["allowed"] == 1
    assert result["error"] == QP_STATE_VAL_ERR_NONE


@cocotb.test()
async def init_to_rtr_is_legal(dut):
    result = await validate(dut, QP_STATE_INIT, QP_STATE_RTR, INIT_TO_RTR_MASK)

    assert result["allowed"] == 1
    assert result["error"] == QP_STATE_VAL_ERR_NONE


@cocotb.test()
async def rtr_to_rts_is_legal(dut):
    result = await validate(dut, QP_STATE_RTR, QP_STATE_RTS, RTR_TO_RTS_MASK)

    assert result["allowed"] == 1
    assert result["error"] == QP_STATE_VAL_ERR_NONE


@cocotb.test()
async def rts_to_sqd_and_sqd_to_rts_are_legal(dut):
    to_sqd = await validate(dut, QP_STATE_RTS, QP_STATE_SQD, QP_MOD_MASK_STATE)
    to_rts = await validate(dut, QP_STATE_SQD, QP_STATE_RTS, QP_MOD_MASK_STATE)

    assert to_sqd["allowed"] == 1
    assert to_sqd["error"] == QP_STATE_VAL_ERR_NONE
    assert to_rts["allowed"] == 1
    assert to_rts["error"] == QP_STATE_VAL_ERR_NONE


@cocotb.test()
async def err_to_reset_is_legal(dut):
    result = await validate(dut, QP_STATE_ERR, QP_STATE_RESET, QP_MOD_MASK_STATE)

    assert result["allowed"] == 1
    assert result["error"] == QP_STATE_VAL_ERR_NONE


@cocotb.test()
async def reset_to_rts_is_illegal(dut):
    result = await validate(dut, QP_STATE_RESET, QP_STATE_RTS, RTR_TO_RTS_MASK)

    assert result["allowed"] == 0
    assert result["error"] == QP_STATE_VAL_ERR_TRANSITION


@cocotb.test()
async def init_to_rts_is_illegal(dut):
    result = await validate(dut, QP_STATE_INIT, QP_STATE_RTS, RTR_TO_RTS_MASK)

    assert result["allowed"] == 0
    assert result["error"] == QP_STATE_VAL_ERR_TRANSITION


@cocotb.test()
async def any_state_to_err_is_legal(dut):
    for state in [
        QP_STATE_RESET,
        QP_STATE_INIT,
        QP_STATE_RTR,
        QP_STATE_RTS,
        QP_STATE_SQD,
        QP_STATE_SQE,
        QP_STATE_ERR,
    ]:
        result = await validate(dut, state, QP_STATE_ERR, QP_MOD_MASK_STATE)
        assert result["allowed"] == 1
        assert result["error"] == QP_STATE_VAL_ERR_NONE


@cocotb.test()
async def err_to_rts_is_illegal(dut):
    result = await validate(dut, QP_STATE_ERR, QP_STATE_RTS, RTR_TO_RTS_MASK)

    assert result["allowed"] == 0
    assert result["error"] == QP_STATE_VAL_ERR_TRANSITION


@cocotb.test()
async def missing_required_attributes_are_reported(dut):
    result = await validate(dut, QP_STATE_RESET, QP_STATE_INIT, QP_MOD_MASK_STATE | QP_MOD_MASK_PD)

    expected_required = (
        QP_ATTR_MASK_PD | QP_ATTR_MASK_CQ | QP_ATTR_MASK_QUEUE_ADDR | QP_ATTR_MASK_QUEUE_DEPTH
    )
    expected_missing = QP_ATTR_MASK_CQ | QP_ATTR_MASK_QUEUE_ADDR | QP_ATTR_MASK_QUEUE_DEPTH

    assert result["allowed"] == 0
    assert result["error"] == QP_STATE_VAL_ERR_MISSING_ATTR
    assert result["required"] == expected_required
    assert result["missing"] == expected_missing
