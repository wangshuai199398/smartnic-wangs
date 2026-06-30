#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# RDMA/RoCE verification regression runner.
#
# This script orchestrates existing project commands only. It does not add new
# coverage bins, module tests, integration flows, or protocol tests; those are
# owned by tasks 14.5 through 14.8.

set -u
set -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_OUT_DIR="${ROOT_DIR}/build/rdma-regression/$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${RDMA_REGRESSION_OUT:-${DEFAULT_OUT_DIR}}"
SIMULATOR="${SIM:-verilator}"
MODE="smoke"
REQUESTED_GROUPS=()

usage() {
    cat <<'USAGE'
Usage: tests/run_rdma_regression.sh [--mode smoke|full] [--out DIR] [--sim SIM] [group...]

Groups:
  lint          Run lint/format-style checks available in this tree.
  unit          Run reusable BFM/model/scoreboard/coverage unit tests.
  module        Run 14.6 module-level Cocotb/BFM tests.
  integration   Run 14.7 RDMA/RoCE integration tests.
  protocol      Run 14.8 protocol compliance tests.
  compatibility Run available driver/userspace compatibility smoke checks.
  perf          Run optional simulation performance counter smoke checks.
  coverage      Generate a lightweight coverage summary from existing coverage tests.
  smoke         Run lint, unit, integration, protocol, and coverage.
  full          Run lint, unit, module, integration, protocol, compatibility, and coverage.

Options:
  --mode MODE   Select smoke or full group expansion. Default: smoke.
  --out DIR     Directory for logs and summary files.
  --sim SIM     Simulator name exported as SIM for Make/Cocotb targets.
  --help        Show this help.

Environment:
  RDMA_REGRESSION_OUT  Override output directory.
  RDMA_REGRESSION_ENABLE_PERF=1
                       Add perf counters to smoke/full group expansion.
  SIM                  Default simulator when --sim is not provided.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --mode)
            MODE="$2"
            shift 2
            ;;
        --out)
            OUT_DIR="$2"
            shift 2
            ;;
        --sim)
            SIMULATOR="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        smoke|full|lint|unit|module|integration|protocol|compatibility|perf|coverage)
            REQUESTED_GROUPS+=("$1")
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

mkdir -p "${OUT_DIR}/logs"
SUMMARY_FILE="${OUT_DIR}/summary.txt"
COVERAGE_FILE="${OUT_DIR}/coverage.txt"
: >"${SUMMARY_FILE}"

PASSED=0
FAILED=0
SKIPPED=0
RESULT_NAMES=()
RESULT_STATUS=()
RESULT_LOGS=()

slugify() {
    printf '%s' "$1" | tr ' /:' '---' | tr -cd '[:alnum:]_.-'
}

record_result() {
    RESULT_NAMES+=("$1")
    RESULT_STATUS+=("$2")
    RESULT_LOGS+=("$3")
    case "$2" in
        PASS) PASSED=$((PASSED + 1)) ;;
        FAIL) FAILED=$((FAILED + 1)) ;;
        SKIP) SKIPPED=$((SKIPPED + 1)) ;;
    esac
}

run_step() {
    local name="$1"
    shift
    local log="${OUT_DIR}/logs/$(slugify "${name}").log"
    echo "[RUN ] ${name}"
    echo "\$ $*" >"${log}"
    if (cd "${ROOT_DIR}" && SIM="${SIMULATOR}" "$@") >>"${log}" 2>&1; then
        echo "[PASS] ${name}"
        record_result "${name}" "PASS" "${log}"
    else
        local rc=$?
        echo "[FAIL] ${name} (rc=${rc})"
        record_result "${name}" "FAIL" "${log}"
    fi
}

skip_step() {
    local name="$1"
    local reason="$2"
    local log="${OUT_DIR}/logs/$(slugify "${name}").log"
    echo "[SKIP] ${name}: ${reason}"
    printf 'SKIP: %s\n' "${reason}" >"${log}"
    record_result "${name}" "SKIP" "${log}"
}

have_file() {
    [ -e "${ROOT_DIR}/$1" ]
}

expand_groups() {
    local group
    local expanded=()
    if [ "${#REQUESTED_GROUPS[@]}" -eq 0 ]; then
        REQUESTED_GROUPS=("${MODE}")
    fi
    for group in "${REQUESTED_GROUPS[@]}"; do
        case "${group}" in
            smoke)
                expanded+=(lint unit integration protocol coverage)
                if [ "${RDMA_REGRESSION_ENABLE_PERF:-0}" = "1" ]; then
                    expanded+=(perf)
                fi
                ;;
            full)
                expanded+=(lint unit module integration protocol compatibility coverage)
                if [ "${RDMA_REGRESSION_ENABLE_PERF:-0}" = "1" ]; then
                    expanded+=(perf)
                fi
                ;;
            *)
                expanded+=("${group}")
                ;;
        esac
    done
    printf '%s\n' "${expanded[@]}"
}

run_lint_group() {
    run_step "lint: make lint" make lint
    if command -v git >/dev/null 2>&1; then
        run_step "lint: git diff --check" git diff --check
    else
        skip_step "lint: git diff --check" "git is not available"
    fi
}

