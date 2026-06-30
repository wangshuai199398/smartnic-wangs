#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# SmartNIC perftest compatibility smoke runner.
#
# This is a bring-up wrapper around standard RDMA perftest tools. It intentionally
# keeps the defaults small and skips cleanly when perftest or an RDMA device is
# not available, so generic CI does not require hardware.

set -u
set -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${SMARTNIC_PERFTEST_OUT:-${ROOT_DIR}/build/perftest-compat}"
ROLE="${SMARTNIC_PERFTEST_ROLE:-client}"
SERVER_ADDR="${SMARTNIC_PERFTEST_SERVER:-}"
DEVICE="${SMARTNIC_PERFTEST_DEVICE:-}"
PORT="${SMARTNIC_PERFTEST_PORT:-1}"
GID_INDEX="${SMARTNIC_PERFTEST_GID_INDEX:-0}"
MSG_SIZE="${SMARTNIC_PERFTEST_SIZE:-64}"
ITERS="${SMARTNIC_PERFTEST_ITERS:-100}"
QUEUE_DEPTH="${SMARTNIC_PERFTEST_QD:-8}"
MTU="${SMARTNIC_PERFTEST_MTU:-}"
TIMEOUT_SEC="${SMARTNIC_PERFTEST_TIMEOUT:-20}"
EXTRA_ARGS="${SMARTNIC_PERFTEST_EXTRA_ARGS:-}"
OPS="${SMARTNIC_PERFTEST_OPS:-send,write,read}"
DRY_RUN=0
FORCE=0

SEND_TOOL="${SMARTNIC_PERFTEST_SEND_TOOL:-ib_send_bw}"
WRITE_TOOL="${SMARTNIC_PERFTEST_WRITE_TOOL:-ib_write_bw}"
READ_TOOL="${SMARTNIC_PERFTEST_READ_TOOL:-ib_read_bw}"

usage() {
	cat <<'USAGE'
Usage: tests/run_perftest_compat.sh [options]

Options:
  --op send|write|read|all   Operation to run. May be repeated. Default: all.
  --role client|server       Perftest role. Client requires --server.
  --server HOST              Server address for client mode.
  --device NAME              RDMA device name passed to perftest -d.
  --port N                   RDMA port. Default: 1.
  --gid-index N              GID index. Default: 0.
  --size BYTES               Message size. Default: 64.
  --iters N                  Iteration count. Default: 100.
  --qp-depth N               Queue depth. Default: 8.
  --mtu MTU                  Optional MTU passed through when set.
  --timeout SEC              Command timeout. Default: 20.
  --out DIR                  Log directory. Default: build/perftest-compat.
  --extra "ARGS"             Extra perftest arguments appended to every run.
  --dry-run                  Print commands and do not require tools/devices.
  --force                    Treat missing tools/devices as failures, not skips.
  --help                     Show this help.

Environment mirrors the options with SMARTNIC_PERFTEST_* variables, for example:
  SMARTNIC_PERFTEST_DEVICE=smartnic0
  SMARTNIC_PERFTEST_SERVER=192.0.2.10
  SMARTNIC_PERFTEST_OPS=send,write,read
USAGE
}

mark_skip() {
	echo "SKIP: $*"
	exit 0
}

mark_fail() {
	echo "FAIL: $*" >&2
	exit 1
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--op)
			case "$2" in
				all) OPS="send,write,read" ;;
				send|write|read)
					if [ "${OPS}" = "send,write,read" ]; then
						OPS="$2"
					else
						OPS="${OPS},$2"
					fi
					;;
				*) mark_fail "unsupported operation: $2" ;;
			esac
			shift 2
			;;
		--role) ROLE="$2"; shift 2 ;;
		--server) SERVER_ADDR="$2"; shift 2 ;;
		--device) DEVICE="$2"; shift 2 ;;
		--port) PORT="$2"; shift 2 ;;
		--gid-index) GID_INDEX="$2"; shift 2 ;;
		--size) MSG_SIZE="$2"; shift 2 ;;
		--iters) ITERS="$2"; shift 2 ;;
		--qp-depth) QUEUE_DEPTH="$2"; shift 2 ;;
		--mtu) MTU="$2"; shift 2 ;;
		--timeout) TIMEOUT_SEC="$2"; shift 2 ;;
		--out) OUT_DIR="$2"; shift 2 ;;
		--extra) EXTRA_ARGS="$2"; shift 2 ;;
		--dry-run) DRY_RUN=1; shift ;;
		--force) FORCE=1; shift ;;
		--help|-h) usage; exit 0 ;;
		*) mark_fail "unknown argument: $1" ;;
	esac
done

case "${ROLE}" in
	client|server) ;;
	*) mark_fail "role must be client or server" ;;
esac

if [ "${ROLE}" = "client" ] && [ -z "${SERVER_ADDR}" ] && [ "${DRY_RUN}" -eq 0 ]; then
	mark_skip "client mode needs SMARTNIC_PERFTEST_SERVER or --server"
fi

mkdir -p "${OUT_DIR}"
SUMMARY="${OUT_DIR}/summary.txt"
: >"${SUMMARY}"

require_or_skip() {
	if command -v "$1" >/dev/null 2>&1; then
		return 0
	fi
	if [ "${FORCE}" -eq 1 ]; then
		mark_fail "required command not found: $1"
	fi
	mark_skip "perftest command not found: $1"
}

