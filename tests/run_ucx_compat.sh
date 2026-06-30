#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# SmartNIC UCX compatibility smoke runner.
#
# This wrapper uses ucx_perftest for small RC-oriented smoke checks. It is not a
# full benchmark suite; missing UCX tools, devices, or server configuration skip
# cleanly unless --force is requested.

set -u
set -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${SMARTNIC_UCX_OUT:-${ROOT_DIR}/build/ucx-compat}"
ROLE="${SMARTNIC_UCX_ROLE:-client}"
SERVER_ADDR="${SMARTNIC_UCX_SERVER:-}"
DEVICE="${SMARTNIC_UCX_DEVICE:-${UCX_NET_DEVICES:-}}"
TLS="${SMARTNIC_UCX_TLS:-${UCX_TLS:-rc,rc_x}}"
GID_INDEX="${SMARTNIC_UCX_GID_INDEX:-${UCX_IB_GID_INDEX:-0}}"
MSG_SIZE="${SMARTNIC_UCX_SIZE:-64}"
ITERS="${SMARTNIC_UCX_ITERS:-100}"
TIMEOUT_SEC="${SMARTNIC_UCX_TIMEOUT:-20}"
EXTRA_ARGS="${SMARTNIC_UCX_EXTRA_ARGS:-}"
OPS="${SMARTNIC_UCX_OPS:-send,write,read}"
UCX_PERFTEST="${SMARTNIC_UCX_PERFTEST:-ucx_perftest}"
DRY_RUN=0
FORCE=0

usage() {
	cat <<'USAGE'
Usage: tests/run_ucx_compat.sh [options]

Options:
  --op send|write|read|all   Operation to run. May be repeated. Default: all.
  --role client|server       UCX perftest role. Client requires --server.
  --server HOST              Server address for client mode.
  --device DEV               UCX_NET_DEVICES value, for example mlx5_0:1.
  --tls LIST                 UCX_TLS value. Default: rc,rc_x.
  --gid-index N              UCX_IB_GID_INDEX. Default: 0.
  --size BYTES               Message size. Default: 64.
  --iters N                  Iteration count. Default: 100.
  --timeout SEC              Command timeout. Default: 20.
  --out DIR                  Log directory. Default: build/ucx-compat.
  --extra "ARGS"             Extra ucx_perftest arguments appended to every run.
  --dry-run                  Print commands and do not require tools/devices.
  --force                    Treat missing tools/configuration as failures.
  --help                     Show this help.

Environment mirrors the options with SMARTNIC_UCX_* variables, for example:
  SMARTNIC_UCX_DEVICE=mlx5_0:1
  SMARTNIC_UCX_SERVER=192.0.2.10
  SMARTNIC_UCX_OPS=send,write,read
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
		--tls) TLS="$2"; shift 2 ;;
		--gid-index) GID_INDEX="$2"; shift 2 ;;
		--size) MSG_SIZE="$2"; shift 2 ;;
		--iters) ITERS="$2"; shift 2 ;;
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
	mark_skip "client mode needs SMARTNIC_UCX_SERVER or --server"
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
	mark_skip "UCX command not found: $1"
}

have_timeout() {
	command -v timeout >/dev/null 2>&1
}

check_ucx_environment() {
	if [ "${DRY_RUN}" -eq 1 ]; then
		return 0
	fi
	require_or_skip "${UCX_PERFTEST}"
	if command -v ucx_info >/dev/null 2>&1; then
		return 0
	fi
	if [ "${FORCE}" -eq 1 ]; then
		mark_fail "ucx_info is not available"
	fi
	echo "WARN: ucx_info is not available; continuing with ucx_perftest only" >&2
}

test_for_op() {
	case "$1" in
		send) printf '%s\n' "tag_bw" ;;
		write) printf '%s\n' "put_bw" ;;
		read) printf '%s\n' "get_bw" ;;
		*) return 1 ;;
	esac
}

