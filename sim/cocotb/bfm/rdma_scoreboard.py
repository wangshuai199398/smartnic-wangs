# SPDX-License-Identifier: MIT
"""Reusable RDMA verification scoreboard.

The scoreboard tracks normalized Work Requests, CQEs, packets, payloads, PSN
state, retry events, and error completions. It intentionally does not collect
functional coverage; coverage is a separate 14.5 concern.
"""

from __future__ import annotations

import hashlib
from collections import defaultdict, deque
from dataclasses import dataclass, field
from enum import Enum
from typing import Deque, Dict, Iterable, List, Optional

from .host_memory_model import HostMemoryModel
from .roce_ethernet_bfm import RocePacket


class ScoreboardError(AssertionError):
    """Raised when observed DUT behavior does not match expectations."""


class WrOpcode(str, Enum):
    SEND = "SEND"
    RECV = "RECV"
    RDMA_WRITE = "RDMA_WRITE"
    RDMA_READ = "RDMA_READ"
    UD_SEND = "UD_SEND"


class CompletionStatus(str, Enum):
    SUCCESS = "SUCCESS"
    LOCAL_PROTECTION_ERROR = "LOCAL_PROTECTION_ERROR"
    LOCAL_LENGTH_ERROR = "LOCAL_LENGTH_ERROR"
    REMOTE_ACCESS_ERROR = "REMOTE_ACCESS_ERROR"
    REMOTE_OPERATION_ERROR = "REMOTE_OPERATION_ERROR"
    RETRY_EXCEEDED = "RETRY_EXCEEDED"
    RNR_RETRY_EXCEEDED = "RNR_RETRY_EXCEEDED"
    WR_FLUSH_ERR = "WR_FLUSH_ERR"
    GENERAL_ERROR = "GENERAL_ERROR"


class QpType(str, Enum):
    RC = "RC"
    UD = "UD"


@dataclass(frozen=True)
class SgeRef:
    addr: int
    length: int
    lkey: int = 0


@dataclass
class ExpectedWorkRequest:
    wr_id: int
    opcode: WrOpcode
    qpn: int
    qp_type: QpType = QpType.RC
    sges: List[SgeRef] = field(default_factory=list)
    byte_len: int = 0
    signaled: bool = True
    expect_completion: bool = True
    expected_status: CompletionStatus = CompletionStatus.SUCCESS
    expected_cqe_opcode: Optional[WrOpcode] = None
    flags: int = 0
    imm_data: Optional[int] = None
    invalidate_rkey: Optional[int] = None
    vendor_err: int = 0
    payload: Optional[bytes] = None
    order_required: bool = True

    def __post_init__(self) -> None:
        if self.expected_cqe_opcode is None:
            self.expected_cqe_opcode = self.opcode
        if self.byte_len == 0 and self.payload is not None:
            self.byte_len = len(self.payload)
        if self.byte_len == 0 and self.sges:
            self.byte_len = sum(sge.length for sge in self.sges)
        if not self.signaled:
            self.expect_completion = False


@dataclass(frozen=True)
class ObservedCqe:
    wr_id: int
    qpn: int
    opcode: WrOpcode
    status: CompletionStatus = CompletionStatus.SUCCESS
    byte_len: int = 0
    wc_flags: int = 0
    imm_data: Optional[int] = None
    invalidate_rkey: Optional[int] = None
    vendor_err: int = 0


@dataclass(frozen=True)
class PacketObservation:
    qpn: int
    psn: int
    opcode: WrOpcode
    payload: bytes = b""
    is_retry: bool = False


@dataclass
class PsnState:
    expected_psn: int
    window: int = 1
    accepted: List[int] = field(default_factory=list)
    duplicates: List[int] = field(default_factory=list)
    gaps: List[int] = field(default_factory=list)


@dataclass
class RetryState:
    retry_limit: int
    attempts: Dict[int, int] = field(default_factory=dict)
    exhausted: List[int] = field(default_factory=list)


