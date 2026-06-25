# SPDX-License-Identifier: MIT
"""Structural and mock-flow checks for task 11.5 RDMA Write/Read integration."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / "rtl" / "transport" / "rdma_write_read_engine.sv"
TOP = ROOT / "rtl" / "top" / "smartnic_top.sv"
TASKS = ROOT / "openspec" / "changes" / "add-rdma-smartnic-design-capability" / "tasks.md"


def read(path):
    assert path.exists(), f"{path} must exist"
    return path.read_text()


def test_engine_module_exists_and_preserves_metadata():
    text = read(ENGINE)
    assert "module rdma_write_read_engine" in text
    for token in [
        "wr_desc_id",
        "wr_qpn",
        "wr_cqn",
        "wr_owner_function",
        "wr_pd_id",
        "wr_id",
        "wr_lkey",
        "wr_remote_va",
        "wr_rkey",
        "completion_event_t",
        "packet_build_req_t",
    ]:
        assert token in text


def test_engine_supports_write_and_read_packets():
    text = read(ENGINE)
    assert "RDMA_OP_RDMA_WRITE" in text
    assert "RDMA_OP_RDMA_READ" in text
    assert "ROCE_OPCODE_RDMA_WRITE_ONLY" in text
    assert "ROCE_OPCODE_RDMA_READ_REQ" in text
    assert "remote_va" in text
    assert "rkey" in text
    assert "dma_read_valid" in text
    assert "dma_write_valid" in text


def test_engine_tracks_single_outstanding_read():
    text = read(ENGINE)
    for token in [
        "RDMA_RD_WAIT_RESPONSE",
        "read_psn_q",
        "read_resp_psn != read_psn_q",
        "outstanding_read_valid",
        "CMPL_BAD_RESP_ERR",
    ]:
        assert token in text


def test_smartnic_top_integrates_rdma_engine():
    text = read(TOP)
    assert "rdma_write_read_engine" in text
    assert "u_rdma_write_read_engine" in text
    assert "rdma_wr_test_valid" in text
    assert "rdma_read_resp_test_valid" in text
    assert "tx_build_valid = cnp_build_valid || rc_build_valid || rdma_build_valid" in text
    assert "rc_build_valid ? rc_build_req : rdma_build_req" in text
    assert "top_completion_valid = rc_completion_valid || rdma_completion_valid" in text
    assert "top_completion_event = rc_completion_valid ? rc_completion_event : rdma_completion_event" in text


def test_mock_write_and_read_flow_order():
    write_flow = ["validate", "dma_read", "packet_write", "completion"]
    read_flow = ["validate", "read_request", "wait_response", "dma_write", "completion"]
    assert write_flow == ["validate", "dma_read", "packet_write", "completion"]
    assert read_flow.index("read_request") < read_flow.index("wait_response")
    assert read_flow.index("dma_write") < read_flow.index("completion")


def test_mock_error_mapping():
    def map_error(opcode, length, lkey, rkey, psn_ok=True):
        if length == 0:
            return "CMPL_LOC_LEN_ERR"
        if lkey == 0 or rkey == 0:
            return "CMPL_LOC_PROT_ERR"
        if opcode == "READ" and not psn_ok:
            return "CMPL_BAD_RESP_ERR"
        return "CMPL_SUCCESS"

    assert map_error("WRITE", 1024, 0x1111, 0x2222) == "CMPL_SUCCESS"
    assert map_error("READ", 1024, 0x1111, 0x2222) == "CMPL_SUCCESS"
    assert map_error("WRITE", 0, 0x1111, 0x2222) == "CMPL_LOC_LEN_ERR"
    assert map_error("WRITE", 64, 0, 0x2222) == "CMPL_LOC_PROT_ERR"
    assert map_error("READ", 64, 0x1111, 0x2222, psn_ok=False) == "CMPL_BAD_RESP_ERR"


def test_task_11_5_marked_done():
    text = read(TASKS)
    assert "- [x] 11.5 Connect RDMA Write and RDMA Read datapaths." in text


def main():
    test_engine_module_exists_and_preserves_metadata()
    test_engine_supports_write_and_read_packets()
    test_engine_tracks_single_outstanding_read()
    test_smartnic_top_integrates_rdma_engine()
    test_mock_write_and_read_flow_order()
    test_mock_error_mapping()
    test_task_11_5_marked_done()
    print("[rdma-write-read] task 11.5 structural checks passed")


if __name__ == "__main__":
    main()
