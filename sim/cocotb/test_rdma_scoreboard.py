# SPDX-License-Identifier: MIT
"""Unit tests for the reusable RDMA scoreboard."""

from bfm import (
    CompletionStatus,
    ExpectedWorkRequest,
    HostMemoryModel,
    ObservedCqe,
    PacketObservation,
    RdmaScoreboard,
    ScoreboardError,
    SgeRef,
    WrOpcode,
)


def expect_scoreboard_error(fn, text):
    try:
        fn()
    except ScoreboardError as exc:
        assert text in str(exc)
        return
    raise AssertionError(f"expected ScoreboardError containing {text!r}")


def test_successful_send_wr_matches_expected_cqe():
    sb = RdmaScoreboard()
    sb.expect_wr(ExpectedWorkRequest(wr_id=1, opcode=WrOpcode.SEND, qpn=0x10, byte_len=12))
    matched = sb.observe_cqe(ObservedCqe(wr_id=1, qpn=0x10, opcode=WrOpcode.SEND, byte_len=12))
    assert matched.wr_id == 1
    sb.finish()
    assert "completed=1" in sb.summary()


def test_successful_recv_wr_matches_cqe_and_payload():
    mem = HostMemoryModel(size=4096)
    recv_buf = mem.allocate(16, init=b"hello-rdma" + bytes(6))
    wr = ExpectedWorkRequest(wr_id=2, opcode=WrOpcode.RECV, qpn=0x11, sges=[SgeRef(recv_buf.dma_addr, 16)], byte_len=10)
    sb = RdmaScoreboard(mem)
    sb.expect_wr(wr)
    sb.observe_cqe(ObservedCqe(wr_id=2, qpn=0x11, opcode=WrOpcode.RECV, byte_len=10))
    sb.compare_recv_payload(wr, b"hello-rdma")
    sb.finish()


def test_rdma_write_payload_comparison_verifies_destination_memory():
    mem = HostMemoryModel(size=4096)
    dst = mem.allocate(8, init=b"ABCDEFGH")
    sb = RdmaScoreboard(mem)
    sb.compare_rdma_write_destination([SgeRef(dst.dma_addr, 8)], b"ABCDEFGH")
    expect_scoreboard_error(lambda: sb.compare_rdma_write_destination([SgeRef(dst.dma_addr, 8)], b"ABXDEFGH"), "mismatch")


def test_rdma_read_payload_comparison_verifies_returned_payload():
    mem = HostMemoryModel(size=4096)
    src = mem.allocate(8, init=b"readback")
    wr = ExpectedWorkRequest(wr_id=3, opcode=WrOpcode.RDMA_READ, qpn=0x12, sges=[SgeRef(src.dma_addr, 8)])
    sb = RdmaScoreboard(mem)
    sb.compare_rdma_read_response(wr, b"readback")
    expect_scoreboard_error(lambda: sb.compare_rdma_read_response(wr, b"readxxxx"), "RDMA_READ")


def test_missing_cqe_is_reported_at_end_of_test():
    sb = RdmaScoreboard()
    sb.expect_wr(ExpectedWorkRequest(wr_id=4, opcode=WrOpcode.SEND, qpn=0x13, byte_len=1))
    expect_scoreboard_error(sb.finish, "missing CQE")


def test_unexpected_cqe_is_reported_immediately():
    sb = RdmaScoreboard()
    expect_scoreboard_error(lambda: sb.observe_cqe(ObservedCqe(wr_id=5, qpn=0x14, opcode=WrOpcode.SEND)), "unexpected CQE")


def test_out_of_order_cqe_is_detected_when_ordering_required():
    sb = RdmaScoreboard()
    sb.expect_wr(ExpectedWorkRequest(wr_id=6, opcode=WrOpcode.SEND, qpn=0x15, byte_len=1))
    sb.expect_wr(ExpectedWorkRequest(wr_id=7, opcode=WrOpcode.SEND, qpn=0x15, byte_len=1))
    expect_scoreboard_error(lambda: sb.observe_cqe(ObservedCqe(wr_id=7, qpn=0x15, opcode=WrOpcode.SEND, byte_len=1)), "out-of-order")


