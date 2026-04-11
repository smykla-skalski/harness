#!/usr/bin/env bash
set -euo pipefail
unalias -a 2>/dev/null || true

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

first_nonempty_env() {
  local var_name value
  for var_name in "$@"; do
    value="${!var_name:-}"
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  done
  return 1
}

sanitize_segment() {
  printf '%s' "$1" | tr -cs '[:alnum:]._-' '-'
}

detect_cpu_count() {
  local count=""

  if command -v getconf >/dev/null 2>&1; then
    count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  fi

  if [[ -z "$count" ]] && command -v sysctl >/dev/null 2>&1; then
    count="$(sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || true)"
  fi

  if [[ -z "$count" ]] && command -v nproc >/dev/null 2>&1; then
    count="$(nproc 2>/dev/null || true)"
  fi

  if [[ ! "$count" =~ ^[0-9]+$ ]] || (( count < 1 )); then
    count=4
  fi

  printf '%s\n' "$count"
}

default_jobs() {
  local cpu_count
  cpu_count="$(detect_cpu_count)"

  # Agent sessions need a lower cap so parallel workers do not drown the host.
  if [[ -n "$session_id" ]]; then
    if (( cpu_count <= 4 )); then
      printf '1\n'
    elif (( cpu_count <= 8 )); then
      printf '2\n'
    elif (( cpu_count <= 12 )); then
      printf '3\n'
    else
      printf '4\n'
    fi
  else
    # Keep the machine responsive by default instead of saturating all cores.
    if (( cpu_count <= 4 )); then
      printf '2\n'
    elif (( cpu_count <= 8 )); then
      printf '3\n'
    elif (( cpu_count <= 12 )); then
      printf '4\n'
    else
      printf '6\n'
    fi
  fi
}

session_id="$(first_nonempty_env \
  CODEX_SESSION_ID \
  CODEX_THREAD_ID \
  CLAUDE_SESSION_ID \
  GEMINI_SESSION_ID \
  COPILOT_SESSION_ID \
  OPENCODE_SESSION_ID || true)"

target_segment="local"
if [[ -n "$session_id" ]]; then
  target_segment="agent-$(sanitize_segment "$session_id")"
fi

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-${HARNESS_CARGO_TARGET_DIR:-$ROOT/target/dev/$target_segment}}"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-${HARNESS_CARGO_JOBS:-$(default_jobs)}}"

if [[ -z "${RUSTC_WRAPPER:-}" ]] && command -v sccache >/dev/null 2>&1; then
  export RUSTC_WRAPPER
  RUSTC_WRAPPER="$(command -v sccache)"
fi

if [[ "${1:-}" == "--print-env" ]]; then
  printf 'CARGO_TARGET_DIR=%s\n' "$CARGO_TARGET_DIR"
  printf 'CARGO_BUILD_JOBS=%s\n' "$CARGO_BUILD_JOBS"
  if [[ -n "$session_id" ]]; then
    printf 'SESSION_MODE=agent\n'
  else
    printf 'SESSION_MODE=local\n'
  fi
  printf 'RUSTC_WRAPPER=%s\n' "${RUSTC_WRAPPER:-}"
  if [[ -n "${RUSTC_WRAPPER:-}" ]]; then
    printf 'CACHE_MODE=sccache\n'
  else
    printf 'CACHE_MODE=none\n'
  fi
  printf 'SESSION_ID=%s\n' "${session_id:-}"
  exit 0
fi

exec cargo "$@"
