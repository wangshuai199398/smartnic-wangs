#!/usr/bin/env python3
"""Packaging checks for the SmartNIC userspace provider."""

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def require(text: str, needle: str, label: str) -> None:
    assert needle in text, f"missing {label}: {needle}"


def main() -> None:
    makefile = read(ROOT / "Makefile")
    pc_template = read(ROOT / "libsmartnic-provider.pc.in")
    metadata = json.loads(read(ROOT / "smartnic-provider.json"))
    examples_make = read(REPO / "examples/Makefile")
    examples = {
        "query": read(REPO / "examples/smartnic_provider_query_example.c"),
        "cq": read(REPO / "examples/smartnic_provider_cq_poll_example.c"),
        "async": read(REPO / "examples/smartnic_provider_async_event_example.c"),
        "minimal": read(REPO / "examples/smartnic_minimal_verbs_example.c"),
    }
    docs = read(REPO / "docs/userspace-provider.md")
    tasks = read(REPO / "openspec/changes/add-rdma-smartnic-design-capability/tasks.md")

    for needle in [
        "Name: libsmartnic-provider",
        "Description: SmartNIC prototype RDMA userspace provider library",
        "Version: @version@",
        "Libs: -L${libdir} -lsmartnic_provider -pthread",
        "Cflags: -I${includedir}",
    ]:
        require(pc_template, needle, f"pkg-config template {needle}")

    assert metadata["name"] == "smartnic"
    assert metadata["provider"] == "libsmartnic-provider"
    assert metadata["abi_version"] == 1
    assert metadata["device_match"]["vendor_id"] == "0x1d0f"
    assert metadata["device_match"]["device_id"] == "0x5a10"
    assert "rc" in metadata["device_match"]["transport"]
    assert "ud" in metadata["device_match"]["transport"]

    for needle in [
        "PC_TEMPLATE := libsmartnic-provider.pc.in",
        "PC_FILE := build/pkgconfig/libsmartnic-provider.pc",
        "PROVIDER_METADATA := smartnic-provider.json",
        "packaging: pkgconfig metadata",
        "sed -e 's|@prefix@|$(PREFIX)|g'",
        "cp $(PC_FILE) $(DESTDIR)$(PKGCONFIGDIR)/",
        "cp $(STAGED_METADATA) $(DESTDIR)$(PROVIDERDIR)/",
        "python3 tests/test_smartnic_provider_packaging.py",
    ]:
        require(makefile, needle, f"provider packaging Makefile {needle}")

    for needle in [
        "PROVIDER_EXAMPLES",
        "smartnic_provider_query_example",
        "smartnic_provider_cq_poll_example",
        "smartnic_provider_async_event_example",
        "smartnic_minimal_verbs_example",
        "smartnic_minimal_verbs_example.build",
        "$(PROVIDER_DIR)/libsmartnic_provider.a",
        "-I$(PROVIDER_DIR)",
    ]:
        require(examples_make, needle, f"examples Makefile {needle}")

    require(examples["query"], "smartnic_provider_open_path", "query example open")
    require(examples["query"], "smartnic_provider_query_device", "query example query")
    require(examples["cq"], "smartnic_provider_create_cq", "CQ example create")
    require(examples["cq"], "smartnic_provider_poll_cq", "CQ example poll")
    require(examples["async"], "smartnic_provider_get_async_event", "async example get")
    require(examples["async"], "smartnic_provider_ack_async_event", "async example ack")
    require(examples["minimal"], "smartnic_provider_alloc_pd", "minimal example alloc PD")
    require(examples["minimal"], "smartnic_provider_create_cq", "minimal example create CQ")
    require(examples["minimal"], "smartnic_provider_create_qp", "minimal example create QP")
    require(examples["minimal"], "smartnic_provider_reg_mr", "minimal example register MR")
    require(examples["minimal"], "smartnic_provider_post_recv", "minimal example post recv")
    require(examples["minimal"], "smartnic_provider_post_send", "minimal example post send")
    require(examples["minimal"], "smartnic_provider_poll_cq", "minimal example poll CQ")
    for source in examples.values():
        require(source, "#include <smartnic_provider.h>", "provider example include")

    for needle in [
        "pkg-config",
        "libsmartnic-provider.pc",
        "smartnic-provider.json",
        "smartnic_provider_query_example",
        "smartnic_provider_cq_poll_example",
        "smartnic_provider_async_event_example",
        "smartnic_minimal_verbs_example",
        "make -C lib/libsmartnic test",
        "DESTDIR=/tmp/smartnic-stage",
    ]:
        require(docs, needle, f"userspace provider packaging doc {needle}")

    require(tasks, "- [x] 13.12 Add pkg-config", "13.12 task completion")
    print("smartnic provider packaging checks passed")


if __name__ == "__main__":
    main()
