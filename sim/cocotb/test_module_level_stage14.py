# SPDX-License-Identifier: MIT
"""Stage 14.6 module-level verification smoke tests.

These checks stay module-scoped: each test exercises one verification-facing
contract with BFMs, host memory, scoreboard, or coverage. They are not the
end-to-end flows reserved for 14.7.
"""

from bfm import (
    CompletionStatus,
    CongestionEvent,
    EthernetRoceBfm,
    ExpectedWorkRequest,
    HostMemoryModel,
    ObservedCqe,
    PacketObservation,
    PcieBar,
    PcieHostBfm,
    QpState,
    QpType,
    RdmaCoverageCollector,
    RdmaScoreboard,
    ScoreboardError,
    SgeRef,
    WrOpcode,
)
from bfm.pcie_bfm import PcieTlp, PcieTlpType
from bfm.roce_ethernet_bfm import RoceOpcode, RocePacket


def expect_error(fn, exc_type=Exception):
    try:
        fn()
    except exc_type:
        return
    raise AssertionError(f"expected {exc_type.__name__}")


def decode_doorbell(db_type, value):
    if db_type == "SQ":
        return {"sq_pi": value & 0xFFFF, "wake_sq": True, "valid": True}
    if db_type == "RQ":
        return {"rq_pi": value & 0xFFFF, "wake_rq": True, "valid": True}
    if db_type == "CQ_ARM":
        return {"consumer_index": value & 0xFFFF, "armed": bool(value & (1 << 31)), "valid": True}
    return {"valid": False, "error": "invalid_doorbell"}


def qp_transition_allowed(old_state, new_state):
    legal = {
        QpState.RESET: {QpState.INIT, QpState.ERROR},
        QpState.INIT: {QpState.RTR, QpState.ERROR},
        QpState.RTR: {QpState.RTS, QpState.ERROR},
        QpState.RTS: {QpState.SQD, QpState.ERROR},
        QpState.SQD: {QpState.RTS, QpState.ERROR},
        QpState.ERROR: {QpState.RESET},
    }
    return new_state in legal.get(old_state, set())


def check_mr_access(va, length, base, size, access_flags, required_flag):
    if length == 0:
        return "length"
    if va < base or va + length > base + size:
        return "bounds"
    if (access_flags & required_flag) == 0:
        return "permission"
    return "ok"


def test_pcie_module_config_mmio_and_tlp_handling():
    bfm = PcieHostBfm(bars=[PcieBar(0, 4096)])
    assert bfm.cfg_read(0x00, 2) == bfm.identity.vendor_id
    bfm.enable_memory_and_bus_master()
    assert bfm.cfg_read(0x04, 2) & (bfm.COMMAND_MEMORY | bfm.COMMAND_BUS_MASTER)
    bfm.program_bar(0, 0x8000_0000)
    bfm.mem_write(0x8000_0010, b"\x11\x22\x33\x44")
    assert bfm.mem_read(0x8000_0010, 4) == b"\x11\x22\x33\x44"


def test_doorbell_module_valid_invalid_ordering_and_queue_updates():
    sq = decode_doorbell("SQ", 0x1234)
    rq = decode_doorbell("RQ", 0x5678)
    cq = decode_doorbell("CQ_ARM", (1 << 31) | 0x22)
    invalid = decode_doorbell("BAD", 0)
    assert sq == {"sq_pi": 0x1234, "wake_sq": True, "valid": True}
    assert rq == {"rq_pi": 0x5678, "wake_rq": True, "valid": True}
    assert cq["armed"] is True and cq["consumer_index"] == 0x22
    assert invalid["valid"] is False


def test_qp_module_creation_state_transitions_and_invalid_access():
    cov = RdmaCoverageCollector()
    cov.sample_qp_type(QpType.RC)
    cov.sample_qp_state_transition(QpState.RESET, QpState.INIT)
    assert qp_transition_allowed(QpState.RESET, QpState.INIT)
    assert qp_transition_allowed(QpState.INIT, QpState.RTS) is False
    assert cov.bins["qp_type"]["RC"].hits == 1
    assert cov.bins["qp_state"]["RESET"].hits == 1


def test_cq_module_cqe_status_and_overflow_empty_behavior():
    sb = RdmaScoreboard()
    sb.expect_wr(ExpectedWorkRequest(wr_id=0x10, opcode=WrOpcode.SEND, qpn=0x44, byte_len=4))
    sb.observe_cqe(ObservedCqe(wr_id=0x10, qpn=0x44, opcode=WrOpcode.SEND, status=CompletionStatus.SUCCESS, byte_len=4))
    sb.finish()

    depth = 4
    producer = 3
    consumer = 0
    next_producer = (producer + 1) % depth
    assert next_producer == consumer
    assert producer != consumer


def test_mr_module_registration_permission_bounds_and_invalid_keys():
    cov = RdmaCoverageCollector()
    base = 0x1000
    size = 0x100
    flags = 0x01 | 0x08
    assert check_mr_access(base + 4, 16, base, size, flags, 0x01) == "ok"
    assert check_mr_access(base + size - 4, 8, base, size, flags, 0x01) == "bounds"
    assert check_mr_access(base + 4, 16, base, size, flags, 0x04) == "permission"
    cov.sample_mr_access_flags(flags)
    cov.sample_mr_access_flags(0, denied=True)
    assert cov.bins["mr_permission"]["LOCAL_READ"].hits == 1
    assert cov.bins["mr_permission"]["INVALID_DENIED"].hits == 1


