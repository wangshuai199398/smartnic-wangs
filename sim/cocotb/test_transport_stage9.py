# SPDX-License-Identifier: MIT
"""Stage 9 transport mock regression tests.

These tests complement module-level Cocotb tests by covering the transport task
9.8 matrix in a pure-Python flow. They intentionally use mock state and do not
model a real PCIe root complex, full RoCEv2 wire timing, or a full DMA engine.
"""

RC = "RC"
UD = "UD"

SEND = "SEND"
RDMA_WRITE = "RDMA_WRITE"
RDMA_READ = "RDMA_READ"
SEND_WITH_IMM = "SEND_WITH_IMM"
RDMA_WRITE_WITH_IMM = "RDMA_WRITE_WITH_IMM"

SUCCESS = "SUCCESS"
PSN_ERROR = "PSN_ERROR"
RETRY_EXHAUSTED = "RETRY_EXHAUSTED"
RNR = "RNR"
LOCAL_PROTECTION_ERROR = "LOCAL_PROTECTION_ERROR"
UNSUPPORTED_OPCODE = "UNSUPPORTED_OPCODE"


class RcQp:
    def __init__(self, qpn=0x123456, send_psn=0x100, recv_psn=0x200, retry=2):
        self.qpn = qpn
        self.send_psn = send_psn
        self.recv_psn = recv_psn
        self.retry = retry
        self.outstanding = {}


class UdQp:
    def __init__(self, qpn=0x222222, qkey=0x11223344):
        self.qpn = qpn
        self.qkey = qkey


def rc_send(qp, opcode=SEND, payload_len=16):
    packet = {
        "transport": RC,
        "opcode": opcode,
        "qpn": qp.qpn,
        "psn": qp.send_psn,
        "payload_len": payload_len,
    }
    qp.outstanding[qp.send_psn] = packet
    qp.send_psn += 1
    return packet


def rc_ack(qp, ack_psn):
    qp.outstanding.pop(ack_psn, None)
    return {"status": SUCCESS, "ack_psn": ack_psn}


def rc_receive(qp, packet):
    if packet["psn"] < qp.recv_psn:
        return {"status": SUCCESS, "duplicate_drop": True}
    if packet["psn"] != qp.recv_psn:
        return {"status": PSN_ERROR, "nak": "sequence", "expected_psn": qp.recv_psn}
    qp.recv_psn += 1
    return {"status": SUCCESS, "ack_psn": packet["psn"]}


def rc_retry(qp, psn):
    if qp.retry == 0:
        return {"status": RETRY_EXHAUSTED, "qp_error": True}
    qp.retry -= 1
    return {"status": SUCCESS, "retry_psn": psn}


def rc_recv_needs_rq(rq_available):
    if not rq_available:
        return {"status": RNR, "rnr_nak": True}
    return {"status": SUCCESS}


def rdma_write(local_ok=True, remote_ok=True):
    if not local_ok or not remote_ok:
        return {"status": LOCAL_PROTECTION_ERROR}
    return {"status": SUCCESS, "packet_opcode": RDMA_WRITE}


def rdma_read(sequence_ok=True, dma_ok=True):
    if not sequence_ok:
        return {"status": PSN_ERROR}
    if not dma_ok:
        return {"status": LOCAL_PROTECTION_ERROR}
    return {"status": SUCCESS, "request": True, "response_written": True}


def immediate(opcode, imm_data, rq_available=True, remote_write_ok=True):
    if not rq_available:
        return {"status": RNR, "has_completion": False}
    if opcode == RDMA_WRITE_WITH_IMM and not remote_write_ok:
        return {"status": LOCAL_PROTECTION_ERROR, "has_completion": False}
    return {"status": SUCCESS, "has_imm": True, "imm_data": imm_data}


def ah_lookup(ah_table, ah_id, owner=1, pd=7):
    ah = ah_table.get(ah_id)
    if ah is None:
        return None
    if ah["owner"] != owner or ah["pd"] != pd:
        return None
    return ah


