# SPDX-License-Identifier: MIT
"""Stage 10 congestion-control integration checks for task 10.6.

These tests intentionally use Python models from test_congestion_stage10.py so
they can run in environments without cocotb/Verilator. RTL-level checks remain
covered by the per-module cocotb tests when the simulator toolchain is present.
"""

from test_congestion_stage10 import (
    CnpGeneratorModel,
    DcqcnModel,
    PfcSchedulerModel,
    TokenBucketPacerModel,
    classify_cnp,
    mark_packet,
    PACER_STATUS_ALLOWED,
    PACER_STATUS_THROTTLED,
    PFC_STATE_ACTIVE,
    PFC_STATE_PAUSED,
    ROCEV2_UDP_PORT,
    ROCE_OPCODE_CNP,
)


def test_ecn_ce_mark_generates_cnp_with_correct_qp_mapping():
    counters = {"ecn": 0, "ce": 0, "malformed": 0}
    _, hook = mark_packet({
        "desc_id": 7,
        "qpn": 0x123456,
        "cqn": 0x20,
        "owner_function": 3,
        "pd_id": 9,
        "ecn_valid": True,
        "ecn": 3,
        "ecn_ce": True,
        "status": 0,
    }, counters)
    gen = CnpGeneratorModel(cooldown=4)
    cnp = gen.trigger(hook["qpn"], congestion_type=0)

    assert cnp["opcode"] == ROCE_OPCODE_CNP
    assert cnp["dest_qpn"] == 0x123456
    assert counters == {"ecn": 1, "ce": 1, "malformed": 0}
    assert gen.generated == 1


def test_cnp_burst_updates_dcqcn_and_clamps_to_min_rate():
    dcqcn = DcqcnModel(current_rate=1000, target_rate=1000, min_rate=125, ai=100)
    for _ in range(8):
        status, event = classify_cnp({
            "opcode": ROCE_OPCODE_CNP,
            "udp_dst_port": ROCEV2_UDP_PORT,
            "status": 0,
            "dest_qpn": 0x44,
            "src_qpn": 0x55,
            "imm_data": 0,
        }, qp_exists=True)
        assert status == "ok"
        assert event["qpn"] == 0x44
        dcqcn.on_cnp()

    assert dcqcn.current_rate == 125
    assert dcqcn.cnp_events == 8
    assert dcqcn.rate_decrease == 8


def test_recovery_without_new_cnp_reaches_target_rate():
    dcqcn = DcqcnModel(current_rate=1000, target_rate=1000, min_rate=100, ai=200)
    dcqcn.on_cnp()
    seen_rates = []
    while dcqcn.current_rate < dcqcn.target_rate:
        seen_rates.append(dcqcn.recovery_tick())

    assert seen_rates == [700, 900, 1000]
    assert dcqcn.current_rate == dcqcn.target_rate
    assert dcqcn.rate_increase == 3


def test_token_bucket_enforces_rate_limit_and_counts_throttle():
    pacer = TokenBucketPacerModel()
    pacer.configure(qpn=0x10, owner_function=1, bucket_size=256, initial_tokens=0, now=0)
    pacer.update_rate(qpn=0x10, owner_function=1, current_rate=32)

    status, _ = pacer.pace(qpn=0x10, owner_function=1, packet_size=128, now=1)
    assert status == PACER_STATUS_THROTTLED
    status, tokens_after = pacer.pace(qpn=0x10, owner_function=1, packet_size=128, now=4)
    assert status == PACER_STATUS_ALLOWED
    assert tokens_after == 0
    assert pacer.tx_throttled_events == 1
    assert pacer.tx_allowed_packets == 1


def test_pfc_pause_resume_stalls_and_recovers_tx_without_deadlock():
    sched = PfcSchedulerModel()
    sched.pause(priority=3, quanta=0)
    assert sched.pause_state[3] == PFC_STATE_PAUSED
    assert sched.can_schedule(3) is False

    sched.resume(priority=3)
    assert sched.pause_state[3] == PFC_STATE_ACTIVE
    assert sched.can_schedule(3) is True
    assert sched.pfc_pause_events == 1
    assert sched.pfc_resume_events == 1
    assert sched.tx_stalled_due_to_pfc == 1


def test_malformed_cnp_is_dropped_without_dcqcn_state_corruption():
    dcqcn = DcqcnModel(current_rate=1000, target_rate=1000, min_rate=100, ai=100)
    status, event = classify_cnp({
        "opcode": ROCE_OPCODE_CNP,
        "udp_dst_port": 1,
        "status": 0,
        "dest_qpn": 0x44,
    }, qp_exists=True)

    assert status == "malformed"
    assert event is None
    assert dcqcn.current_rate == 1000
    assert dcqcn.state == "NORMAL"
    assert dcqcn.cnp_events == 0
    assert dcqcn.rate_decrease == 0


def test_ecn_to_cnp_to_rate_to_pacing_chain():
    counters = {"ecn": 0, "ce": 0, "malformed": 0}
    _, hook = mark_packet({
        "desc_id": 9,
        "qpn": 0x10,
        "ecn_valid": True,
        "ecn": 3,
        "ecn_ce": True,
        "status": 0,
    }, counters)
    gen = CnpGeneratorModel(cooldown=0)
    cnp = gen.trigger(hook["qpn"], congestion_type=0)
    status, event = classify_cnp({
        "opcode": cnp["opcode"],
        "udp_dst_port": ROCEV2_UDP_PORT,
        "status": 0,
        "dest_qpn": cnp["dest_qpn"],
        "src_qpn": 0x20,
        "imm_data": cnp["imm_data"],
    }, qp_exists=True)

    dcqcn = DcqcnModel(current_rate=512, target_rate=512, min_rate=64, ai=64)
    pacer = TokenBucketPacerModel()
    pacer.configure(qpn=event["qpn"], owner_function=1, bucket_size=512, initial_tokens=0, now=0)
    assert status == "ok"
    new_rate = dcqcn.on_cnp()
    pacer.update_rate(qpn=event["qpn"], owner_function=1, current_rate=new_rate)

    pace_status, _ = pacer.pace(qpn=event["qpn"], owner_function=1, packet_size=300, now=1)
    assert pace_status == PACER_STATUS_THROTTLED
    assert counters["ce"] == 1
    assert gen.generated == 1
    assert dcqcn.rate_decrease == 1
    assert pacer.tx_throttled_events == 1


def main():
    test_ecn_ce_mark_generates_cnp_with_correct_qp_mapping()
    test_cnp_burst_updates_dcqcn_and_clamps_to_min_rate()
    test_recovery_without_new_cnp_reaches_target_rate()
    test_token_bucket_enforces_rate_limit_and_counts_throttle()
    test_pfc_pause_resume_stalls_and_recovers_tx_without_deadlock()
    test_malformed_cnp_is_dropped_without_dcqcn_state_corruption()
    test_ecn_to_cnp_to_rate_to_pacing_chain()
    print("[stage10-integration] congestion control integration checks passed")


if __name__ == "__main__":
    main()
