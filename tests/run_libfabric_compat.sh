#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# SmartNIC libfabric compatibility smoke runner.
#
# This wrapper validates verbs-backed libfabric discovery and small message/RMA
# smoke tests when libfabric tools are available. It skips cleanly on developer
# machines without libfabric or RDMA hardware unless --force is requested.

set -u
set -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${SMARTNIC_LIBFABRIC_OUT:-${ROOT_DIR}/build/libfabric-compat}"
ROLE="${SMARTNIC_LIBFABRIC_ROLE:-client}"
SERVER_ADDR="${SMARTNIC_LIBFABRIC_SERVER:-}"
PROVIDER="${SMARTNIC_LIBFABRIC_PROVIDER:-verbs}"
DOMAIN="${SMARTNIC_LIBFABRIC_DOMAIN:-}"
FABRIC="${SMARTNIC_LIBFABRIC_FABRIC:-}"
DEVICE="${SMARTNIC_LIBFABRIC_DEVICE:-${FI_VERBS_IFACE:-}}"
SERVICE="${SMARTNIC_LIBFABRIC_SERVICE:-7471}"
MSG_SIZE="${SMARTNIC_LIBFABRIC_SIZE:-64}"
ITERS="${SMARTNIC_LIBFABRIC_ITERS:-100}"
QUEUE_DEPTH="${SMARTNIC_LIBFABRIC_QD:-8}"
TIMEOUT_SEC="${SMARTNIC_LIBFABRIC_TIMEOUT:-20}"
EXTRA_ARGS="${SMARTNIC_LIBFABRIC_EXTRA_ARGS:-}"
OPS="${SMARTNIC_LIBFABRIC_OPS:-send,write,read}"
DRY_RUN=0
FORCE=0

FI_INFO="${SMARTNIC_LIBFABRIC_FI_INFO:-fi_info}"
SEND_TOOL="${SMARTNIC_LIBFABRIC_SEND_TOOL:-fi_pingpong}"
RMA_TOOL="${SMARTNIC_LIBFABRIC_RMA_TOOL:-fi_rma_pingpong}"

usage() {
	cat <<'USAGE'
Usage: tests/run_libfabric_compat.sh [options]

Options:
  --op send|write|read|all   Operation to run. May be repeated. Default: all.
  --role client|server       libfabric test role. Client requires --server.
  --server HOST              Server address for client mode.
  --provider NAME            libfabric provider. Default: verbs.
  --domain NAME              Optional libfabric domain.
  --fabric NAME              Optional libfabric fabric.
  --device NAME              Verbs interface/device hint, exported as FI_VERBS_IFACE.
  --service PORT             Service/port. Default: 7471.
  --size BYTES               Message size. Default: 64.
  --iters N                  Iteration count. Default: 100.
  --queue-depth N            Queue depth / window hint. Default: 8.
  --timeout SEC              Command timeout. Default: 20.
  --out DIR                  Log directory. Default: build/libfabric-compat.
  --extra "ARGS"             Extra fabtests arguments appended to every run.
  --dry-run                  Print commands and do not require tools/devices.
  --force                    Treat missing tools/providers as failures.
  --help                     Show this help.

Environment mirrors the options with SMARTNIC_LIBFABRIC_* variables, for example:
  SMARTNIC_LIBFABRIC_PROVIDER=verbs
  SMARTNIC_LIBFABRIC_DEVICE=smartnic0
  SMARTNIC_LIBFABRIC_SERVER=192.0.2.10
  SMARTNIC_LIBFABRIC_OPS=send,write,read
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
		--provider) PROVIDER="$2"; shift 2 ;;
		--domain) DOMAIN="$2"; shift 2 ;;
		--fabric) FABRIC="$2"; shift 2 ;;
		--device) DEVICE="$2"; shift 2 ;;
		--service) SERVICE="$2"; shift 2 ;;
		--size) MSG_SIZE="$2"; shift 2 ;;
		--iters) ITERS="$2"; shift 2 ;;
		--queue-depth|--qp-depth) QUEUE_DEPTH="$2"; shift 2 ;;
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
	mark_skip "client mode needs SMARTNIC_LIBFABRIC_SERVER or --server"
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
	mark_skip "libfabric command not found: $1"
}

have_timeout() {
	command -v timeout >/dev/null 2>&1
}

run_with_timeout() {
	if have_timeout; then
		timeout "${TIMEOUT_SEC}" "$@"
	else
		"$@"
	fi
}

DISCOVERY_ARGS=()

