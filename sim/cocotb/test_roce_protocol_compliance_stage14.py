# SPDX-License-Identifier: MIT
"""Stage 14.8 RoCEv2/RDMA protocol compliance tests.

The suite checks protocol-visible packet fields and error behavior using the
reusable Ethernet/RoCEv2 BFM, scoreboard, host memory model, and coverage
collector. It deliberately avoids the regression orchestration reserved for
14.9 and treats ICRC as the current BFM placeholder model.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from bfm import (
    CompletionStatus,
    CoverageCategory,
    EthernetRoceBfm,
    ExpectedWorkRequest,
    HostMemoryModel,
    ObservedCqe,
    QpType,
    RdmaCoverageCollector,
    RdmaScoreboard,
    RoceBfmError,
    RoceOpcode,
    RocePacket,
    ScoreboardError,
    SgeRef,
    WrOpcode,
)


AETH_ACK = 0x0000_0000
AETH_NAK_SEQUENCE = 0x8000_0001
AETH_NAK_RNR = 0x8000_0002


def expect_error(fn, exc_type=Exception, text: str | None = None):
    try:
        fn()
    except exc_type as exc:
        if text is not None:
            assert text in str(exc)
        return exc
    raise AssertionError(f"expected {exc_type.__name__}")


@dataclass
class ProtocolHarness:
    qpn: int = 0x123456
    expected_psn: int = 0x100
    rnr_retry_limit: int = 1
    memory: HostMemoryModel = field(default_factory=lambda: HostMemoryModel(base_addr=0x5000_0000, size=1 << 16))
    bfm: EthernetRoceBfm = field(default_factory=EthernetRoceBfm)
    coverage: RdmaCoverageCollector = field(default_factory=RdmaCoverageCollector)

    def __post_init__(self) -> None:
        self.scoreboard = RdmaScoreboard(self.memory)
        self.scoreboard.set_expected_psn(self.qpn, self.expected_psn)
        self.scoreboard.retry[self.qpn] = self.scoreboard.retry.get(self.qpn) or type("RetryStateShim", (), {})()
        self.rnr_retries = 0
        self.dropped = 0
        self.error_cqes: list[ObservedCqe] = []

    def build_parse(self, packet: RocePacket, **kwargs) -> RocePacket:
        parsed = self.bfm.parse_frame(self.bfm.build_roce_frame(packet, **kwargs), has_icrc=kwargs.get("include_icrc", False)).roce
        self.coverage.sample_packet(parsed)
        return parsed

    def accept_packet(self, packet: RocePacket, opcode: WrOpcode | None = None) -> None:
        self.scoreboard.observe_packet(packet, opcode)
        self.coverage.sample_packet(packet)

    def handle_ack(self, ack: RocePacket) -> str:
        if ack.opcode != RoceOpcode.ACK:
            raise ValueError("not an ACK/NAK packet")
        if ack.aeth == AETH_ACK:
            self.expected_psn = (ack.psn + 1) & 0x00FF_FFFF
            self.coverage.sample_opcode(WrOpcode.SEND, ack=True)
            return "ACK"
        self.coverage.sample_opcode(WrOpcode.SEND, nak=True)
        if ack.aeth == AETH_NAK_RNR:
            self.rnr_retries += 1
            if self.rnr_retries > self.rnr_retry_limit:
                cqe = ObservedCqe(
                    wr_id=0xBEEF,
                    qpn=self.qpn,
                    opcode=WrOpcode.SEND,
                    status=CompletionStatus.RNR_RETRY_EXCEEDED,
                    byte_len=0,
                    vendor_err=AETH_NAK_RNR,
                )
                self.error_cqes.append(cqe)
                self.coverage.sample_cqe(cqe)
                return "RNR_EXHAUSTED"
            return "RNR_RETRY"
        if ack.aeth == AETH_NAK_SEQUENCE:
            return "NAK_RETRY"
        return "NAK_UNKNOWN"

    def drop_packet(self) -> None:
        self.dropped += 1


def test_rocev2_header_fields_are_encoded_and_parsed():
    h = ProtocolHarness()
    packet = RocePacket(
        opcode=RoceOpcode.RDMA_WRITE_ONLY,
        dest_qpn=0xABCDE,
        psn=0x10203,
        pkey=0xBEEF,
        remote_va=0x1000_2000_3000_4000,
        rkey=0xCAFEBABE,
        payload=b"protocol-payload",
        solicited=True,
        ack_req=True,
    )
    raw = h.bfm.build_roce_frame(packet, vlan_tci=0x123, dscp_ecn=0x02, include_fcs=True)
    parsed = h.bfm.parse_frame(raw, has_fcs=True)

    assert parsed.ethernet.vlan_tci == 0x123
    assert parsed.ipv4_udp.dscp_ecn == 0x02
    assert parsed.ipv4_udp.dst_port == 4791
    assert parsed.roce.opcode == RoceOpcode.RDMA_WRITE_ONLY
    assert parsed.roce.dest_qpn == 0xABCDE
    assert parsed.roce.psn == 0x10203
    assert parsed.roce.pkey == 0xBEEF
    assert parsed.roce.ack_req is True
    assert parsed.roce.solicited is True
    assert parsed.roce.remote_va == 0x1000_2000_3000_4000
    assert parsed.roce.rkey == 0xCAFEBABE
    assert parsed.roce.dma_length == len(b"protocol-payload")
    assert parsed.roce.payload == b"protocol-payload"
    h.coverage.sample_packet(parsed.roce)


def test_ack_and_nak_update_psn_retry_expectations():
    h = ProtocolHarness(qpn=0x200, expected_psn=0x300)
    send = h.bfm.build_rc_send(dest_qpn=0x200, psn=0x300, payload=b"x")
    h.accept_packet(send, WrOpcode.SEND)
    ack = h.bfm.build_ack(dest_qpn=0x200, psn=0x300, aeth=AETH_ACK)
    assert h.handle_ack(ack) == "ACK"
    assert h.expected_psn == 0x301

    seq_nak = h.bfm.build_ack(dest_qpn=0x200, psn=0x301, aeth=AETH_NAK_SEQUENCE)
    assert h.handle_ack(seq_nak) == "NAK_RETRY"
    assert h.coverage.bins[CoverageCategory.OPCODE]["ACK"].hits == 1
    assert h.coverage.bins[CoverageCategory.OPCODE]["NAK"].hits == 1


def test_rnr_nak_retry_and_retry_exhaustion_status():
    h = ProtocolHarness(qpn=0x201, expected_psn=0x400, rnr_retry_limit=1)
    rnr = h.bfm.build_ack(dest_qpn=0x201, psn=0x400, aeth=AETH_NAK_RNR)
    assert h.handle_ack(rnr) == "RNR_RETRY"
    assert h.handle_ack(rnr) == "RNR_EXHAUSTED"
    assert h.error_cqes[-1].status == CompletionStatus.RNR_RETRY_EXCEEDED
    assert h.error_cqes[-1].vendor_err == AETH_NAK_RNR


def test_send_and_rdma_write_immediate_data_reaches_cqe():
    h = ProtocolHarness(qpn=0x300)
    send_imm = RocePacket(opcode=RoceOpcode.RC_SEND_ONLY_IMM, dest_qpn=0x300, psn=0x100, imm_data=0x11223344)
    parsed_send = h.build_parse(send_imm)
    assert parsed_send.imm_data == 0x11223344
    assert b"\x11\x22\x33\x44" in send_imm.roce_payload()

    recv_wr = ExpectedWorkRequest(
        wr_id=0x9001,
        opcode=WrOpcode.RECV,
        qpn=0x300,
        byte_len=0,
        imm_data=0x11223344,
    )
    h.scoreboard.expect_wr(recv_wr)
    h.scoreboard.observe_cqe(
        ObservedCqe(0x9001, 0x300, WrOpcode.RECV, CompletionStatus.SUCCESS, byte_len=0, wc_flags=1, imm_data=0x11223344)
    )

    write_imm = RocePacket(
        opcode=RoceOpcode.RDMA_WRITE_ONLY_IMM,
        dest_qpn=0x300,
        psn=0x101,
        remote_va=0x5000_1000,
        rkey=0x1234,
        imm_data=0xAABBCCDD,
        payload=b"write",
    )
    parsed_write = h.build_parse(write_imm)
    assert parsed_write.imm_data == 0xAABBCCDD
    assert parsed_write.payload == b"write"
    h.coverage.sample_opcode(WrOpcode.RDMA_WRITE, immediate=True)
    h.scoreboard.finish()


def test_invalid_packets_are_rejected_without_false_success():
    h = ProtocolHarness(qpn=0x400)
    good = h.bfm.build_rc_send(dest_qpn=0x400, psn=0x100)

    expect_error(lambda: h.bfm.parse_frame(h.bfm.build_roce_frame(good, errors={"invalid_opcode": True})), RoceBfmError, "invalid BTH opcode")
    h.drop_packet()
    bad_qpn = h.bfm.parse_frame(h.bfm.build_roce_frame(good, errors={"invalid_dest_qp": True})).roce
    if bad_qpn.dest_qpn != h.qpn:
        h.drop_packet()
    expect_error(lambda: h.accept_packet(RocePacket(opcode=RoceOpcode.RC_SEND_ONLY, dest_qpn=0x400, psn=0x105), WrOpcode.SEND), ScoreboardError)
    h.drop_packet()
    expect_error(lambda: h.bfm.parse_frame(h.bfm.build_roce_frame(good, errors={"truncated_frame": True, "truncate_bytes": 24})), RoceBfmError)
    h.drop_packet()
    expect_error(lambda: h.bfm.parse_frame(h.bfm.build_roce_frame(good, errors={"bad_udp_length": True})), RoceBfmError, "invalid UDP length")
    h.drop_packet()

    assert h.dropped == 5
    expect_error(lambda: h.scoreboard.finish(), ScoreboardError)


def test_invalid_rkey_or_address_produces_remote_access_error():
    h = ProtocolHarness(qpn=0x500)
    remote = h.memory.allocate(16, init=b"\x00" * 16)
    expected = ExpectedWorkRequest(
        wr_id=0x5001,
        opcode=WrOpcode.RDMA_WRITE,
        qpn=0x500,
        byte_len=4,
        expected_status=CompletionStatus.REMOTE_ACCESS_ERROR,
        vendor_err=0xBAD0,
    )
    h.scoreboard.expect_wr(expected)
    write = h.bfm.build_rdma_write(0x500, 0x100, remote.dma_addr + 32, 0xDEAD, b"bad!")
    parsed = h.build_parse(write)
    assert parsed.rkey == 0xDEAD
    assert parsed.remote_va == remote.dma_addr + 32
    h.scoreboard.observe_cqe(
        ObservedCqe(0x5001, 0x500, WrOpcode.RDMA_WRITE, CompletionStatus.REMOTE_ACCESS_ERROR, byte_len=4, vendor_err=0xBAD0)
    )
    assert h.memory.read(remote.dma_addr, 4) == b"\x00\x00\x00\x00"
    h.scoreboard.finish()


def test_valid_icrc_is_accepted_and_bad_icrc_is_dropped():
    h = ProtocolHarness(qpn=0x600)
    packet = h.bfm.build_rc_send(dest_qpn=0x600, psn=0x100, payload=b"icrc-ok")
    parsed = h.bfm.parse_frame(h.bfm.build_roce_frame(packet, include_icrc=True), has_icrc=True)
    assert parsed.roce.payload == b"icrc-ok"
    assert parsed.roce.icrc is not None

    bad = h.bfm.build_roce_frame(packet, include_icrc=True, errors={"bad_icrc": True})
    expect_error(lambda: h.bfm.parse_frame(bad, has_icrc=True), RoceBfmError, "bad RoCE ICRC")
    h.scoreboard.expect_wr(ExpectedWorkRequest(0x6001, WrOpcode.RECV, 0x600, byte_len=len(b"icrc-ok")))
    expect_error(lambda: h.scoreboard.finish(), ScoreboardError)


def test_malformed_immediate_and_header_do_not_hang():
    h = ProtocolHarness(qpn=0x700)
    imm = RocePacket(opcode=RoceOpcode.RC_SEND_ONLY_IMM, dest_qpn=0x700, psn=0x100, imm_data=0x11223344)
    raw = h.bfm.build_roce_frame(imm)
    expect_error(lambda: h.bfm.parse_frame(raw[:-3]), RoceBfmError)

    short_bth = raw[:14 + 20 + 8 + 8]
    expect_error(lambda: h.bfm.parse_frame(short_bth), RoceBfmError)


def run_all():
    tests = [
        test_rocev2_header_fields_are_encoded_and_parsed,
        test_ack_and_nak_update_psn_retry_expectations,
        test_rnr_nak_retry_and_retry_exhaustion_status,
        test_send_and_rdma_write_immediate_data_reaches_cqe,
        test_invalid_packets_are_rejected_without_false_success,
        test_invalid_rkey_or_address_produces_remote_access_error,
        test_valid_icrc_is_accepted_and_bad_icrc_is_dropped,
        test_malformed_immediate_and_header_do_not_hang,
    ]
    for test in tests:
        test()


if __name__ == "__main__":
    run_all()
    print("stage 14.8 RoCEv2 protocol compliance tests passed")
