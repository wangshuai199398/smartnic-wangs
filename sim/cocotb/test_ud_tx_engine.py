# SPDX-License-Identifier: MIT
"""UD transmit path tests for task 9.5."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


RDMA_OP_SEND = 0x00
RDMA_OP_RDMA_WRITE = 0x02
QP_TYPE_RC = 0
QP_TYPE_UD = 2
ROCE_OPCODE_UD_SEND_ONLY = 0x64
CMPL_SUCCESS = 0

UD_TX_STATUS_OK = 0
UD_TX_STATUS_BAD_QP_TYPE = 1
UD_TX_STATUS_UNSUPPORTED_OP = 2
UD_TX_STATUS_AH_MISS = 3
UD_TX_STATUS_AH_PERMISSION = 4
UD_TX_STATUS_MISSING_QKEY = 5


UD_TX_REQ_FIELDS = [
    ("desc_id", 16), ("qpn", 24), ("cqn", 24), ("owner_function", 16),
    ("pd_id", 24), ("wr_id", 64), ("qp_type", 3), ("opcode", 8),
    ("ah_id", 24), ("dest_qpn", 24), ("qkey", 32), ("psn", 24),
    ("payload_data", 512), ("payload_len", 16), ("solicited", 1),
    ("completion_required", 1),
]

AH_FIELDS = [
    ("valid", 1), ("owner_func", 16), ("ah_id", 24), ("pd_id", 24),
    ("dst_mac", 48), ("dst_ipv4", 32), ("udp_src_port", 16),
    ("udp_dst_port", 16), ("pkey", 16), ("qkey", 32),
    ("traffic_class", 8), ("hop_limit", 8), ("service_level", 3),
]

BUILD_REQ_FIELDS = [
    ("desc_id", 16), ("qpn", 24), ("cqn", 24), ("owner_function", 16),
    ("pd_id", 24), ("opcode", 8), ("status", 5), ("error_code", 16),
    ("dst_mac", 48), ("src_mac", 48), ("has_vlan", 1), ("vlan_tci", 16),
    ("src_ipv4", 32), ("dst_ipv4", 32), ("udp_src_port", 16), ("udp_dst_port", 16),
    ("pkey", 16), ("dest_qpn", 24), ("src_qpn", 24), ("psn", 24),
    ("remote_va", 64), ("rkey", 32), ("dma_length", 32), ("aeth", 32),
    ("qkey", 32), ("has_imm", 1), ("imm_data", 32), ("payload_data", 512),
    ("payload_len", 16), ("icrc_placeholder", 32),
]

COMPLETION_FIELDS = [
    ("event_type", 2), ("qpn", 24), ("cqn", 24), ("owner_function", 16),
    ("wr_id", 64), ("opcode", 8), ("status", 8), ("byte_len", 32),
    ("imm_data", 32), ("has_imm", 1), ("solicited", 1), ("vendor_error", 32),
    ("source_engine", 3),
]


def pack_fields(fields, values):
    packed = 0
    for name, width in fields:
        packed = (packed << width) | (values.get(name, 0) & ((1 << width) - 1))
    return packed


def extract_field(fields, packed, name):
    bit = sum(width for _, width in fields)
    for field_name, width in fields:
        bit -= width
        if field_name == name:
            return (packed >> bit) & ((1 << width) - 1)
    raise KeyError(name)


def pack_ud_req(**overrides):
    values = {
        "desc_id": 0x55,
        "qpn": 0x123456,
        "cqn": 0x44,
        "owner_function": 1,
        "pd_id": 7,
        "wr_id": 0xABCDEF,
        "qp_type": QP_TYPE_UD,
        "opcode": RDMA_OP_SEND,
        "ah_id": 0x22,
        "dest_qpn": 0x654321,
        "qkey": 0,
        "psn": 0x100,
        "payload_data": 0xA5A5,
        "payload_len": 16,
        "solicited": 1,
        "completion_required": 1,
    }
    values.update(overrides)
    return pack_fields(UD_TX_REQ_FIELDS, values)


def pack_ah(**overrides):
    values = {
        "valid": 1,
        "owner_func": 1,
        "ah_id": 0x22,
        "pd_id": 7,
        "dst_mac": 0xAABBCCDDEEFF,
        "dst_ipv4": 0x0A000002,
        "udp_src_port": 0xC001,
        "udp_dst_port": 4791,
        "pkey": 0xFFFF,
        "qkey": 0x11223344,
        "traffic_class": 0,
        "hop_limit": 64,
        "service_level": 0,
    }
    values.update(overrides)
    return pack_fields(AH_FIELDS, values)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.ud_req_valid.value = 0
    dut.ud_req.value = 0
    dut.ah_lookup_ready.value = 1
    dut.ah_lookup_resp_valid.value = 0
    dut.ah_lookup_hit.value = 0
    dut.ah_lookup_entry.value = 0
    dut.ah_lookup_error_code.value = 0
    dut.packet_ready.value = 1
    dut.completion_ready.value = 1
    dut.wqe_error_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def wait_for(dut, signal_name, cycles=32):
    sig = getattr(dut, signal_name)
    for _ in range(cycles):
        await Timer(1, units="ns")
        if int(sig.value) == 1:
            value = None
            if signal_name == "packet_valid":
                value = int(dut.packet_req.value)
            elif signal_name == "completion_valid":
                value = int(dut.completion_event.value)
            await RisingEdge(dut.clk)
            return value
        await RisingEdge(dut.clk)
    raise AssertionError(f"{signal_name} not asserted")


async def issue_req_and_ah(dut, req_value=None, ah_value=None, hit=1, error_code=0):
    dut.ud_req.value = pack_ud_req() if req_value is None else req_value
    dut.ud_req_valid.value = 1
    await RisingEdge(dut.clk)
    dut.ud_req_valid.value = 0

    await wait_for(dut, "ah_lookup_valid")
    dut.ah_lookup_hit.value = hit
    dut.ah_lookup_entry.value = pack_ah() if ah_value is None else ah_value
    dut.ah_lookup_error_code.value = error_code
    dut.ah_lookup_resp_valid.value = 1
    await RisingEdge(dut.clk)
    dut.ah_lookup_resp_valid.value = 0


@cocotb.test()
async def valid_ud_send_builds_packet_and_completion(dut):
    await reset_dut(dut)
    await issue_req_and_ah(dut)

    packet = await wait_for(dut, "packet_valid")
    assert extract_field(BUILD_REQ_FIELDS, packet, "opcode") == ROCE_OPCODE_UD_SEND_ONLY
    assert extract_field(BUILD_REQ_FIELDS, packet, "dest_qpn") == 0x654321
    assert extract_field(BUILD_REQ_FIELDS, packet, "dst_mac") == 0xAABBCCDDEEFF
    assert extract_field(BUILD_REQ_FIELDS, packet, "dst_ipv4") == 0x0A000002

    event = await wait_for(dut, "completion_valid")
    assert extract_field(COMPLETION_FIELDS, event, "opcode") == RDMA_OP_SEND
    assert extract_field(COMPLETION_FIELDS, event, "status") == CMPL_SUCCESS
    assert extract_field(COMPLETION_FIELDS, event, "has_imm") == 0


@cocotb.test()
async def ud_send_deth_fields_use_qkey_and_source_qpn(dut):
    await reset_dut(dut)
    await issue_req_and_ah(dut)
    packet = await wait_for(dut, "packet_valid")
    assert extract_field(BUILD_REQ_FIELDS, packet, "qkey") == 0x11223344
    assert extract_field(BUILD_REQ_FIELDS, packet, "src_qpn") == 0x123456


@cocotb.test()
async def ah_lookup_failure_reports_local_wqe_error(dut):
    await reset_dut(dut)
    await issue_req_and_ah(dut, hit=0, error_code=0x9999)
    await wait_for(dut, "wqe_error_valid")
    assert int(dut.wqe_error_status.value) == UD_TX_STATUS_AH_MISS
    assert int(dut.wqe_error_code.value) == 0x9999


@cocotb.test()
async def ud_send_does_not_require_rc_connection_state(dut):
    await reset_dut(dut)
    req = pack_ud_req(psn=0, dest_qpn=0x101010)
    await issue_req_and_ah(dut, req_value=req)
    packet = await wait_for(dut, "packet_valid")
    assert extract_field(BUILD_REQ_FIELDS, packet, "dest_qpn") == 0x101010
    assert extract_field(BUILD_REQ_FIELDS, packet, "psn") == 0
    await wait_for(dut, "completion_valid")


@cocotb.test()
async def rdma_ops_on_ud_are_rejected(dut):
    await reset_dut(dut)
    dut.ud_req.value = pack_ud_req(opcode=RDMA_OP_RDMA_WRITE)
    dut.ud_req_valid.value = 1
    await RisingEdge(dut.clk)
    dut.ud_req_valid.value = 0
    await wait_for(dut, "wqe_error_valid")
    assert int(dut.wqe_error_status.value) == UD_TX_STATUS_UNSUPPORTED_OP


@cocotb.test()
async def missing_qkey_reports_local_wqe_error(dut):
    await reset_dut(dut)
    await issue_req_and_ah(dut, ah_value=pack_ah(qkey=0))
    await wait_for(dut, "wqe_error_valid")
    assert int(dut.wqe_error_status.value) == UD_TX_STATUS_MISSING_QKEY


@cocotb.test()
async def rc_qp_type_is_not_accepted_by_ud_tx(dut):
    await reset_dut(dut)
    dut.ud_req.value = pack_ud_req(qp_type=QP_TYPE_RC)
    dut.ud_req_valid.value = 1
    await RisingEdge(dut.clk)
    dut.ud_req_valid.value = 0
    await wait_for(dut, "wqe_error_valid")
    assert int(dut.wqe_error_status.value) == UD_TX_STATUS_BAD_QP_TYPE
