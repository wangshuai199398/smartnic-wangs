# SPDX-License-Identifier: MIT
"""Unit tests for the reusable RDMA functional coverage collector."""

from bfm import (
    CompletionStatus,
    CongestionEvent,
    CoverageCategory,
    ExpectedWorkRequest,
    MessageSizeBin,
    MrPermission,
    ObservedCqe,
    QpState,
    QpType,
    RdmaCoverageCollector,
    SgeCountBin,
    SgeRef,
    WrOpcode,
)
from bfm.roce_ethernet_bfm import RoceOpcode, RocePacket


def hits(cov, category, bin_name):
    return cov.bins[CoverageCategory(category)][bin_name].hits


def test_opcode_bin_hit_from_wr_and_packet():
    cov = RdmaCoverageCollector()
    cov.sample_wr(ExpectedWorkRequest(wr_id=1, opcode=WrOpcode.SEND, qpn=1, byte_len=8, imm_data=0x11223344))
    cov.sample_packet(RocePacket(opcode=RoceOpcode.RDMA_WRITE_ONLY_IMM, imm_data=0xAABBCCDD, payload=b"abc"))
    cov.sample_opcode(WrOpcode.SEND, ack=True)
    cov.sample_opcode(WrOpcode.SEND, nak=True)
    assert hits(cov, CoverageCategory.OPCODE, "SEND") == 1
    assert hits(cov, CoverageCategory.OPCODE, "SEND_IMM") == 1
    assert hits(cov, CoverageCategory.OPCODE, "RDMA_WRITE") == 1
    assert hits(cov, CoverageCategory.OPCODE, "RDMA_WRITE_IMM") == 1
    assert hits(cov, CoverageCategory.OPCODE, "ACK") == 1
    assert hits(cov, CoverageCategory.OPCODE, "NAK") == 1


def test_qp_state_transition_bin_hit():
    cov = RdmaCoverageCollector()
    cov.sample_qp_state_transition(QpState.RESET, QpState.INIT)
    cov.sample_qp_state(QpState.RTS)
    assert hits(cov, CoverageCategory.QP_STATE, "RESET") == 1
    assert hits(cov, CoverageCategory.QP_STATE, "INIT") == 1
    assert hits(cov, CoverageCategory.QP_STATE, "RTS") == 1


def test_cq_success_and_error_status_bins():
    cov = RdmaCoverageCollector()
    cov.sample_cqe(ObservedCqe(wr_id=1, qpn=1, opcode=WrOpcode.SEND, status=CompletionStatus.SUCCESS))
    cov.sample_cqe(ObservedCqe(wr_id=2, qpn=1, opcode=WrOpcode.SEND, status=CompletionStatus.LOCAL_PROTECTION_ERROR))
    assert hits(cov, CoverageCategory.CQ_STATUS, "SUCCESS") == 1
    assert hits(cov, CoverageCategory.CQ_STATUS, "LOCAL_PROTECTION_ERROR") == 1


def test_mr_permission_bins_from_access_flags_and_denied():
    cov = RdmaCoverageCollector()
    cov.sample_mr_access_flags(0x01 | 0x04 | 0x08)
    cov.sample_mr_permission(MrPermission.REMOTE_ATOMIC)
    cov.sample_mr_access_flags(0, denied=True)
    assert hits(cov, CoverageCategory.MR_PERMISSION, "LOCAL_READ") == 1
    assert hits(cov, CoverageCategory.MR_PERMISSION, "REMOTE_READ") == 1
    assert hits(cov, CoverageCategory.MR_PERMISSION, "REMOTE_WRITE") == 1
    assert hits(cov, CoverageCategory.MR_PERMISSION, "REMOTE_ATOMIC") == 1
    assert hits(cov, CoverageCategory.MR_PERMISSION, "INVALID_DENIED") == 1


def test_message_size_bins():
    cov = RdmaCoverageCollector(mtu_bytes=1024, max_message_size=4096)
    for size in (0, 64, 1024, 2048, 4096):
        cov.sample_message_size(size)
    assert hits(cov, CoverageCategory.MESSAGE_SIZE, MessageSizeBin.ZERO.value) == 1
    assert hits(cov, CoverageCategory.MESSAGE_SIZE, MessageSizeBin.SMALL.value) == 1
    assert hits(cov, CoverageCategory.MESSAGE_SIZE, MessageSizeBin.MTU.value) == 1
    assert hits(cov, CoverageCategory.MESSAGE_SIZE, MessageSizeBin.MULTI_PACKET.value) == 1
    assert hits(cov, CoverageCategory.MESSAGE_SIZE, MessageSizeBin.MAX.value) == 1