COMMON_ARGS=()

build_common_args() {
	local test_name="$1"

	COMMON_ARGS=("-t" "${test_name}" "-n" "${ITERS}" "-s" "${MSG_SIZE}")
	if [ -n "${EXTRA_ARGS}" ]; then
		# shellcheck disable=SC2206
		local extra=( ${EXTRA_ARGS} )
		COMMON_ARGS+=("${extra[@]}")
	fi
	if [ "${ROLE}" = "client" ] && [ -n "${SERVER_ADDR}" ]; then
		COMMON_ARGS+=("${SERVER_ADDR}")
	fi
}

run_op() {
	local op="$1"
	local test_name
	local log

	test_name="$(test_for_op "${op}")" || mark_fail "unsupported operation: ${op}"
	log="${OUT_DIR}/${op}.log"
	build_common_args "${test_name}"

	{
		echo "operation=${op}"
		echo "ucx_test=${test_name}"
		echo "role=${ROLE}"
		echo "tool=${UCX_PERFTEST}"
		echo "UCX_TLS=${TLS}"
		echo "UCX_NET_DEVICES=${DEVICE:-<ucx-default>}"
		echo "UCX_IB_GID_INDEX=${GID_INDEX}"
		echo "size=${MSG_SIZE}"
		echo "iters=${ITERS}"
		echo
		printf 'command:'
		printf ' %q=%q' "UCX_TLS" "${TLS}"
		[ -n "${DEVICE}" ] && printf ' %q=%q' "UCX_NET_DEVICES" "${DEVICE}"
		printf ' %q=%q' "UCX_IB_GID_INDEX" "${GID_INDEX}"
		printf ' %q' "${UCX_PERFTEST}"
		printf ' %q' "${COMMON_ARGS[@]}"
		echo
	} >"${log}"

	printf '[ucx] %s: UCX_TLS=%s' "${op}" "${TLS}"
	[ -n "${DEVICE}" ] && printf ' UCX_NET_DEVICES=%s' "${DEVICE}"
	printf ' UCX_IB_GID_INDEX=%s %s' "${GID_INDEX}" "${UCX_PERFTEST}"
	printf ' %q' "${COMMON_ARGS[@]}"
	echo

	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "DRY-RUN: ${op}" >>"${log}"
		printf 'PASS dry-run %s\n' "${op}" >>"${SUMMARY}"
		return 0
	fi

	if have_timeout; then
		if UCX_TLS="${TLS}" UCX_NET_DEVICES="${DEVICE}" UCX_IB_GID_INDEX="${GID_INDEX}" \
			timeout "${TIMEOUT_SEC}" "${UCX_PERFTEST}" "${COMMON_ARGS[@]}" >>"${log}" 2>&1; then
			printf 'PASS %s log=%s\n' "${op}" "${log}" >>"${SUMMARY}"
			return 0
		fi
	else
		if UCX_TLS="${TLS}" UCX_NET_DEVICES="${DEVICE}" UCX_IB_GID_INDEX="${GID_INDEX}" \
			"${UCX_PERFTEST}" "${COMMON_ARGS[@]}" >>"${log}" 2>&1; then
			printf 'PASS %s log=%s\n' "${op}" "${log}" >>"${SUMMARY}"
			return 0
		fi
	fi

	printf 'FAIL %s log=%s\n' "${op}" "${log}" >>"${SUMMARY}"
	echo "FAIL: ${op} UCX command failed; see ${log}" >&2
	return 1
}

check_ucx_environment

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
			mark_fail "unsupported operation in SMARTNIC_UCX_OPS: ${op}"
			;;
	esac
	IFS=','
done
IFS="${OLD_IFS}"

echo "UCX compatibility summary: ${SUMMARY}"
cat "${SUMMARY}"

if [ "${FAILED}" -ne 0 ]; then
	exit 1
fi
