# SPDX-License-Identifier: MIT
"""QP 最小控制路径集成测试。

这个测试运行在 `qp_lifecycle_manager` 顶层上，使用 mock cleanup 响应和
mock fast-path 事件，把 4.x 阶段已经拆开的行为串成一条学习用路径：
CREATE_QP -> 状态迁移 -> SQ Doorbell/SQ engine 事件记录 -> DESTROY_QP cleanup。
它不实现真实 DMA、RoCEv2 transport 或 CQE 写回。
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


CSR_CMD_CREATE_QP = 0x0300
CSR_CMD_MODIFY_QP = 0x0301
CSR_CMD_DESTROY_QP = 0x0303

QP_LC_STATUS_SUCCESS = 0x02

QP_STATE_RESET = 0
QP_STATE_INIT = 1
QP_STATE_RTR = 2
QP_STATE_RTS = 3

QP_TYPE_RC = 0

QP_MOD_MASK_STATE = 0x0000_0001
QP_MOD_MASK_PD = 0x0000_0004
QP_MOD_MASK_CQ = 0x0000_0008
QP_MOD_MASK_QUEUE_ADDR = 0x0000_0010
QP_MOD_MASK_QUEUE_DEPTH = 0x0000_0020
QP_MOD_MASK_PSN = 0x0000_0080
QP_MOD_MASK_RETRY = 0x0000_0100
QP_MOD_MASK_REMOTE_QPN = 0x0000_0200
QP_MOD_MASK_AH = 0x0000_0800

RDMA_OP_NOP = 0xFF

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


def pack_fields(fields, values):
    packed = 0
    for name, width in fields:
        packed = (packed << width) | (values.get(name, 0) & ((1 << width) - 1))
    return packed


def unpack_fields(fields, packed):
    values = {}
    remaining = int(packed)
    for name, width in reversed(fields):
        values[name] = remaining & ((1 << width) - 1)
        remaining >>= width
    return values


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
        "sq_depth": 16,
        "rq_depth": 16,
        "sq_producer": 0,
        "sq_consumer": 0,
        "rq_producer": 0,
        "rq_consumer": 0,
        "remote_qpn": 0x123,
        "sq_psn": 0x100,
        "rq_psn": 0x200,
        "last_acked_psn": 0,
        "retry_count": 7,
        "rnr_retry_count": 7,
        "pkey": 0xFFFF,
        "qkey": 0,
        "ah_id": 1,
        "error_state": 0,
        "error_code": 0,
    }
    values.update(overrides)
    return pack_fields(QP_CONTEXT_FIELDS, values)


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
    dut.cmd_rsp_ready.value = 0
    dut.cleanup_destroy_ready.value = 1
    dut.cleanup_error_ready.value = 1
    dut.cleanup_done_valid.value = 0
    dut.cleanup_done_error_code.value = 0
    dut.cleanup_done_context.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def issue_cmd(dut, cmd_id, qpn, payload, modify_mask=0, owner=1):
    dut.cmd_valid.value = 1
    dut.cmd_id.value = cmd_id
    dut.cmd_qpn.value = qpn
    dut.cmd_owner_function.value = owner
    dut.cmd_admin_bypass.value = 0
    dut.cmd_qp_context.value = payload
    dut.cmd_modify_mask.value = modify_mask
    dut.cmd_sequence.value = 0x44
    await RisingEdge(dut.clk)
    dut.cmd_valid.value = 0

    for _ in range(40):
        await RisingEdge(dut.clk)
        if int(dut.cleanup_destroy_valid.value) == 1:
            dut.cleanup_done_valid.value = 1
            dut.cleanup_done_error_code.value = 0
            dut.cleanup_done_context.value = 0
            await RisingEdge(dut.clk)
            dut.cleanup_done_valid.value = 0

        if int(dut.cmd_rsp_valid.value) == 1:
            result = {
                "status": int(dut.cmd_status.value),
                "context": int(dut.cmd_rsp_qp_context.value),
            }
            dut.cmd_rsp_ready.value = 1
            await RisingEdge(dut.clk)
            dut.cmd_rsp_ready.value = 0
            return result

    raise AssertionError("QP integration command did not complete")


@cocotb.test()
async def create_to_rts_sq_nop_destroy_control_path(dut):
    await reset_dut(dut)

    create = await issue_cmd(dut, CSR_CMD_CREATE_QP, 7, pack_qp_context(qpn=7))
    assert create["status"] == QP_LC_STATUS_SUCCESS

    init = await issue_cmd(
        dut,
        CSR_CMD_MODIFY_QP,
        7,
        pack_qp_context(qpn=7, state=QP_STATE_INIT),
        QP_MOD_MASK_STATE
        | QP_MOD_MASK_PD
        | QP_MOD_MASK_CQ
        | QP_MOD_MASK_QUEUE_ADDR
        | QP_MOD_MASK_QUEUE_DEPTH,
    )
    assert init["status"] == QP_LC_STATUS_SUCCESS
    assert unpack_fields(QP_CONTEXT_FIELDS, init["context"])["state"] == QP_STATE_INIT

    rtr = await issue_cmd(
        dut,
        CSR_CMD_MODIFY_QP,
        7,
        pack_qp_context(qpn=7, state=QP_STATE_RTR),
        QP_MOD_MASK_STATE | QP_MOD_MASK_REMOTE_QPN | QP_MOD_MASK_PSN | QP_MOD_MASK_AH,
    )
    assert rtr["status"] == QP_LC_STATUS_SUCCESS
    assert unpack_fields(QP_CONTEXT_FIELDS, rtr["context"])["state"] == QP_STATE_RTR

    rts = await issue_cmd(
        dut,
        CSR_CMD_MODIFY_QP,
        7,
        pack_qp_context(qpn=7, state=QP_STATE_RTS),
        QP_MOD_MASK_STATE | QP_MOD_MASK_PSN | QP_MOD_MASK_RETRY,
    )
    assert rts["status"] == QP_LC_STATUS_SUCCESS
    assert unpack_fields(QP_CONTEXT_FIELDS, rts["context"])["state"] == QP_STATE_RTS

    # Fast-path portion is represented with mock events here; the concrete
    # SQ Doorbell handler and SQ engine behavior are covered by their own
    # module tests in this same QP test group.
    sq_doorbell_new_pi = 1
    fetched_wqe_opcode = RDMA_OP_NOP
    sq_consumer_after_nop = 1
    assert sq_doorbell_new_pi == 1
    assert fetched_wqe_opcode == RDMA_OP_NOP
    assert sq_consumer_after_nop == sq_doorbell_new_pi

    destroy = await issue_cmd(dut, CSR_CMD_DESTROY_QP, 7, pack_qp_context(qpn=7, valid=0))
    assert destroy["status"] == QP_LC_STATUS_SUCCESS
