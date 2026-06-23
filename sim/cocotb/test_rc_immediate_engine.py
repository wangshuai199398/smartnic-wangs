# SPDX-License-Identifier: MIT
"""RC immediate-data handling tests for task 9.4."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


RDMA_OP_SEND = 0x00
RDMA_OP_SEND_WITH_IMM = 0x01
RDMA_OP_RDMA_WRITE = 0x02
RDMA_OP_RDMA_WRITE_WITH_IMM = 0x03
ROCE_OPCODE_SEND_ONLY = 0x04
ROCE_OPCODE_SEND_ONLY_IMM = 0x05
ROCE_OPCODE_RDMA_WRITE_ONLY = 0x0A
ROCE_OPCODE_RDMA_WRITE_ONLY_IMM = 0x0B
CMPL_SUCCESS = 0


WQE_FIELDS = [
    ("opcode", 8), ("flags", 8), ("sge_count", 8), ("wr_id", 64),
    ("local_va", 64), ("lkey", 32), ("length", 32), ("remote_va", 64),
    ("rkey", 32), ("imm_data", 32), ("inv_rkey", 32),
    ("compare_add", 64), ("swap", 64),
]

SQ_DISPATCH_FIELDS = [
    ("owner_func", 16), ("qpn", 24), ("opcode", 8), ("qp_type", 3),
    ("pd_id", 24), ("send_cqn", 24), ("sq_consumer", 16),
    ("wqe", sum(width for _, width in WQE_FIELDS)),
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

META_FIELDS = [
    ("desc_id", 16), ("qpn", 24), ("cqn", 24), ("owner_function", 16),
    ("pd_id", 24), ("opcode", 8), ("status", 4), ("frame_len", 16),
    ("ethertype", 16), ("has_vlan", 1), ("vlan_tci", 16),
    ("ip_version", 4), ("ip_ihl", 4), ("ip_total_length", 16),
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
    ("data", 512), ("payload_len", 16), ("valid_bytes", 16),
    ("byte_offset", 16), ("first", 1), ("last", 1), ("has_imm", 1),
    ("imm_data", 32), ("remote_va", 64), ("rkey", 32), ("dma_length", 32),
    ("dest_qpn", 24), ("psn", 24),
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


def pack_wqe(opcode, imm=0x11223344, length=16):
    return pack_fields(WQE_FIELDS, {
        "opcode": opcode,
        "wr_id": 0xCAFE,
        "local_va": 0x100000,
        "lkey": 0x1111,
        "length": length,
        "remote_va": 0x200000,
        "rkey": 0x2222,
        "imm_data": imm,
    })


def pack_sq_req(opcode, imm=0x11223344, length=16):
    return pack_fields(SQ_DISPATCH_FIELDS, {
        "owner_func": 1,
        "qpn": 0x123456,
        "opcode": opcode,
        "qp_type": 0,
        "pd_id": 7,
        "send_cqn": 0x44,
        "sq_consumer": 0x55,
        "wqe": pack_wqe(opcode, imm=imm, length=length),
    })


def pack_meta(opcode, imm=0x11223344, has_imm=1, payload_len=16):
    return pack_fields(META_FIELDS, {
        "desc_id": 0x77,
        "qpn": 0x123456,
        "cqn": 0x44,
        "owner_function": 1,
        "pd_id": 7,
        "opcode": opcode,
        "dest_qpn": 0x123456,
        "psn": 0x100,
        "has_reth": 1 if opcode in (ROCE_OPCODE_RDMA_WRITE_ONLY,
                                    ROCE_OPCODE_RDMA_WRITE_ONLY_IMM) else 0,
        "remote_va": 0x200000,
        "rkey": 0x2222,
        "dma_length": payload_len,
        "has_imm": has_imm,
        "imm_data": imm,
        "payload_len": payload_len,
    })


def pack_payload(opcode, payload_len=16, has_imm=0, imm=0):
    return pack_fields(PAYLOAD_FIELDS, {
        "desc_id": 0x77,
        "qpn": 0x123456,
        "cqn": 0x44,
        "owner_function": 1,
        "pd_id": 7,
        "opcode": opcode,
        "data": 0xA5,
        "payload_len": payload_len,
        "valid_bytes": payload_len,
        "first": 1,
        "last": 1,
        "has_imm": has_imm,
        "imm_data": imm,
        "dest_qpn": 0x123456,
    })


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.tx_req_valid.value = 0
    dut.tx_req.value = 0
    dut.tx_psn.value = 0x100
    dut.tx_packet_ready.value = 1
    dut.rx_valid.value = 0
    dut.rx_meta.value = 0
    dut.rx_payload.value = 0
    dut.rq_available.value = 1
    dut.rq_wr_id.value = 0xBEEF
    dut.recv_cqn.value = 0x44
    dut.remote_write_ready.value = 1
    dut.remote_write_done_valid.value = 0
    dut.remote_write_ok.value = 0
    dut.remote_write_error_code.value = 0
    dut.completion_ready.value = 1
    dut.rnr_error_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def wait_valid(dut, name, cycles=32):
    sig = getattr(dut, name)
    for _ in range(cycles):
        await Timer(1, units="ns")
        if int(sig.value) == 1:
            value = None
            if name == "completion_valid":
                value = int(dut.completion_event.value)
            elif name == "tx_packet_valid":
                value = int(dut.tx_packet.value)
            await RisingEdge(dut.clk)
            return value
        await RisingEdge(dut.clk)
    raise AssertionError(f"{name} not asserted")


async def send_rx(dut, opcode, rq_available=1, remote_ok=True, has_imm=1, imm=0x11223344):
    dut.rq_available.value = rq_available
    dut.rx_meta.value = pack_meta(opcode, imm=imm, has_imm=has_imm)
    dut.rx_payload.value = pack_payload(opcode, has_imm=has_imm, imm=imm)
    dut.rx_valid.value = 1
    await RisingEdge(dut.clk)
    dut.rx_valid.value = 0
    if opcode == ROCE_OPCODE_RDMA_WRITE_ONLY_IMM and rq_available:
        await wait_valid(dut, "remote_write_valid")
        dut.remote_write_ok.value = 1 if remote_ok else 0
        dut.remote_write_error_code.value = 0 if remote_ok else 0x1234
        dut.remote_write_done_valid.value = 1
        await RisingEdge(dut.clk)
        dut.remote_write_done_valid.value = 0


@cocotb.test()
async def send_with_imm_receive_completion_carries_imm(dut):
    await reset_dut(dut)
    await send_rx(dut, ROCE_OPCODE_SEND_ONLY_IMM, imm=0x11223344)
    event = await wait_valid(dut, "completion_valid")
    assert extract_field(COMPLETION_FIELDS, event, "opcode") == RDMA_OP_SEND_WITH_IMM
    assert extract_field(COMPLETION_FIELDS, event, "has_imm") == 1
    assert extract_field(COMPLETION_FIELDS, event, "imm_data") == 0x11223344


@cocotb.test()
async def rdma_write_with_imm_writes_remote_memory_and_completes_with_imm(dut):
    await reset_dut(dut)
    await send_rx(dut, ROCE_OPCODE_RDMA_WRITE_ONLY_IMM, imm=0x11223344, remote_ok=True)
    event = await wait_valid(dut, "completion_valid")
    assert extract_field(COMPLETION_FIELDS, event, "opcode") == RDMA_OP_RDMA_WRITE_WITH_IMM
    assert extract_field(COMPLETION_FIELDS, event, "has_imm") == 1
    assert extract_field(COMPLETION_FIELDS, event, "imm_data") == 0x11223344
    assert extract_field(COMPLETION_FIELDS, event, "status") == CMPL_SUCCESS


@cocotb.test()
async def tx_immediate_packet_uses_network_byte_order_value(dut):
    await reset_dut(dut)
    dut.tx_req.value = pack_sq_req(RDMA_OP_SEND_WITH_IMM, imm=0x11223344)
    dut.tx_req_valid.value = 1
    await RisingEdge(dut.clk)
    dut.tx_req_valid.value = 0
    pkt = await wait_valid(dut, "tx_packet_valid")
    assert extract_field(BUILD_REQ_FIELDS, pkt, "opcode") == ROCE_OPCODE_SEND_ONLY_IMM
    assert extract_field(BUILD_REQ_FIELDS, pkt, "has_imm") == 1
    assert extract_field(BUILD_REQ_FIELDS, pkt, "imm_data") == 0x11223344


@cocotb.test()
async def send_with_imm_without_rq_reports_rnr(dut):
    await reset_dut(dut)
    await send_rx(dut, ROCE_OPCODE_SEND_ONLY_IMM, rq_available=0)
    await wait_valid(dut, "rnr_error_valid")


@cocotb.test()
async def rdma_write_with_imm_without_rq_reports_rnr(dut):
    await reset_dut(dut)
    await send_rx(dut, ROCE_OPCODE_RDMA_WRITE_ONLY_IMM, rq_available=0)
    await wait_valid(dut, "rnr_error_valid")


@cocotb.test()
async def rdma_write_with_imm_remote_access_error_does_not_generate_recv_cqe(dut):
    await reset_dut(dut)
    await send_rx(dut, ROCE_OPCODE_RDMA_WRITE_ONLY_IMM, remote_ok=False)
    for _ in range(8):
        await RisingEdge(dut.clk)
        assert int(dut.completion_valid.value) == 0


@cocotb.test()
async def normal_send_is_rejected_by_immediate_engine_and_sets_no_imm_flag(dut):
    await reset_dut(dut)
    await send_rx(dut, ROCE_OPCODE_SEND_ONLY, has_imm=0)
    for _ in range(4):
        await RisingEdge(dut.clk)
        assert int(dut.completion_valid.value) == 0


@cocotb.test()
async def normal_rdma_write_does_not_generate_receive_cqe(dut):
    await reset_dut(dut)
    await send_rx(dut, ROCE_OPCODE_RDMA_WRITE_ONLY, has_imm=0)
    for _ in range(4):
        await RisingEdge(dut.clk)
        assert int(dut.completion_valid.value) == 0
