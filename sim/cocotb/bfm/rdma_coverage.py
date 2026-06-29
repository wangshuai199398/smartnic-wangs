# SPDX-License-Identifier: MIT
"""Reusable RDMA functional coverage collector.

The collector is intentionally lightweight and pure Python. It records named
bin hits from monitors, BFMs, scoreboard events, and mock models, while leaving
module-level test creation and regression scripting to later 14.6-14.9 tasks.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Dict, Iterable, Optional

from .rdma_scoreboard import CompletionStatus, ExpectedWorkRequest, ObservedCqe, QpType, SgeRef, WrOpcode
from .roce_ethernet_bfm import RoceOpcode, RocePacket


class CoverageCategory(str, Enum):
    OPCODE = "opcode"
    QP_STATE = "qp_state"
    CQ_STATUS = "cq_status"
    MR_PERMISSION = "mr_permission"
    MESSAGE_SIZE = "message_size"
    SGE_COUNT = "sge_count"
    QP_TYPE = "qp_type"
    CONGESTION = "congestion"


class QpState(str, Enum):
    RESET = "RESET"
    INIT = "INIT"
    RTR = "RTR"
    RTS = "RTS"
    SQD = "SQD"
    SQE = "SQE"
    ERROR = "ERROR"


class MrPermission(str, Enum):
    LOCAL_READ = "LOCAL_READ"
    LOCAL_WRITE = "LOCAL_WRITE"
    REMOTE_READ = "REMOTE_READ"
    REMOTE_WRITE = "REMOTE_WRITE"
    REMOTE_ATOMIC = "REMOTE_ATOMIC"
    MW_BIND = "MW_BIND"
    INVALID_DENIED = "INVALID_DENIED"


class MessageSizeBin(str, Enum):
    ZERO = "ZERO"
    SMALL = "SMALL"
    MTU = "MTU"
    MULTI_PACKET = "MULTI_PACKET"
    MAX = "MAX"


class SgeCountBin(str, Enum):
    ZERO = "ZERO"
    ONE = "ONE"
    MULTIPLE = "MULTIPLE"
    MAX = "MAX"
    INVALID = "INVALID"


class CongestionEvent(str, Enum):
    ECN = "ECN"
    CNP = "CNP"
    RATE_REDUCTION = "RATE_REDUCTION"
    RECOVERY = "RECOVERY"


@dataclass
class CoverageBin:
    name: str
    optional: bool = False
    hits: int = 0


@dataclass
class CoverageSummary:
    total_bins: int
    hit_bins: int
    missing_required: Dict[str, list[str]] = field(default_factory=dict)
    missing_optional: Dict[str, list[str]] = field(default_factory=dict)

    @property
    def percent(self) -> float:
        if self.total_bins == 0:
            return 100.0
        return 100.0 * self.hit_bins / self.total_bins


class RdmaCoverageCollector:
    """Functional coverage bins for RDMA/RoCE verification stimuli."""

    def __init__(
        self,
        enabled: bool = True,
        mtu_bytes: int = 1024,
        max_message_size: int = 4096,
        max_sge: int = 256,
        optional_bins: Optional[Dict[CoverageCategory | str, Iterable[str]]] = None,
    ) -> None:
        self.enabled = enabled
        self.mtu_bytes = mtu_bytes
        self.max_message_size = max_message_size
        self.max_sge = max_sge
        self.bins: Dict[CoverageCategory, Dict[str, CoverageBin]] = {}
        self._init_default_bins(optional_bins or {})

    def clear(self) -> None:
        for category in self.bins.values():
            for cov_bin in category.values():
                cov_bin.hits = 0

    reset = clear

    def enable(self) -> None:
        self.enabled = True

    def disable(self) -> None:
        self.enabled = False

    def mark_optional(self, category: CoverageCategory | str, bin_name: str) -> None:
        self.bins[CoverageCategory(category)][bin_name].optional = True

    def hit(self, category: CoverageCategory | str, bin_name: str) -> None:
        if not self.enabled:
            return
        cat = CoverageCategory(category)
        if bin_name not in self.bins[cat]:
            self.bins[cat][bin_name] = CoverageBin(bin_name, optional=True)
        self.bins[cat][bin_name].hits += 1

    def sample_wr(self, wr: ExpectedWorkRequest) -> None:
        self.sample_opcode(wr.opcode, immediate=wr.imm_data is not None)
        self.sample_qp_type(wr.qp_type)
        self.sample_message_size(wr.byte_len)
        self.sample_sge_count(len(wr.sges))

    def sample_cqe(self, cqe: ObservedCqe) -> None:
        self.sample_opcode(cqe.opcode, immediate=cqe.imm_data is not None)
        self.sample_cq_status(cqe.status)
        self.sample_message_size(cqe.byte_len)

    def sample_packet(self, packet: RocePacket) -> None:
        opcode = self._opcode_from_roce(packet.opcode)
        self.sample_opcode(opcode, immediate=packet.has_immediate())
        self.sample_message_size(len(packet.payload))

    def sample_qp_state_transition(self, old_state: QpState | str, new_state: QpState | str) -> None:
        self.sample_qp_state(old_state)
        self.sample_qp_state(new_state)

    def sample_qp_state(self, state: QpState | str) -> None:
        self.hit(CoverageCategory.QP_STATE, self._enum_name(state))

    def sample_qp_type(self, qp_type: QpType | str) -> None:
        self.hit(CoverageCategory.QP_TYPE, self._enum_name(qp_type))

    def sample_cq_status(self, status: CompletionStatus | str) -> None:
        self.hit(CoverageCategory.CQ_STATUS, self._enum_name(status))

    def sample_mr_permission(self, permission: MrPermission | str, allowed: bool = True) -> None:
        self.hit(CoverageCategory.MR_PERMISSION, self._enum_name(permission) if allowed else MrPermission.INVALID_DENIED.value)

    def sample_mr_access_flags(self, access_flags: int, denied: bool = False) -> None:
        if denied:
            self.sample_mr_permission(MrPermission.INVALID_DENIED, allowed=True)
            return
        mapping = [
            (0x01, MrPermission.LOCAL_READ),
            (0x02, MrPermission.LOCAL_WRITE),
            (0x04, MrPermission.REMOTE_READ),
            (0x08, MrPermission.REMOTE_WRITE),
            (0x10, MrPermission.REMOTE_ATOMIC),
            (0x20, MrPermission.MW_BIND),
        ]
        for bit, permission in mapping:
            if access_flags & bit:
                self.sample_mr_permission(permission)

    def sample_message_size(self, byte_len: int) -> None:
        self.hit(CoverageCategory.MESSAGE_SIZE, self._message_size_bin(byte_len).value)

    def sample_sge_count(self, count: int) -> None:
        self.hit(CoverageCategory.SGE_COUNT, self._sge_count_bin(count).value)

    def sample_sges(self, sges: Iterable[SgeRef]) -> None:
        self.sample_sge_count(len(list(sges)))

    def sample_opcode(self, opcode: WrOpcode | str, immediate: bool = False, ack: bool = False, nak: bool = False) -> None:
        if ack:
            self.hit(CoverageCategory.OPCODE, "ACK")
            return
        if nak:
            self.hit(CoverageCategory.OPCODE, "NAK")
            return
        name = self._enum_name(opcode)
        self.hit(CoverageCategory.OPCODE, name)
        if immediate:
            self.hit(CoverageCategory.OPCODE, f"{name}_IMM")

    def sample_congestion_event(self, event: CongestionEvent | str) -> None:
        self.hit(CoverageCategory.CONGESTION, self._enum_name(event))

    def summary(self) -> CoverageSummary:
        total = 0
        hit = 0
        missing_required: Dict[str, list[str]] = {}
        missing_optional: Dict[str, list[str]] = {}
        for category, bins in self.bins.items():
            for name, cov_bin in bins.items():
                total += 1
                if cov_bin.hits:
                    hit += 1
                elif cov_bin.optional:
                    missing_optional.setdefault(category.value, []).append(name)
                else:
                    missing_required.setdefault(category.value, []).append(name)
        return CoverageSummary(total, hit, missing_required, missing_optional)

    def report(self) -> str:
        summary = self.summary()
        lines = [
            f"RDMA functional coverage: {summary.hit_bins}/{summary.total_bins} bins hit ({summary.percent:.1f}%)"
        ]
        for title, missing in (("missing required", summary.missing_required), ("missing optional", summary.missing_optional)):
            if not missing:
                continue
            lines.append(title + ":")
            for category, names in sorted(missing.items()):
                lines.append(f"  {category}: {', '.join(sorted(names))}")
        return "\n".join(lines)

    def _init_default_bins(self, optional_bins: Dict[CoverageCategory | str, Iterable[str]]) -> None:
        defaults = {
            CoverageCategory.OPCODE: [
                "SEND",
                "RECV",
                "RDMA_WRITE",
                "RDMA_READ",
                "UD_SEND",
                "ACK",
                "NAK",
                "SEND_IMM",
                "RDMA_WRITE_IMM",
                "UD_SEND_IMM",
            ],
            CoverageCategory.QP_STATE: [state.value for state in QpState],
            CoverageCategory.CQ_STATUS: [status.value for status in CompletionStatus],
            CoverageCategory.MR_PERMISSION: [permission.value for permission in MrPermission],
            CoverageCategory.MESSAGE_SIZE: [size.value for size in MessageSizeBin],
            CoverageCategory.SGE_COUNT: [count.value for count in SgeCountBin],
            CoverageCategory.QP_TYPE: [qp_type.value for qp_type in QpType],
            CoverageCategory.CONGESTION: [event.value for event in CongestionEvent],
        }
        optional = {CoverageCategory(key): set(values) for key, values in optional_bins.items()}
        for category, names in defaults.items():
            self.bins[category] = {
                name: CoverageBin(name, optional=name in optional.get(category, set())) for name in names
            }

    def _message_size_bin(self, byte_len: int) -> MessageSizeBin:
        if byte_len == 0:
            return MessageSizeBin.ZERO
        if byte_len < self.mtu_bytes:
            return MessageSizeBin.SMALL
        if byte_len == self.mtu_bytes:
            return MessageSizeBin.MTU
        if byte_len >= self.max_message_size:
            return MessageSizeBin.MAX
        return MessageSizeBin.MULTI_PACKET

    def _sge_count_bin(self, count: int) -> SgeCountBin:
        if count < 0 or count > self.max_sge:
            return SgeCountBin.INVALID
        if count == 0:
            return SgeCountBin.ZERO
        if count == 1:
            return SgeCountBin.ONE
        if count == self.max_sge:
            return SgeCountBin.MAX
        return SgeCountBin.MULTIPLE

    @staticmethod
    def _enum_name(value) -> str:
        if isinstance(value, Enum):
            return value.value
        return str(value)

    @staticmethod
    def _opcode_from_roce(opcode: int) -> WrOpcode:
        mapping = {
            RoceOpcode.RC_SEND_ONLY: WrOpcode.SEND,
            RoceOpcode.RC_SEND_ONLY_IMM: WrOpcode.SEND,
            RoceOpcode.RDMA_WRITE_ONLY: WrOpcode.RDMA_WRITE,
            RoceOpcode.RDMA_WRITE_ONLY_IMM: WrOpcode.RDMA_WRITE,
            RoceOpcode.RDMA_READ_REQUEST: WrOpcode.RDMA_READ,
            RoceOpcode.RDMA_READ_RESPONSE_ONLY: WrOpcode.RDMA_READ,
            RoceOpcode.UD_SEND_ONLY: WrOpcode.UD_SEND,
            RoceOpcode.UD_SEND_ONLY_IMM: WrOpcode.UD_SEND,
        }
        return mapping.get(RoceOpcode(opcode), WrOpcode.SEND)

