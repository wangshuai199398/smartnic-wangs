# SPDX-License-Identifier: MIT
"""Pure Python checks for stage 10 ECN/CNP congestion semantics."""


ECN_CE = 0b11
ROCE_OPCODE_CNP = 0x81
ROCEV2_UDP_PORT = 4791
DCQCN_STATE_NORMAL = "NORMAL"
DCQCN_STATE_CONGESTED = "CONGESTED"
DCQCN_STATE_RECOVERY = "RECOVERY"
PACER_STATUS_ALLOWED = "ALLOWED"
PACER_STATUS_THROTTLED = "THROTTLED"
PACER_STATUS_DISABLED = "DISABLED"
PACER_STATUS_INVALID = "INVALID"


def parse_ipv4_ecn(dsfield):
    return {
        "ip_dsfield": dsfield & 0xFF,
        "ecn": dsfield & 0x3,
        "ecn_valid": True,
        "ecn_ce": (dsfield & 0x3) == ECN_CE,
    }


def parse_ipv6_ecn(traffic_class):
    return {
        "ipv6_traffic_class": traffic_class & 0xFF,
        "ecn": traffic_class & 0x3,
        "ecn_valid": True,
        "ecn_ce": (traffic_class & 0x3) == ECN_CE,
    }


def mark_packet(meta, counters):
    marked = dict(meta)
    if marked.get("ecn_valid", False):
        counters["ecn"] += 1
        if marked.get("ecn_ce", False):
            counters["ce"] += 1
        if marked.get("status", 0) != 0:
            counters["malformed"] += 1
    hook = marked if marked.get("ecn_valid", False) and marked.get("ecn_ce", False) else None
    return marked, hook


def test_ipv4_ce_detection():
    meta = parse_ipv4_ecn(0x03)
    assert meta["ecn"] == 0x03
    assert meta["ecn_ce"] is True


def test_ipv6_traffic_class_ce_detection():
    meta = parse_ipv6_ecn(0xAB)
    assert meta["ipv6_traffic_class"] == 0xAB
    assert meta["ecn"] == 0x03
    assert meta["ecn_ce"] is True


def test_non_ecn_behavior_unchanged():
    counters = {"ecn": 0, "ce": 0, "malformed": 0}
    meta = {"desc_id": 1, "qpn": 2, "ecn_valid": False, "ecn_ce": False, "status": 0}
    marked, hook = mark_packet(meta, counters)
    assert marked == meta
    assert hook is None
    assert counters == {"ecn": 0, "ce": 0, "malformed": 0}


def test_ce_mark_hook_and_counters():
    counters = {"ecn": 0, "ce": 0, "malformed": 0}
    meta = {"desc_id": 1, "qpn": 0x123456, "ecn_valid": True, "ecn": 3, "ecn_ce": True, "status": 0}
    marked, hook = mark_packet(meta, counters)
    assert marked["qpn"] == 0x123456
    assert hook is not None
    assert hook["ecn"] == 3
    assert counters == {"ecn": 1, "ce": 1, "malformed": 0}


def test_malformed_ecn_counter():
    counters = {"ecn": 0, "ce": 0, "malformed": 0}
    meta = {"desc_id": 1, "ecn_valid": True, "ecn": 3, "ecn_ce": True, "status": 3}
    mark_packet(meta, counters)
    assert counters == {"ecn": 1, "ce": 1, "malformed": 1}


class CnpGeneratorModel:
    def __init__(self, cooldown):
        self.cooldown = cooldown
        self.cooldown_by_qpn = {}
        self.generated = 0
        self.rate_limited = 0

    def tick(self):
        for qpn in list(self.cooldown_by_qpn):
            if self.cooldown_by_qpn[qpn] > 0:
                self.cooldown_by_qpn[qpn] -= 1

    def trigger(self, qpn, congestion_type=0):
        if self.cooldown_by_qpn.get(qpn, 0) > 0:
            self.rate_limited += 1
            return None
        self.generated += 1
        self.cooldown_by_qpn[qpn] = self.cooldown
        return {
            "opcode": ROCE_OPCODE_CNP,
            "dest_qpn": qpn,
            "imm_data": congestion_type & 0x3,
            "has_imm": True,
        }


