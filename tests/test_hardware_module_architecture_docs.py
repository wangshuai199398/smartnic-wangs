# SPDX-License-Identifier: MIT
"""Static checks for the 16.1 hardware architecture documentation."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def test_architecture_document_has_required_sections() -> None:
    doc = read("docs/25-hardware-module-architecture.md")

    for heading in (
        "# Hardware Module Architecture",
        "## Top-Level Hierarchy",
        "## External Interfaces",
        "## Control Path",
        "## Queue And Work-Request Path",
        "## DMA Data Paths",
        "## Packet TX/RX Paths",
        "## Completion And Error Paths",
        "## Key Internal Interfaces",
        "## Implemented Capabilities And Limitations",
        "## Reading Map",
    ):
        assert heading in doc


def test_architecture_document_mentions_major_modules_and_paths() -> None:
    doc = read("docs/25-hardware-module-architecture.md")

    for token in (
        "smartnic_top",
        "pcie_endpoint_wrapper",
        "csr_fabric",
        "doorbell_ctrl",
        "qp_context_table",
        "cq_context_table",
        "mr_table",
        "dma_descriptor_dispatcher",
        "dma_mr_integration",
        "roce_packet_parser",
        "roce_packet_builder",
        "completion_engine",
        "rc_pipeline_top",
        "ud_datapath_top",
        "Doorbell",
        "WQE",
        "CQE",
        "MSI-X",
        "ready/valid",
    ):
        assert token in doc


def test_diagrams_and_interface_table_are_present() -> None:
    doc = read("docs/25-hardware-module-architecture.md")

    assert doc.count("```mermaid") >= 5
    assert "| Interface family | Producer | Consumer |" in doc
    assert "desc_id" in doc
    assert "qpn" in doc
    assert "owner_function" in doc


def test_referenced_rtl_paths_exist() -> None:
    doc = read("docs/25-hardware-module-architecture.md")
    rtl_refs = sorted(set(re.findall(r"`(rtl/[^`]+)`", doc)))
    assert rtl_refs

    for ref in rtl_refs:
        assert (ROOT / ref).exists(), f"missing referenced RTL path: {ref}"


def test_docs_index_and_task_status_are_consistent() -> None:
    index = read("docs/README.md")
    tasks = read("openspec/changes/add-rdma-smartnic-design-capability/tasks.md")

    assert "25-hardware-module-architecture.md" in index
    assert "16.1" in index
    assert "- [x] 16.1 Document hardware module architecture" in tasks
    assert "- [ ] 16.2 Document Linux driver ioctl ABI" in tasks
    assert "- [ ] 16.3 Document userspace Verbs API compatibility" in tasks
    assert "- [ ] 16.4 Document verification strategy" in tasks


def run_all() -> None:
    test_architecture_document_has_required_sections()
    test_architecture_document_mentions_major_modules_and_paths()
    test_diagrams_and_interface_table_are_present()
    test_referenced_rtl_paths_exist()
    test_docs_index_and_task_status_are_consistent()


if __name__ == "__main__":
    run_all()
    print("hardware module architecture documentation checks passed")
