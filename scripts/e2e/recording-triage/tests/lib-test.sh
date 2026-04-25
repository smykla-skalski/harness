#!/usr/bin/env bash
# Shared helpers for recording-triage shell tests. Sourced, never run directly.

# shellcheck shell=bash

recording_triage_test_repo_root() {
  local script_dir
  script_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  CDPATH='' cd -- "$script_dir/../../../.." && pwd
}

recording_triage_test_skip_unless_ffmpeg() {
  if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
    printf 'skipping: ffmpeg/ffprobe unavailable\n'
    exit 0
  fi
}

recording_triage_test_skip_unless_binary() {
  local repo_root="$1"
  local debug_path="$repo_root/apps/harness-monitor-macos/Tools/HarnessMonitorE2E/.build/debug/harness-monitor-e2e"
  local release_path="$repo_root/apps/harness-monitor-macos/Tools/HarnessMonitorE2E/.build/release/harness-monitor-e2e"
  # Prefer the freshly-compiled debug binary so tests always exercise the
  # current source instead of a stale release artefact left over from a prior
  # mise run monitor:macos:tools:build:e2e invocation.
  if [[ -x "$debug_path" ]]; then
    export HARNESS_MONITOR_E2E_TOOL_BINARY="$debug_path"
    return 0
  fi
  if [[ -x "$release_path" ]]; then
    export HARNESS_MONITOR_E2E_TOOL_BINARY="$release_path"
    return 0
  fi
  printf 'skipping: harness-monitor-e2e binary missing; run mise run monitor:macos:tools:build:e2e\n'
  exit 0
}

recording_triage_test_make_run_dir() {
  local prefix="$1"
  mktemp -d -t "recording-triage-${prefix}.XXXXXX"
}

recording_triage_test_seed_run() {
  local run_dir="$1"
  local recording_source="$2"
  mkdir -p "$run_dir/logs" "$run_dir/ui-snapshots"
  cp "$recording_source" "$run_dir/swarm-full-flow.mov"
}