class RdmaScoreboard:
    """Shared scoreboard for later module, integration, and protocol tests."""

    def __init__(self, memory: Optional[HostMemoryModel] = None, strict: bool = True, digest_threshold: int = 4096) -> None:
        self.memory = memory
        self.strict = strict
        self.digest_threshold = digest_threshold
        self.expected_by_qp: Dict[int, Deque[ExpectedWorkRequest]] = defaultdict(deque)
        self.completed: List[ObservedCqe] = []
        self.packet_log: List[PacketObservation] = []
        self.dma_expectations: List[tuple[str, int, int]] = []
        self.psn: Dict[int, PsnState] = {}
        self.retry: Dict[int, RetryState] = {}
        self.unexpected: List[str] = []

    def reset(self) -> None:
        self.expected_by_qp.clear()
        self.completed.clear()
        self.packet_log.clear()
        self.dma_expectations.clear()
        self.psn.clear()
        self.retry.clear()
        self.unexpected.clear()

    def create_qp(self, qpn: int, initial_psn: int = 0, psn_window: int = 1, retry_limit: int = 0) -> None:
        self.psn[qpn] = PsnState(initial_psn & 0x00FF_FFFF, psn_window)
        self.retry[qpn] = RetryState(retry_limit)

    def expect_wr(self, wr: ExpectedWorkRequest) -> None:
        if wr.expect_completion:
            self.expected_by_qp[wr.qpn].append(wr)

    def observe_cqe(self, cqe: ObservedCqe) -> ExpectedWorkRequest:
        queue = self.expected_by_qp.get(cqe.qpn)
        if not queue:
            return self._fail(f"unexpected CQE qpn=0x{cqe.qpn:x} wr_id=0x{cqe.wr_id:x} opcode={cqe.opcode}")
        expected = self._select_expected(queue, cqe)
        self._validate_cqe(expected, cqe)
        self.completed.append(cqe)
        return expected

    def compare_expected_payload(self, wr: ExpectedWorkRequest, observed_payload: bytes) -> None:
        expected = self._wr_payload(wr)
        self._compare_bytes(f"qpn=0x{wr.qpn:x} wr_id=0x{wr.wr_id:x} payload", expected, observed_payload)

    def compare_recv_payload(self, wr: ExpectedWorkRequest, expected_payload: bytes) -> None:
        actual = self._gather_sges(wr.sges)
        self._compare_bytes(f"RECV wr_id=0x{wr.wr_id:x}", expected_payload, actual[: len(expected_payload)])

    def compare_rdma_write_destination(self, dest_sges: Iterable[SgeRef], expected_payload: bytes, label: str = "RDMA_WRITE") -> None:
        actual = self._gather_sges(list(dest_sges))
        self._compare_bytes(label, expected_payload, actual[: len(expected_payload)])

    def compare_rdma_read_response(self, wr: ExpectedWorkRequest, response_payload: bytes) -> None:
        expected = self._wr_payload(wr)
        self._compare_bytes(f"RDMA_READ wr_id=0x{wr.wr_id:x}", expected, response_payload)

    def set_expected_psn(self, qpn: int, psn: int, window: int = 1) -> None:
        self.psn[qpn] = PsnState(psn & 0x00FF_FFFF, window)

    def observe_packet(self, packet: PacketObservation | RocePacket, opcode: Optional[WrOpcode] = None) -> PacketObservation:
        observation = self._normalize_packet(packet, opcode)
        state = self.psn.setdefault(observation.qpn, PsnState(observation.psn))
        expected = state.expected_psn
        if observation.is_retry:
            self._validate_retry(observation.qpn, observation.psn)
        elif observation.psn == expected:
            state.accepted.append(observation.psn)
            state.expected_psn = (state.expected_psn + 1) & 0x00FF_FFFF
        elif observation.psn < expected:
            state.duplicates.append(observation.psn)
            self._fail(f"duplicate PSN qpn=0x{observation.qpn:x} psn=0x{observation.psn:x} expected=0x{expected:x}", permissive_ok=True)
        else:
            state.gaps.append(observation.psn)
            self._fail(f"PSN gap qpn=0x{observation.qpn:x} psn=0x{observation.psn:x} expected=0x{expected:x}", permissive_ok=True)
        self.packet_log.append(observation)
        return observation

    def expect_retry(self, qpn: int, psn: int, retry_limit: int = 1) -> None:
        state = self.retry.setdefault(qpn, RetryState(retry_limit))
        state.retry_limit = retry_limit
        state.attempts.setdefault(psn & 0x00FF_FFFF, 0)

    def observe_retry_packet(self, qpn: int, psn: int) -> None:
        self._validate_retry(qpn, psn & 0x00FF_FFFF)

    def expect_dma_read(self, addr: int, length: int) -> None:
        self.dma_expectations.append(("read", addr, length))

    def expect_dma_write(self, addr: int, length: int) -> None:
        self.dma_expectations.append(("write", addr, length))

    def verify_dma_history(self) -> None:
        if self.memory is None:
            return
        for kind, addr, length in list(self.dma_expectations):
            if kind == "read":
                self.memory.assert_dma_read(addr, length)
            else:
                self.memory.assert_dma_write(addr, length)
            self.dma_expectations.remove((kind, addr, length))

    def finish(self) -> None:
        outstanding = [
            f"qpn=0x{qpn:x} wr_id=0x{wr.wr_id:x} opcode={wr.opcode}"
            for qpn, queue in self.expected_by_qp.items()
            for wr in queue
        ]
        if outstanding:
            self._fail("missing CQE for " + ", ".join(outstanding))
        self.verify_dma_history()
        if self.dma_expectations:
            self._fail("missing DMA transactions: " + repr(self.dma_expectations))
        if self.unexpected and self.strict:
            raise ScoreboardError("; ".join(self.unexpected))

    def summary(self) -> str:
        outstanding = sum(len(queue) for queue in self.expected_by_qp.values())
        return (
            f"scoreboard completed={len(self.completed)} packets={len(self.packet_log)} "
            f"outstanding_wrs={outstanding} unexpected={len(self.unexpected)}"
        )

    def _select_expected(self, queue: Deque[ExpectedWorkRequest], cqe: ObservedCqe) -> ExpectedWorkRequest:
        head = queue[0]
        if head.wr_id == cqe.wr_id:
            return queue.popleft()
        for idx, wr in enumerate(queue):
            if wr.wr_id == cqe.wr_id:
                if head.order_required:
                    return self._fail(
                        f"out-of-order CQE qpn=0x{cqe.qpn:x} wr_id=0x{cqe.wr_id:x}; expected wr_id=0x{head.wr_id:x}"
                    )
                del queue[idx]
                return wr
        return self._fail(f"unexpected CQE wr_id=0x{cqe.wr_id:x} for qpn=0x{cqe.qpn:x}")

    def _validate_cqe(self, expected: ExpectedWorkRequest, cqe: ObservedCqe) -> None:
        checks = [
            (cqe.opcode == expected.expected_cqe_opcode, "opcode"),
            (cqe.status == expected.expected_status, "status"),
            (cqe.byte_len == expected.byte_len, "byte_len"),
            (cqe.imm_data == expected.imm_data, "imm_data"),
            (cqe.invalidate_rkey == expected.invalidate_rkey, "invalidate_rkey"),
        ]
        if expected.expected_status != CompletionStatus.SUCCESS:
            checks.append((cqe.vendor_err == expected.vendor_err, "vendor_err"))
        for ok, field in checks:
            if not ok:
                exp = getattr(expected, f"expected_{field}", None)
                if field == "opcode":
                    exp = expected.expected_cqe_opcode
                elif field == "status":
                    exp = expected.expected_status
                else:
                    exp = getattr(expected, field)
                got = getattr(cqe, field)
                self._fail(
                    f"CQE {field} mismatch qpn=0x{cqe.qpn:x} wr_id=0x{cqe.wr_id:x}: expected {exp}, got {got}"
                )

    def _wr_payload(self, wr: ExpectedWorkRequest) -> bytes:
        if wr.payload is not None:
            return wr.payload
        return self._gather_sges(wr.sges)[: wr.byte_len]

    def _gather_sges(self, sges: Iterable[SgeRef]) -> bytes:
        if self.memory is None:
            raise ScoreboardError("payload comparison requires a HostMemoryModel")
        return b"".join(self.memory.read(sge.addr, sge.length) for sge in sges)

    def _compare_bytes(self, label: str, expected: bytes, actual: bytes) -> None:
        if expected == actual:
            return
        if len(expected) > self.digest_threshold or len(actual) > self.digest_threshold:
            exp_digest = hashlib.sha256(expected).hexdigest()
            got_digest = hashlib.sha256(actual).hexdigest()
            self._fail(f"{label} digest mismatch expected={exp_digest} got={got_digest}")
        for idx, (exp, got) in enumerate(zip(expected, actual)):
            if exp != got:
                self._fail(f"{label} mismatch at byte {idx}: expected 0x{exp:02x}, got 0x{got:02x}")
        self._fail(f"{label} length mismatch expected={len(expected)} got={len(actual)}")

    def _normalize_packet(self, packet: PacketObservation | RocePacket, opcode: Optional[WrOpcode]) -> PacketObservation:
        if isinstance(packet, PacketObservation):
            return packet
        op = opcode or self._opcode_from_roce(packet.opcode)
        return PacketObservation(packet.dest_qpn, packet.psn, op, packet.payload)

    @staticmethod
    def _opcode_from_roce(opcode: int) -> WrOpcode:
        mapping = {
            0x04: WrOpcode.SEND,
            0x05: WrOpcode.SEND,
            0x0A: WrOpcode.RDMA_WRITE,
            0x0B: WrOpcode.RDMA_WRITE,
            0x0C: WrOpcode.RDMA_READ,
            0x10: WrOpcode.RDMA_READ,
            0x64: WrOpcode.UD_SEND,
            0x65: WrOpcode.UD_SEND,
        }
        return mapping.get(int(opcode), WrOpcode.SEND)

    def _validate_retry(self, qpn: int, psn: int) -> None:
        state = self.retry.setdefault(qpn, RetryState(0))
        attempts = state.attempts.get(psn, 0) + 1
        state.attempts[psn] = attempts
        if attempts > state.retry_limit:
            state.exhausted.append(psn)
            self._fail(f"retry exhausted qpn=0x{qpn:x} psn=0x{psn:x} attempts={attempts} limit={state.retry_limit}", permissive_ok=True)

    def _fail(self, message: str, permissive_ok: bool = False):
        if self.strict and not permissive_ok:
            raise ScoreboardError(message)
        self.unexpected.append(message)
        if self.strict and permissive_ok:
            raise ScoreboardError(message)
        return None

