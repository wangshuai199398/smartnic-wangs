# SPDX-License-Identifier: MIT
"""Static checks for the 15.6 FPGA prototype checklist."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def test_checklist_covers_required_bring_up_sections() -> None:
    checklist = read("docs/24-fpga-prototype-checklist.md")

    for section in (
        "# FPGA Prototype Checklist",
        "Board Selection",
        "PCIe IP Wrapper",
        "MAC IP Wrapper",
        "Clocks And Resets",
        "Constraints",
        "Loopback And Smoke Bring-Up",
        "Host Driver Loading",
        "Pre-Flight Checklist",
        "Post-Programming Checklist",
        "Known Limitations",
    ):
        assert section in checklist


def test_checklist_mentions_key_validation_artifacts() -> None:
    checklist = read("docs/24-fpga-prototype-checklist.md")

    for token in (
        "FPGA part",
        "speed grade",
        "PCIe generation",
        "lane width",
        "BAR0",
        "BAR2",
        "MSI-X",
        "DMA",
        "FCS",
        "PFC",
        "PLL/MMCM",
        "CDC",
        "XDC/SDC",
        "lspci",
        "ibv_devices",
        "smartnicctl",
        "generic CI must not require vendor tools",
    ):
        assert token in checklist


def test_docs_index_links_fpga_checklist() -> None:
    index = read("docs/README.md")

    assert "24-fpga-prototype-checklist.md" in index
    assert "15.6" in index
    assert "FPGA 原型 bring-up 清单" in index


def test_task_15_6_is_marked_complete() -> None:
    tasks = read("openspec/changes/add-rdma-smartnic-design-capability/tasks.md")

    assert "- [x] 15.6 Add FPGA prototype checklist" in tasks
    assert "- [ ] 16.1 Document hardware module architecture" in tasks


def run_all() -> None:
    test_checklist_covers_required_bring_up_sections()
    test_checklist_mentions_key_validation_artifacts()
    test_docs_index_links_fpga_checklist()
    test_task_15_6_is_marked_complete()


if __name__ == "__main__":
    run_all()
    print("FPGA prototype checklist static checks passed")
