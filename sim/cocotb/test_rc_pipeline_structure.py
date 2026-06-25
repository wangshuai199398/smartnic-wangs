# SPDX-License-Identifier: MIT
"""Structural checks for the 11.4 minimal RC Send/Recv pipeline."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PIPE = ROOT / "rtl" / "top" / "rc_pipeline_top.sv"
TOP = ROOT / "rtl" / "top" / "smartnic_top.sv"
TASKS = ROOT / "openspec" / "changes" / "add-rdma-smartnic-design-capability" / "tasks.md"


def read(path):
    assert path.exists(), f"{path} must exist"
    return path.read_text()


def test_rc_pipeline_module_exists():
    text = read(PIPE)
    assert "module rc_pipeline_top" in text
    assert "RC_PIPE_SEND_DMA_READ" in text
    assert "RC_PIPE_SEND_PACKET" in text
    assert "RC_PIPE_SEND_COMPLETE" in text
    assert "RC_PIPE_RECV_DMA_WRITE" in text
    assert "RC_PIPE_RECV_COMPLETE" in text
    assert "RC_PIPE_CQ_COMMIT" in text


def test_rc_pipeline_preserves_required_metadata():
    text = read(PIPE)
    for signal in [
        "send_qpn",
        "send_cqn",
        "send_owner_function",
        "send_pd_id",
        "send_wr_id",
        "recv_qpn",
        "recv_cqn",
        "recv_owner_function",
        "recv_pd_id",
        "recv_wr_id",
        "completion_event_t",
        "packet_build_req_t",
    ]:
        assert signal in text


def test_rc_pipeline_send_and_recv_order():
    text = read(PIPE)
    send_order = [
        "RC_PIPE_SEND_DMA_READ",
        "RC_PIPE_SEND_PACKET",
        "RC_PIPE_SEND_COMPLETE",
        "RC_PIPE_CQ_COMMIT",
    ]
    recv_order = [
        "RC_PIPE_RECV_DMA_WRITE",
        "RC_PIPE_RECV_COMPLETE",
        "RC_PIPE_CQ_COMMIT",
    ]
    assert all(item in text for item in send_order)
    assert all(item in text for item in recv_order)
    assert text.index("RC_PIPE_SEND_DMA_READ") < text.index("RC_PIPE_SEND_PACKET")
    assert text.index("RC_PIPE_RECV_DMA_WRITE") < text.index("RC_PIPE_RECV_COMPLETE")


def test_smartnic_top_integrates_rc_pipeline():
    text = read(TOP)
    assert "rc_pipeline_top u_rc_pipeline_top" in text
    assert "rc_send_test_valid" in text
    assert "rc_recv_test_valid" in text
    assert "rc_build_valid" in text
    assert "tx_build_req = cnp_build_valid ? cnp_build_req : rc_build_req" in text
    assert ".event_valid(rc_completion_valid)" in text
    assert ".event_type(rc_completion_event.event_type)" in text
    assert "cmpl_cqe_write_valid" in text


def test_task_11_4_marked_done():
    text = read(TASKS)
    assert "- [x] 11.4 Connect QP, DMA, packet, transport, completion, and CQ managers for RC Send/Recv minimal loop." in text


def main():
    test_rc_pipeline_module_exists()
    test_rc_pipeline_preserves_required_metadata()
    test_rc_pipeline_send_and_recv_order()
    test_smartnic_top_integrates_rc_pipeline()
    test_task_11_4_marked_done()
    print("[rc-pipeline] minimal RC Send/Recv pipeline checks passed")


if __name__ == "__main__":
    main()