def test_sge_count_bins():
    cov = RdmaCoverageCollector(max_sge=4)
    for count in (0, 1, 2, 4, 5):
        cov.sample_sge_count(count)
    assert hits(cov, CoverageCategory.SGE_COUNT, SgeCountBin.ZERO.value) == 1
    assert hits(cov, CoverageCategory.SGE_COUNT, SgeCountBin.ONE.value) == 1
    assert hits(cov, CoverageCategory.SGE_COUNT, SgeCountBin.MULTIPLE.value) == 1
    assert hits(cov, CoverageCategory.SGE_COUNT, SgeCountBin.MAX.value) == 1
    assert hits(cov, CoverageCategory.SGE_COUNT, SgeCountBin.INVALID.value) == 1


def test_qp_type_bins():
    cov = RdmaCoverageCollector()
    cov.sample_qp_type(QpType.RC)
    cov.sample_qp_type(QpType.UD)
    assert hits(cov, CoverageCategory.QP_TYPE, "RC") == 1
    assert hits(cov, CoverageCategory.QP_TYPE, "UD") == 1


def test_congestion_event_bins():
    cov = RdmaCoverageCollector()
    cov.sample_congestion_event(CongestionEvent.ECN)
    cov.sample_congestion_event(CongestionEvent.CNP)
    cov.sample_congestion_event(CongestionEvent.RATE_REDUCTION)
    cov.sample_congestion_event(CongestionEvent.RECOVERY)
    assert hits(cov, CoverageCategory.CONGESTION, "ECN") == 1
    assert hits(cov, CoverageCategory.CONGESTION, "CNP") == 1
    assert hits(cov, CoverageCategory.CONGESTION, "RATE_REDUCTION") == 1
    assert hits(cov, CoverageCategory.CONGESTION, "RECOVERY") == 1


def test_wr_hook_samples_message_sge_qp_type_and_opcode():
    cov = RdmaCoverageCollector()
    cov.sample_wr(
        ExpectedWorkRequest(
            wr_id=3,
            opcode=WrOpcode.RDMA_READ,
            qpn=7,
            qp_type=QpType.RC,
            sges=[SgeRef(0x1000, 16), SgeRef(0x2000, 16)],
        )
    )
    assert hits(cov, CoverageCategory.OPCODE, "RDMA_READ") == 1
    assert hits(cov, CoverageCategory.SGE_COUNT, "MULTIPLE") == 1
    assert hits(cov, CoverageCategory.MESSAGE_SIZE, "SMALL") == 1
    assert hits(cov, CoverageCategory.QP_TYPE, "RC") == 1


def test_disable_enable_and_reset_behavior():
    cov = RdmaCoverageCollector()
    cov.disable()
    cov.sample_opcode(WrOpcode.SEND)
    assert hits(cov, CoverageCategory.OPCODE, "SEND") == 0
    cov.enable()
    cov.sample_opcode(WrOpcode.SEND)
    assert hits(cov, CoverageCategory.OPCODE, "SEND") == 1
    cov.reset()
    assert hits(cov, CoverageCategory.OPCODE, "SEND") == 0


def test_summary_reports_missing_required_and_optional_bins():
    cov = RdmaCoverageCollector(optional_bins={CoverageCategory.OPCODE: ["UD_SEND_IMM"]})
    cov.sample_opcode(WrOpcode.SEND)
    summary = cov.summary()
    report = cov.report()
    assert summary.hit_bins == 1
    assert "RDMA functional coverage" in report
    assert "opcode" in summary.missing_required
    assert "UD_SEND_IMM" in summary.missing_optional["opcode"]
    assert "RDMA_WRITE" in summary.missing_required["opcode"]


def run_all():
    tests = [
        test_opcode_bin_hit_from_wr_and_packet,
        test_qp_state_transition_bin_hit,
        test_cq_success_and_error_status_bins,
        test_mr_permission_bins_from_access_flags_and_denied,
        test_message_size_bins,
        test_sge_count_bins,
        test_qp_type_bins,
        test_congestion_event_bins,
        test_wr_hook_samples_message_sge_qp_type_and_opcode,
        test_disable_enable_and_reset_behavior,
        test_summary_reports_missing_required_and_optional_bins,
    ]
    for test in tests:
        test()


if __name__ == "__main__":
    run_all()
    print("RDMA functional coverage unit tests passed")

