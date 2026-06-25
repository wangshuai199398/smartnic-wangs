# SPDX-License-Identifier: MIT
"""Structural checks for smartnic_top integration, task 11.1."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
TOP = ROOT / "rtl" / "top" / "smartnic_top.sv"


REQUIRED_INSTANCES = [
    "pcie_endpoint_wrapper u_pcie_endpoint",
    "roce_packet_parser u_packet_parser",
    "ecn_ingress_marker u_ecn_marker",
    "cnp_receive_classifier u_cnp_classifier",
    "cnp_packet_generator u_cnp_generator",
    "roce_packet_builder u_packet_builder",
    "dcqcn_state_machine u_dcqcn",
    "pfc_pause_scheduler u_pfc_scheduler",
    "tx_pacer_token_bucket u_tx_pacer",
    "qp_context_table u_qp_table",
    "cq_context_table u_cq_table",
    "completion_engine u_completion_engine",
    "dma_descriptor_dispatcher u_dma_dispatcher",
    "mr_table u_mr_table",
    "rc_send_engine u_rc_send_engine",
    "ud_tx_engine u_ud_tx_engine",
]


def read_top():
    assert TOP.exists(), "smartnic_top.sv must exist"
    return TOP.read_text()


def test_top_module_exists():
    text = read_top()
    assert "module smartnic_top" in text
    assert "input  logic                         clk" in text
    assert "input  logic                         rst_n" in text


def test_major_subsystems_are_instantiated():
    text = read_top()
    missing = [instance for instance in REQUIRED_INSTANCES if instance not in text]
    assert not missing, f"missing smartnic_top subsystem instances: {missing}"


def test_reset_sync_and_debug_observability_exist():
    text = read_top()
    assert "rst_sync_1" in text
    assert "rst_sync_2" in text
    assert "core_rst_n" in text
    assert "debug_qp_status" in text
    assert "debug_cq_status" in text
    assert "debug_transport_status" in text
    assert "debug_congestion_status" in text


def test_stable_boundaries_are_named():
    text = read_top()
    for boundary in [
        "PCIe subsystem boundary",
        "Packet ingress, ECN/CNP, and packet builder boundary",
        "Congestion control and TX scheduler gate",
        "Resource managers and datapath engines",
    ]:
        assert boundary in text


def main():
    test_top_module_exists()
    test_major_subsystems_are_instantiated()
    test_reset_sync_and_debug_observability_exist()
    test_stable_boundaries_are_named()
    print("[smartnic-top] structural integration checks passed")


if __name__ == "__main__":
    main()
