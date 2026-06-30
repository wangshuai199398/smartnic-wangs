# SPDX-License-Identifier: MIT
"""Static checks for the 16.3 userspace Verbs compatibility documentation."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def test_userspace_verbs_doc_has_required_sections() -> None:
    doc = read("docs/27-userspace-verbs-compatibility.md")

    for heading in (
        "# 用户态 Verbs 兼容性范围",
        "## 兼容目标",
        "## 支持的 Verbs 对象",
        "## 支持的操作",
        "## QP 状态与连接行为",
        "## Memory Registration 兼容性",
        "## Completion 行为",
        "## 能力与限制矩阵",
        "## 已知上限",
        "## 不支持特性和预期失败",
        "## 外部兼容性范围",
        "## 文档级示例流程",
        "## 已知限制 / TODO",
    ):
        assert heading in doc


def test_documented_provider_api_names_match_header() -> None:
    doc = read("docs/27-userspace-verbs-compatibility.md")
    header = read("lib/libsmartnic/smartnic_provider.h")

    for token in (
        "SMARTNIC_PROVIDER_ABI_VERSION",
        "SMARTNIC_PROVIDER_ENV_DEV_DIR",
        "SMARTNIC_PROVIDER_TRANSPORT_RC",
        "SMARTNIC_PROVIDER_TRANSPORT_UD",
        "SMARTNIC_PROVIDER_MAX_WQE_SGE",
        "SMARTNIC_PROVIDER_WQE_INLINE_BYTES",
        "SMARTNIC_PROVIDER_CQE_BYTES",
        "SMARTNIC_PROVIDER_CQE_VALID_BIT",
        "SMARTNIC_PROVIDER_QPT_RC",
        "SMARTNIC_PROVIDER_QPT_UD",
        "SMARTNIC_PROVIDER_QPS_RESET",
        "SMARTNIC_PROVIDER_QPS_INIT",
        "SMARTNIC_PROVIDER_QPS_RTR",
        "SMARTNIC_PROVIDER_QPS_RTS",
        "SMARTNIC_PROVIDER_QP_REQUIRED_INIT",
        "SMARTNIC_PROVIDER_QP_REQUIRED_RTR",
        "SMARTNIC_PROVIDER_QP_REQUIRED_RTS",
        "SMARTNIC_PROVIDER_ACCESS_LOCAL_WRITE",
        "SMARTNIC_PROVIDER_ACCESS_REMOTE_WRITE",
        "SMARTNIC_PROVIDER_ACCESS_REMOTE_READ",
        "SMARTNIC_PROVIDER_SEND_SIGNALED",
        "SMARTNIC_PROVIDER_SEND_INLINE",
        "SMARTNIC_PROVIDER_WR_SEND",
        "SMARTNIC_PROVIDER_WR_SEND_WITH_IMM",
        "SMARTNIC_PROVIDER_WR_RDMA_WRITE",
        "SMARTNIC_PROVIDER_WR_RDMA_WRITE_WITH_IMM",
        "SMARTNIC_PROVIDER_WR_RDMA_READ",
        "SMARTNIC_PROVIDER_WR_UD_SEND",
        "SMARTNIC_PROVIDER_WR_UD_SEND_WITH_IMM",
        "SMARTNIC_PROVIDER_WC_SUCCESS",
        "SMARTNIC_PROVIDER_WC_LOC_LEN_ERR",
        "SMARTNIC_PROVIDER_WC_LOC_PROT_ERR",
        "SMARTNIC_PROVIDER_WC_LOC_ACCESS_ERR",
        "SMARTNIC_PROVIDER_WC_WR_FLUSH_ERR",
        "SMARTNIC_PROVIDER_WC_REM_ACCESS_ERR",
        "SMARTNIC_PROVIDER_WC_REM_OP_ERR",
        "SMARTNIC_PROVIDER_WC_CQ_OVERFLOW_ERR",
        "SMARTNIC_PROVIDER_WC_GENERAL_ERR",
        "struct smartnic_provider_cqe",
        "struct smartnic_provider_wc",
        "struct smartnic_provider_send_wr",
        "struct smartnic_provider_recv_wr",
        "smartnic_provider_discover",
        "smartnic_provider_open_path",
        "smartnic_provider_query_device",
        "smartnic_provider_alloc_pd",
        "smartnic_provider_create_cq",
        "smartnic_provider_create_qp",
        "smartnic_provider_reg_mr",
        "smartnic_provider_create_ah",
        "smartnic_provider_post_send",
        "smartnic_provider_post_recv",
        "smartnic_provider_poll_cq",
        "smartnic_provider_get_async_event",
        "smartnic_provider_ack_async_event",
    ):
        assert token in header
        assert token in doc


def test_documented_source_paths_exist() -> None:
    doc = read("docs/27-userspace-verbs-compatibility.md")
    refs = sorted(set(re.findall(r"`((?:lib|docs|examples|tests)/[^`]+)`", doc)))
    assert refs

    for ref in refs:
        assert (ROOT / ref).exists(), f"missing documented path: {ref}"


def test_limit_and_external_compatibility_scope_is_documented() -> None:
    doc = read("docs/27-userspace-verbs-compatibility.md")

    for token in (
        "perftest",
        "UCX",
        "libfabric",
        "tests/run_perftest_compat.sh",
        "tests/run_ucx_compat.sh",
        "tests/run_libfabric_compat.sh",
        "rdma-core provider plugin",
        "不是完整 rdma-core plugin ABI",
        "真实 mmap Doorbell MMIO",
        "单 MR 长度暂不超过 4GB",
        "WQE builder SGE",
        "query max_sge",
        "EOPNOTSUPP",
        "EINVAL",
        "ENOSPC",
        "EBUSY",
        "EAGAIN",
    ):
        assert token in doc


def test_docs_index_and_task_status_are_consistent() -> None:
    index = read("docs/README.md")
    tasks = read("openspec/changes/add-rdma-smartnic-design-capability/tasks.md")

    assert "27-userspace-verbs-compatibility.md" in index
    assert "16.3" in index
    assert "- [x] 16.3 Document userspace Verbs API compatibility" in tasks
    assert "- [ ] 16.4 Document verification strategy" in tasks


def run_all() -> None:
    test_userspace_verbs_doc_has_required_sections()
    test_documented_provider_api_names_match_header()
    test_documented_source_paths_exist()
    test_limit_and_external_compatibility_scope_is_documented()
    test_docs_index_and_task_status_are_consistent()


if __name__ == "__main__":
    run_all()
    print("Userspace Verbs compatibility documentation checks passed")
