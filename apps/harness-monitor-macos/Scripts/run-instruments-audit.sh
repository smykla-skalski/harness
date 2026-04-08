#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
APP_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$APP_ROOT/../.." && pwd)"
PROJECT_PATH="$APP_ROOT/HarnessMonitor.xcodeproj"
DERIVED_DATA_PATH="$REPO_ROOT/tmp/xcode-derived"
RUNS_ROOT="$REPO_ROOT/tmp/perf/harness-monitor-instruments/runs"
SHIPPING_SCHEME="HarnessMonitor"
HOST_SCHEME="HarnessMonitorUITestHost"
HOST_BUNDLE_ID="io.harnessmonitor.app.ui-testing"
HOST_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/Harness Monitor UI Testing.app"
HOST_BINARY_PATH="$HOST_APP_PATH/Contents/MacOS/Harness Monitor UI Testing"
SHIPPING_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/Harness Monitor.app"
UI_TESTS_ENV="HARNESS_MONITOR_UI_TESTS=1"
KEEP_ANIMATIONS_ENV="HARNESS_MONITOR_KEEP_ANIMATIONS=1"
LAUNCH_MODE_ENV="HARNESS_MONITOR_LAUNCH_MODE=preview"
WINDOW_WIDTH_ENV="HARNESS_MONITOR_UI_MAIN_WINDOW_WIDTH=1640"
WINDOW_HEIGHT_ENV="HARNESS_MONITOR_UI_MAIN_WINDOW_HEIGHT=980"
HIDE_DOCK_ENV="HARNESS_MONITOR_PERF_HIDE_DOCK_ICON=1"
PERSISTENCE_ARG_ONE="-ApplePersistenceIgnoreState"
PERSISTENCE_ARG_TWO="YES"

ALL_SCENARIOS=(
  "launch-dashboard"
  "select-session-cockpit"
  "refresh-and-search"
  "sidebar-overflow-search"
  "settings-backdrop-cycle"
  "settings-background-cycle"
  "timeline-burst"
  "offline-cached-open"
)
SWIFTUI_SCENARIOS=(
  "launch-dashboard"
  "select-session-cockpit"
  "refresh-and-search"
  "sidebar-overflow-search"
  "timeline-burst"
  "offline-cached-open"
)
ALLOCATIONS_SCENARIOS=(
  "settings-backdrop-cycle"
  "settings-background-cycle"
  "offline-cached-open"
)

usage() {
  cat <<'EOF'
Usage:
  run-instruments-audit.sh --label <name> [--compare-to <run-dir-or-summary.json>] [--scenarios all|comma,list] [--discard-traces]

Options:
  --label <name>         Required run label.
  --compare-to <path>    Optional baseline run directory or summary.json.
  --scenarios <value>    Scenario selection. Default: all
  --keep-traces          Keep raw .trace bundles. Default behavior.
  --discard-traces       Delete raw .trace bundles after export and summary generation.
EOF
}

contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

preview_scenario_for() {
  case "$1" in
    launch-dashboard|select-session-cockpit)
      printf '%s\n' "dashboard-landing"
      ;;
    settings-backdrop-cycle|settings-background-cycle)
      printf '%s\n' "dashboard"
      ;;
    refresh-and-search|sidebar-overflow-search)
      printf '%s\n' "overflow"
      ;;
    timeline-burst)
      printf '%s\n' "cockpit"
      ;;
    offline-cached-open)
      printf '%s\n' "offline-cached"
      ;;
    *)
      printf '%s\n' "dashboard"
      ;;
  esac
}

duration_for() {
  case "$1" in
    launch-dashboard) printf '%s\n' "6" ;;
    select-session-cockpit) printf '%s\n' "8" ;;
    refresh-and-search) printf '%s\n' "10" ;;
    sidebar-overflow-search) printf '%s\n' "8" ;;
    settings-backdrop-cycle) printf '%s\n' "9" ;;
    settings-background-cycle) printf '%s\n' "10" ;;
    timeline-burst) printf '%s\n' "8" ;;
    offline-cached-open) printf '%s\n' "7" ;;
    *) printf '%s\n' "8" ;;
  esac
}

build_release_targets() {
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SHIPPING_SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build \
    CODE_SIGNING_ALLOWED=NO \
    -quiet

  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$HOST_SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build \
    CODE_SIGNING_ALLOWED=NO \
    -quiet
}

cleanup_host_processes() {
  local host_pattern='Harness Monitor UI Testing.app/Contents/MacOS/Harness Monitor UI Testing'
  local pids
  pids="$(pgrep -f "$host_pattern" || true)"
  if [[ -z "$pids" ]]; then
    return
  fi

  while IFS= read -r pid; do
    if [[ -n "$pid" ]]; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  done <<<"$pids"
}

