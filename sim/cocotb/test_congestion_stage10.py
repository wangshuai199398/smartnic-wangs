# SPDX-License-Identifier: MIT
"""Pure Python checks for task 10.1 ECN ingress semantics."""


ECN_CE = 0b11


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


def main():
    test_ipv4_ce_detection()
    test_ipv6_traffic_class_ce_detection()
    test_non_ecn_behavior_unchanged()
    test_ce_mark_hook_and_counters()
    test_malformed_ecn_counter()
    print("[stage10] ECN ingress semantic checks passed")


if __name__ == "__main__":
    main()
