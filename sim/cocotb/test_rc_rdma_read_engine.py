# SPDX-License-Identifier: MIT
"""RC RDMA Read requester/responder sequencing tests for task 9.3."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


QP_TYPE_RC = 0
QP_STATE_RTR = 2
QP_STATE_RTS = 3
ROCE_OPCODE_RDMA_READ_REQ = 0x0C
ROCE_OPCODE_RDMA_READ_RESP = 0x10
RDMA_OP_RDMA_READ = 0x04
CMPL_SUCCESS = 0x00
CMPL_BAD_RESP_ERR = 0x06
CMPL_REM_ACCESS_ERR = 0x07
CMPL_DMA_ERR = 0x0C


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

READ_REQ_FIELDS = [
    ("desc_id", 16), ("qpn", 24), ("cqn", 24), ("owner_function", 16),
    ("pd_id", 24), ("wr_id", 64), ("qp_type", 3), ("qp_state", 4),
    ("remote_qpn", 24), ("request_psn", 24), ("expected_resp_psn", 24),
    ("local_va", 64), ("local_lkey", 32), ("remote_va", 64),
    ("remote_rkey", 32), ("length", 32), ("retry_count", 8),
    ("rnr_retry_count", 8),
]

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

LOCAL_WRITE_FIELDS = [
    ("desc_id", 16), ("qpn", 24), ("cqn", 24), ("owner_function", 16),
    ("pd_id", 24), ("wr_id", 64), ("local_va", 64), ("local_lkey", 32),
    ("data", 512), ("byte_len", 16), ("byte_offset", 32), ("last", 1),
    ("status", 5), ("error_code", 16),
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


def pack_read_req(length=16, request_psn=0x100, resp_psn=0x900):
    return pack_fields(READ_REQ_FIELDS, {
        "desc_id": 0x55,
        "qpn": 0x123456,
        "cqn": 0x44,
        "owner_function": 1,
        "pd_id": 7,
        "wr_id": 0xCAFE,
        "qp_type": QP_TYPE_RC,
        "qp_state": QP_STATE_RTS,
        "remote_qpn": 0x654321,
        "request_psn": request_psn,
        "expected_resp_psn": resp_psn,
        "local_va": 0x100000,
        "local_lkey": 0x1111,
        "remote_va": 0x200000,
        "remote_rkey": 0x2222,
        "length": length,
        "retry_count": 3,
        "rnr_retry_count": 3,
    })


def pack_meta(opcode, psn, length=16, desc_id=0x77, dest_qpn=0x123456):
    return pack_fields(META_FIELDS, {
        "desc_id": desc_id,
        "qpn": dest_qpn,
        "cqn": 0x44,
        "owner_function": 1,
        "pd_id": 7,
        "opcode": opcode,
        "frame_len": 64,
        "dest_qpn": dest_qpn,
        "src_qpn": 0x654321,
        "psn": psn,
        "has_reth": 1 if opcode == ROCE_OPCODE_RDMA_READ_REQ else 0,
        "remote_va": 0x200000,
        "rkey": 0x2222,
        "dma_length": length,
        "payload_len": length if opcode == ROCE_OPCODE_RDMA_READ_RESP else 0,
    })


def pack_payload(psn, valid_bytes=16):
    return pack_fields(PAYLOAD_FIELDS, {
        "desc_id": 0x55,
        "qpn": 0x123456,
        "cqn": 0x44,
        "owner_function": 1,
        "pd_id": 7,
        "opcode": ROCE_OPCODE_RDMA_READ_RESP,
        "data": 0xA5A5,
        "payload_len": valid_bytes,
        "valid_bytes": valid_bytes,
        "first": 1,
        "last": 1,
        "dest_qpn": 0x123456,
        "psn": psn,
    })


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.responder_ctx_valid.value = 1
    dut.responder_qp_type.value = QP_TYPE_RC
    dut.responder_qp_state.value = QP_STATE_RTS
    dut.responder_owner_function.value = 1
    dut.responder_pd_id.value = 7
    dut.read_req_valid.value = 0
    dut.read_req.value = 0
    dut.read_request_packet_ready.value = 1
    dut.inbound_read_req_valid.value = 0
    dut.inbound_read_req_meta.value = 0
    dut.mr_check_ready.value = 1
    dut.mr_check_resp_valid.value = 0
    dut.mr_check_allowed.value = 0
    dut.mr_check_physical_addr.value = 0
    dut.mr_check_error_code.value = 0
    dut.dma_read_req_ready.value = 1
    dut.dma_read_resp_valid.value = 0
    dut.dma_read_resp_data.value = 0
    dut.dma_read_resp_len.value = 0
    dut.dma_read_resp_error.value = 0
    dut.dma_read_resp_last.value = 1
    dut.read_response_packet_ready.value = 1
    dut.inbound_resp_valid.value = 0
    dut.inbound_resp_meta.value = 0
    dut.inbound_resp_payload_valid.value = 0
    dut.inbound_resp_payload.value = 0
    dut.local_write_ready.value = 1
    dut.completion_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def issue_read_req(dut, length=16):
    dut.read_req.value = pack_read_req(length=length)
    dut.read_req_valid.value = 1
    while int(dut.read_req_ready.value) == 0:
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.read_req_valid.value = 0


async def wait_signal(dut, signal_name, cycles=32):
    signal = getattr(dut, signal_name)
    for _ in range(cycles):
        await Timer(1, units="ns")
        if int(signal.value) == 1:
            await RisingEdge(dut.clk)
            return
        await RisingEdge(dut.clk)
    raise AssertionError(f"{signal_name} not asserted")


async def wait_completion(dut):
    for _ in range(48):
        await Timer(1, units="ns")
        if int(dut.completion_valid.value) == 1:
            event = int(dut.completion_event.value)
            await RisingEdge(dut.clk)
            return event
        await RisingEdge(dut.clk)
    raise AssertionError("completion_valid not asserted")


@cocotb.test()
async def requester_generates_rdma_read_request_packet(dut):
    await reset_dut(dut)
    await issue_read_req(dut, length=32)
    await wait_signal(dut, "read_request_packet_valid")
    pkt = int(dut.read_request_packet.value)
    assert extract_field(BUILD_REQ_FIELDS, pkt, "opcode") == ROCE_OPCODE_RDMA_READ_REQ
    assert extract_field(BUILD_REQ_FIELDS, pkt, "dest_qpn") == 0x654321
    assert extract_field(BUILD_REQ_FIELDS, pkt, "remote_va") == 0x200000
    assert extract_field(BUILD_REQ_FIELDS, pkt, "rkey") == 0x2222
    assert extract_field(BUILD_REQ_FIELDS, pkt, "dma_length") == 32


@cocotb.test()
async def inbound_read_request_triggers_mr_check_dma_read_and_response(dut):
    await reset_dut(dut)
    dut.inbound_read_req_meta.value = pack_meta(ROCE_OPCODE_RDMA_READ_REQ, psn=0x10, length=16)
    dut.inbound_read_req_valid.value = 1
    await RisingEdge(dut.clk)
    dut.inbound_read_req_valid.value = 0
    await wait_signal(dut, "mr_check_valid")
    dut.mr_check_allowed.value = 1
    dut.mr_check_physical_addr.value = 0xABC000
    dut.mr_check_resp_valid.value = 1
    await RisingEdge(dut.clk)
    dut.mr_check_resp_valid.value = 0
    await wait_signal(dut, "dma_read_req_valid")
    assert int(dut.dma_read_req_addr.value) == 0xABC000
    dut.dma_read_resp_data.value = 0x1234
    dut.dma_read_resp_len.value = 16
    dut.dma_read_resp_valid.value = 1
    await RisingEdge(dut.clk)
    dut.dma_read_resp_valid.value = 0
    await wait_signal(dut, "read_response_packet_valid")
    pkt = int(dut.read_response_packet.value)
    assert extract_field(BUILD_REQ_FIELDS, pkt, "opcode") == ROCE_OPCODE_RDMA_READ_RESP
    assert extract_field(BUILD_REQ_FIELDS, pkt, "payload_len") == 16


@cocotb.test()
async def read_response_payload_writes_local_buffer_and_completes(dut):
    await reset_dut(dut)
    await issue_read_req(dut, length=16)
    await wait_signal(dut, "read_request_packet_valid")
    dut.inbound_resp_meta.value = pack_meta(ROCE_OPCODE_RDMA_READ_RESP, psn=0x900, length=16)
    dut.inbound_resp_payload.value = pack_payload(psn=0x900, valid_bytes=16)
    dut.inbound_resp_valid.value = 1
    dut.inbound_resp_payload_valid.value = 1
    await RisingEdge(dut.clk)
    dut.inbound_resp_valid.value = 0
    dut.inbound_resp_payload_valid.value = 0
    await wait_signal(dut, "local_write_valid")
    write_req = int(dut.local_write.value)
    assert extract_field(LOCAL_WRITE_FIELDS, write_req, "local_va") == 0x100000
    assert extract_field(LOCAL_WRITE_FIELDS, write_req, "byte_len") == 16
    event = await wait_completion(dut)
    assert extract_field(COMPLETION_FIELDS, event, "status") == CMPL_SUCCESS
    assert extract_field(COMPLETION_FIELDS, event, "byte_len") == 16


@cocotb.test()
async def multiple_response_packets_are_sequenced_by_psn(dut):
    await reset_dut(dut)
    await issue_read_req(dut, length=16)
    await wait_signal(dut, "read_request_packet_valid")
    for psn, offset in [(0x900, 0), (0x901, 8)]:
        dut.inbound_resp_meta.value = pack_meta(ROCE_OPCODE_RDMA_READ_RESP, psn=psn, length=8)
        dut.inbound_resp_payload.value = pack_payload(psn=psn, valid_bytes=8)
        dut.inbound_resp_valid.value = 1
        dut.inbound_resp_payload_valid.value = 1
        await RisingEdge(dut.clk)
        dut.inbound_resp_valid.value = 0
        dut.inbound_resp_payload_valid.value = 0
        await wait_signal(dut, "local_write_valid")
        write_req = int(dut.local_write.value)
        assert extract_field(LOCAL_WRITE_FIELDS, write_req, "byte_offset") == offset
    event = await wait_completion(dut)
    assert extract_field(COMPLETION_FIELDS, event, "status") == CMPL_SUCCESS


@cocotb.test()
async def response_psn_mismatch_generates_completion_error(dut):
    await reset_dut(dut)
    await issue_read_req(dut, length=16)
    await wait_signal(dut, "read_request_packet_valid")
    dut.inbound_resp_meta.value = pack_meta(ROCE_OPCODE_RDMA_READ_RESP, psn=0x901, length=16)
    dut.inbound_resp_payload.value = pack_payload(psn=0x901, valid_bytes=16)
    dut.inbound_resp_valid.value = 1
    dut.inbound_resp_payload_valid.value = 1
    await RisingEdge(dut.clk)
    dut.inbound_resp_valid.value = 0
    dut.inbound_resp_payload_valid.value = 0
    event = await wait_completion(dut)
    assert extract_field(COMPLETION_FIELDS, event, "status") == CMPL_BAD_RESP_ERR


@cocotb.test()
async def mr_permission_denied_maps_to_completion_error(dut):
    await reset_dut(dut)
    dut.inbound_read_req_meta.value = pack_meta(ROCE_OPCODE_RDMA_READ_REQ, psn=0x10, length=16)
    dut.inbound_read_req_valid.value = 1
    await RisingEdge(dut.clk)
    dut.inbound_read_req_valid.value = 0
    await wait_signal(dut, "mr_check_valid")
    dut.mr_check_allowed.value = 0
    dut.mr_check_error_code.value = 0x1234
    dut.mr_check_resp_valid.value = 1
    await RisingEdge(dut.clk)
    dut.mr_check_resp_valid.value = 0
    event = await wait_completion(dut)
    assert extract_field(COMPLETION_FIELDS, event, "status") == CMPL_REM_ACCESS_ERR


@cocotb.test()
async def dma_read_error_maps_to_completion_error(dut):
    await reset_dut(dut)
    dut.inbound_read_req_meta.value = pack_meta(ROCE_OPCODE_RDMA_READ_REQ, psn=0x10, length=16)
    dut.inbound_read_req_valid.value = 1
    await RisingEdge(dut.clk)
    dut.inbound_read_req_valid.value = 0
    await wait_signal(dut, "mr_check_valid")
    dut.mr_check_allowed.value = 1
    dut.mr_check_physical_addr.value = 0xABC000
    dut.mr_check_resp_valid.value = 1
    await RisingEdge(dut.clk)
    dut.mr_check_resp_valid.value = 0
    await wait_signal(dut, "dma_read_req_valid")
    dut.dma_read_resp_error.value = 1
    dut.dma_read_resp_len.value = 16
    dut.dma_read_resp_valid.value = 1
    await RisingEdge(dut.clk)
    dut.dma_read_resp_valid.value = 0
    event = await wait_completion(dut)
    assert extract_field(COMPLETION_FIELDS, event, "status") == CMPL_DMA_ERR