have_timeout() {
	command -v timeout >/dev/null 2>&1
}

check_device_available() {
	if [ "${DRY_RUN}" -eq 1 ]; then
		return 0
	fi
	if ! command -v ibv_devices >/dev/null 2>&1; then
		if [ "${FORCE}" -eq 1 ]; then
			mark_fail "ibv_devices is not available"
		fi
		mark_skip "ibv_devices is not available; RDMA device discovery skipped"
	fi
	if [ -z "${DEVICE}" ]; then
		if ibv_devices 2>/dev/null | awk 'NR > 2 && $1 !~ /^-+/ { found = 1 } END { exit found ? 0 : 1 }'; then
			return 0
		fi
		if [ "${FORCE}" -eq 1 ]; then
			mark_fail "no RDMA devices reported by ibv_devices"
		fi
		mark_skip "no RDMA devices reported by ibv_devices"
	fi
	if ibv_devices 2>/dev/null | awk -v dev="${DEVICE}" '$1 == dev { found = 1 } END { exit found ? 0 : 1 }'; then
		return 0
	fi
	if [ "${FORCE}" -eq 1 ]; then
		mark_fail "RDMA device not found: ${DEVICE}"
	fi
	mark_skip "RDMA device not found: ${DEVICE}"
}

COMMON_ARGS=()

build_common_args() {
	COMMON_ARGS=()
	[ -n "${DEVICE}" ] && COMMON_ARGS+=("-d" "${DEVICE}")
	COMMON_ARGS+=("-i" "${PORT}")
	COMMON_ARGS+=("-x" "${GID_INDEX}")
	COMMON_ARGS+=("-s" "${MSG_SIZE}")
	COMMON_ARGS+=("-n" "${ITERS}")
	COMMON_ARGS+=("-q" "${QUEUE_DEPTH}")
	[ -n "${MTU}" ] && COMMON_ARGS+=("-m" "${MTU}")
	if [ -n "${EXTRA_ARGS}" ]; then
		# shellcheck disable=SC2206
		local extra=( ${EXTRA_ARGS} )
		COMMON_ARGS+=("${extra[@]}")
	fi
	if [ "${ROLE}" = "client" ] && [ -n "${SERVER_ADDR}" ]; then
		COMMON_ARGS+=("${SERVER_ADDR}")
	fi
}

tool_for_op() {
	case "$1" in
		send) printf '%s\n' "${SEND_TOOL}" ;;
		write) printf '%s\n' "${WRITE_TOOL}" ;;
		read) printf '%s\n' "${READ_TOOL}" ;;
		*) return 1 ;;
	esac
}

run_op() {
	local op="$1"
	local tool
	local log

	tool="$(tool_for_op "${op}")" || mark_fail "unsupported operation: ${op}"
	log="${OUT_DIR}/${op}.log"
	if [ "${DRY_RUN}" -eq 0 ]; then
		require_or_skip "${tool}"
	fi
	build_common_args

	{
		echo "operation=${op}"
		echo "role=${ROLE}"
		echo "tool=${tool}"
		echo "device=${DEVICE:-<default>}"
		echo "port=${PORT}"
		echo "gid_index=${GID_INDEX}"
		echo "size=${MSG_SIZE}"
		echo "iters=${ITERS}"
		echo "queue_depth=${QUEUE_DEPTH}"
		echo "mtu=${MTU:-<default>}"
		echo
		printf 'command: %q' "${tool}"
		printf ' %q' "${COMMON_ARGS[@]}"
		echo
	} >"${log}"

	printf '[perftest] %s: %s' "${op}" "${tool}"
	printf ' %q' "${COMMON_ARGS[@]}"
	echo

	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "DRY-RUN: ${op}" >>"${log}"
		printf 'PASS dry-run %s\n' "${op}" >>"${SUMMARY}"
		return 0
	fi

	if have_timeout; then
		if timeout "${TIMEOUT_SEC}" "${tool}" "${COMMON_ARGS[@]}" >>"${log}" 2>&1; then
			printf 'PASS %s log=%s\n' "${op}" "${log}" >>"${SUMMARY}"
			return 0
		fi
	else
		if "${tool}" "${COMMON_ARGS[@]}" >>"${log}" 2>&1; then
			printf 'PASS %s log=%s\n' "${op}" "${log}" >>"${SUMMARY}"
			return 0
		fi
	fi

	printf 'FAIL %s log=%s\n' "${op}" "${log}" >>"${SUMMARY}"
	echo "FAIL: ${op} perftest command failed; see ${log}" >&2
	return 1
}

check_device_available

FAILED=0
OLD_IFS="${IFS}"
IFS=','
for op in ${OPS}; do
	IFS="${OLD_IFS}"
	case "${op}" in
		send|write|read)
			run_op "${op}" || FAILED=1
			;;
		"")
			;;
		*)
			mark_fail "unsupported operation in SMARTNIC_PERFTEST_OPS: ${op}"
			;;
	esac
	IFS=','
done
IFS="${OLD_IFS}"

echo "perftest compatibility summary: ${SUMMARY}"
cat "${SUMMARY}"

if [ "${FAILED}" -ne 0 ]; then
	exit 1
fi
