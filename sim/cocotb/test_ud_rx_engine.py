# SPDX-License-Identifier: MIT
"""UD receive path tests for task 9.6."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


RDMA_OP_SEND = 0x00
QP_TYPE_UD = 2
QP_STATE_RTS = 3
ROCE_OPCODE_UD_SEND_ONLY = 0x64
PKT_PARSE_STATUS_OK = 0
PKT_PAYLOAD_OK = 0
QP_TABLE_STATUS_OK = 0
CMPL_SUCCESS = 0

UD_RX_STATUS_INVALID_DETH = 1
UD_RX_STATUS_QKEY_MISMATCH = 2
UD_RX_STATUS_MISSING_RQ_WQE = 3
UD_RX_STATUS_MALFORMED = 4


META_FIELDS = [
    ("desc_id", 16), ("qpn", 24), ("cqn", 24), ("owner_function", 16),
    ("pd_id", 24), ("opcode", 8), ("status", 4), ("frame_len", 16),
    ("ethertype", 16), ("has_vlan", 1), ("vlan_tci", 16),
    ("ip_version", 4), ("ip_ihl", 4), ("ip_dsfield", 8),
    ("ipv6_traffic_class", 8), ("ecn", 2), ("ecn_valid", 1), ("ecn_ce", 1),
    ("ip_total_length", 16),
    ("ip_protocol", 8), ("ip_checksum", 16), ("ipv4_src", 32),
    ("ipv4_dst", 32), ("udp_src_port", 16), ("udp_dst_port", 16),
    ("udp_length", 16), ("udp_checksum", 16), ("bth_transport_version", 4),
    ("pkey", 16), ("dest_qpn", 24), ("psn", 24), ("has_reth", 1),
    ("remote_va", 64), ("rkey", 32), ("dma_length", 32), ("has_aeth", 1),
    ("aeth", 32), ("has_deth", 1), ("qkey", 32), ("src_qpn", 24),
    ("has_imm", 1), ("imm_data", 32), ("icrc", 32), ("payload_offset", 16),
    ("payload_len", 16),
]

PAYLOAD_FIELDS = [
    ("desc_id", 16), ("qpn", 24), ("cqn", 24), ("owner_function", 16),
    ("pd_id", 24), ("opcode", 8), ("status", 5), ("error_code", 16),
    ("ecn", 2),
    ("ecn_valid", 1),
    ("ecn_ce", 1),
    ("data", 512), ("payload_len", 16), ("valid_bytes", 16),
    ("byte_offset", 16), ("first", 1), ("last", 1), ("has_imm", 1),
    ("imm_data", 32), ("remote_va", 64), ("rkey", 32), ("dma_length", 32),
    ("dest_qpn", 24), ("psn", 24),
]

QP_CONTEXT_FIELDS = [
    ("valid", 1), ("owner_func", 16), ("qpn", 24), ("qp_type", 3),
    ("state", 4), ("pd_id", 24), ("send_cqn", 24), ("recv_cqn", 24),
    ("sq_base", 64), ("rq_base", 64), ("sq_depth", 16), ("rq_depth", 16),
    ("sq_producer", 16), ("sq_consumer", 16), ("rq_producer", 16),
    ("rq_consumer", 16), ("remote_qpn", 24), ("sq_psn", 24), ("rq_psn", 24),
    ("last_acked_psn", 24), ("retry_count", 8), ("rnr_retry_count", 8),
    ("pkey", 16), ("qkey", 32), ("ah_id", 24), ("error_state", 1),
    ("error_code", 16),
]

RQ_DMA_WRITE_FIELDS = [
    ("owner_func", 16), ("qpn", 24), ("pd_id", 24), ("wr_id", 64),
    ("dst_addr", 64), ("lkey", 32), ("length", 32), ("flags", 8),
]

COMPLETION_EVENT_FIELDS = [
    ("event_type", 2), ("qpn", 24), ("cqn", 24), ("owner_function", 16),
    ("wr_id", 64), ("opcode", 8), ("status", 8), ("byte_len", 32),
    ("imm_data", 32), ("has_imm", 1), ("solicited", 1), ("vendor_error", 32),
    ("source_engine", 3),
]

UD_RX_COMPLETION_FIELDS = COMPLETION_EVENT_FIELDS + [("source_qpn", 24)]

COUNTER_FIELDS = [
    ("invalid_deth", 32), ("qkey_mismatch", 32), ("missing_rq_wqe", 32),
    ("malformed", 32),
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


def pack_meta(**overrides):
    values = {
        "desc_id": 0x66,
        "qpn": 0,
        "cqn": 0,
        "owner_function": 1,
        "pd_id": 7,
        "opcode": ROCE_OPCODE_UD_SEND_ONLY,
        "status": PKT_PARSE_STATUS_OK,
        "dest_qpn": 0x123456,
        "psn": 0x222,
        "has_deth": 1,
        "qkey": 0x11223344,
        "src_qpn": 0x654321,
        "payload_len": 16,
    }
    values.update(overrides)
    return pack_fields(META_FIELDS, values)


def pack_payload(**overrides):
    values = {
        "desc_id": 0x66,
        "owner_function": 1,
        "pd_id": 7,
        "opcode": ROCE_OPCODE_UD_SEND_ONLY,
        "status": PKT_PAYLOAD_OK,
        "data": 0xA5A5,
        "payload_len": 16,
        "valid_bytes": 16,
        "first": 1,
        "last": 1,
        "dest_qpn": 0x123456,
        "psn": 0x222,
    }
    values.update(overrides)
    return pack_fields(PAYLOAD_FIELDS, values)


def pack_qp(**overrides):
    values = {
        "valid": 1,
        "owner_func": 1,
        "qpn": 0x123456,
        "qp_type": QP_TYPE_UD,
        "state": QP_STATE_RTS,
        "pd_id": 7,
        "recv_cqn": 0x44,
        "rq_depth": 8,
        "rq_producer": 1,
        "rq_consumer": 0,
        "pkey": 0xFFFF,
        "qkey": 0x11223344,
    }
    values.update(overrides)
    return pack_fields(QP_CONTEXT_FIELDS, values)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.rx_meta_valid.value = 0
    dut.rx_meta.value = 0
    dut.rx_payload_valid.value = 0
    dut.rx_payload.value = 0
    dut.qp_read_ready.value = 1
    dut.qp_read_rsp_valid.value = 0
    dut.qp_read_hit.value = 0
    dut.qp_read_status.value = QP_TABLE_STATUS_OK
    dut.qp_read_data.value = 0
    dut.rq_wqe_available.value = 1
    dut.rq_wqe_wr_id.value = 0xBEEF
    dut.rq_wqe_cqn.value = 0x44
    dut.rq_wqe_buffer_addr.value = 0x100000
    dut.rq_wqe_lkey.value = 0x1111
    dut.rq_wqe_buffer_len.value = 64
    dut.rq_consume_ready.value = 1
    dut.dma_write_ready.value = 1
    dut.dma_write_done_valid.value = 0
    dut.dma_write_error.value = 0
    dut.completion_ready.value = 1
    dut.drop_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def wait_for(dut, name, cycles=48):
    sig = getattr(dut, name)
    for _ in range(cycles):
        await Timer(1, units="ns")
        if int(sig.value) == 1:
            value = None
            if name == "completion_valid":
                value = int(dut.completion.value)
            elif name == "dma_write_valid":
                value = int(dut.dma_write_req.value)
            await RisingEdge(dut.clk)
            return value
        await RisingEdge(dut.clk)
    raise AssertionError(f"{name} not asserted")


async def issue_packet(dut, meta=None, payload=None):
    dut.rx_meta.value = pack_meta() if meta is None else meta
    dut.rx_payload.value = pack_payload() if payload is None else payload
    dut.rx_meta_valid.value = 1
    dut.rx_payload_valid.value = 1
    await RisingEdge(dut.clk)
    dut.rx_meta_valid.value = 0
    dut.rx_payload_valid.value = 0


async def respond_qp(dut, qp=None):
    await wait_for(dut, "qp_read_valid")
    dut.qp_read_hit.value = 1
    dut.qp_read_status.value = QP_TABLE_STATUS_OK
    dut.qp_read_data.value = pack_qp() if qp is None else qp
    dut.qp_read_rsp_valid.value = 1
    await RisingEdge(dut.clk)
    dut.qp_read_rsp_valid.value = 0


async def complete_dma(dut, error=0):
    await wait_for(dut, "dma_write_valid")
    dut.dma_write_error.value = error
    dut.dma_write_done_valid.value = 1
    await RisingEdge(dut.clk)
    dut.dma_write_done_valid.value = 0


@cocotb.test()
async def valid_ud_receive_writes_payload_and_completes(dut):
    await reset_dut(dut)
    await issue_packet(dut)
    await respond_qp(dut)
    dma_req = await wait_for(dut, "dma_write_valid")
    assert extract_field(RQ_DMA_WRITE_FIELDS, dma_req, "qpn") == 0x123456
    assert extract_field(RQ_DMA_WRITE_FIELDS, dma_req, "length") == 16
    dut.dma_write_done_valid.value = 1
    await RisingEdge(dut.clk)
    dut.dma_write_done_valid.value = 0
    await wait_for(dut, "rq_consume_valid")
    comp = await wait_for(dut, "completion_valid")
    assert extract_field(UD_RX_COMPLETION_FIELDS, comp, "opcode") == RDMA_OP_SEND
    assert extract_field(UD_RX_COMPLETION_FIELDS, comp, "status") == CMPL_SUCCESS
    assert extract_field(UD_RX_COMPLETION_FIELDS, comp, "source_qpn") == 0x654321


@cocotb.test()
async def qkey_mismatch_is_dropped_and_counted(dut):
    await reset_dut(dut)
    await issue_packet(dut)
    await respond_qp(dut, pack_qp(qkey=0xDEADBEEF))
    await wait_for(dut, "drop_valid")
    assert int(dut.drop_status.value) == UD_RX_STATUS_QKEY_MISMATCH
    counters = int(dut.counters.value)
    assert extract_field(COUNTER_FIELDS, counters, "qkey_mismatch") == 1


@cocotb.test()
async def source_qpn_is_reported_in_completion_seed(dut):
    await reset_dut(dut)
    await issue_packet(dut, meta=pack_meta(src_qpn=0x010203))
    await respond_qp(dut)
    await complete_dma(dut)
    await wait_for(dut, "rq_consume_valid")
    comp = await wait_for(dut, "completion_valid")
    assert extract_field(UD_RX_COMPLETION_FIELDS, comp, "source_qpn") == 0x010203
    assert extract_field(UD_RX_COMPLETION_FIELDS, comp, "vendor_error") == 0x010203


@cocotb.test()
async def missing_rq_wqe_is_dropped_and_counted(dut):
    await reset_dut(dut)
    dut.rq_wqe_available.value = 0
    await issue_packet(dut)
    await respond_qp(dut)
    await wait_for(dut, "drop_valid")
    assert int(dut.drop_status.value) == UD_RX_STATUS_MISSING_RQ_WQE
    counters = int(dut.counters.value)
    assert extract_field(COUNTER_FIELDS, counters, "missing_rq_wqe") == 1


@cocotb.test()
async def malformed_deth_is_dropped_and_counted(dut):
    await reset_dut(dut)
    await issue_packet(dut, meta=pack_meta(has_deth=0))
    await wait_for(dut, "drop_valid")
    assert int(dut.drop_status.value) == UD_RX_STATUS_INVALID_DETH
    counters = int(dut.counters.value)
    assert extract_field(COUNTER_FIELDS, counters, "invalid_deth") == 1


@cocotb.test()
async def malformed_packet_counter_increments(dut):
    await reset_dut(dut)
    await issue_packet(dut, meta=pack_meta(opcode=0x04))
    await wait_for(dut, "drop_valid")
    assert int(dut.drop_status.value) == UD_RX_STATUS_MALFORMED
    counters = int(dut.counters.value)
    assert extract_field(COUNTER_FIELDS, counters, "malformed") == 1
