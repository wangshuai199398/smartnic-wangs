# SPDX-License-Identifier: MIT
"""Stage 8 packet processing mock integration tests.

This file complements the module-level Cocotb tests by covering the task 8.6
matrix in a pure-Python mock flow. It intentionally does not model real PCIe,
MAC, RoCEv2 transport state, or a real ICRC calculator.
"""

ROCE_OPCODE_SEND_ONLY = 0x04
ROCE_OPCODE_SEND_ONLY_IMM = 0x05
ROCE_OPCODE_RDMA_WRITE_ONLY = 0x0A
ROCE_OPCODE_RDMA_READ_REQ = 0x0C
ROCE_OPCODE_RDMA_READ_RESP = 0x10
ROCE_OPCODE_ACK = 0x11
ROCE_OPCODE_CNP = 0x81
ROCE_OPCODE_UD_SEND_ONLY = 0x64

ETH_TYPE_IPV4 = 0x0800
IPV4_VERSION = 4
IPV4_IHL = 5
IP_PROTO_UDP = 17
ROCE_UDP_PORT = 4791
BTH_TRANSPORT_VERSION = 0

VALIDATION_OK = "ok"
ICRC_PLACEHOLDER = "placeholder"
ICRC_UNCHECKED = "unchecked"

SUPPORTED_OPCODES = [
    ROCE_OPCODE_SEND_ONLY,
    ROCE_OPCODE_SEND_ONLY_IMM,
    ROCE_OPCODE_RDMA_WRITE_ONLY,
    ROCE_OPCODE_RDMA_READ_REQ,
    ROCE_OPCODE_RDMA_READ_RESP,
    ROCE_OPCODE_ACK,
    ROCE_OPCODE_CNP,
    ROCE_OPCODE_UD_SEND_ONLY,
]


def make_packet(opcode=ROCE_OPCODE_SEND_ONLY, payload_len=8, **overrides):
    pkt = {
        "desc_id": 0x55,
        "qpn": 0x123456,
        "cqn": 0x44,
        "owner_function": 1,
        "pd_id": 7,
        "ethertype": ETH_TYPE_IPV4,
        "ip_version": IPV4_VERSION,
        "ip_ihl": IPV4_IHL,
        "ip_protocol": IP_PROTO_UDP,
        "udp_dst_port": ROCE_UDP_PORT,
        "bth_transport_version": BTH_TRANSPORT_VERSION,
        "opcode": opcode,
        "pkey": 0xFFFF,
        "dest_qpn": 0x654321,
        "src_qpn": 0x123456,
        "psn": 0x010203,
        "remote_va": 0x1000200030004000,
        "rkey": 0xABCDEF01,
        "dma_length": 0x20,
        "aeth": 0xCAFEBABE,
        "qkey": 0x11112222,
        "imm_data": 0xA1B2C3D4,
        "payload_offset": header_length_for_opcode(opcode),
        "payload_len": payload_len,
        "payload": bytes(range(payload_len)),
        "icrc": 0xFEEDFACE,
        "checksum_ok": True,
    }
    pkt["frame_len"] = pkt["payload_offset"] + pkt["payload_len"] + 4
    pkt["ip_total_length"] = pkt["frame_len"] - 14
    pkt["udp_length"] = pkt["ip_total_length"] - 20
    pkt.update(overrides)
    return pkt


def header_length_for_opcode(opcode):
    base = 14 + 20 + 8 + 12
    if opcode in (ROCE_OPCODE_RDMA_WRITE_ONLY, ROCE_OPCODE_RDMA_READ_REQ):
        return base + 16
    if opcode in (ROCE_OPCODE_RDMA_READ_RESP, ROCE_OPCODE_ACK):
        return base + 4
    if opcode == ROCE_OPCODE_SEND_ONLY_IMM:
        return base + 4
    if opcode == ROCE_OPCODE_UD_SEND_ONLY:
        return base + 8
    return base


def parse_headers(packet):
    return {
        "opcode": packet["opcode"],
        "dest_qpn": packet["dest_qpn"],
        "psn": packet["psn"],
        "pkey": packet["pkey"],
        "remote_va": packet["remote_va"],
        "rkey": packet["rkey"],
        "aeth": packet["aeth"],
        "qkey": packet["qkey"],
        "src_qpn": packet["src_qpn"],
        "imm_data": packet["imm_data"],
        "payload_offset": packet["payload_offset"],
        "payload_len": packet["payload_len"],
        "icrc": packet["icrc"],
    }


def validate_packet(packet):
    if packet["ethertype"] != ETH_TYPE_IPV4:
        return "ethertype"
    if packet["ip_version"] != IPV4_VERSION:
        return "ip_version"
    if packet["ip_ihl"] != IPV4_IHL:
        return "ihl"
    if packet["ip_protocol"] != IP_PROTO_UDP:
        return "protocol"
    if packet["udp_dst_port"] != ROCE_UDP_PORT:
        return "udp_port"
    if packet["bth_transport_version"] != BTH_TRANSPORT_VERSION:
        return "bth_version"
    if packet["opcode"] not in SUPPORTED_OPCODES:
        return "opcode"
    if not packet["checksum_ok"]:
        return "checksum"
    if packet["frame_len"] != packet["payload_offset"] + packet["payload_len"] + 4:
        return "length"
    return VALIDATION_OK


