#!/usr/bin/env bash
set -euo pipefail
unalias -a 2>/dev/null || true

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=scripts/lib/release-set.sh
source "$ROOT/scripts/lib/release-set.sh"
if (( $# > 0 )); then
  selectors=("$@")
else
  selectors=(all)
fi

if ! release_set_resolve_selectors "${selectors[@]}"; then
  printf 'usage: %s [<selector>...]\n' "${0##*/}" >&2
  printf 'selector: all, harness, aff, or a leaf (harness-cli, daemon, systemd, bridge, mcp, hook, codex, openrouter)\n' >&2
  exit 2
fi

resolve_target_dir() {
  if [[ -n "${CARGO_TARGET_DIR:-}" ]]; then
    printf '%s\n' "$CARGO_TARGET_DIR"
    return 0
  fi

  "$ROOT/scripts/cargo-local.sh" --print-env \
    | command awk -F= '/^CARGO_TARGET_DIR=/{print $2}'
}

cleanup_on_exit() {
  local status=$?
  trap - EXIT INT TERM
  set +e
  release_pipeline_lock_release
  exit "$status"
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$ROOT"
target_dir="$(resolve_target_dir)"
if [[ -z "$target_dir" ]]; then
  printf 'failed to resolve CARGO_TARGET_DIR\n' >&2
  exit 1
fi
target_dir="$(release_normalize_target_dir "$target_dir")"
export CARGO_TARGET_DIR="$target_dir"
release_pipeline_lock_acquire "$target_dir"

"$ROOT/scripts/cargo-local.sh" --with-group-lease \
  "$ROOT/scripts/build-release-set.sh" "${selectors[@]}"
"$ROOT/scripts/install-release-set.sh" "${selectors[@]}"
