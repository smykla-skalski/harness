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
  if [[ -n "${HARNESS_MONITOR_E2E_TOOL_BINARY:-}" ]]; then
    printf '%s\n' "$HARNESS_MONITOR_E2E_TOOL_BINARY"
    return 0
  fi
  local release_path="$repo_root/apps/harness-monitor-macos/Tools/HarnessMonitorE2E/.build/release/harness-monitor-e2e"
  local debug_path="$repo_root/apps/harness-monitor-macos/Tools/HarnessMonitorE2E/.build/debug/harness-monitor-e2e"
  if [[ -x "$release_path" ]]; then
    printf '%s\n' "$release_path"
    return 0
  fi
  if [[ -x "$debug_path" ]]; then
    printf '%s\n' "$debug_path"
    return 0
  fi
  printf 'error: harness-monitor-e2e binary missing; build via mise run monitor:macos:tools:build:e2e\n' >&2
  return 1
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
