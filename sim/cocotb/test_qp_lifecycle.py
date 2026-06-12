# SPDX-License-Identifier: MIT
"""QP lifecycle manager 最小行为测试。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


CSR_CMD_CREATE_QP = 0x0300
CSR_CMD_MODIFY_QP = 0x0301
CSR_CMD_QUERY_QP = 0x0302
CSR_CMD_DESTROY_QP = 0x0303
CSR_CMD_QP_TO_ERROR = 0x0304

QP_LC_STATUS_SUCCESS = 0x02
QP_LC_STATUS_FAILED = 0x03

QP_LC_ERR_NONE = 0x0000
QP_LC_ERR_NOT_FOUND = 0x0002
QP_LC_ERR_DUPLICATE_QPN = 0x0003
QP_LC_ERR_PERMISSION = 0x0004
QP_LC_ERR_STATE_TRANSITION = 0x0009
QP_LC_ERR_MISSING_ATTR = 0x000A

QP_TYPE_RC = 0
QP_STATE_RESET = 0
QP_STATE_INIT = 1
QP_STATE_RTR = 2
QP_STATE_RTS = 3
QP_STATE_ERR = 6

QP_MOD_MASK_STATE = 0x0000_0001
QP_MOD_MASK_PD = 0x0000_0004
QP_MOD_MASK_CQ = 0x0000_0008
QP_MOD_MASK_QUEUE_ADDR = 0x0000_0010
QP_MOD_MASK_QUEUE_DEPTH = 0x0000_0020
QP_MOD_MASK_PSN = 0x0000_0080
QP_MOD_MASK_RETRY = 0x0000_0100
QP_MOD_MASK_REMOTE_QPN = 0x0000_0200
QP_MOD_MASK_AH = 0x0000_0800


QP_CONTEXT_FIELDS = [
    ("valid", 1),
    ("owner_func", 16),
    ("qpn", 24),
    ("qp_type", 3),
    ("state", 4),
    ("pd_id", 24),
    ("send_cqn", 24),
    ("recv_cqn", 24),
    ("sq_base", 64),
    ("rq_base", 64),
    ("sq_depth", 16),
    ("rq_depth", 16),
    ("sq_producer", 16),
    ("sq_consumer", 16),
    ("rq_producer", 16),
    ("rq_consumer", 16),
    ("remote_qpn", 24),
    ("sq_psn", 24),
    ("rq_psn", 24),
    ("last_acked_psn", 24),
    ("retry_count", 8),
    ("rnr_retry_count", 8),
    ("pkey", 16),
    ("qkey", 32),
    ("ah_id", 24),
    ("error_state", 1),
    ("error_code", 16),
]


def pack_qp_context(**overrides):
    values = {
        "valid": 1,
        "owner_func": 1,
        "qpn": 7,
        "qp_type": QP_TYPE_RC,
        "state": QP_STATE_RESET,
        "pd_id": 3,
        "send_cqn": 10,
        "recv_cqn": 11,
        "sq_base": 0x1000_0000,
        "rq_base": 0x2000_0000,
        "sq_depth": 128,
        "rq_depth": 128,
        "sq_producer": 0,
        "sq_consumer": 0,
        "rq_producer": 0,
        "rq_consumer": 0,
        "remote_qpn": 0x123,
        "sq_psn": 0x100,
        "rq_psn": 0x200,
        "last_acked_psn": 0x0FF,
        "retry_count": 7,
        "rnr_retry_count": 7,
        "pkey": 0xFFFF,
        "qkey": 0x1111_1111,
        "ah_id": 0,
        "error_state": 0,
        "error_code": 0,
    }
    values.update(overrides)

    packed = 0
    for name, width in QP_CONTEXT_FIELDS:
        packed = (packed << width) | (values[name] & ((1 << width) - 1))
    return packed


def extract_field(packed, field_name):
    offset = 0
    for name, width in reversed(QP_CONTEXT_FIELDS):
        if name == field_name:
            return (packed >> offset) & ((1 << width) - 1)
        offset += width
    raise KeyError(field_name)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.cmd_valid.value = 0
    dut.cmd_id.value = 0
    dut.cmd_qpn.value = 0
    dut.cmd_owner_function.value = 0
    dut.cmd_admin_bypass.value = 0
    dut.cmd_qp_context.value = 0
    dut.cmd_modify_mask.value = 0
    dut.cmd_sequence.value = 0
    dut.cmd_error_code.value = 0
    dut.cleanup_destroy_ready.value = 1
    dut.cleanup_error_ready.value = 1
    dut.cleanup_done_valid.value = 0
    dut.cleanup_done_error_code.value = 0
    dut.cleanup_done_context.value = 0
    dut.cmd_rsp_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def issue_cmd(
    dut,
    cmd_id,
    qpn,
    owner=1,
    payload=None,
    modify_mask=0,
    sequence=0x55,
    error_code=0,
    admin_bypass=0,
):
    dut.cmd_valid.value = 1
    dut.cmd_id.value = cmd_id
    dut.cmd_qpn.value = qpn
    dut.cmd_owner_function.value = owner
    dut.cmd_admin_bypass.value = admin_bypass
    dut.cmd_qp_context.value = payload if payload is not None else pack_qp_context(qpn=qpn, owner_func=owner)
    dut.cmd_modify_mask.value = modify_mask
    dut.cmd_sequence.value = sequence
    dut.cmd_error_code.value = error_code
    await RisingEdge(dut.clk)
    dut.cmd_valid.value = 0

    cleanup_seen = False
    for _ in range(30):
        await RisingEdge(dut.clk)
        if int(dut.cleanup_destroy_valid.value) == 1 and not cleanup_seen:
            cleanup_seen = True
            dut.cleanup_done_valid.value = 1
            dut.cleanup_done_error_code.value = 0
            dut.cleanup_done_context.value = 0
            await RisingEdge(dut.clk)
            dut.cleanup_done_valid.value = 0
        elif int(dut.cleanup_error_valid.value) == 1 and not cleanup_seen:
            cleanup_seen = True
            dut.cleanup_done_valid.value = 1
            dut.cleanup_done_error_code.value = 0
            dut.cleanup_done_context.value = pack_qp_context(
                qpn=qpn,
                owner_func=owner,
                state=QP_STATE_ERR,
                error_state=1,
                error_code=error_code,
            )
            await RisingEdge(dut.clk)
            dut.cleanup_done_valid.value = 0

        if int(dut.cmd_rsp_valid.value) == 1:
            result = {
                "status": int(dut.cmd_status.value),
                "error": int(dut.cmd_rsp_error_code.value),
                "sequence": int(dut.cmd_rsp_sequence.value),
                "context": int(dut.cmd_rsp_qp_context.value),
            }
            dut.cmd_rsp_ready.value = 1
            await RisingEdge(dut.clk)
            dut.cmd_rsp_ready.value = 0
            return result

    raise AssertionError("QP lifecycle command did not complete")


async def create_qp(dut, qpn, owner=1, state=QP_STATE_RESET):
    payload = pack_qp_context(qpn=qpn, owner_func=owner, state=state)
    return await issue_cmd(dut, CSR_CMD_CREATE_QP, qpn, owner=owner, payload=payload)


@cocotb.test()
async def create_qp_success(dut):
    await reset_dut(dut)

    result = await create_qp(dut, qpn=7, owner=1)

    assert result["status"] == QP_LC_STATUS_SUCCESS
    assert result["error"] == QP_LC_ERR_NONE
    assert extract_field(result["context"], "valid") == 1
    assert extract_field(result["context"], "qpn") == 7
    assert extract_field(result["context"], "owner_func") == 1
    assert extract_field(result["context"], "sq_producer") == 0
    assert extract_field(result["context"], "rq_producer") == 0


@cocotb.test()
async def create_duplicate_qpn_is_rejected(dut):
    await reset_dut(dut)

    assert (await create_qp(dut, qpn=8, owner=1))["status"] == QP_LC_STATUS_SUCCESS
    result = await create_qp(dut, qpn=8, owner=1)

    assert result["status"] == QP_LC_STATUS_FAILED
    assert result["error"] == QP_LC_ERR_DUPLICATE_QPN


@cocotb.test()
async def query_qp_success(dut):
    await reset_dut(dut)

    await create_qp(dut, qpn=9, owner=1)
    result = await issue_cmd(dut, CSR_CMD_QUERY_QP, qpn=9, owner=1)

    assert result["status"] == QP_LC_STATUS_SUCCESS
    assert extract_field(result["context"], "qpn") == 9
    assert extract_field(result["context"], "owner_func") == 1


@cocotb.test()
async def modify_qp_basic_fields(dut):
    await reset_dut(dut)

    await create_qp(dut, qpn=10, owner=1)
    payload = pack_qp_context(
        qpn=10,
        owner_func=1,
        state=QP_STATE_RTS,
        pd_id=44,
        send_cqn=70,
        recv_cqn=71,
    )
    result = await issue_cmd(
        dut,
        CSR_CMD_MODIFY_QP,
        qpn=10,
        owner=1,
        payload=payload,
        modify_mask=QP_MOD_MASK_PD | QP_MOD_MASK_CQ,
    )

    assert result["status"] == QP_LC_STATUS_SUCCESS
    assert extract_field(result["context"], "state") == QP_STATE_RESET
    assert extract_field(result["context"], "pd_id") == 44
    assert extract_field(result["context"], "send_cqn") == 70
    assert extract_field(result["context"], "recv_cqn") == 71


@cocotb.test()
async def destroy_qp_makes_query_miss(dut):
    await reset_dut(dut)

    await create_qp(dut, qpn=11, owner=1)
    destroy = await issue_cmd(dut, CSR_CMD_DESTROY_QP, qpn=11, owner=1)
    query = await issue_cmd(dut, CSR_CMD_QUERY_QP, qpn=11, owner=1)

    assert destroy["status"] == QP_LC_STATUS_SUCCESS
    assert extract_field(destroy["context"], "valid") == 0
    assert query["status"] == QP_LC_STATUS_FAILED
    assert query["error"] == QP_LC_ERR_NOT_FOUND


@cocotb.test()
async def qp_to_error_sets_err_state(dut):
    await reset_dut(dut)

    await create_qp(dut, qpn=12, owner=1)
    result = await issue_cmd(dut, CSR_CMD_QP_TO_ERROR, qpn=12, owner=1, error_code=0xBEEF)

    assert result["status"] == QP_LC_STATUS_SUCCESS
    assert extract_field(result["context"], "state") == QP_STATE_ERR
    assert extract_field(result["context"], "error_state") == 1
    assert extract_field(result["context"], "error_code") == 0xBEEF


@cocotb.test()
async def cross_function_modify_and_destroy_are_denied(dut):
    await reset_dut(dut)

    await create_qp(dut, qpn=13, owner=2)
    payload = pack_qp_context(qpn=13, owner_func=2, state=QP_STATE_INIT)
    modify = await issue_cmd(
        dut,
        CSR_CMD_MODIFY_QP,
        qpn=13,
        owner=1,
        payload=payload,
        modify_mask=QP_MOD_MASK_STATE,
    )
    destroy = await issue_cmd(dut, CSR_CMD_DESTROY_QP, qpn=13, owner=1)

    assert modify["status"] == QP_LC_STATUS_FAILED
    assert modify["error"] == QP_LC_ERR_PERMISSION
    assert destroy["status"] == QP_LC_STATUS_FAILED
    assert destroy["error"] == QP_LC_ERR_PERMISSION


@cocotb.test()
async def modify_qp_state_uses_validator(dut):
    await reset_dut(dut)

    await create_qp(dut, qpn=14, owner=1)

    illegal_payload = pack_qp_context(qpn=14, owner_func=1, state=QP_STATE_RTS)
    illegal = await issue_cmd(
        dut,
        CSR_CMD_MODIFY_QP,
        qpn=14,
        owner=1,
        payload=illegal_payload,
        modify_mask=QP_MOD_MASK_STATE | QP_MOD_MASK_PSN | QP_MOD_MASK_RETRY,
    )

    legal_payload = pack_qp_context(qpn=14, owner_func=1, state=QP_STATE_INIT)
    legal = await issue_cmd(
        dut,
        CSR_CMD_MODIFY_QP,
        qpn=14,
        owner=1,
        payload=legal_payload,
        modify_mask=(
            QP_MOD_MASK_STATE
            | QP_MOD_MASK_PD
            | QP_MOD_MASK_CQ
            | QP_MOD_MASK_QUEUE_ADDR
            | QP_MOD_MASK_QUEUE_DEPTH
        ),
    )

    assert illegal["status"] == QP_LC_STATUS_FAILED
    assert illegal["error"] == QP_LC_ERR_STATE_TRANSITION
    assert legal["status"] == QP_LC_STATUS_SUCCESS
    assert extract_field(legal["context"], "state") == QP_STATE_INIT
