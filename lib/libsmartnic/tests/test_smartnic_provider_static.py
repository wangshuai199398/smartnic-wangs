#!/usr/bin/env python3
"""Static checks for the 13.x SmartNIC userspace provider API."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def require(text: str, needle: str, label: str) -> None:
    assert needle in text, f"missing {label}: {needle}"


def main() -> None:
    header = read(ROOT / "smartnic_provider.h")
    source = read(ROOT / "smartnic_provider.c")
    makefile = read(ROOT / "Makefile")
    tasks = read(REPO / "openspec/changes/add-rdma-smartnic-design-capability/tasks.md")

    for needle in [
        "SMARTNIC_PROVIDER_ABI_VERSION",
        "SMARTNIC_PROVIDER_MAX_DEVICES",
        "SMARTNIC_PROVIDER_ENV_DEV_DIR",
        "SMARTNIC_CMD_ALLOC_PD",
        "SMARTNIC_CMD_DEALLOC_PD",
        "SMARTNIC_CMD_CREATE_CQ",
        "SMARTNIC_CMD_DESTROY_CQ",
        "SMARTNIC_CMD_RESIZE_CQ",
        "SMARTNIC_CMD_POLL_CQ",
        "SMARTNIC_CMD_ARM_CQ",
        "SMARTNIC_CMD_CREATE_QP",
        "SMARTNIC_CMD_MODIFY_QP",
        "SMARTNIC_CMD_QUERY_QP",
        "SMARTNIC_CMD_DESTROY_QP",
        "SMARTNIC_CMD_REG_MR",
        "SMARTNIC_CMD_DEREG_MR",
        "struct smartnic_provider_device",
        "struct smartnic_provider_context",
        "struct smartnic_provider_device_attr",
        "struct smartnic_provider_port_attr",
        "struct smartnic_provider_gid",
        "struct smartnic_provider_wc",
        "struct smartnic_provider_qp_init_attr",
        "struct smartnic_provider_qp_attr",
        "struct smartnic_provider_pd",
        "struct smartnic_provider_cq",
        "struct smartnic_provider_qp",
        "struct smartnic_provider_mr",
        "smartnic_provider_discover",
        "smartnic_provider_free_devices",
        "smartnic_provider_open",
        "smartnic_provider_open_path",
        "smartnic_provider_close",
        "smartnic_provider_query_device",
        "smartnic_provider_query_port",
        "smartnic_provider_query_gid",
        "smartnic_provider_query_pkey",
        "smartnic_provider_alloc_pd",
        "smartnic_provider_dealloc_pd",
        "smartnic_provider_create_cq",
        "smartnic_provider_destroy_cq",
        "smartnic_provider_resize_cq",
        "smartnic_provider_poll_cq",
        "smartnic_provider_req_notify_cq",
        "smartnic_provider_create_qp",
        "smartnic_provider_modify_qp",
        "smartnic_provider_query_qp",
        "smartnic_provider_destroy_qp",
        "smartnic_provider_reg_mr",
        "smartnic_provider_dereg_mr",
        "SMARTNIC_PROVIDER_TRANSPORT_RC",
        "SMARTNIC_PROVIDER_TRANSPORT_UD",
        "SMARTNIC_PROVIDER_LINK_LAYER_ETHERNET",
        "SMARTNIC_PROVIDER_GID_TABLE_LEN",
        "SMARTNIC_PROVIDER_PKEY_TABLE_LEN",
        "SMARTNIC_PROVIDER_OBJECT_MAGIC_PD",
        "SMARTNIC_PROVIDER_OBJECT_MAGIC_CQ",
        "SMARTNIC_PROVIDER_OBJECT_MAGIC_QP",
        "SMARTNIC_PROVIDER_OBJECT_MAGIC_MR",
        "SMARTNIC_PROVIDER_ACCESS_LOCAL_WRITE",
        "SMARTNIC_PROVIDER_ACCESS_REMOTE_WRITE",
        "SMARTNIC_PROVIDER_ACCESS_REMOTE_READ",
        "SMARTNIC_PROVIDER_ACCESS_REMOTE_ATOMIC",
        "SMARTNIC_PROVIDER_ACCESS_RELAXED_ORDER",
        "SMARTNIC_PROVIDER_ACCESS_SUPPORTED_MASK",
        "SMARTNIC_PROVIDER_QPT_RC",
        "SMARTNIC_PROVIDER_QPS_RESET",
        "SMARTNIC_PROVIDER_QPS_INIT",
        "SMARTNIC_PROVIDER_QPS_RTR",
        "SMARTNIC_PROVIDER_QPS_RTS",
        "SMARTNIC_PROVIDER_QP_ATTR_STATE",
        "SMARTNIC_PROVIDER_QP_REQUIRED_INIT",
        "SMARTNIC_PROVIDER_QP_REQUIRED_RTR",
        "SMARTNIC_PROVIDER_QP_REQUIRED_RTS",
        "SMARTNIC_PROVIDER_CQE_VALID_BIT",
        "SMARTNIC_PROVIDER_WC_FLAG_IMM",
        "kernel_handle",
        "child_count",
        "refcount",
        "pd_list",
        "cq_list",
        "qp_list",
        "mr_list",
        "producer_index",
        "consumer_index",
        "armed",
        "solicited_only",
        "pd_count",
        "cq_count",
        "qp_count",
        "mr_count",
        "ah_count",
    ]:
        require(header, needle, f"provider header {needle}")

    for needle in [
        "opendir(dir_path)",
        "readdir(dir)",
        "smartnic_provider_name_matches",
        "smartnic_provider_validate_node",
        "S_ISCHR",
        "SMARTNIC_IOCTL_MBOX_EXEC",
        "SMARTNIC_CMD_QUERY_DEVICE",
        "SMARTNIC_CMD_ALLOC_PD",
        "SMARTNIC_CMD_DEALLOC_PD",
        "SMARTNIC_CMD_CREATE_CQ",
        "SMARTNIC_CMD_DESTROY_CQ",
        "SMARTNIC_CMD_RESIZE_CQ",
        "SMARTNIC_CMD_POLL_CQ",
        "SMARTNIC_CMD_ARM_CQ",
        "SMARTNIC_CMD_CREATE_QP",
        "SMARTNIC_CMD_MODIFY_QP",
        "SMARTNIC_CMD_DESTROY_QP",
        "SMARTNIC_CMD_REG_MR",
        "SMARTNIC_CMD_DEREG_MR",
        "smartnic_provider_mailbox_exec",
        "O_RDWR | O_CLOEXEC",
        "pthread_mutex_init",
        "pthread_mutex_lock(&ctx->lock)",
        "errno = EBUSY",
        "errno = ENOSPC",
        "errno = EBADF",
        "close(fd)",
        "pthread_mutex_destroy",
        "free(ctx)",
        "smartnic_provider_context_is_valid",
        "smartnic_provider_validate_abi",
        "smartnic_provider_translate_device_attr",
        "smartnic_provider_translate_port_attr",
        "smartnic_provider_get_gid",
        "smartnic_provider_get_pkey",
        "SMARTNIC_PROVIDER_FULL_MEMBERSHIP_PKEY",
        "SMARTNIC_PROVIDER_DEFAULT_MAX_QP",
        "SMARTNIC_PROVIDER_DEFAULT_MAX_CQ",
        "SMARTNIC_PROVIDER_DEFAULT_MAX_MR",
        "SMARTNIC_PROVIDER_DEFAULT_MAX_PD",
        "SMARTNIC_PROVIDER_DEFAULT_MAX_SGE",
        "SMARTNIC_PROVIDER_DEFAULT_MAX_WR",
        "errno = EPROTO",
        "smartnic_provider_pd_alloc_object",
        "smartnic_provider_pd_link_locked",
        "smartnic_provider_pd_unlink_locked",
        "smartnic_provider_pd_is_linked_locked",
        "pd->child_count != 0",
        "pd->refcount > 1",
        "out[0] == 0",
        "smartnic_provider_cq_alloc_object",
        "smartnic_provider_cq_free_object",
        "smartnic_provider_cq_link_locked",
        "smartnic_provider_cq_unlink_locked",
        "smartnic_provider_cq_is_linked_locked",
        "smartnic_provider_validate_cqe_count",
        "smartnic_provider_translate_wc",
        "cq->child_count != 0",
        "cq->refcount > 1",
        "SMARTNIC_PROVIDER_CQE_VALID_BIT",
        "return polled ? polled : -err",
        "cq->armed = 1",
        "smartnic_provider_qp_alloc_object",
        "smartnic_provider_qp_free_object",
        "smartnic_provider_qp_link_locked",
        "smartnic_provider_qp_unlink_locked",
        "smartnic_provider_qp_is_linked_locked",
        "smartnic_provider_validate_qp_type",
        "smartnic_provider_validate_qp_caps",
        "smartnic_provider_validate_qp_transition",
        "smartnic_provider_qp_refs_valid_locked",
        "smartnic_provider_qp_hold_refs_locked",
        "smartnic_provider_qp_put_refs_locked",
        "SMARTNIC_PROVIDER_QPS_INIT",
        "SMARTNIC_PROVIDER_QPS_RTR",
        "SMARTNIC_PROVIDER_QPS_RTS",
        "qp->active_ops != 0",
        "qp->refcount > 1",
        "smartnic_provider_page_shift",
        "smartnic_provider_validate_mr_access",
        "smartnic_provider_mr_alloc_object",
        "smartnic_provider_mr_link_locked",
        "smartnic_provider_mr_unlink_locked",
        "smartnic_provider_mr_is_linked_locked",
        "smartnic_provider_mr_hold_pd_locked",
        "smartnic_provider_mr_put_pd_locked",
        "SMARTNIC_PROVIDER_ACCESS_REMOTE_WRITE",
        "SMARTNIC_PROVIDER_ACCESS_REMOTE_ATOMIC",
        "length > UINT32_MAX",
        "out[0] == 0 || out[1] == 0 || out[2] == 0",
        "mr->active_ops != 0",
        "mr->refcount > 1",
    ]:
        require(source, needle, f"provider source {needle}")

    for needle in [
        "smartnic_provider.o",
        "libsmartnic_provider.a",
        "test_smartnic_provider_static.py",
        "-pthread",
    ]:
        require(makefile, needle, f"provider Makefile {needle}")

    require(tasks, "- [x] 13.1 Implement device discovery", "13.1 task completion")
    require(tasks, "- [x] 13.2 Implement query_device", "13.2 task completion")
    require(tasks, "- [x] 13.3 Implement PD alloc/dealloc", "13.3 task completion")
    require(tasks, "- [x] 13.4 Implement CQ create/destroy/resize", "13.4 task completion")
    require(tasks, "- [x] 13.5 Implement QP create/modify/query/destroy", "13.5 task completion")
    require(tasks, "- [x] 13.6 Implement MR register/deregister", "13.6 task completion")
    print("smartnic provider static checks passed")


if __name__ == "__main__":
    main()
