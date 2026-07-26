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

resolve_repo_cache_root() {
  local resolved_repo_root="${1:-${repo_root:-$(resolve_repo_root)}}"
  local cache_root="$resolved_repo_root/.cache"

  if [ -L "$cache_root" ]; then
    local link_target
    link_target="$(readlink "$cache_root")"
    case "$link_target" in
      *".spotlight-build-artifacts.noindex"*)
        /bin/rm -f "$cache_root"
        ;;
      *)
        if [ "${link_target#/}" = "$link_target" ]; then
          cache_root="$(dirname "$cache_root")/$link_target"
        else
          cache_root="$link_target"
        fi
        ;;
    esac
  fi

  /bin/mkdir -p "$cache_root"
  printf '%s\n' "$cache_root"
}

default_cargo_target_dir() {
  local resolved_repo_root="${1:-${repo_root:-$(resolve_repo_root)}}"
  local common_repo_root
  common_repo_root="$(resolve_common_repo_root "$resolved_repo_root")"
  local cache_root
  cache_root="$(resolve_repo_cache_root "$common_repo_root")"
  # Keep the shared daemon cargo cache out of target/ because raw Xcode builds
  # surface spurious SWIFT_DEBUG_INFORMATION_* warnings for that location.
  # Also avoid repo tmp/ so IDE indexing does not traverse Rust build outputs.
  printf '%s/harness-monitor-xcode-daemon\n' "$cache_root"
}

# `build-for-testing` copies the app-hosted test bundle into the host app's
# PlugIns before the host app's own build phases run, and leaves it an empty
# skeleton until the test target itself builds. codesign walks every embedded
# bundle, so sealing the app while one is a skeleton fails the whole build with
# "bundle format unrecognized, invalid, or unsuitable". Names the first such
# plug-in, or returns 1 when every one of them is complete.
first_unsealable_plugin() {
  local app_bundle="$1"
  local plugin
  for plugin in "$app_bundle"/Contents/PlugIns/*/; do
    [ -d "$plugin" ] || continue
    if [ ! -f "${plugin}Contents/Info.plist" ]; then
      printf '%s\n' "$(/usr/bin/basename "${plugin%/}")"
      return 0
    fi
  done
  return 1
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
