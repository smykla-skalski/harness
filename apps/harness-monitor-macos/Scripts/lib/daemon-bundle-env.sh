#!/bin/bash

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
  printf '%s/target/harness-monitor-xcode-daemon\n' "$repo_root"
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

  default_cargo_target_dir
}