build_discovery_args() {
	DISCOVERY_ARGS=("-p" "${PROVIDER}")
	[ -n "${DOMAIN}" ] && DISCOVERY_ARGS+=("-d" "${DOMAIN}")
	[ -n "${FABRIC}" ] && DISCOVERY_ARGS+=("-f" "${FABRIC}")
	[ -n "${SERVER_ADDR}" ] && DISCOVERY_ARGS+=("${SERVER_ADDR}")
}

check_provider_available() {
	local log="${OUT_DIR}/fi_info.log"

	if [ "${DRY_RUN}" -eq 1 ]; then
		return 0
	fi
	require_or_skip "${FI_INFO}"
	build_discovery_args
	{
		echo "provider=${PROVIDER}"
		echo "domain=${DOMAIN:-<default>}"
		echo "fabric=${FABRIC:-<default>}"
		echo "FI_VERBS_IFACE=${DEVICE:-<default>}"
		printf 'command: %q' "${FI_INFO}"
		printf ' %q' "${DISCOVERY_ARGS[@]}"
		echo
		echo
	} >"${log}"
	if FI_VERBS_IFACE="${DEVICE}" run_with_timeout "${FI_INFO}" "${DISCOVERY_ARGS[@]}" >>"${log}" 2>&1; then
		return 0
	fi
	if [ "${FORCE}" -eq 1 ]; then
		mark_fail "verbs-backed libfabric provider discovery failed; see ${log}"
	fi
	mark_skip "verbs-backed libfabric provider unavailable; see ${log}"
}

tool_for_op() {
	case "$1" in
		send) printf '%s\n' "${SEND_TOOL}" ;;
		write|read) printf '%s\n' "${RMA_TOOL}" ;;
		*) return 1 ;;
	esac
}

COMMON_ARGS=()

build_common_args() {
	local op="$1"

	COMMON_ARGS=("-p" "${PROVIDER}" "-S" "${MSG_SIZE}" "-I" "${ITERS}")
	[ -n "${DOMAIN}" ] && COMMON_ARGS+=("-d" "${DOMAIN}")
	[ -n "${FABRIC}" ] && COMMON_ARGS+=("-f" "${FABRIC}")
	[ -n "${SERVICE}" ] && COMMON_ARGS+=("-P" "${SERVICE}")
	if [ "${op}" = "write" ] || [ "${op}" = "read" ]; then
		COMMON_ARGS+=("-o" "${op}")
	fi
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
	local tool
	local log

	tool="$(tool_for_op "${op}")" || mark_fail "unsupported operation: ${op}"
	log="${OUT_DIR}/${op}.log"
	if [ "${DRY_RUN}" -eq 0 ]; then
		require_or_skip "${tool}"
	fi
	build_common_args "${op}"

	{
		echo "operation=${op}"
		echo "role=${ROLE}"
		echo "tool=${tool}"
		echo "provider=${PROVIDER}"
		echo "domain=${DOMAIN:-<default>}"
		echo "fabric=${FABRIC:-<default>}"
		echo "FI_VERBS_IFACE=${DEVICE:-<default>}"
		echo "service=${SERVICE}"
		echo "size=${MSG_SIZE}"
		echo "iters=${ITERS}"
		echo "queue_depth=${QUEUE_DEPTH}"
		echo
		printf 'command:'
		[ -n "${DEVICE}" ] && printf ' %q=%q' "FI_VERBS_IFACE" "${DEVICE}"
		printf ' %q' "${tool}"
		printf ' %q' "${COMMON_ARGS[@]}"
		echo
	} >"${log}"

	printf '[libfabric] %s:' "${op}"
	[ -n "${DEVICE}" ] && printf ' FI_VERBS_IFACE=%s' "${DEVICE}"
	printf ' %s' "${tool}"
	printf ' %q' "${COMMON_ARGS[@]}"
	echo

	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "DRY-RUN: ${op}" >>"${log}"
		printf 'PASS dry-run %s\n' "${op}" >>"${SUMMARY}"
		return 0
	fi

	if FI_VERBS_IFACE="${DEVICE}" run_with_timeout "${tool}" "${COMMON_ARGS[@]}" >>"${log}" 2>&1; then
		printf 'PASS %s log=%s\n' "${op}" "${log}" >>"${SUMMARY}"
		return 0
	fi

	printf 'FAIL %s log=%s\n' "${op}" "${log}" >>"${SUMMARY}"
	echo "FAIL: ${op} libfabric command failed; see ${log}" >&2
	return 1
}

check_provider_available

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
			mark_fail "unsupported operation in SMARTNIC_LIBFABRIC_OPS: ${op}"
			;;
	esac
	IFS=','
done
IFS="${OLD_IFS}"

echo "libfabric compatibility summary: ${SUMMARY}"
cat "${SUMMARY}"

if [ "${FAILED}" -ne 0 ]; then
	exit 1
fi
