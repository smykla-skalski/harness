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
UI_ACCESSIBILITY_MARKERS_ENV="HARNESS_MONITOR_UI_ACCESSIBILITY_MARKERS=0"
KEEP_ANIMATIONS_ENV="HARNESS_MONITOR_KEEP_ANIMATIONS=1"
LAUNCH_MODE_ENV="HARNESS_MONITOR_LAUNCH_MODE=preview"
WINDOW_WIDTH_ENV="HARNESS_MONITOR_UI_MAIN_WINDOW_WIDTH=1640"
WINDOW_HEIGHT_ENV="HARNESS_MONITOR_UI_MAIN_WINDOW_HEIGHT=980"
HIDE_DOCK_ENV="HARNESS_MONITOR_PERF_HIDE_DOCK_ICON=1"
PERSISTENCE_ARG_ONE="-ApplePersistenceIgnoreState"
PERSISTENCE_ARG_TWO="YES"
AUDIT_COMMIT_ENV_KEY="HARNESS_MONITOR_AUDIT_GIT_COMMIT"
AUDIT_DIRTY_ENV_KEY="HARNESS_MONITOR_AUDIT_GIT_DIRTY"
AUDIT_RUN_ID_ENV_KEY="HARNESS_MONITOR_AUDIT_RUN_ID"
AUDIT_LABEL_ENV_KEY="HARNESS_MONITOR_AUDIT_LABEL"
BUILD_COMMIT_KEY="HarnessMonitorBuildGitCommit"
BUILD_DIRTY_KEY="HarnessMonitorBuildGitDirty"
BUILD_PROVENANCE_RESOURCE="HarnessMonitorBuildProvenance.plist"
AUDIT_LOCK_DIR="$RUNS_ROOT/.audit.lock"
AUDIT_LOCK_INFO_PATH="$AUDIT_LOCK_DIR/owner.tsv"
SKIP_BUILD="${HARNESS_MONITOR_AUDIT_SKIP_BUILD:-0}"

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
    -scheme "$HOST_SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    clean \
    CODE_SIGNING_ALLOWED=NO \
    -quiet

  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SHIPPING_SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build \
    "HARNESS_MONITOR_BUILD_GIT_COMMIT=$git_commit" \
    "HARNESS_MONITOR_BUILD_GIT_DIRTY=$git_dirty" \
    CODE_SIGNING_ALLOWED=NO \
    -quiet

  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$HOST_SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build \
    "HARNESS_MONITOR_BUILD_GIT_COMMIT=$git_commit" \
    "HARNESS_MONITOR_BUILD_GIT_DIRTY=$git_dirty" \
    CODE_SIGNING_ALLOWED=NO \
    -quiet
}

cleanup_host_processes() {
  local host_pattern='Harness Monitor UI Testing.app/Contents/MacOS/Harness Monitor UI Testing'
  local pids
  pids="$(
    ps -Ao pid=,command= \
      | awk -v pattern="$host_pattern" '$0 ~ pattern { print $1 }'
  )"
  if [[ -z "$pids" ]]; then
    return
  fi

  while IFS= read -r pid; do
    if [[ -n "$pid" ]]; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  done <<<"$pids"
}

write_lock_info() {
  local run_id="$1"
  local run_label="$2"
  local started_at_utc="$3"
  local run_dir="$4"

  mkdir -p "$AUDIT_LOCK_DIR"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$$" \
    "$run_id" \
    "$run_label" \
    "$started_at_utc" \
    "$run_dir" >"$AUDIT_LOCK_INFO_PATH"
}

release_audit_lock() {
  if [[ -f "$AUDIT_LOCK_INFO_PATH" ]]; then
    local owner_pid
    owner_pid="$(cut -f1 "$AUDIT_LOCK_INFO_PATH" 2>/dev/null || true)"
    if [[ "$owner_pid" == "$$" ]]; then
      rm -f "$AUDIT_LOCK_INFO_PATH"
    fi
  fi

  rmdir "$AUDIT_LOCK_DIR" 2>/dev/null || true
}

