# SPDX-License-Identifier: MIT
"""Stage 14.7 RDMA/RoCE integration tests.

These tests compose the reusable BFMs and models from 14.1-14.6 into bounded
end-to-end flows. They intentionally stay below the protocol-compliance layer
reserved for 14.8 and avoid adding a regression runner from 14.9.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from bfm import (
    CompletionStatus,
    CongestionEvent,
    EthernetRoceBfm,
    ExpectedWorkRequest,
    HostMemoryModel,
    ObservedCqe,
    PcieBar,
    PcieCompletionTimeout,
    PcieFunctionIdentity,
    PcieHostBfm,
    QpType,
    RdmaCoverageCollector,
    RdmaScoreboard,
    RoceOpcode,
    RocePacket,
    ScoreboardError,
    SgeRef,
    WrOpcode,
)


LOCAL_READ = 0x01
LOCAL_WRITE = 0x02
REMOTE_READ = 0x04
REMOTE_WRITE = 0x08


def expect_error(fn, exc_type=Exception):
    try:
        fn()
    except exc_type:
        return
    raise AssertionError(f"expected {exc_type.__name__}")


@dataclass
class QpContext:
    qpn: int
    cqn: int
    owner_function: int = 0
    pd_id: int = 1
    qp_type: QpType = QpType.RC
    state: str = "RTS"
    sq_pi: int = 0
    rq_pi: int = 0
    send_psn: int = 0x100
    recv_psn: int = 0x200
    qkey: int = 0x1111_2222


@dataclass
class MrContext:
    lkey: int
    rkey: int
    addr: int
    length: int
    pd_id: int = 1
    owner_function: int = 0
    access: int = LOCAL_READ | LOCAL_WRITE | REMOTE_READ | REMOTE_WRITE

    def check(self, key: int, remote: bool, va: int, length: int, required: int, owner_function: int, pd_id: int) -> int:
        if owner_function != self.owner_function or pd_id != self.pd_id:
            raise PermissionError("owner function or PD mismatch")
        if key != (self.rkey if remote else self.lkey):
            raise KeyError("invalid lkey/rkey")
        if length == 0 or va < self.addr or va + length > self.addr + self.length:
            raise ValueError("MR bounds error")
        if (self.access & required) == 0:
            raise PermissionError("MR permission denied")
        return va


@dataclass
class AhContext:
    index: int
    dest_qpn: int
    qkey: int
    dst_mac: str = "02:00:00:00:00:20"
    src_mac: str = "02:00:00:00:00:10"
    dst_ip: str = "10.0.0.20"
    src_ip: str = "10.0.0.10"
    udp_port: int = 4791
    service_level: int = 0


@dataclass
class IntegrationHarness:
    memory: HostMemoryModel = field(default_factory=lambda: HostMemoryModel(base_addr=0x4000_0000, size=1 << 20))
    packet_bfm: EthernetRoceBfm = field(default_factory=EthernetRoceBfm)
    pcie: PcieHostBfm = field(
        default_factory=lambda: PcieHostBfm(
            identity=PcieFunctionIdentity(bus=1, device=0, function=0),
            bars=[PcieBar(0, 4096), PcieBar(2, 4096), PcieBar(4, 4096)],
        )
    )
    coverage: RdmaCoverageCollector = field(default_factory=RdmaCoverageCollector)

    def __post_init__(self) -> None:
        self.scoreboard = RdmaScoreboard(self.memory)
        self.qps: dict[int, QpContext] = {}
        self.mrs: dict[int, MrContext] = {}
        self.ahs: dict[int, AhContext] = {}
        self.cqes: list[ObservedCqe] = []
        self.doorbells: list[tuple[str, int, int]] = []
        self.pcie.program_bar(0, 0x8000_0000)
        self.pcie.program_bar(2, 0x9000_0000)
        self.pcie.program_bar(4, 0xA000_0000)

    def add_qp(self, qp: QpContext) -> QpContext:
        self.qps[qp.qpn] = qp
        self.scoreboard.create_qp(qp.qpn, qp.send_psn, retry_limit=1)
        self.coverage.sample_qp_type(qp.qp_type)
        return qp

    def add_mr(self, mr: MrContext) -> MrContext:
        self.mrs[mr.lkey] = mr
        self.mrs[mr.rkey] = mr
        self.coverage.sample_mr_access_flags(mr.access)
        return mr

    def add_ah(self, ah: AhContext) -> AhContext:
        self.ahs[ah.index] = ah
        return ah

    def ring_doorbell(self, qp: QpContext, queue_type: str, value: int, owner_function: int = 0) -> None:
        if owner_function != qp.owner_function:
            raise PermissionError("cross-function doorbell rejected")
        if queue_type == "SQ":
            qp.sq_pi = value & 0xFFFF
        elif queue_type == "RQ":
            qp.rq_pi = value & 0xFFFF
        else:
            raise ValueError("invalid doorbell type")
        self.doorbells.append((queue_type, qp.qpn, value & 0xFFFF))

    def emit_cqe(self, wr: ExpectedWorkRequest, status: CompletionStatus = CompletionStatus.SUCCESS, vendor_err: int = 0) -> ObservedCqe:
        cqe = ObservedCqe(
            wr_id=wr.wr_id,
            qpn=wr.qpn,
            opcode=wr.expected_cqe_opcode or wr.opcode,
            status=status,
            byte_len=wr.byte_len,
            imm_data=wr.imm_data,
            vendor_err=vendor_err,
        )
        self.cqes.append(cqe)
        self.scoreboard.observe_cqe(cqe)
        self.coverage.sample_cqe(cqe)
        return cqe

    def expect_wr(self, wr: ExpectedWorkRequest) -> ExpectedWorkRequest:
        self.scoreboard.expect_wr(wr)
        self.coverage.sample_wr(wr)
        return wr

    def validate_qp_ready(self, qp: QpContext) -> None:
        if qp.state != "RTS":
            raise RuntimeError("QP is not ready to send")


def test_doorbell_to_cqe_flow():
    h = IntegrationHarness()
    qp = h.add_qp(QpContext(qpn=0x101, cqn=0x21))
    payload = b"doorbell-to-cqe"
    buf = h.memory.allocate(len(payload), init=payload)
    wr = h.expect_wr(ExpectedWorkRequest(0xD001, WrOpcode.SEND, qp.qpn, sges=[SgeRef(buf.dma_addr, len(payload), 0x10)]))

    h.ring_doorbell(qp, "SQ", 1)
    h.memory.dma_read(buf.dma_addr, len(payload))
    h.emit_cqe(wr)

    assert h.doorbells == [("SQ", qp.qpn, 1)]
    h.scoreboard.expect_dma_read(buf.dma_addr, len(payload))
    h.scoreboard.finish()
    assert h.coverage.summary().hit_bins > 0


def test_rc_send_packet_dma_ack_and_cqe():
    h = IntegrationHarness()
    qp = h.add_qp(QpContext(qpn=0x201, cqn=0x22, send_psn=0x321))
    payload = b"rc-send-payload"
    buf = h.memory.allocate(len(payload), init=payload)
    wr = h.expect_wr(ExpectedWorkRequest(0x5001, WrOpcode.SEND, qp.qpn, sges=[SgeRef(buf.dma_addr, len(payload), 0x20)]))

    h.validate_qp_ready(qp)
    h.ring_doorbell(qp, "SQ", 1)
    tx_payload = h.memory.dma_read(buf.dma_addr, len(payload))
    pkt = h.packet_bfm.build_rc_send(qp.qpn, qp.send_psn, tx_payload)
    h.packet_bfm.observe_tx_frame(h.packet_bfm.build_roce_frame(pkt))
    parsed = h.packet_bfm.recv_roce_packet().roce
    h.scoreboard.observe_packet(parsed, WrOpcode.SEND)
    h.coverage.sample_packet(parsed)
    ack = h.packet_bfm.build_ack(qp.qpn, qp.send_psn)
    assert ack.opcode == RoceOpcode.ACK
    h.emit_cqe(wr)

    assert parsed.payload == payload
    assert parsed.psn == 0x321
    h.scoreboard.finish()


def test_rdma_write_updates_remote_memory_and_completes():
    h = IntegrationHarness()
    qp = h.add_qp(QpContext(qpn=0x301, cqn=0x23, send_psn=0x410))
    src_payload = b"rdma-write-data"
    src = h.memory.allocate(len(src_payload), init=src_payload)
    remote = h.memory.allocate(64, init=b"\x00" * 64)
    mr = h.add_mr(MrContext(lkey=0x31, rkey=0x32, addr=remote.dma_addr, length=64, access=REMOTE_WRITE | LOCAL_READ))
    wr = h.expect_wr(ExpectedWorkRequest(0x6001, WrOpcode.RDMA_WRITE, qp.qpn, sges=[SgeRef(src.dma_addr, len(src_payload), mr.lkey)]))

    mr.check(mr.rkey, remote=True, va=remote.dma_addr, length=len(src_payload), required=REMOTE_WRITE, owner_function=0, pd_id=1)
    payload = h.memory.dma_read(src.dma_addr, len(src_payload))
    pkt = h.packet_bfm.build_rdma_write(qp.qpn, qp.send_psn, remote.dma_addr, mr.rkey, payload)
    h.packet_bfm.observe_tx_frame(h.packet_bfm.build_roce_frame(pkt))
    parsed = h.packet_bfm.recv_roce_packet().roce
    h.memory.dma_write(remote.dma_addr, parsed.payload)
    h.scoreboard.observe_packet(parsed, WrOpcode.RDMA_WRITE)
    h.coverage.sample_packet(parsed)
    h.emit_cqe(wr)

    h.scoreboard.compare_rdma_write_destination([SgeRef(remote.dma_addr, len(src_payload), mr.rkey)], src_payload)
    h.scoreboard.finish()
    assert parsed.rkey == mr.rkey


def test_rdma_read_request_response_writeback_and_cqe():
    h = IntegrationHarness()
    qp = h.add_qp(QpContext(qpn=0x401, cqn=0x24, send_psn=0x510))
    remote_payload = b"rdma-read-response"
    remote = h.memory.allocate(len(remote_payload), init=remote_payload)
    local = h.memory.allocate(len(remote_payload), init=b"\x00" * len(remote_payload))
    mr = h.add_mr(MrContext(lkey=0x41, rkey=0x42, addr=remote.dma_addr, length=len(remote_payload), access=REMOTE_READ | LOCAL_WRITE))
    wr = h.expect_wr(ExpectedWorkRequest(0x7001, WrOpcode.RDMA_READ, qp.qpn, sges=[SgeRef(local.dma_addr, len(remote_payload), mr.lkey)]))

    mr.check(mr.rkey, remote=True, va=remote.dma_addr, length=len(remote_payload), required=REMOTE_READ, owner_function=0, pd_id=1)
    req = h.packet_bfm.build_rdma_read_request(qp.qpn, qp.send_psn, remote.dma_addr, mr.rkey, len(remote_payload))
    h.packet_bfm.observe_tx_frame(h.packet_bfm.build_roce_frame(req))
    parsed_req = h.packet_bfm.recv_roce_packet().roce
    assert parsed_req.opcode == RoceOpcode.RDMA_READ_REQUEST
    response_payload = h.memory.dma_read(remote.dma_addr, len(remote_payload))
    resp = RocePacket(opcode=RoceOpcode.RDMA_READ_RESPONSE_ONLY, dest_qpn=qp.qpn, psn=(qp.send_psn + 1) & 0x00FF_FFFF, payload=response_payload)
    h.memory.dma_write(local.dma_addr, resp.payload)
    h.emit_cqe(wr)

    assert h.memory.read(local.dma_addr, len(remote_payload)) == remote_payload
    h.scoreboard.finish()


def test_ud_send_uses_ah_deth_payload_and_completion():
    h = IntegrationHarness()
    qp = h.add_qp(QpContext(qpn=0x501, cqn=0x25, qp_type=QpType.UD, send_psn=0x610, qkey=0x1357_2468))
    ah = h.add_ah(AhContext(index=7, dest_qpn=0x777, qkey=qp.qkey))
    payload = b"ud-send"
    buf = h.memory.allocate(len(payload), init=payload)
    wr = h.expect_wr(ExpectedWorkRequest(0x8001, WrOpcode.UD_SEND, qp.qpn, qp_type=QpType.UD, sges=[SgeRef(buf.dma_addr, len(payload), 0x50)]))

    pkt = h.packet_bfm.build_ud_send(ah.dest_qpn, qp.send_psn, ah.qkey, qp.qpn, h.memory.dma_read(buf.dma_addr, len(payload)))
    h.packet_bfm.observe_tx_frame(h.packet_bfm.build_roce_frame(pkt, dst_mac=ah.dst_mac, src_mac=ah.src_mac, dst_ip=ah.dst_ip, src_ip=ah.src_ip))
    parsed = h.packet_bfm.recv_roce_packet().roce
    h.coverage.sample_packet(parsed)
    h.emit_cqe(wr)

    assert parsed.opcode == RoceOpcode.UD_SEND_ONLY
    assert parsed.dest_qpn == ah.dest_qpn
    assert parsed.qkey == ah.qkey
    assert parsed.source_qpn == qp.qpn
    assert parsed.payload == payload
    h.scoreboard.finish()


def test_msix_completion_interrupt_delivery_and_masking():
    h = IntegrationHarness()
    vector = 3
    h.pcie.program_msix_vector(vector, 0xFEE0_0000, 0x45, masked=False)
    observed = h.pcie.observe_msix_write(0xFEE0_0000, 0x45)
    assert observed == vector
    assert h.pcie.wait_msix(vector) == vector

    h.pcie.program_msix_vector(vector, 0xFEE0_0000, 0x46, masked=True)
    assert h.pcie.observe_msix_write(0xFEE0_0000, 0x46) is None
    expect_error(lambda: h.pcie.wait_msix(vector), PcieCompletionTimeout)
    h.pcie.unmask_msix_vector(vector)
    assert h.pcie.wait_msix(vector) == vector


def test_sriov_vf_resource_isolation_and_rejection():
    h = IntegrationHarness()
    pf_qp = h.add_qp(QpContext(qpn=0x601, cqn=0x26, owner_function=0))
    vf_qp = h.add_qp(QpContext(qpn=0x602, cqn=0x27, owner_function=2))
    vf_mr = h.add_mr(MrContext(lkey=0x61, rkey=0x62, addr=h.memory.allocate(32).dma_addr, length=32, owner_function=2))

    h.ring_doorbell(vf_qp, "SQ", 1, owner_function=2)
    assert vf_qp.sq_pi == 1
    expect_error(lambda: h.ring_doorbell(pf_qp, "SQ", 1, owner_function=2), PermissionError)
    expect_error(
        lambda: vf_mr.check(vf_mr.rkey, remote=True, va=vf_mr.addr, length=8, required=REMOTE_WRITE, owner_function=0, pd_id=1),
        PermissionError,
    )


def test_negative_invalid_state_permission_key_and_queue_errors():
    h = IntegrationHarness()
    qp = h.add_qp(QpContext(qpn=0x701, cqn=0x28, state="INIT"))
    mr = h.add_mr(MrContext(lkey=0x71, rkey=0x72, addr=h.memory.allocate(16).dma_addr, length=16, access=LOCAL_READ))
    h.expect_wr(ExpectedWorkRequest(0x9001, WrOpcode.SEND, qp.qpn, byte_len=4))
    expect_error(lambda: h.validate_qp_ready(qp), RuntimeError)
    expect_error(lambda: mr.check(mr.rkey, True, mr.addr, 8, REMOTE_WRITE, 0, 1), PermissionError)
    expect_error(lambda: mr.check(0xDEAD, False, mr.addr, 8, LOCAL_READ, 0, 1), KeyError)
    expect_error(lambda: mr.check(mr.lkey, False, mr.addr + 12, 8, LOCAL_READ, 0, 1), ValueError)
    expect_error(lambda: h.scoreboard.finish(), ScoreboardError)


def run_all():
    tests = [
        test_doorbell_to_cqe_flow,
        test_rc_send_packet_dma_ack_and_cqe,
        test_rdma_write_updates_remote_memory_and_completes,
        test_rdma_read_request_response_writeback_and_cqe,
        test_ud_send_uses_ah_deth_payload_and_completion,
        test_msix_completion_interrupt_delivery_and_masking,
        test_sriov_vf_resource_isolation_and_rejection,
        test_negative_invalid_state_permission_key_and_queue_errors,
    ]
    for test in tests:
        test()


if __name__ == "__main__":
    run_all()
    print("stage 14.7 RDMA/RoCE integration tests passed")
