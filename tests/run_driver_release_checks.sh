#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KDIR="${KDIR:-/lib/modules/$(uname -r)/build}"

pass=0
skip=0

log() {
    printf '[smartnic-driver-release] %s\n' "$*"
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

run_optional_tool() {
    local tool="$1"
    shift

    if command -v "$tool" >/dev/null 2>&1; then
        run_required "$tool" "$@"
    else
        mark_skip "$tool unavailable"
    fi
}

run_clean_rebuild() {
    run_required make -C "$ROOT/drivers/linux" clean
    run_required make -C "$ROOT/drivers/linux" static-check

    if have_linux_headers; then
        run_required make -C "$ROOT/drivers/linux" W=1
        run_required make -C "$ROOT/drivers/linux" sparse-check
        run_required make -C "$ROOT/drivers/linux" checkpatch
    else
        mark_skip "kernel headers not found at $KDIR; Kbuild/W=1/sparse/checkpatch skipped"
    fi
}

run_consistency_checks() {
    run_required python3 "$ROOT/docs/tests_driver_docs.py"
    run_required python3 "$ROOT/drivers/linux/tests/test_smartnic_pci_driver_static.py"
    run_required python3 "$ROOT/drivers/linux/tests/test_smartnic_driver_lifecycle_static.py"
    run_required python3 "$ROOT/drivers/linux/tests/test_smartnic_driver_error_paths_static.py"
    run_required bash "$ROOT/tests/run_driver_integration.sh"
}

run_source_hygiene_checks() {
    run_required test -f "$ROOT/drivers/linux/Kconfig"
    run_required test -f "$ROOT/docs/linux-driver-guide.md"
    run_required test -f "$ROOT/docs/driver-release-checklist.md"

    if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        run_required git -C "$ROOT" diff --check
    else
        mark_skip "not a git checkout; diff whitespace check skipped"
    fi

    # Keep this advisory: the prototype still has intentional TODOs in RTL.
    local debug_hits
    debug_hits="$(grep -R "temporary debug\\|HACK\\|FIXME" "$ROOT/drivers/linux" \
        --exclude-dir=.git || true)"
    if [[ -n "$debug_hits" ]]; then
        log "FAIL: unguarded temporary debug marker found"
        printf '%s\n' "$debug_hits"
        exit 1
    fi
    mark_pass "no unguarded temporary debug markers in driver"
}

run_static_tools_if_available() {
    run_optional_tool shellcheck "$ROOT/tests/run_driver_integration.sh" "$ROOT/tests/run_driver_release_checks.sh"
}

main() {
    log "starting Linux SmartNIC driver release-readiness checks"
    run_clean_rebuild
    run_consistency_checks
    run_source_hygiene_checks
    run_static_tools_if_available
    log "complete: pass=$pass skip=$skip"
}

main "$@"