acquire_audit_lock() {
  local run_id="$1"
  local run_label="$2"
  local started_at_utc="$3"
  local run_dir="$4"

  mkdir -p "$RUNS_ROOT"
  local active_audit_processes active_pid active_ppid active_command
  active_audit_processes="$(
    ps -Ao pid=,ppid=,command= \
      | awk '
        /run-instruments-audit[.]sh/ {
          pid = $1
          ppid = $2
          $1 = ""
          $2 = ""
          sub(/^  */, "")
          printf "%s\t%s\t%s\n", pid, ppid, $0
        }
      '
  )"
  while IFS=$'\t' read -r active_pid active_ppid active_command; do
    if [[ -z "$active_pid" ]]; then
      continue
    fi
    if [[ "$active_command" == *"harness hook --agent codex suite:run audit-turn"* ]]; then
      continue
    fi
    if [[ "$active_pid" != "$$" && "$active_pid" != "$PPID" && "$active_ppid" != "$$" ]]; then
      printf 'Another audit script process is already active (pid=%s command=%s). Wait for it to finish before starting %s.\n' \
        "$active_pid" \
        "$active_command" \
        "$run_id" >&2
      exit 1
    fi
  done <<<"$active_audit_processes"

  if mkdir "$AUDIT_LOCK_DIR" 2>/dev/null; then
    write_lock_info "$run_id" "$run_label" "$started_at_utc" "$run_dir"
    return
  fi

  if [[ -f "$AUDIT_LOCK_INFO_PATH" ]]; then
    local owner_pid owner_run_id owner_label owner_started_at owner_run_dir
    IFS=$'\t' read -r owner_pid owner_run_id owner_label owner_started_at owner_run_dir <"$AUDIT_LOCK_INFO_PATH" || true
    if [[ -n "${owner_pid:-}" ]] && kill -0 "$owner_pid" 2>/dev/null; then
      printf 'Another audit run is already active (pid=%s run_id=%s label=%s started_at=%s run_dir=%s).\n' \
        "$owner_pid" \
        "${owner_run_id:-unknown}" \
        "${owner_label:-unknown}" \
        "${owner_started_at:-unknown}" \
        "${owner_run_dir:-unknown}" >&2
      exit 1
    fi
  fi

  rm -rf "$AUDIT_LOCK_DIR"
  mkdir "$AUDIT_LOCK_DIR"
  write_lock_info "$run_id" "$run_label" "$started_at_utc" "$run_dir"
}

plist_value() {
  local plist_path="$1"
  local key="$2"

  /usr/libexec/PlistBuddy -c "Print :$key" "$plist_path" 2>/dev/null || true
}

bundle_provenance_value() {
  local bundle_path="$1"
  local key="$2"
  local provenance_path="$bundle_path/Contents/Resources/$BUILD_PROVENANCE_RESOURCE"

  if [[ -f "$provenance_path" ]]; then
    plist_value "$provenance_path" "$key"
  else
    printf '%s' ""
  fi
}

binary_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

binary_mtime_utc() {
  TZ=UTC /usr/bin/stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%SZ' "$1"
}

