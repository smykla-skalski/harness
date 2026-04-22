#!/usr/bin/env bash
set -euo pipefail
unalias -a 2>/dev/null || true

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
lease_dir="$ROOT/target/.cargo-local/leases"
lease_path=""
active_build_count=1

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

rtk_supports_cargo_subcommand() {
  case "${1:-}" in
    build|check|clippy|fmt|install|nextest|test)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

tmpdir_is_usable() {
  local candidate probe
  candidate="${1:-}"
  candidate="${candidate%/}"

  if [[ -z "$candidate" ]] || [[ ! -d "$candidate" ]]; then
    return 1
  fi

  probe="$candidate/.harness-tmp-probe-$$"
  if ! touch "$probe" 2>/dev/null; then
    return 1
  fi
  rm -f "$probe"
}

cleanup_stale_leases() {
  local lease_file pid

  mkdir -p "$lease_dir"

  for lease_file in "$lease_dir"/*; do
    if [[ ! -f "$lease_file" ]]; then
      continue
    fi

    pid="$(cat "$lease_file" 2>/dev/null || true)"
    if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$lease_file"
    fi
  done
}

register_build_lease() {
  cleanup_stale_leases
  lease_path="$lease_dir/$(sanitize_segment "${session_id:-local}")-$$"
  printf '%s\n' "$$" >"$lease_path"
  cleanup_stale_leases
  active_build_count="$(find "$lease_dir" -type f | wc -l | tr -d ' ')"
  if [[ ! "$active_build_count" =~ ^[0-9]+$ ]] || (( active_build_count < 1 )); then
    active_build_count=1
  fi
}

release_build_lease() {
  if [[ -n "$lease_path" ]]; then
    rm -f "$lease_path"
  fi
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
  local cpu_count base_jobs
  cpu_count="$(detect_cpu_count)"

  # Agent sessions need a lower cap so parallel workers do not drown the host.
  if [[ -n "$session_id" ]]; then
    if (( cpu_count <= 4 )); then
      base_jobs=1
    elif (( cpu_count <= 8 )); then
      base_jobs=2
    elif (( cpu_count <= 12 )); then
      base_jobs=3
    else
      base_jobs=4
    fi
  else
    # Keep the machine responsive by default instead of saturating all cores.
    if (( cpu_count <= 4 )); then
      base_jobs=2
    elif (( cpu_count <= 8 )); then
      base_jobs=3
    elif (( cpu_count <= 12 )); then
      base_jobs=4
    else
      base_jobs=6
    fi
  fi

  if (( active_build_count > 1 )); then
    base_jobs=$(((base_jobs + active_build_count - 1) / active_build_count))
  fi

  if (( base_jobs < 1 )); then
    base_jobs=1
  fi

  printf '%s\n' "$base_jobs"
}

session_id="$(first_nonempty_env \
  CODEX_SESSION_ID \
  CODEX_THREAD_ID \
  CLAUDE_SESSION_ID \
  GEMINI_SESSION_ID \
  COPILOT_SESSION_ID \
  OPENCODE_SESSION_ID || true)"

register_build_lease
trap release_build_lease EXIT

target_segment="local"
if [[ -n "$session_id" ]]; then
  target_segment="agent-$(sanitize_segment "$session_id")"
fi

if ! tmpdir_is_usable "${TMPDIR:-}"; then
  tmpdir_fallback="$ROOT/target/.cargo-local/tmp/$target_segment"
  mkdir -p "$tmpdir_fallback"
  if ! tmpdir_is_usable "$tmpdir_fallback"; then
    printf 'failed to prepare writable TMPDIR at %s\n' "$tmpdir_fallback" >&2
    exit 1
  fi
  export TMPDIR="$tmpdir_fallback/"
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
  printf 'ACTIVE_BUILD_COUNT=%s\n' "$active_build_count"
  if [[ -n "$session_id" ]]; then
    printf 'SESSION_MODE=agent\n'
  else
    printf 'SESSION_MODE=local\n'
  fi
  printf 'TMPDIR=%s\n' "${TMPDIR:-}"
  printf 'RUSTC_WRAPPER=%s\n' "${RUSTC_WRAPPER:-}"
  if [[ -n "${RUSTC_WRAPPER:-}" ]]; then
    printf 'CACHE_MODE=sccache\n'
  else
    printf 'CACHE_MODE=none\n'
  fi
  printf 'SESSION_ID=%s\n' "${session_id:-}"
  if [[ -n "${HARNESS_CARGO_LEASE_HOLD_SECONDS:-}" ]]; then
    sleep "${HARNESS_CARGO_LEASE_HOLD_SECONDS}"
  fi
  exit 0
fi

if [[ $# -gt 0 ]] && command -v rtk >/dev/null 2>&1 && rtk_supports_cargo_subcommand "$1"; then
  exec rtk cargo "$@"
fi

exec cargo "$@"