run_unit_group() {
    run_step "unit: PCIe BFM" make -C sim/cocotb test-pcie-bfm
    run_step "unit: host memory model" make -C sim/cocotb test-host-memory-model
    run_step "unit: RDMA scoreboard" make -C sim/cocotb test-rdma-scoreboard
    run_step "unit: RDMA coverage" make -C sim/cocotb test-rdma-coverage
    run_step "unit: Ethernet RoCE BFM" make -C sim/cocotb test-roce-ethernet-bfm
}

run_module_group() {
    run_step "module: stage 14.6 module-level tests" make -C sim/cocotb module-level-tests
}

run_integration_group() {
    run_step "integration: stage 14.7 RDMA/RoCE tests" make -C sim/cocotb rdma-integration-tests
}

run_protocol_group() {
    run_step "protocol: stage 14.8 compliance tests" make -C sim/cocotb protocol-compliance-tests
}

run_compatibility_group() {
    if have_file "tests/run_driver_integration.sh"; then
        run_step "compatibility: driver integration smoke" bash tests/run_driver_integration.sh
    else
        skip_step "compatibility: driver integration smoke" "tests/run_driver_integration.sh not found"
    fi

    if have_file "tools/tests/test_smartnicctl.py"; then
        run_step "compatibility: smartnicctl userspace tests" python3 tools/tests/test_smartnicctl.py
    else
        skip_step "compatibility: smartnicctl userspace tests" "tools/tests/test_smartnicctl.py not found"
    fi

    if have_file "lib/libsmartnic/tests/test_smartnic_provider_static.py"; then
        run_step "compatibility: provider static tests" python3 lib/libsmartnic/tests/test_smartnic_provider_static.py
    else
        skip_step "compatibility: provider static tests" "provider static test not found"
    fi

    if have_file "tests/run_perftest_compat.sh"; then
        run_step "compatibility: perftest RC smoke" bash tests/run_perftest_compat.sh
    else
        skip_step "compatibility: perftest RC smoke" "tests/run_perftest_compat.sh not found"
    fi

    if have_file "tests/run_ucx_compat.sh"; then
        run_step "compatibility: UCX RC smoke" bash tests/run_ucx_compat.sh
    else
        skip_step "compatibility: UCX RC smoke" "tests/run_ucx_compat.sh not found"
    fi

    if have_file "tests/run_libfabric_compat.sh"; then
        run_step "compatibility: libfabric verbs smoke" bash tests/run_libfabric_compat.sh
    else
        skip_step "compatibility: libfabric verbs smoke" "tests/run_libfabric_compat.sh not found"
    fi
}

run_perf_group() {
    run_step "perf: simulation performance counters" make sim-perf-counters
}

run_coverage_group() {
    run_step "coverage: RDMA functional coverage unit test" make -C sim/cocotb test-rdma-coverage
    {
        echo "RDMA regression coverage report"
        echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Simulator: ${SIMULATOR}"
        echo
        echo "Existing coverage support:"
        echo "- Functional coverage collector: sim/cocotb/bfm/rdma_coverage.py"
        echo "- Coverage unit test: sim/cocotb/test_rdma_coverage.py"
        echo
        echo "Simulator/Python coverage merge:"
        echo "- No project-level simulator coverage merge tool is configured yet."
        echo "- No Python coverage.py configuration is present in this tree."
    } >"${COVERAGE_FILE}"
    echo "[INFO] coverage report: ${COVERAGE_FILE}"
}

SELECTED_GROUPS=()
while IFS= read -r group; do
    [ -n "${group}" ] && SELECTED_GROUPS+=("${group}")
done < <(expand_groups)

echo "RDMA regression output: ${OUT_DIR}"
echo "Simulator: ${SIMULATOR}"
echo "Groups: ${SELECTED_GROUPS[*]}"
echo

for group in "${SELECTED_GROUPS[@]}"; do
    case "${group}" in
        lint) run_lint_group ;;
        unit) run_unit_group ;;
        module) run_module_group ;;
        integration) run_integration_group ;;
        protocol) run_protocol_group ;;
        compatibility) run_compatibility_group ;;
        perf) run_perf_group ;;
        coverage) run_coverage_group ;;
        *) skip_step "${group}" "unknown group" ;;
    esac
done

{
    echo "RDMA regression summary"
    echo "Output: ${OUT_DIR}"
    echo "Simulator: ${SIMULATOR}"
    echo "Passed: ${PASSED}"
    echo "Failed: ${FAILED}"
    echo "Skipped: ${SKIPPED}"
    echo
    printf '%-8s  %-48s  %s\n' "STATUS" "STAGE" "LOG"
    printf '%-8s  %-48s  %s\n' "------" "-----" "---"
    for idx in "${!RESULT_NAMES[@]}"; do
        printf '%-8s  %-48s  %s\n' "${RESULT_STATUS[$idx]}" "${RESULT_NAMES[$idx]}" "${RESULT_LOGS[$idx]}"
    done
    echo
    if [ -f "${COVERAGE_FILE}" ]; then
        echo "Coverage report: ${COVERAGE_FILE}"
    fi
} | tee "${SUMMARY_FILE}"

echo
echo "Summary written to ${SUMMARY_FILE}"

if [ "${FAILED}" -ne 0 ]; then
    exit 1
fi
