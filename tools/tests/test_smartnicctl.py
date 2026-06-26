#!/usr/bin/env python3
"""Basic userspace SmartNIC CLI/library checks."""

from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(ROOT / "smartnicctl"), *args],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def require(text: str, needle: str, label: str) -> None:
    assert needle in text, f"missing {label}: {needle}"


def main() -> None:
    help_result = run("--help")
    assert help_result.returncode == 0
    assert "Usage: smartnicctl" in help_result.stdout
    assert "mbox OPCODE" in help_result.stdout

    invalid = run("--device", "/dev/this-smartnic-does-not-exist", "info")
    assert invalid.returncode != 0
    assert "failed to open" in invalid.stderr

    read_csr = run("read-csr", "0")
    assert read_csr.returncode == 2
    assert "not supported" in read_csr.stderr

    lib_h = read(ROOT / "libsmartnic.h")
    lib_c = read(ROOT / "libsmartnic.c")
    cli_c = read(ROOT / "smartnicctl.c")
    uapi = read(REPO / "include/uapi/linux/smartnic_ioctl.h")
    makefile = read(ROOT / "Makefile")
    top_make = read(REPO / "Makefile")
    tasks = read(REPO / "openspec/changes/add-rdma-smartnic-design-capability/tasks.md")

    require(lib_h, "#include <linux/smartnic_ioctl.h>", "UAPI include")
    require(lib_h, "smartnic_open", "open wrapper")
    require(lib_h, "smartnic_query_device", "feature helper")
    require(lib_h, "smartnic_reset_device", "reset helper")
    require(lib_h, "smartnic_mailbox", "mailbox helper")
    require(lib_c, "SMARTNIC_IOCTL_MBOX_EXEC", "ioctl reuse")
    require(lib_c, "req.struct_size = sizeof(req)", "struct size validation")
    require(lib_c, "ioctl(dev->fd, SMARTNIC_IOCTL_MBOX_EXEC", "ioctl call")
    require(cli_c, "cmd_list", "list command")
    require(cli_c, "cmd_info", "info command")
    require(cli_c, "cmd_reset", "reset command")
    require(cli_c, "cmd_mbox", "mailbox command")
    require(cli_c, "unsupported_csr_command", "unsupported CSR handling")
    require(makefile, "-I$(UAPI_INC)", "UAPI include path")
    require(top_make, "$(MAKE) -C tools", "top-level userspace tools build")
    require(uapi, "SMARTNIC_IOCTL_MBOX_EXEC", "single source UAPI")
    require(tasks, "- [x] 12.4 Implement user-space library and CLI tool", "12.4 completion")

    print("smartnic userspace tool checks passed")


if __name__ == "__main__":
    main()