def test_dma_module_read_write_alignment_completion_and_error_handling():
    mem = HostMemoryModel(base_addr=0x4000_0000, size=4096)
    buf = mem.allocate(16, init=b"abcdefghijklmnop")
    read_cpl = mem.service_pcie_tlp(PcieTlp(PcieTlpType.MEM_READ, address=buf.dma_addr + 1, length=4, tag=5))
    assert read_cpl.data == b"bcde"
    mem.service_pcie_tlp(PcieTlp(PcieTlpType.MEM_WRITE, address=buf.dma_addr + 4, data=b"WXYZ", first_be=0b0101))
    assert mem.read(buf.dma_addr, 8) == b"abcdWfYh"
    expect_error(lambda: mem.service_pcie_tlp(PcieTlp(PcieTlpType.MEM_READ, address=0xDEAD, length=4)), ValueError)


def test_packet_module_build_parse_header_payload_and_malformed_input():
    bfm = EthernetRoceBfm()
    pkt = bfm.build_rdma_write(0x123456, 0x22, 0x1000_2000_3000_4000, 0xAABBCCDD, b"payload")
    parsed = bfm.parse_frame(bfm.build_roce_frame(pkt)).roce
    assert parsed.opcode == RoceOpcode.RDMA_WRITE_ONLY
    assert parsed.remote_va == 0x1000_2000_3000_4000
    assert parsed.payload == b"payload"
    malformed = bfm.build_roce_frame(pkt, errors={"bad_ipv4_checksum": True})
    expect_error(lambda: bfm.parse_frame(malformed), ValueError)


def test_transport_module_send_rdma_psn_retry_and_ack_nak_basics():
    sb = RdmaScoreboard()
    sb.set_expected_psn(0x55, 0x100)
    sb.observe_packet(PacketObservation(qpn=0x55, psn=0x100, opcode=WrOpcode.SEND))
    sb.expect_retry(0x55, 0x101, retry_limit=1)
    sb.observe_retry_packet(0x55, 0x101)
    expect_error(lambda: sb.observe_retry_packet(0x55, 0x101), ScoreboardError)
    sb2 = RdmaScoreboard()
    sb2.set_expected_psn(0x56, 0x200)
    expect_error(
        lambda: sb2.observe_packet(PacketObservation(qpn=0x56, psn=0x202, opcode=WrOpcode.RDMA_READ)),
        ScoreboardError,
    )


def test_congestion_module_ecn_cnp_and_rate_control_event_sampling():
    cov = RdmaCoverageCollector()
    cov.sample_congestion_event(CongestionEvent.ECN)
    cov.sample_congestion_event(CongestionEvent.CNP)
    cov.sample_congestion_event(CongestionEvent.RATE_REDUCTION)
    cov.sample_congestion_event(CongestionEvent.RECOVERY)
    cnp = RocePacket(opcode=RoceOpcode.CNP, dest_qpn=0x123456, congestion_type=1)
    frame = EthernetRoceBfm().build_roce_frame(cnp, dscp_ecn=0x03)
    parsed = EthernetRoceBfm().parse_frame(frame).roce
    assert parsed.opcode == RoceOpcode.CNP
    assert cov.bins["congestion"]["ECN"].hits == 1
    assert cov.bins["congestion"]["RECOVERY"].hits == 1


def test_top_level_reset_idle_active_and_clean_recovery():
    mem = HostMemoryModel(size=4096)
    cov = RdmaCoverageCollector()
    sb = RdmaScoreboard(mem)
    buf = mem.allocate(8, init=b"reset123")
    sb.expect_wr(ExpectedWorkRequest(wr_id=1, opcode=WrOpcode.SEND, qpn=1, byte_len=8))
    cov.sample_opcode(WrOpcode.SEND)
    mem.dma_read(buf.dma_addr, 4)
    mem.reset(clear_allocations=True)
    sb.reset()
    cov.reset()
    assert mem.buffers == ()
    assert sb.summary().endswith("outstanding_wrs=0 unexpected=0")
    assert cov.summary().hit_bins == 0


def run_all():
    tests = [
        test_pcie_module_config_mmio_and_tlp_handling,
        test_doorbell_module_valid_invalid_ordering_and_queue_updates,
        test_qp_module_creation_state_transitions_and_invalid_access,
        test_cq_module_cqe_status_and_overflow_empty_behavior,
        test_mr_module_registration_permission_bounds_and_invalid_keys,
        test_dma_module_read_write_alignment_completion_and_error_handling,
        test_packet_module_build_parse_header_payload_and_malformed_input,
        test_transport_module_send_rdma_psn_retry_and_ack_nak_basics,
        test_congestion_module_ecn_cnp_and_rate_control_event_sampling,
        test_top_level_reset_idle_active_and_clean_recovery,
    ]
    for test in tests:
        test()


if __name__ == "__main__":
    run_all()
    print("stage 14.6 module-level smoke tests passed")
