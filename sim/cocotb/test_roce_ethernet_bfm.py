# SPDX-License-Identifier: MIT
"""Unit tests for the Ethernet/RoCEv2 verification BFM."""

from bfm import EthernetFrame, EthernetRoceBfm, Ipv4UdpPacket, RoceBfmError, RoceOpcode, RocePacket


def expect_error(fn, text):
    try:
        fn()
    except RoceBfmError as exc:
        assert text in str(exc)
        return
    raise AssertionError(f"expected RoceBfmError containing {text!r}")


def test_ethernet_frame_round_trip_with_vlan_and_fcs():
    frame = EthernetFrame(
        dst_mac=bytes.fromhex("020000000002"),
        src_mac=bytes.fromhex("020000000001"),
        ethertype=0x0800,
        payload=b"payload",
        vlan_tci=0x123,
    )
    raw = frame.to_bytes(include_fcs=True)
    parsed = EthernetFrame.parse(raw, has_fcs=True)
    assert parsed.dst_mac == frame.dst_mac
    assert parsed.src_mac == frame.src_mac
    assert parsed.vlan_tci == 0x123
    assert parsed.ethertype == 0x0800
    assert parsed.payload == b"payload"


def test_ipv4_udp_checksum_and_length_generation():
    pkt = Ipv4UdpPacket(payload=b"abcdef")
    raw = pkt.to_bytes(checksum_udp=True)
    parsed = Ipv4UdpPacket.parse(raw, validate=True)
    assert parsed.dst_port == 4791
    assert parsed.payload == b"abcdef"
    assert int.from_bytes(raw[2:4], "big") == 20 + 8 + 6
    assert int.from_bytes(raw[24:26], "big") == 8 + 6


def test_roce_bth_construction_and_parsing_round_trip():
    roce = RocePacket(
        opcode=RoceOpcode.RC_SEND_ONLY,
        dest_qpn=0x123456,
        psn=0x010203,
        payload=b"hello",
        solicited=True,
        ack_req=True,
    )
    parsed = RocePacket.parse(roce.roce_payload())
    assert parsed.opcode == RoceOpcode.RC_SEND_ONLY
    assert parsed.dest_qpn == 0x123456
    assert parsed.psn == 0x010203
    assert parsed.solicited is True
    assert parsed.ack_req is True
    assert parsed.payload == b"hello"


def test_rc_send_packet_construction_and_parsing():
    bfm = EthernetRoceBfm()
    raw = bfm.build_roce_frame(bfm.build_rc_send(dest_qpn=7, psn=9, payload=b"send"))
    parsed = bfm.parse_frame(raw)
    assert parsed.is_roce is True
    assert parsed.roce.opcode == RoceOpcode.RC_SEND_ONLY
    assert parsed.roce.dest_qpn == 7
    assert parsed.roce.psn == 9
    assert parsed.roce.payload == b"send"


def test_rdma_write_reth_construction_and_parsing():
    bfm = EthernetRoceBfm()
    raw = bfm.build_roce_frame(
        bfm.build_rdma_write(
            dest_qpn=0x11,
            psn=0x22,
            remote_va=0x1000_2000_3000_4000,
            rkey=0xAABBCCDD,
            payload=b"write-data",
        )
    )
    parsed = bfm.parse_frame(raw)
    assert parsed.roce.opcode == RoceOpcode.RDMA_WRITE_ONLY
    assert parsed.roce.remote_va == 0x1000_2000_3000_4000
    assert parsed.roce.rkey == 0xAABBCCDD
    assert parsed.roce.dma_length == len(b"write-data")
    assert parsed.roce.payload == b"write-data"


def test_ack_and_ud_extension_headers_round_trip():
    bfm = EthernetRoceBfm()
    ack = bfm.parse_frame(bfm.build_roce_frame(bfm.build_ack(dest_qpn=1, psn=2, aeth=0xCAFEBABE))).roce
    assert ack.opcode == RoceOpcode.ACK
    assert ack.aeth == 0xCAFEBABE

    ud = bfm.parse_frame(bfm.build_roce_frame(bfm.build_ud_send(dest_qpn=3, psn=4, qkey=0x11112222, source_qpn=0x445566))).roce
    assert ud.opcode == RoceOpcode.UD_SEND_ONLY
    assert ud.qkey == 0x11112222
    assert ud.source_qpn == 0x445566


def test_immediate_data_network_byte_order():
    bfm = EthernetRoceBfm()
    packet = RocePacket(opcode=RoceOpcode.RC_SEND_ONLY_IMM, dest_qpn=1, psn=2, imm_data=0x11223344)
    raw = bfm.build_roce_frame(packet)
    assert b"\x11\x22\x33\x44" in raw
    parsed = bfm.parse_frame(raw)
    assert parsed.roce.imm_data == 0x11223344