def ud_send(qp, ah_table, ah_id, opcode=SEND, dest_qpn=0x333333):
    if opcode != SEND:
        return {"status": UNSUPPORTED_OPCODE}
    ah = ah_lookup(ah_table, ah_id)
    if ah is None:
        return {"status": LOCAL_PROTECTION_ERROR}
    qkey = ah["qkey"]
    if qkey == 0:
        return {"status": LOCAL_PROTECTION_ERROR}
    return {
        "status": SUCCESS,
        "packet_opcode": "UD_SEND_ONLY",
        "dest_qpn": dest_qpn,
        "src_qpn": qp.qpn,
        "qkey": qkey,
        "dst_mac": ah["dst_mac"],
        "dst_ip": ah["dst_ip"],
        "service_level": ah["service_level"],
        "dgid": ah["dgid"],
    }


def ud_receive(qp, packet, rq_available=True):
    if packet.get("qkey") != qp.qkey:
        return {"status": LOCAL_PROTECTION_ERROR, "drop": "qkey"}
    if not rq_available:
        return {"status": RNR, "drop": "missing_rq"}
    return {"status": SUCCESS, "source_qpn": packet["src_qpn"]}


def test_rc_send_ack_clears_outstanding():
    qp = RcQp()
    packet = rc_send(qp, SEND)
    assert packet["psn"] in qp.outstanding
    assert rc_ack(qp, packet["psn"])["status"] == SUCCESS
    assert packet["psn"] not in qp.outstanding


def test_rc_rdma_write_success_and_permission_error():
    assert rdma_write()["status"] == SUCCESS
    assert rdma_write(remote_ok=False)["status"] == LOCAL_PROTECTION_ERROR


def test_rc_rdma_read_request_response_and_sequence_error():
    assert rdma_read()["response_written"] is True
    assert rdma_read(sequence_ok=False)["status"] == PSN_ERROR


def test_psn_gap_generates_sequence_nak():
    qp = RcQp(recv_psn=0x200)
    result = rc_receive(qp, {"psn": 0x202})
    assert result["status"] == PSN_ERROR
    assert result["nak"] == "sequence"
    assert result["expected_psn"] == 0x200


def test_retry_and_retry_exhaustion():
    qp = RcQp(retry=1)
    assert rc_retry(qp, 0x100)["status"] == SUCCESS
    exhausted = rc_retry(qp, 0x100)
    assert exhausted["status"] == RETRY_EXHAUSTED
    assert exhausted["qp_error"] is True


def test_rnr_when_receive_queue_missing():
    result = rc_recv_needs_rq(False)
    assert result["status"] == RNR
    assert result["rnr_nak"] is True


def test_immediate_data_send_and_write():
    imm = immediate(SEND_WITH_IMM, 0x11223344)
    assert imm["status"] == SUCCESS
    assert imm["has_imm"] is True
    assert imm["imm_data"] == 0x11223344

    write_imm = immediate(RDMA_WRITE_WITH_IMM, 0xAABBCCDD)
    assert write_imm["status"] == SUCCESS
    assert write_imm["imm_data"] == 0xAABBCCDD


def test_ud_send_uses_ah_and_deth_fields():
    qp = UdQp(qpn=0x111111)
    ah_table = {
        0x22: {
            "owner": 1,
            "pd": 7,
            "qkey": 0x11223344,
            "dst_mac": 0xAABBCCDDEEFF,
            "dst_ip": 0x0A000002,
            "service_level": 5,
            "dgid": (0xFE80000000000000, 0x2),
        }
    }
    packet = ud_send(qp, ah_table, 0x22, dest_qpn=0x333333)
    assert packet["status"] == SUCCESS
    assert packet["packet_opcode"] == "UD_SEND_ONLY"
    assert packet["src_qpn"] == 0x111111
    assert packet["qkey"] == 0x11223344
    assert packet["service_level"] == 5
    assert packet["dgid"] == (0xFE80000000000000, 0x2)


def test_ud_rejects_rdma_ops_and_qkey_mismatch():
    qp = UdQp()
    ah_table = {0x22: {"owner": 1, "pd": 7, "qkey": 0x11223344}}
    assert ud_send(qp, ah_table, 0x22, opcode=RDMA_WRITE)["status"] == UNSUPPORTED_OPCODE

    packet = {"src_qpn": 0x123456, "qkey": 0xDEADBEEF}
    result = ud_receive(qp, packet)
    assert result["status"] == LOCAL_PROTECTION_ERROR
    assert result["drop"] == "qkey"


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    print("[transport-stage9] all mock regression tests passed")
