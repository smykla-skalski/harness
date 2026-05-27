#!/usr/bin/env bash
# Shared helpers for the recording-triage shell wrappers. Sourced, never run.

# shellcheck shell=bash

recording_triage_repo_root() {
  local script_dir
  script_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  CDPATH='' cd -- "$script_dir/../../.." && pwd
}

recording_triage_resolve_binary() {
  local repo_root="$1"
  local helper_lib_dir package_dir

  if [[ -n "${HARNESS_MONITOR_E2E_TOOL_BINARY:-}" ]]; then
    if [[ ! -x "$HARNESS_MONITOR_E2E_TOOL_BINARY" ]]; then
      printf 'error: HARNESS_MONITOR_E2E_TOOL_BINARY is not executable: %s\n' "$HARNESS_MONITOR_E2E_TOOL_BINARY" >&2
      return 1
    fi
    printf '%s\n' "$HARNESS_MONITOR_E2E_TOOL_BINARY"
    return 0
  fi

  helper_lib_dir="$repo_root/apps/harness-monitor/Scripts/lib"
  # shellcheck source=apps/harness-monitor/Scripts/lib/swift-tool-env.sh
  source "$helper_lib_dir/swift-tool-env.sh"
  # shellcheck source=apps/harness-monitor/Scripts/lib/swift-package-freshness.sh
  source "$helper_lib_dir/swift-package-freshness.sh"
  sanitize_xcode_only_swift_environment

  package_dir="$repo_root/apps/harness-monitor/Tools/HarnessMonitorE2E"
  ensure_swift_package_release_binary_fresh "$package_dir" "harness-monitor-e2e"
}

recording_triage_output_dir() {
  local run_dir="$1"
  printf '%s/recording-triage\n' "$run_dir"
}

recording_triage_require_run_dir() {
  local run_dir="$1"
  if [[ -z "$run_dir" || ! -d "$run_dir" ]]; then
    printf 'error: run dir missing: %s\n' "$run_dir" >&2
    return 1
  fi
}