def test_malformed_checksum_and_invalid_opcode_are_detected():
    bfm = EthernetRoceBfm()
    packet = bfm.build_rc_send(dest_qpn=1, psn=2)
    bad_ip = bfm.build_roce_frame(packet, errors={"bad_ipv4_checksum": True})
    expect_error(lambda: bfm.parse_frame(bad_ip), "bad IPv4 checksum")

    bad_opcode = bfm.build_roce_frame(packet, errors={"invalid_opcode": True})
    expect_error(lambda: bfm.parse_frame(bad_opcode), "invalid BTH opcode")


def test_error_injection_for_udp_length_icrc_fcs_and_truncation():
    bfm = EthernetRoceBfm()
    packet = bfm.build_rc_send(dest_qpn=1, psn=2, payload=b"payload")

    bad_udp_len = bfm.build_roce_frame(packet, errors={"bad_udp_length": True})
    expect_error(lambda: bfm.parse_frame(bad_udp_len), "invalid UDP length")

    bad_icrc = bfm.build_roce_frame(packet, include_icrc=True, errors={"bad_icrc": True})
    expect_error(lambda: bfm.parse_frame(bad_icrc, has_icrc=True), "bad RoCE ICRC")

    bad_fcs = bfm.build_roce_frame(packet, include_fcs=True, errors={"bad_fcs": True})
    expect_error(lambda: bfm.parse_frame(bad_fcs, has_fcs=True), "bad Ethernet FCS")

    truncated = bfm.build_roce_frame(packet, errors={"truncated_frame": True, "truncate_bytes": 12})
    expect_error(lambda: bfm.parse_frame(truncated), "invalid IPv4 total length")


def test_cnp_helper_builds_congestion_notification_packet():
    bfm = EthernetRoceBfm()
    cnp = bfm.build_cnp(dest_qpn=0x123456, source_qpn=0xABCDEF, congestion_type=1)
    parsed = bfm.parse_frame(bfm.build_roce_frame(cnp)).roce
    assert parsed.opcode == RoceOpcode.CNP
    assert parsed.dest_qpn == 0x123456
    assert parsed.cnp_source_qpn == 0xABCDEF
    assert parsed.congestion_type == 1


def test_pfc_pause_and_resume_helpers():
    bfm = EthernetRoceBfm()
    pause = bfm.build_pfc_frame(priorities=0b0000_0101, pause_quanta=0x2222)
    class_enable, quanta = bfm.parse_pfc_frame(pause)
    assert class_enable == 0b0000_0101
    assert quanta[0] == 0x2222
    assert quanta[2] == 0x2222
    assert quanta[1] == 0

    resume = bfm.build_pfc_frame(priorities=0b0000_0101, pause_quanta=0)
    _, resume_quanta = bfm.parse_pfc_frame(resume)
    assert resume_quanta[0] == 0
    assert resume_quanta[2] == 0


def test_packet_injection_and_observation_queues_preserve_order():
    bfm = EthernetRoceBfm()
    rx_seen = []
    tx_seen = []
    bfm.on_rx_frame = rx_seen.append
    bfm.on_tx_frame = tx_seen.append

    first = bfm.send_roce_packet(bfm.build_rc_send(dest_qpn=1, psn=1, payload=b"first"))
    second = bfm.build_roce_frame(bfm.build_rc_send(dest_qpn=1, psn=2, payload=b"second"))
    bfm.observe_tx_frame(second)

    assert rx_seen == [first]
    assert tx_seen == [second]
    assert bfm.rx_queue.pop(0) == first
    assert bfm.recv_roce_packet().roce.payload == b"second"


def run_all():
    tests = [
        test_ethernet_frame_round_trip_with_vlan_and_fcs,
        test_ipv4_udp_checksum_and_length_generation,
        test_roce_bth_construction_and_parsing_round_trip,
        test_rc_send_packet_construction_and_parsing,
        test_rdma_write_reth_construction_and_parsing,
        test_ack_and_ud_extension_headers_round_trip,
        test_immediate_data_network_byte_order,
        test_malformed_checksum_and_invalid_opcode_are_detected,
        test_error_injection_for_udp_length_icrc_fcs_and_truncation,
        test_cnp_helper_builds_congestion_notification_packet,
        test_pfc_pause_and_resume_helpers,
        test_packet_injection_and_observation_queues_preserve_order,
    ]
    for test in tests:
        test()


if __name__ == "__main__":
    run_all()
    print("Ethernet/RoCEv2 BFM unit tests passed")