def extract_payload(packet):
    parsed = parse_headers(packet)
    return {
        "desc_id": packet["desc_id"],
        "qpn": packet["qpn"],
        "cqn": packet["cqn"],
        "owner_function": packet["owner_function"],
        "pd_id": packet["pd_id"],
        "opcode": packet["opcode"],
        "payload": packet["payload"],
        "payload_len": parsed["payload_len"],
        "byte_offset": 0,
        "first": True,
        "last": True,
    }


def build_headers(packet):
    return {
        "ethertype": ETH_TYPE_IPV4,
        "ip_version": IPV4_VERSION,
        "ip_protocol": IP_PROTO_UDP,
        "udp_dst_port": ROCE_UDP_PORT,
        "opcode": packet["opcode"],
        "dest_qpn": packet["dest_qpn"],
        "psn": packet["psn"],
        "payload_len": packet["payload_len"],
        "icrc": packet["icrc"],
    }


def icrc_placeholder(packet, is_tx=True):
    return {
        "status": ICRC_PLACEHOLDER if is_tx else ICRC_UNCHECKED,
        "icrc_value": packet["icrc"],
        "compatibility_limited": True,
    }


def test_every_supported_opcode_is_parsed_and_accepted():
    for opcode in SUPPORTED_OPCODES:
        packet = make_packet(opcode=opcode, payload_len=0)
        parsed = parse_headers(packet)
        assert parsed["opcode"] == opcode
        assert validate_packet(packet) == VALIDATION_OK


def test_invalid_packet_drop_matrix():
    cases = [
        ("ethertype", {"ethertype": 0x86DD}),
        ("ip_version", {"ip_version": 6}),
        ("ihl", {"ip_ihl": 6}),
        ("protocol", {"ip_protocol": 6}),
        ("udp_port", {"udp_dst_port": 1234}),
        ("bth_version", {"bth_transport_version": 1}),
        ("opcode", {"opcode": 0xFE}),
        ("checksum", {"checksum_ok": False}),
        ("length", {"frame_len": 12}),
    ]
    for expected, overrides in cases:
        assert validate_packet(make_packet(**overrides)) == expected


def test_header_field_extraction_for_extended_headers():
    rdma_write = parse_headers(make_packet(opcode=ROCE_OPCODE_RDMA_WRITE_ONLY))
    assert rdma_write["remote_va"] == 0x1000200030004000
    assert rdma_write["rkey"] == 0xABCDEF01

    ack = parse_headers(make_packet(opcode=ROCE_OPCODE_ACK, payload_len=0))
    assert ack["aeth"] == 0xCAFEBABE

    ud = parse_headers(make_packet(opcode=ROCE_OPCODE_UD_SEND_ONLY, payload_len=0))
    assert ud["qkey"] == 0x11112222
    assert ud["src_qpn"] == 0x123456

    imm = parse_headers(make_packet(opcode=ROCE_OPCODE_SEND_ONLY_IMM, payload_len=0))
    assert imm["imm_data"] == 0xA1B2C3D4


def test_header_generation_for_supported_opcodes():
    for opcode in SUPPORTED_OPCODES:
        packet = make_packet(opcode=opcode, payload_len=0)
        header = build_headers(packet)
        assert header["ethertype"] == ETH_TYPE_IPV4
        assert header["udp_dst_port"] == ROCE_UDP_PORT
        assert header["opcode"] == opcode
        assert header["dest_qpn"] == 0x654321


def test_payload_alignment_and_metadata_preservation():
    packet = make_packet(opcode=ROCE_OPCODE_SEND_ONLY, payload_len=8)
    payload = extract_payload(packet)
    assert payload["payload"] == bytes(range(8))
    assert payload["payload_len"] == 8
    assert payload["byte_offset"] == 0
    assert payload["first"] is True
    assert payload["last"] is True
    assert payload["desc_id"] == 0x55
    assert payload["qpn"] == 0x123456
    assert payload["owner_function"] == 1


def test_icrc_placeholder_behavior_marks_known_limitation():
    packet = make_packet()
    tx = icrc_placeholder(packet, is_tx=True)
    rx = icrc_placeholder(packet, is_tx=False)
    assert tx["status"] == ICRC_PLACEHOLDER
    assert rx["status"] == ICRC_UNCHECKED
    assert tx["icrc_value"] == packet["icrc"]
    assert rx["icrc_value"] == packet["icrc"]
    assert tx["compatibility_limited"] is True
    assert rx["compatibility_limited"] is True


def run_all():
    tests = [
        test_every_supported_opcode_is_parsed_and_accepted,
        test_invalid_packet_drop_matrix,
        test_header_field_extraction_for_extended_headers,
        test_header_generation_for_supported_opcodes,
        test_payload_alignment_and_metadata_preservation,
        test_icrc_placeholder_behavior_marks_known_limitation,
    ]
    for test in tests:
        test()


if __name__ == "__main__":
    run_all()
    print("stage 8 packet mock integration tests passed")
