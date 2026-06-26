#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KDIR="${KDIR:-/lib/modules/$(uname -r)/build}"
SMARTNICCTL="$ROOT/tools/smartnicctl"
SMARTNIC_DEV="${SMARTNIC_DEV:-}"

pass=0
skip=0

log() {
    printf '[smartnic-integration] %s\n' "$*"
}

mark_pass() {
    pass=$((pass + 1))
    log "PASS: $*"
}

mark_skip() {
    skip=$((skip + 1))
    log "SKIP: $*"
}

run_required() {
    log "RUN: $*"
    "$@"
    mark_pass "$*"
}

have_linux_headers() {
    [[ -f "$KDIR/Makefile" ]]
}

have_linux_uapi_headers() {
    printf '#include <linux/ioctl.h>\n#include <linux/types.h>\nint main(void){return 0;}\n' | \
        ${CC:-cc} -x c - -o /tmp/smartnic-uapi-check.$$ >/dev/null 2>&1
    local rc=$?
    rm -f /tmp/smartnic-uapi-check.$$
    return "$rc"
}

detect_device() {
    if [[ -n "$SMARTNIC_DEV" ]]; then
        [[ -e "$SMARTNIC_DEV" ]] && return 0
        return 1
    fi

    if compgen -G "/dev/smartnic*" >/dev/null; then
        SMARTNIC_DEV="$(compgen -G "/dev/smartnic*" | head -n 1)"
        return 0
    fi

    return 1
}

run_static_tests() {
    run_required python3 "$ROOT/drivers/linux/tests/test_smartnic_pci_driver_static.py"
    run_required python3 "$ROOT/drivers/linux/tests/test_smartnic_driver_lifecycle_static.py"
    run_required python3 "$ROOT/docs/tests_driver_docs.py"
}

run_build_checks() {
    run_required make -C "$ROOT/drivers/linux" syntax-check

    if have_linux_headers; then
        run_required make -C "$ROOT/drivers/linux" W=1
    else
        mark_skip "kernel headers not found at $KDIR; module build skipped"
    fi

    if have_linux_uapi_headers; then
        run_required make -C "$ROOT/tools" clean
        run_required make -C "$ROOT/tools"
        run_required make -C "$ROOT/tools" test
        run_required make -C "$ROOT/examples" clean
        run_required make -C "$ROOT/examples"
    else
        mark_skip "Linux UAPI headers not available; userspace/examples build skipped"
    fi
}

run_packaging_checks() {
    run_required test -f "$ROOT/include/uapi/linux/smartnic_ioctl.h"

    local duplicated
    duplicated="$(grep -R "^struct smartnic_ioctl_mbox[[:space:]]*{" \
        "$ROOT" \
        --exclude-dir=.git \
        --exclude='smartnic_ioctl.h' \
        --exclude='uapi.md' \
        --exclude='tests_driver_docs.py' \
        || true)"
    if [[ -n "$duplicated" ]]; then
        log "FAIL: duplicated UAPI definition found"
        printf '%s\n' "$duplicated"
        exit 1
    fi
    mark_pass "no duplicated UAPI definitions"
}

run_module_load_unload_smoke() {
    if ! have_linux_headers; then
        mark_skip "kernel headers missing; load/unload smoke skipped"
        return
    fi

    if [[ ! -f "$ROOT/drivers/linux/smartnic.ko" ]]; then
        mark_skip "smartnic.ko was not produced; load/unload smoke skipped"
        return
    fi

    if [[ "$(id -u)" != "0" ]]; then
        mark_skip "not root; module load/unload smoke skipped"
        return
    fi

    for _cycle in 1 2; do
        run_required insmod "$ROOT/drivers/linux/smartnic.ko"
        run_required rmmod smartnic
    done
}

run_hardware_smoke() {
    if ! detect_device; then
        mark_skip "no /dev/smartnic* device; hardware probe/ioctl/poll/DMA smoke skipped"
        return
    fi

    if [[ ! -x "$SMARTNICCTL" ]]; then
        mark_skip "smartnicctl is not built; hardware CLI smoke skipped"
        return
    fi

    log "hardware device detected: $SMARTNIC_DEV"
    run_required "$SMARTNICCTL" --device "$SMARTNIC_DEV" info
    run_required "$SMARTNICCTL" --device "$SMARTNIC_DEV" reset

    if [[ -x "$ROOT/examples/smartnic_ioctl_example" ]]; then
        run_required "$ROOT/examples/smartnic_ioctl_example" "$SMARTNIC_DEV"
    else
        mark_skip "examples not built; DMA ring create/destroy hardware smoke skipped"
    fi

    if [[ -x "$ROOT/examples/smartnic_poll_example" ]]; then
        run_required "$ROOT/examples/smartnic_poll_example" "$SMARTNIC_DEV"
    else
        mark_skip "examples not built; poll/mmap hardware smoke skipped"
    fi

    if command -v dmesg >/dev/null 2>&1; then
        dmesg | tail -n 200 | grep -Ei "WARNING:|BUG:|smartnic.*(warn|error)" || \
            mark_pass "no obvious recent SmartNIC kernel warnings"
    else
        mark_skip "dmesg unavailable; kernel warning scan skipped"
    fi
}

main() {
    log "starting SmartNIC driver integration checks"
    run_static_tests
    run_build_checks
    run_packaging_checks
    run_module_load_unload_smoke
    run_hardware_smoke
    log "complete: pass=$pass skip=$skip"
}

main "$@"
