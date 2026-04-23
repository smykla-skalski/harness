#!/usr/bin/env bash

resolve_common_repo_root() {
  local start_path="${1:-.}"
  local common_git_dir=""

  if common_git_dir="$(git -C "$start_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
    dirname -- "$common_git_dir"
    return 0
  fi

  if [[ -d "$start_path" ]]; then
    printf '%s\n' "${start_path%/}"
    return 0
  fi

  printf '%s\n' "$start_path"
}