def classify_cnp(meta, qp_exists):
    if meta.get("opcode") != ROCE_OPCODE_CNP:
        return "not_cnp", None
    if meta.get("status", 0) != 0 or meta.get("udp_dst_port") != ROCEV2_UDP_PORT:
        return "malformed", None
    if not qp_exists:
        return "qp_miss", None
    return "ok", {
        "qpn": meta["dest_qpn"],
        "source_qpn": meta.get("src_qpn", 0),
        "congestion_type": meta.get("imm_data", 0) & 0x3,
    }


def test_ce_mark_triggers_cnp_generation():
    gen = CnpGeneratorModel(cooldown=4)
    cnp = gen.trigger(0x123456, congestion_type=0)
    assert cnp["opcode"] == ROCE_OPCODE_CNP
    assert cnp["dest_qpn"] == 0x123456
    assert cnp["imm_data"] == 0
    assert gen.generated == 1


def test_cnp_rate_limit_per_qp():
    gen = CnpGeneratorModel(cooldown=4)
    assert gen.trigger(0x10) is not None
    assert gen.trigger(0x10) is None
    assert gen.rate_limited == 1
    for _ in range(4):
        gen.tick()
    assert gen.trigger(0x10) is not None
    assert gen.generated == 2


def test_valid_cnp_classifies_to_dcqcn_event():
    status, event = classify_cnp({
        "opcode": ROCE_OPCODE_CNP,
        "udp_dst_port": ROCEV2_UDP_PORT,
        "status": 0,
        "dest_qpn": 0x222222,
        "src_qpn": 0x111111,
        "imm_data": 2,
    }, qp_exists=True)
    assert status == "ok"
    assert event == {"qpn": 0x222222, "source_qpn": 0x111111, "congestion_type": 2}


def test_invalid_cnp_classification():
    status, event = classify_cnp({"opcode": ROCE_OPCODE_CNP, "udp_dst_port": 1, "status": 0}, qp_exists=True)
    assert status == "malformed"
    assert event is None
    status, event = classify_cnp({
        "opcode": ROCE_OPCODE_CNP,
        "udp_dst_port": ROCEV2_UDP_PORT,
        "status": 0,
        "dest_qpn": 3,
    }, qp_exists=False)
    assert status == "qp_miss"
    assert event is None