bundle_sha256() {
  python3 - "$1" <<'PY'
from __future__ import annotations

import hashlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
digest = hashlib.sha256()

for path in sorted(candidate for candidate in root.rglob("*") if candidate.is_file()):
    relative_path = path.relative_to(root).as_posix()
    digest.update(relative_path.encode("utf-8"))
    digest.update(b"\0")
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    digest.update(b"\0")

print(digest.hexdigest())
PY
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

git_commit="$(git rev-parse HEAD)"
git_dirty="false"
if [[ -n "$(git status --short)" ]]; then
  git_dirty="true"
fi
audit_commit_env="$AUDIT_COMMIT_ENV_KEY=$git_commit"
audit_dirty_env="$AUDIT_DIRTY_ENV_KEY=$git_dirty"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
label_slug="${label//[^A-Za-z0-9._-]/-}"
run_id="${timestamp}-${label_slug}"
run_dir="$RUNS_ROOT/${timestamp}-${label_slug}"
traces_root="$run_dir/traces"
xctrace_tmp_root="$run_dir/xctrace-tmp"
acquire_audit_lock "$run_id" "$label" "$timestamp" "$run_dir"
trap 'release_audit_lock' EXIT INT TERM
mkdir -p "$traces_root"
mkdir -p "$xctrace_tmp_root"

audit_run_id_env="$AUDIT_RUN_ID_ENV_KEY=$run_id"
audit_label_env="$AUDIT_LABEL_ENV_KEY=$label"

printf 'Building Release targets for Instruments...\n'
cleanup_host_processes
if [[ "$SKIP_BUILD" == "1" ]]; then
  printf 'Skipping Release build step because HARNESS_MONITOR_AUDIT_SKIP_BUILD=1.\n'
else
  build_release_targets
fi

if [[ ! -x "$HOST_BINARY_PATH" ]]; then
  printf 'Expected UI-test host binary not found at %s\n' "$HOST_BINARY_PATH" >&2
  exit 1
fi

host_info_plist="$HOST_APP_PATH/Contents/Info.plist"
shipping_info_plist="$SHIPPING_APP_PATH/Contents/Info.plist"
host_embedded_commit="$(bundle_provenance_value "$HOST_APP_PATH" "$BUILD_COMMIT_KEY")"
host_embedded_dirty="$(bundle_provenance_value "$HOST_APP_PATH" "$BUILD_DIRTY_KEY")"
shipping_embedded_commit="$(bundle_provenance_value "$SHIPPING_APP_PATH" "$BUILD_COMMIT_KEY")"
shipping_embedded_dirty="$(bundle_provenance_value "$SHIPPING_APP_PATH" "$BUILD_DIRTY_KEY")"

host_binary_sha256="$(binary_sha256 "$HOST_BINARY_PATH")"
shipping_binary_sha256="$(binary_sha256 "$SHIPPING_APP_PATH/Contents/MacOS/Harness Monitor")"
host_bundle_sha256="$(bundle_sha256 "$HOST_APP_PATH")"
shipping_bundle_sha256="$(bundle_sha256 "$SHIPPING_APP_PATH")"
host_binary_mtime_utc="$(binary_mtime_utc "$HOST_BINARY_PATH")"
shipping_binary_mtime_utc="$(binary_mtime_utc "$SHIPPING_APP_PATH/Contents/MacOS/Harness Monitor")"

if [[ "$host_embedded_commit" != "$git_commit" || "$host_embedded_dirty" != "$git_dirty" ]]; then
  if [[ "$SKIP_BUILD" == "1" ]]; then
    printf 'Host build provenance mismatch: expected commit=%s dirty=%s but bundle reports commit=%s dirty=%s. Continuing because HARNESS_MONITOR_AUDIT_SKIP_BUILD=1.\n' \
      "$git_commit" "$git_dirty" "$host_embedded_commit" "$host_embedded_dirty" >&2
  else
    printf 'Host build provenance mismatch: expected commit=%s dirty=%s but bundle reports commit=%s dirty=%s\n' \
      "$git_commit" "$git_dirty" "$host_embedded_commit" "$host_embedded_dirty" >&2
    exit 1
  fi
fi

if [[ "$shipping_embedded_commit" != "$git_commit" || "$shipping_embedded_dirty" != "$git_dirty" ]]; then
  if [[ "$SKIP_BUILD" == "1" ]]; then
    printf 'Shipping build provenance mismatch: expected commit=%s dirty=%s but bundle reports commit=%s dirty=%s. Continuing because HARNESS_MONITOR_AUDIT_SKIP_BUILD=1.\n' \
      "$git_commit" "$git_dirty" "$shipping_embedded_commit" "$shipping_embedded_dirty" >&2
  else
    printf 'Shipping build provenance mismatch: expected commit=%s dirty=%s but bundle reports commit=%s dirty=%s\n' \
      "$git_commit" "$git_dirty" "$shipping_embedded_commit" "$shipping_embedded_dirty" >&2
    exit 1
  fi
fi

printf 'Using host binary: %s\n' "$HOST_BINARY_PATH"
printf 'Host SHA256: %s\n' "$host_binary_sha256"
printf 'Host bundle SHA256: %s\n' "$host_bundle_sha256"
printf 'Host mtime (UTC): %s\n' "$host_binary_mtime_utc"
printf 'Audit commit stamp: %s dirty=%s\n' "$git_commit" "$git_dirty"

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
      --env "$UI_ACCESSIBILITY_MARKERS_ENV" \
      --env "$KEEP_ANIMATIONS_ENV" \
    --env "$LAUNCH_MODE_ENV" \
    --env "$HIDE_DOCK_ENV" \
    --env "$audit_commit_env" \
    --env "$audit_dirty_env" \
    --env "$audit_run_id_env" \
    --env "$audit_label_env" \
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

xcode_version="$(xcodebuild -version | tr '\n' ';' | sed 's/;*$//')"
xctrace_version="$(xcrun xctrace version | tr '\n' ';' | sed 's/;*$//')"
macos_version="$(sw_vers -productVersion)"
macos_build="$(sw_vers -buildVersion)"
host_arch="$(uname -m)"

python3 - "$run_dir/manifest.json" "$label" "$run_id" "$timestamp" "$git_commit" "$git_dirty" "$xcode_version" "$xctrace_version" "$macos_version" "$macos_build" "$host_arch" "$PROJECT_PATH" "$SHIPPING_SCHEME" "$HOST_SCHEME" "$SHIPPING_APP_PATH" "$HOST_APP_PATH" "$HOST_BUNDLE_ID" "$host_embedded_commit" "$host_embedded_dirty" "$host_binary_sha256" "$host_bundle_sha256" "$host_binary_mtime_utc" "$shipping_embedded_commit" "$shipping_embedded_dirty" "$shipping_binary_sha256" "$shipping_bundle_sha256" "$shipping_binary_mtime_utc" "$capture_records_file" "$UI_TESTS_ENV" "$UI_ACCESSIBILITY_MARKERS_ENV" "$KEEP_ANIMATIONS_ENV" "$LAUNCH_MODE_ENV" "$WINDOW_WIDTH_ENV" "$WINDOW_HEIGHT_ENV" "$HIDE_DOCK_ENV" "$audit_commit_env" "$audit_dirty_env" "$audit_run_id_env" "$audit_label_env" "$PERSISTENCE_ARG_ONE" "$PERSISTENCE_ARG_TWO" "${selected_scenarios[@]}" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

(
    manifest_path,
    label,
    run_id,
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
    host_embedded_commit,
    host_embedded_dirty,
    host_binary_sha256,
    host_bundle_sha256,
    host_binary_mtime_utc,
    shipping_embedded_commit,
    shipping_embedded_dirty,
    shipping_binary_sha256,
    shipping_bundle_sha256,
    shipping_binary_mtime_utc,
    capture_records_path,
    ui_tests_env,
    ui_accessibility_markers_env,
    keep_animations_env,
    launch_mode_env,
    window_width_env,
    window_height_env,
    hide_dock_env,
    audit_commit_env,
    audit_dirty_env,
    audit_run_id_env,
    audit_label_env,
    launch_arg_one,
    launch_arg_two,
    *selected_scenarios,
) = sys.argv[1:]

environment_pairs = [
    item.split("=", 1)
    for item in [
        ui_tests_env,
        ui_accessibility_markers_env,
        keep_animations_env,
        launch_mode_env,
        window_width_env,
        window_height_env,
        hide_dock_env,
        audit_commit_env,
        audit_dirty_env,
        audit_run_id_env,
        audit_label_env,
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
    "run_id": run_id,
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
    "build_provenance": {
        "host": {
            "embedded_commit": host_embedded_commit,
            "embedded_dirty": host_embedded_dirty,
            "binary_sha256": host_binary_sha256,
            "bundle_sha256": host_bundle_sha256,
            "binary_mtime_utc": host_binary_mtime_utc,
        },
        "shipping": {
            "embedded_commit": shipping_embedded_commit,
            "embedded_dirty": shipping_embedded_dirty,
            "binary_sha256": shipping_binary_sha256,
            "bundle_sha256": shipping_bundle_sha256,
            "binary_mtime_utc": shipping_binary_mtime_utc,
        },
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