label=""
compare_to=""
scenario_selection="all"
keep_traces=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)
      label="${2:-}"
      shift 2
      ;;
    --compare-to)
      compare_to="${2:-}"
      shift 2
      ;;
    --scenarios)
      scenario_selection="${2:-}"
      shift 2
      ;;
    --keep-traces)
      keep_traces=1
      shift
      ;;
    --discard-traces)
      keep_traces=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$label" ]]; then
  printf '%s\n' "--label is required." >&2
  usage >&2
  exit 1
fi

selected_scenarios=()
if [[ "$scenario_selection" == "all" ]]; then
  selected_scenarios=("${ALL_SCENARIOS[@]}")
else
  IFS=',' read -r -a requested_scenarios <<<"$scenario_selection"
  for scenario in "${requested_scenarios[@]}"; do
    normalized="${scenario#"${scenario%%[![:space:]]*}"}"
    normalized="${normalized%"${normalized##*[![:space:]]}"}"
    if [[ -z "$normalized" ]]; then
      continue
    fi
    if ! contains "$normalized" "${ALL_SCENARIOS[@]}"; then
      printf 'Unknown scenario: %s\n' "$normalized" >&2
      exit 1
    fi
    selected_scenarios+=("$normalized")
  done
fi

if [[ ${#selected_scenarios[@]} -eq 0 ]]; then
  printf '%s\n' "No scenarios selected." >&2
  exit 1
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
label_slug="${label//[^A-Za-z0-9._-]/-}"
run_dir="$RUNS_ROOT/${timestamp}-${label_slug}"
traces_root="$run_dir/traces"
xctrace_tmp_root="$run_dir/xctrace-tmp"
mkdir -p "$traces_root"
mkdir -p "$xctrace_tmp_root"

printf 'Building Release targets for Instruments...\n'
build_release_targets

if [[ ! -x "$HOST_BINARY_PATH" ]]; then
  printf 'Expected UI-test host binary not found at %s\n' "$HOST_BINARY_PATH" >&2
  exit 1
fi

capture_records_file="$run_dir/captures.tsv"
: >"$capture_records_file"

record_capture() {
  local template="$1"
  local scenario="$2"
  local duration_seconds="$3"
  local template_slug
  template_slug="$(printf '%s' "$template" | tr '[:upper:] ' '[:lower:]-')"
  local preview_scenario
  preview_scenario="$(preview_scenario_for "$scenario")"
  local template_dir="$traces_root/$template_slug"
  mkdir -p "$template_dir"
  local trace_path="$template_dir/${scenario}.trace"
  local toc_path="$template_dir/${scenario}.toc.xml"

  printf 'Recording %s / %s (%ss)...\n' "$template" "$scenario" "$duration_seconds"
  set +e
  TMPDIR="$xctrace_tmp_root/" xcrun xctrace record \
    --template "$template" \
    --time-limit "${duration_seconds}s" \
    --output "$trace_path" \
    --env "$UI_TESTS_ENV" \
    --env "$KEEP_ANIMATIONS_ENV" \
    --env "$LAUNCH_MODE_ENV" \
    --env "$HIDE_DOCK_ENV" \
    --env "HARNESS_MONITOR_PERF_SCENARIO=$scenario" \
    --env "HARNESS_MONITOR_PREVIEW_SCENARIO=$preview_scenario" \
    --env "$WINDOW_WIDTH_ENV" \
    --env "$WINDOW_HEIGHT_ENV" \
    --launch -- "$HOST_BINARY_PATH" "$PERSISTENCE_ARG_ONE" "$PERSISTENCE_ARG_TWO"
  local record_status=$?
  set -e

  if [[ ! -d "$trace_path" ]]; then
    printf 'Trace bundle missing for %s / %s\n' "$template" "$scenario" >&2
    exit 1
  fi

  TMPDIR="$xctrace_tmp_root/" xcrun xctrace export --input "$trace_path" --toc >"$toc_path"
  local end_reason
  end_reason="$(
    python3 - "$toc_path" <<'PY'
from __future__ import annotations
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
end_reason = root.findtext(".//end-reason", default="")
print(end_reason.strip())
PY
  )"

  if [[ "$record_status" -ne 0 && "$end_reason" != "Time limit reached" ]]; then
    printf 'xctrace record failed for %s / %s with exit %s and end reason "%s"\n' \
      "$template" "$scenario" "$record_status" "$end_reason" >&2
    exit "$record_status"
  fi

  cleanup_host_processes

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$scenario" \
    "$template" \
    "$duration_seconds" \
    "${trace_path#"$run_dir"/}" \
    "$record_status" \
    "$end_reason" \
    "$preview_scenario" >>"$capture_records_file"
}

for scenario in "${selected_scenarios[@]}"; do
  if contains "$scenario" "${SWIFTUI_SCENARIOS[@]}"; then
    record_capture "SwiftUI" "$scenario" "$(duration_for "$scenario")"
  fi
  if contains "$scenario" "${ALLOCATIONS_SCENARIOS[@]}"; then
    record_capture "Allocations" "$scenario" "$(duration_for "$scenario")"
  fi
done

cleanup_host_processes

git_commit="$(git rev-parse HEAD)"
git_dirty="false"
if [[ -n "$(git status --short)" ]]; then
  git_dirty="true"
fi
xcode_version="$(xcodebuild -version | tr '\n' ';' | sed 's/;*$//')"
xctrace_version="$(xcrun xctrace version | tr '\n' ';' | sed 's/;*$//')"
macos_version="$(sw_vers -productVersion)"
macos_build="$(sw_vers -buildVersion)"
host_arch="$(uname -m)"

python3 - "$run_dir/manifest.json" "$label" "$timestamp" "$git_commit" "$git_dirty" "$xcode_version" "$xctrace_version" "$macos_version" "$macos_build" "$host_arch" "$PROJECT_PATH" "$SHIPPING_SCHEME" "$HOST_SCHEME" "$SHIPPING_APP_PATH" "$HOST_APP_PATH" "$HOST_BUNDLE_ID" "$capture_records_file" "$UI_TESTS_ENV" "$KEEP_ANIMATIONS_ENV" "$LAUNCH_MODE_ENV" "$WINDOW_WIDTH_ENV" "$WINDOW_HEIGHT_ENV" "$HIDE_DOCK_ENV" "$PERSISTENCE_ARG_ONE" "$PERSISTENCE_ARG_TWO" "${selected_scenarios[@]}" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

(
    manifest_path,
    label,
    timestamp,
    git_commit,
    git_dirty,
    xcode_version,
    xctrace_version,
    macos_version,
    macos_build,
    host_arch,
    project_path,
    shipping_scheme,
    host_scheme,
    shipping_app_path,
    host_app_path,
    host_bundle_id,
    capture_records_path,
    ui_tests_env,
    keep_animations_env,
    launch_mode_env,
    window_width_env,
    window_height_env,
    hide_dock_env,
    launch_arg_one,
    launch_arg_two,
    *selected_scenarios,
) = sys.argv[1:]

environment_pairs = [
    item.split("=", 1)
    for item in [
        ui_tests_env,
        keep_animations_env,
        launch_mode_env,
        window_width_env,
        window_height_env,
        hide_dock_env,
    ]
]
default_environment = {key: value for key, value in environment_pairs}
captures = []
for line in Path(capture_records_path).read_text(encoding="utf-8").splitlines():
    if not line.strip():
        continue
    scenario, template, duration_seconds, trace_relpath, exit_status, end_reason, preview_scenario = line.split("\t")
    captures.append(
        {
            "scenario": scenario,
            "template": template,
            "duration_seconds": int(duration_seconds),
            "trace_relpath": trace_relpath,
            "exit_status": int(exit_status),
            "end_reason": end_reason,
            "preview_scenario": preview_scenario,
            "environment": {
                **default_environment,
                "HARNESS_MONITOR_PREVIEW_SCENARIO": preview_scenario,
                "HARNESS_MONITOR_PERF_SCENARIO": scenario,
            },
            "launch_arguments": [launch_arg_one, launch_arg_two],
        }
    )

manifest = {
    "label": label,
    "created_at_utc": timestamp,
    "git": {
        "commit": git_commit,
        "dirty": git_dirty == "true",
    },
    "system": {
        "xcode_version": xcode_version,
        "xctrace_version": xctrace_version,
        "macos_version": macos_version,
        "macos_build": macos_build,
        "arch": host_arch,
    },
    "targets": {
        "project": project_path,
        "shipping_scheme": shipping_scheme,
        "host_scheme": host_scheme,
        "shipping_app_path": shipping_app_path,
        "host_app_path": host_app_path,
        "host_bundle_id": host_bundle_id,
    },
    "templates": {
        "swiftui": ["launch-dashboard", "select-session-cockpit", "refresh-and-search", "sidebar-overflow-search", "timeline-burst", "offline-cached-open"],
        "allocations": ["settings-backdrop-cycle", "settings-background-cycle", "offline-cached-open"],
    },
    "default_environment": default_environment,
    "launch_arguments": [launch_arg_one, launch_arg_two],
    "selected_scenarios": selected_scenarios,
    "captures": captures,
}
Path(manifest_path).write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")
PY

python3 "$SCRIPT_DIR/extract-instruments-metrics.py" --run-dir "$run_dir"

if [[ -n "$compare_to" ]]; then
  python3 "$SCRIPT_DIR/compare-instruments-runs.py" \
    --current "$run_dir" \
    --baseline "$compare_to" \
    --output-dir "$run_dir"
fi

if [[ "$keep_traces" -eq 0 ]]; then
  python3 - "$traces_root" <<'PY'
from __future__ import annotations
import shutil
import sys
from pathlib import Path

for trace in Path(sys.argv[1]).rglob("*.trace"):
    shutil.rmtree(trace, ignore_errors=True)
PY
fi

printf '\nArtifacts written to %s\n' "$run_dir"
printf 'Summary: %s\n' "$run_dir/summary.json"
if [[ -n "$compare_to" ]]; then
  printf 'Comparison: %s\n' "$run_dir/comparison.md"
fi