def test_psn_increment_and_gap_detection_work():
    sb = RdmaScoreboard()
    sb.set_expected_psn(qpn=0x20, psn=0x100)
    sb.observe_packet(PacketObservation(qpn=0x20, psn=0x100, opcode=WrOpcode.SEND))
    sb.observe_packet(PacketObservation(qpn=0x20, psn=0x101, opcode=WrOpcode.SEND))
    assert sb.psn[0x20].expected_psn == 0x102
    expect_scoreboard_error(lambda: sb.observe_packet(PacketObservation(qpn=0x20, psn=0x104, opcode=WrOpcode.SEND)), "PSN gap")


def test_duplicate_psn_is_detected():
    sb = RdmaScoreboard()
    sb.set_expected_psn(qpn=0x21, psn=0x200)
    sb.observe_packet(PacketObservation(qpn=0x21, psn=0x200, opcode=WrOpcode.SEND))
    expect_scoreboard_error(lambda: sb.observe_packet(PacketObservation(qpn=0x21, psn=0x200, opcode=WrOpcode.SEND)), "duplicate PSN")


def test_retry_packet_is_recognized_as_expected_retransmission():
    sb = RdmaScoreboard()
    sb.expect_retry(qpn=0x30, psn=0x300, retry_limit=2)
    sb.observe_retry_packet(0x30, 0x300)
    sb.observe_packet(PacketObservation(qpn=0x30, psn=0x300, opcode=WrOpcode.SEND, is_retry=True))
    assert sb.retry[0x30].attempts[0x300] == 2
    expect_scoreboard_error(lambda: sb.observe_retry_packet(0x30, 0x300), "retry exhausted")


def test_expected_error_completion_matches_status_and_vendor_err():
    sb = RdmaScoreboard()
    sb.expect_wr(
        ExpectedWorkRequest(
            wr_id=8,
            opcode=WrOpcode.RDMA_WRITE,
            qpn=0x40,
            byte_len=0,
            expected_status=CompletionStatus.REMOTE_ACCESS_ERROR,
            vendor_err=0x55,
        )
    )
    sb.observe_cqe(
        ObservedCqe(
            wr_id=8,
            qpn=0x40,
            opcode=WrOpcode.RDMA_WRITE,
            status=CompletionStatus.REMOTE_ACCESS_ERROR,
            byte_len=0,
            vendor_err=0x55,
        )
    )
    sb.finish()


def test_success_completion_when_error_expected_is_rejected():
    sb = RdmaScoreboard()
    sb.expect_wr(
        ExpectedWorkRequest(
            wr_id=9,
            opcode=WrOpcode.SEND,
            qpn=0x41,
            expected_status=CompletionStatus.LOCAL_PROTECTION_ERROR,
            vendor_err=1,
        )
    )
    expect_scoreboard_error(
        lambda: sb.observe_cqe(ObservedCqe(wr_id=9, qpn=0x41, opcode=WrOpcode.SEND, status=CompletionStatus.SUCCESS)),
        "status mismatch",
    )


def test_dma_history_expectations_use_host_memory_model():
    mem = HostMemoryModel(size=4096)
    buf = mem.allocate(8, init=b"payload!")
    sb = RdmaScoreboard(mem)
    sb.expect_dma_read(buf.dma_addr, 4)
    sb.expect_dma_write(buf.dma_addr + 4, 4)
    mem.dma_read(buf.dma_addr, 4)
    mem.dma_write(buf.dma_addr + 4, b"DATA")
    sb.verify_dma_history()
    sb.finish()


def run_all():
    tests = [
        test_successful_send_wr_matches_expected_cqe,
        test_successful_recv_wr_matches_cqe_and_payload,
        test_rdma_write_payload_comparison_verifies_destination_memory,
        test_rdma_read_payload_comparison_verifies_returned_payload,
        test_missing_cqe_is_reported_at_end_of_test,
        test_unexpected_cqe_is_reported_immediately,
        test_out_of_order_cqe_is_detected_when_ordering_required,
        test_psn_increment_and_gap_detection_work,
        test_duplicate_psn_is_detected,
        test_retry_packet_is_recognized_as_expected_retransmission,
        test_expected_error_completion_matches_status_and_vendor_err,
        test_success_completion_when_error_expected_is_rejected,
        test_dma_history_expectations_use_host_memory_model,
    ]
    for test in tests:
        test()


if __name__ == "__main__":
    run_all()
    print("RDMA scoreboard unit tests passed")

