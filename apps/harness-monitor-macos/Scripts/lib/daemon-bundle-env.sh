#!/bin/bash

COMMON_REPO_ROOT_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../../scripts/lib" && pwd)"
# shellcheck source=scripts/lib/common-repo-root.sh
source "$COMMON_REPO_ROOT_LIB_DIR/common-repo-root.sh"

resolve_repo_root() {
  local candidate="${PROJECT_DIR:-}"
  while [ -n "$candidate" ] && [ "$candidate" != "/" ]; do
    # Git worktrees expose `.git` as a file, not a directory.
    if [ -e "$candidate/.git" ]; then
      printf '%s\n' "$candidate"
      return
    fi
    candidate="$(dirname "$candidate")"
  done
  printf '%s\n' "${PROJECT_DIR:-.}"
}

default_cargo_target_dir() {
  local resolved_repo_root="${1:-${repo_root:-$(resolve_repo_root)}}"
  local common_repo_root
  common_repo_root="$(resolve_common_repo_root "$resolved_repo_root")"
  # Keep the shared daemon cargo cache out of target/ because raw Xcode builds
  # surface spurious SWIFT_DEBUG_INFORMATION_* warnings for that location.
  printf '%s/tmp/harness-monitor-xcode-daemon\n' "$common_repo_root"
}

resolve_cargo_target_dir() {
  if [ -n "${HARNESS_MONITOR_DAEMON_CARGO_TARGET_DIR:-}" ]; then
    printf '%s\n' "$HARNESS_MONITOR_DAEMON_CARGO_TARGET_DIR"
    return
  fi

  if [ -n "${CARGO_TARGET_DIR:-}" ]; then
    printf '%s\n' "$CARGO_TARGET_DIR"
    return
  fi

  default_cargo_target_dir "${repo_root:-}"
}
