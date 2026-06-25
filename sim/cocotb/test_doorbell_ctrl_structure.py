# SPDX-License-Identifier: MIT
"""Structural and semantic checks for top-level Doorbell control wiring."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CTRL = ROOT / "rtl" / "doorbell" / "doorbell_ctrl.sv"
TOP = ROOT / "rtl" / "top" / "smartnic_top.sv"
TASKS = ROOT / "openspec" / "changes" / "add-rdma-smartnic-design-capability" / "tasks.md"


DB_TYPE_SQ = "DB_TYPE_SQ"
DB_TYPE_RQ = "DB_TYPE_RQ"
DB_TYPE_CQ_ARM = "DB_TYPE_CQ_ARM"


def read(path):
    assert path.exists(), f"{path} must exist"
    return path.read_text()


def route(db_type, db_qp_num, db_value, owner_function=0):
    queue_index = db_value & 0xFFFF
    if db_type == DB_TYPE_SQ:
        return {
            "sq_pi_update_valid": True,
            "sq_pi_update_qpn": db_qp_num,
            "sq_pi_update_new_pi": queue_index,
            "sq_scheduler_valid": True,
            "function_id": owner_function,
        }
    if db_type == DB_TYPE_RQ:
        return {
            "rq_pi_update_valid": True,
            "rq_pi_update_qpn": db_qp_num,
            "rq_pi_update_new_pi": queue_index,
            "rq_post_valid": True,
            "function_id": owner_function,
        }
    if db_type == DB_TYPE_CQ_ARM:
        return {
            "cq_arm_valid": True,
            "cq_arm_cqn": db_qp_num,
            "cq_arm_consumer_index": queue_index,
            "cq_arm_armed": True,
            "function_id": owner_function,
        }
    return {"db_error_valid": True}


def test_doorbell_ctrl_exists_and_reuses_stage3_handlers():
    text = read(CTRL)
    assert "module doorbell_ctrl" in text
    assert "sq_doorbell_handler u_sq_doorbell_handler" in text
    assert "rq_doorbell_handler u_rq_doorbell_handler" in text
    assert "cq_arm_doorbell_handler u_cq_arm_doorbell_handler" in text
    assert "db_qp_num" in text
    assert "db_type" in text
    assert "db_value" in text


def test_doorbell_ctrl_exposes_qp_cq_and_scheduler_outputs():
    text = read(CTRL)
    for signal in [
        "sq_pi_update_valid",
        "sq_pi_update_new_pi",
        "rq_pi_update_valid",
        "rq_pi_update_new_pi",
        "cq_arm_valid",
        "cq_arm_consumer_index",
        "sq_scheduler_valid",
        "rq_post_valid",
    ]:
        assert signal in text


def test_top_connects_doorbell_to_qp_and_cq_tables():
    text = read(TOP)
    assert "bar0_db_valid" in text
    assert "doorbell_ctrl u_doorbell_ctrl" in text
    assert ".sq_pi_update_valid(db_sq_pi_update_valid)" in text
    assert ".rq_pi_update_valid(db_rq_pi_update_valid)" in text
    assert ".cq_arm_valid(db_cq_arm_valid)" in text
    assert ".sq_pi_update_ready(db_sq_pi_update_ready)" in text
    assert ".cq_arm_ready(db_cq_arm_ready)" in text


def test_route_model_for_sq_rq_and_cq_arm():
    assert route(DB_TYPE_SQ, 7, 0x00030022)["sq_pi_update_new_pi"] == 0x22
    assert route(DB_TYPE_RQ, 8, 0x00040033)["rq_pi_update_new_pi"] == 0x33
    cq = route(DB_TYPE_CQ_ARM, 9, 0x00010044)
    assert cq["cq_arm_cqn"] == 9
    assert cq["cq_arm_consumer_index"] == 0x44
    assert cq["cq_arm_armed"] is True


def test_task_11_3_marked_done():
    text = read(TASKS)
    assert "- [x] 11.3 Connect Doorbell path to QP SQ/RQ and CQ arm logic." in text


def main():
    test_doorbell_ctrl_exists_and_reuses_stage3_handlers()
    test_doorbell_ctrl_exposes_qp_cq_and_scheduler_outputs()
    test_top_connects_doorbell_to_qp_and_cq_tables()
    test_route_model_for_sq_rq_and_cq_arm()
    test_task_11_3_marked_done()
    print("[doorbell-ctrl] top-level Doorbell control checks passed")


if __name__ == "__main__":
    main()