class DcqcnModel:
    def __init__(self, current_rate, target_rate, min_rate, ai, alpha=0, g=4):
        self.current_rate = current_rate
        self.target_rate = target_rate
        self.min_rate = min_rate
        self.ai = ai
        self.alpha = alpha
        self.g = g
        self.state = DCQCN_STATE_NORMAL
        self.cnp_events = 0
        self.rate_decrease = 0
        self.rate_increase = 0
        self.state_transitions = 0

    def on_cnp(self):
        old_state = self.state
        self.state = DCQCN_STATE_CONGESTED
        self.current_rate = max(self.current_rate // 2, self.min_rate)
        self.alpha = min(0xFFFF, self.alpha - (self.alpha >> self.g) + (0xFFFF >> self.g))
        self.cnp_events += 1
        self.rate_decrease += 1
        if old_state != self.state:
            self.state_transitions += 1
        return self.current_rate

    def recovery_tick(self):
        old_state = self.state
        self.current_rate = min(self.current_rate + self.ai, self.target_rate)
        self.rate_increase += 1
        self.state = DCQCN_STATE_NORMAL if self.current_rate == self.target_rate else DCQCN_STATE_RECOVERY
        if old_state != self.state:
            self.state_transitions += 1
        return self.current_rate


def test_dcqcn_cnp_halves_rate_and_updates_alpha():
    dcqcn = DcqcnModel(current_rate=1000, target_rate=1000, min_rate=100, ai=100, alpha=0, g=4)
    assert dcqcn.on_cnp() == 500
    assert dcqcn.state == DCQCN_STATE_CONGESTED
    assert dcqcn.alpha == 0x0FFF
    assert dcqcn.cnp_events == 1
    assert dcqcn.rate_decrease == 1


def test_dcqcn_decrease_clamps_to_min_rate():
    dcqcn = DcqcnModel(current_rate=120, target_rate=1000, min_rate=100, ai=100)
    assert dcqcn.on_cnp() == 100


def test_dcqcn_recovery_additive_increase_to_normal():
    dcqcn = DcqcnModel(current_rate=1000, target_rate=1000, min_rate=100, ai=250)
    dcqcn.on_cnp()
    assert dcqcn.recovery_tick() == 750
    assert dcqcn.state == DCQCN_STATE_RECOVERY
    assert dcqcn.recovery_tick() == 1000
    assert dcqcn.state == DCQCN_STATE_NORMAL
    assert dcqcn.rate_increase == 2


class TokenBucketPacerModel:
    def __init__(self):
        self.enabled = True
        self.buckets = {}
        self.tokens_refilled = 0
        self.tx_throttled_events = 0
        self.tx_allowed_packets = 0

    def configure(self, qpn, owner_function, bucket_size, initial_tokens, now):
        self.buckets[(qpn, owner_function)] = {
            "rate": 0,
            "bucket_size": bucket_size,
            "tokens": min(initial_tokens, bucket_size),
            "last_update_time": now,
        }

    def update_rate(self, qpn, owner_function, current_rate):
        bucket = self.buckets.setdefault((qpn, owner_function), {
            "rate": 0,
            "bucket_size": 0,
            "tokens": 0,
            "last_update_time": 0,
        })
        bucket["rate"] = current_rate

    def pace(self, qpn, owner_function, packet_size, now):
        if not self.enabled:
            self.tx_allowed_packets += 1
            return PACER_STATUS_DISABLED, 0
        bucket = self.buckets.get((qpn, owner_function))
        if bucket is None or bucket["bucket_size"] == 0 or packet_size == 0:
            return PACER_STATUS_INVALID, 0
        delta = now - bucket["last_update_time"]
        refill = bucket["rate"] * delta
        before = bucket["tokens"]
        bucket["tokens"] = min(bucket["tokens"] + refill, bucket["bucket_size"])
        self.tokens_refilled += max(bucket["tokens"] - before, 0)
        bucket["last_update_time"] = now
        if bucket["tokens"] < packet_size:
            self.tx_throttled_events += 1
            return PACER_STATUS_THROTTLED, bucket["tokens"]
        bucket["tokens"] -= packet_size
        self.tx_allowed_packets += 1
        return PACER_STATUS_ALLOWED, bucket["tokens"]


def test_pacer_refills_tokens_from_dcqcn_rate_and_allows_packet():
    pacer = TokenBucketPacerModel()
    pacer.configure(qpn=0x10, owner_function=1, bucket_size=1000, initial_tokens=0, now=0)
    pacer.update_rate(qpn=0x10, owner_function=1, current_rate=100)

    status, tokens_after = pacer.pace(qpn=0x10, owner_function=1, packet_size=150, now=2)
    assert status == PACER_STATUS_ALLOWED
    assert tokens_after == 50
    assert pacer.tokens_refilled == 200
    assert pacer.tx_allowed_packets == 1


def test_pacer_throttles_when_packet_exceeds_tokens():
    pacer = TokenBucketPacerModel()
    pacer.configure(qpn=0x10, owner_function=1, bucket_size=1000, initial_tokens=10, now=0)
    pacer.update_rate(qpn=0x10, owner_function=1, current_rate=0)

    status, tokens_after = pacer.pace(qpn=0x10, owner_function=1, packet_size=100, now=1)
    assert status == PACER_STATUS_THROTTLED
    assert tokens_after == 10
    assert pacer.tx_throttled_events == 1


def test_pacer_refill_clamps_to_bucket_size():
    pacer = TokenBucketPacerModel()
    pacer.configure(qpn=0x10, owner_function=1, bucket_size=1000, initial_tokens=900, now=0)
    pacer.update_rate(qpn=0x10, owner_function=1, current_rate=100)

    status, tokens_after = pacer.pace(qpn=0x10, owner_function=1, packet_size=100, now=5)
    assert status == PACER_STATUS_ALLOWED
    assert tokens_after == 900
    assert pacer.tokens_refilled == 100


def main():
    test_ipv4_ce_detection()
    test_ipv6_traffic_class_ce_detection()
    test_non_ecn_behavior_unchanged()
    test_ce_mark_hook_and_counters()
    test_malformed_ecn_counter()
    test_ce_mark_triggers_cnp_generation()
    test_cnp_rate_limit_per_qp()
    test_valid_cnp_classifies_to_dcqcn_event()
    test_invalid_cnp_classification()
    test_dcqcn_cnp_halves_rate_and_updates_alpha()
    test_dcqcn_decrease_clamps_to_min_rate()
    test_dcqcn_recovery_additive_increase_to_normal()
    test_pacer_refills_tokens_from_dcqcn_rate_and_allows_packet()
    test_pacer_throttles_when_packet_exceeds_tokens()
    test_pacer_refill_clamps_to_bucket_size()
    print("[stage10] ECN/CNP/DCQCN/pacing semantic checks passed")


if __name__ == "__main__":
    main()
