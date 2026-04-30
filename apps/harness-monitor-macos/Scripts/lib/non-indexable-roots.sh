#!/bin/bash

HARNESS_MONITOR_NON_INDEXABLE_MARKER_NAME=".metadata_never_index"

ensure_non_indexable_directory() {
  local root="$1"
  local marker="$root/$HARNESS_MONITOR_NON_INDEXABLE_MARKER_NAME"

  /bin/mkdir -p "$root"
  if [[ ! -e "$marker" ]]; then
    : > "$marker"
  fi
}

ensure_monitor_build_artifact_roots_non_indexable() {
  local repo_root="$1"

  ensure_non_indexable_directory "$repo_root/xcode-derived"
  ensure_non_indexable_directory "$repo_root/xcode-derived-e2e"
  ensure_non_indexable_directory "$repo_root/xcode-derived-instruments"
}
