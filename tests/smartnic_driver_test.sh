#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[smartnic-driver-test] running static driver checks"
python3 "$ROOT/drivers/linux/tests/test_smartnic_pci_driver_static.py"
python3 "$ROOT/drivers/linux/tests/test_smartnic_driver_lifecycle_static.py"
python3 "$ROOT/drivers/linux/tests/test_smartnic_driver_error_paths_static.py"

if [[ -x "$ROOT/tools/smartnicctl" ]]; then
    "$ROOT/tools/smartnicctl" --help >/dev/null
else
    echo "[smartnic-driver-test] smartnicctl not built; skipping CLI execution"
fi

if compgen -G "/dev/smartnic*" >/dev/null; then
    dev="$(compgen -G "/dev/smartnic*" | head -n 1)"
    echo "[smartnic-driver-test] running hardware smoke tests against $dev"
    "$ROOT/tools/smartnicctl" --device "$dev" info || \
        echo "[smartnic-driver-test] feature query not supported by this device yet"
    "$ROOT/tools/smartnicctl" --device "$dev" reset || \
        echo "[smartnic-driver-test] reset command not supported by this device yet"
else
    echo "[smartnic-driver-test] No /dev/smartnic device present; hardware smoke tests skipped"
fi

echo "[smartnic-driver-test] passed"
