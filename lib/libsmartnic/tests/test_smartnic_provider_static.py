#!/usr/bin/env python3
"""Static checks for the 13.1 SmartNIC userspace provider context API."""

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
        "struct smartnic_provider_device",
        "struct smartnic_provider_context",
        "struct smartnic_provider_device_attr",
        "struct smartnic_provider_port_attr",
        "struct smartnic_provider_gid",
        "smartnic_provider_discover",
        "smartnic_provider_free_devices",
        "smartnic_provider_open",
        "smartnic_provider_open_path",
        "smartnic_provider_close",
        "smartnic_provider_query_device",
        "smartnic_provider_query_port",
        "smartnic_provider_query_gid",
        "smartnic_provider_query_pkey",
        "SMARTNIC_PROVIDER_TRANSPORT_RC",
        "SMARTNIC_PROVIDER_TRANSPORT_UD",
        "SMARTNIC_PROVIDER_LINK_LAYER_ETHERNET",
        "SMARTNIC_PROVIDER_GID_TABLE_LEN",
        "SMARTNIC_PROVIDER_PKEY_TABLE_LEN",
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
        "O_RDWR | O_CLOEXEC",
        "pthread_mutex_init",
        "pthread_mutex_lock(&ctx->lock)",
        "errno = EBUSY",
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
    print("smartnic provider static checks passed")


if __name__ == "__main__":
    main()
