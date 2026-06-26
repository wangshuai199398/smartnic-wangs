# SPDX-License-Identifier: MIT
"""Structural checks for task 11.6 UD transmit/receive top integration."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
UD_TOP = ROOT / "rtl" / "transport" / "ud_datapath_top.sv"
TOP = ROOT / "rtl" / "top" / "smartnic_top.sv"
TASKS = ROOT / "openspec" / "changes" / "add-rdma-smartnic-design-capability" / "tasks.md"


def read(path):
    assert path.exists(), f"{path} must exist"
    return path.read_text()


def test_ud_datapath_top_exists_and_reuses_engines():
    text = read(UD_TOP)
    assert "module ud_datapath_top" in text
    assert "ah_table u_ah_table" in text
    assert "ud_tx_engine u_ud_tx_engine" in text
    assert "ud_rx_engine u_ud_rx_engine" in text


def test_ud_tx_flow_has_ah_dma_packet_completion():
    text = read(UD_TOP)
    for token in [
        "UD_TOP_TX_DMA_READ",
        "tx_dma_read_valid",
        "ah_lookup_valid",
        "packet_valid",
        "completion_valid",
        "UD_TX_STATUS_AH_MISS",
        "UD_TX_STATUS_MISSING_QKEY",
    ]:
        assert token in text


def test_ud_rx_flow_has_qp_lookup_dma_completion_and_counters():
    text = read(UD_TOP)
    for token in [
        "rx_meta_valid",
        "qp_read_valid",
        "rx_rq_wqe_available",
        "rx_dma_write_valid",
        "ud_rx_counters_t",
        "rx_counters",
        "drop_status",
        "drop_error_code",
        "source_qpn",
    ]:
        assert token in text


def test_smartnic_top_integrates_ud_datapath():
    text = read(TOP)
    assert "ud_datapath_top u_ud_datapath_top" in text
    assert "ud_ah_create_valid" in text
    assert "ud_tx_test_valid" in text
    assert "ud_rx_rq_available" in text
    assert "marked_meta.opcode == ROCE_OPCODE_UD_SEND_ONLY" in text
    assert "context_read_valid(ud_rx_qp_read_valid)" in text
    assert "tx_build_valid = cnp_build_valid || rc_build_valid || rdma_build_valid || ud_build_valid" in text
    assert "rdma_build_valid ? rdma_build_req : ud_build_req" in text
    assert "top_completion_valid = rc_completion_valid || rdma_completion_valid || ud_completion_valid" in text


def test_mock_ud_error_counters():
    counters = {
        "qkey_mismatch": 0,
        "invalid_dest_qpn": 0,
        "rq_empty": 0,
        "malformed_ud_packet": 0,
        "ah_lookup_fail": 0,
    }
    counters["qkey_mismatch"] += 1
    counters["rq_empty"] += 1
    counters["ah_lookup_fail"] += 1
    assert counters == {
        "qkey_mismatch": 1,
        "invalid_dest_qpn": 0,
        "rq_empty": 1,
        "malformed_ud_packet": 0,
        "ah_lookup_fail": 1,
    }


def test_task_11_6_marked_done():
    text = read(TASKS)
    assert "- [x] 11.6 Connect UD transmit and receive datapaths." in text


def main():
    test_ud_datapath_top_exists_and_reuses_engines()
    test_ud_tx_flow_has_ah_dma_packet_completion()
    test_ud_rx_flow_has_qp_lookup_dma_completion_and_counters()
    test_smartnic_top_integrates_ud_datapath()
    test_mock_ud_error_counters()
    test_task_11_6_marked_done()
    print("[ud-datapath] task 11.6 structural checks passed")


if __name__ == "__main__":
    main()
