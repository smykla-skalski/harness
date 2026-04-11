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
HOST_APP_PATH=""
HOST_BINARY_PATH=""
SHIPPING_APP_PATH=""
UI_TESTS_ENV="HARNESS_MONITOR_UI_TESTS=1"
DAEMON_DATA_HOME_ENV_KEY="HARNESS_DAEMON_DATA_HOME"
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
AUDIT_WORKSPACE_FINGERPRINT_ENV_KEY="HARNESS_MONITOR_AUDIT_WORKSPACE_FINGERPRINT"
AUDIT_BUILD_STARTED_AT_UTC_ENV_KEY="HARNESS_MONITOR_AUDIT_BUILD_STARTED_AT_UTC"
BUILD_COMMIT_KEY="HarnessMonitorBuildGitCommit"
BUILD_DIRTY_KEY="HarnessMonitorBuildGitDirty"
BUILD_WORKSPACE_FINGERPRINT_KEY="HarnessMonitorBuildWorkspaceFingerprint"
BUILD_STARTED_AT_UTC_KEY="HarnessMonitorBuildStartedAtUTC"
BUILD_PROVENANCE_RESOURCE="HarnessMonitorBuildProvenance.plist"
AUDIT_LOCK_DIR="$RUNS_ROOT/.audit.lock"
AUDIT_LOCK_INFO_PATH="$AUDIT_LOCK_DIR/owner.tsv"
SKIP_BUILD="${HARNESS_MONITOR_AUDIT_SKIP_BUILD:-0}"
SKIP_DAEMON_BUNDLE="${HARNESS_MONITOR_AUDIT_SKIP_DAEMON_BUNDLE:-0}"
FORCE_CLEAN="${HARNESS_MONITOR_AUDIT_FORCE_CLEAN:-0}"
BUILD_SHIPPING="${HARNESS_MONITOR_AUDIT_BUILD_SHIPPING:-0}"
STAGED_HOST_APP_PATH=""
STAGED_HOST_BINARY_PATH=""
STAGED_HOST_BUNDLE_ID=""
STAGED_HOST_LAUNCHER_PATH=""
AUDIT_DAEMON_BUNDLE_MODE="unknown"
AUDIT_DAEMON_CARGO_TARGET_DIR=""
AUDIT_BUILD_ARCH=""

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
  run-instruments-audit.sh --label <name> [--compare-to <run-dir-or-summary.json>] [--scenarios all|comma,list] [--keep-traces]

Options:
  --label <name>         Required run label.
  --compare-to <path>    Optional baseline run directory or summary.json.
  --scenarios <value>    Scenario selection. Default: all
  --keep-traces          Keep raw .trace bundles after metrics extraction. Default: discard raw traces.
  --discard-traces       Explicitly discard raw .trace bundles after metrics extraction.
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

resolve_common_repo_root() {
  local common_git_dir
  common_git_dir="$(git -C "$REPO_ROOT" rev-parse --git-common-dir)"
  if [[ "$common_git_dir" != /* ]]; then
    common_git_dir="$REPO_ROOT/$common_git_dir"
  fi
  CDPATH='' cd -- "$common_git_dir/.." && pwd
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

COMMON_REPO_ROOT="$(resolve_common_repo_root)"
DERIVED_DATA_PATH="$COMMON_REPO_ROOT/tmp/perf/harness-monitor-instruments/xcode-derived"
AUDIT_DAEMON_CARGO_TARGET_DIR="${HARNESS_MONITOR_AUDIT_DAEMON_CARGO_TARGET_DIR:-$COMMON_REPO_ROOT/target/harness-monitor-audit-daemon}"
AUDIT_BUILD_ARCH="${HARNESS_MONITOR_AUDIT_BUILD_ARCH:-$(uname -m)}"
HOST_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/Harness Monitor UI Testing.app"
HOST_BINARY_PATH="$HOST_APP_PATH/Contents/MacOS/Harness Monitor UI Testing"
SHIPPING_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/Harness Monitor.app"

if [[ "$SKIP_DAEMON_BUNDLE" == "1" ]]; then
  AUDIT_DAEMON_BUNDLE_MODE="skipped"
else
  AUDIT_DAEMON_BUNDLE_MODE="shared-cargo-target"
fi

build_release_targets() {
  local daemon_bundle_env=()
  local common_build_env=(
    "ARCHS=$AUDIT_BUILD_ARCH"
    "ONLY_ACTIVE_ARCH=YES"
    "ENABLE_CODE_COVERAGE=NO"
    "CLANG_COVERAGE_MAPPING=NO"
    "GCC_GENERATE_TEST_COVERAGE_FILES=NO"
    "COMPILER_INDEX_STORE_ENABLE=NO"
  )
  if [[ "$SKIP_DAEMON_BUNDLE" == "1" ]]; then
    daemon_bundle_env=("HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE=1")
  else
    mkdir -p "$AUDIT_DAEMON_CARGO_TARGET_DIR"
    daemon_bundle_env=("CARGO_TARGET_DIR=$AUDIT_DAEMON_CARGO_TARGET_DIR")
  fi

  purge_release_products

  if [[ "$FORCE_CLEAN" == "1" ]]; then
    if [[ "$BUILD_SHIPPING" == "1" ]]; then
      xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SHIPPING_SCHEME" \
        -configuration Release \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        clean \
        "${common_build_env[@]}" \
        CODE_SIGNING_ALLOWED=NO \
        -quiet
    fi

    xcodebuild \
      -project "$PROJECT_PATH" \
      -scheme "$HOST_SCHEME" \
      -configuration Release \
      -derivedDataPath "$DERIVED_DATA_PATH" \
      clean \
      "${common_build_env[@]}" \
      CODE_SIGNING_ALLOWED=NO \
      -quiet
  fi

  if [[ "$BUILD_SHIPPING" == "1" ]]; then
    xcodebuild \
      -project "$PROJECT_PATH" \
      -scheme "$SHIPPING_SCHEME" \
      -configuration Release \
      -derivedDataPath "$DERIVED_DATA_PATH" \
      build \
      "${common_build_env[@]}" \
      "${daemon_bundle_env[@]}" \
      "HARNESS_MONITOR_BUILD_GIT_COMMIT=$git_commit" \
      "HARNESS_MONITOR_BUILD_GIT_DIRTY=$git_dirty" \
      "HARNESS_MONITOR_BUILD_WORKSPACE_FINGERPRINT=$workspace_fingerprint" \
      "HARNESS_MONITOR_BUILD_STARTED_AT_UTC=$build_started_at_utc" \
      CODE_SIGNING_ALLOWED=NO \
      -quiet
  fi

  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$HOST_SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build \
    "${common_build_env[@]}" \
    "${daemon_bundle_env[@]}" \
    "HARNESS_MONITOR_BUILD_GIT_COMMIT=$git_commit" \
    "HARNESS_MONITOR_BUILD_GIT_DIRTY=$git_dirty" \
    "HARNESS_MONITOR_BUILD_WORKSPACE_FINGERPRINT=$workspace_fingerprint" \
    "HARNESS_MONITOR_BUILD_STARTED_AT_UTC=$build_started_at_utc" \
    CODE_SIGNING_ALLOWED=NO \
    -quiet
}

purge_release_products() {
  /bin/rm -rf \
    "$HOST_APP_PATH" \
    "$HOST_APP_PATH.dSYM" \
    "$SHIPPING_APP_PATH" \
    "$SHIPPING_APP_PATH.dSYM"
}

bundle_matches_provenance() {
  local bundle_path="$1"
  local expected_commit="$2"
  local expected_dirty="$3"
  local expected_workspace_fingerprint="$4"

  if [[ ! -d "$bundle_path" ]]; then
    return 1
  fi

  [[ "$(bundle_provenance_value "$bundle_path" "$BUILD_COMMIT_KEY")" == "$expected_commit" ]] \
    && [[ "$(bundle_provenance_value "$bundle_path" "$BUILD_DIRTY_KEY")" == "$expected_dirty" ]] \
    && [[ "$(bundle_provenance_value "$bundle_path" "$BUILD_WORKSPACE_FINGERPRINT_KEY")" == "$expected_workspace_fingerprint" ]]
}

release_products_are_current() {
  if [[ ! -x "$HOST_BINARY_PATH" ]]; then
    return 1
  fi

  if ! bundle_matches_provenance "$HOST_APP_PATH" "$git_commit" "$git_dirty" "$workspace_fingerprint"; then
    return 1
  fi

  if [[ "$BUILD_SHIPPING" == "1" ]]; then
    if [[ ! -x "$SHIPPING_APP_PATH/Contents/MacOS/Harness Monitor" ]]; then
      return 1
    fi

    if ! bundle_matches_provenance "$SHIPPING_APP_PATH" "$git_commit" "$git_dirty" "$workspace_fingerprint"; then
      return 1
    fi
  fi

  return 0
}

cleanup_host_processes() {
  local pids
  pids="$(
    ps -Ao pid=,command= \
      | awk '
        /Harness Monitor UI Testing[.]app\/Contents\/MacOS\/Harness Monitor UI Testing/ { print $1; next }
        /launch-staged-host([[:space:]]|$)/ { print $1; next }
      '
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

strip_app_attrs() {
  local target_path="$1"
  if [[ -e "$target_path" ]]; then
    /usr/bin/xattr -dr com.apple.provenance "$target_path" 2>/dev/null || true
    /usr/bin/xattr -dr com.apple.quarantine "$target_path" 2>/dev/null || true
  fi
}

stage_launch_host() {
  local stage_root="$run_dir/launch-host"
  local staged_bundle_name="Harness Monitor UI Testing.app"
  local staged_bundle_id_suffix
  local launcher_source_path
  staged_bundle_id_suffix="$(printf '%s' "$run_id" | tr -cd '[:alnum:]')"

  STAGED_HOST_APP_PATH="$stage_root/$staged_bundle_name"
  STAGED_HOST_BINARY_PATH="$STAGED_HOST_APP_PATH/Contents/MacOS/Harness Monitor UI Testing"
  STAGED_HOST_BUNDLE_ID="${HOST_BUNDLE_ID}.audit.${staged_bundle_id_suffix}"
  STAGED_HOST_LAUNCHER_PATH="$stage_root/launch-staged-host"
  launcher_source_path="$stage_root/launch-staged-host.c"

  rm -rf "$stage_root"
  mkdir -p "$stage_root"
  /usr/bin/ditto "$HOST_APP_PATH" "$STAGED_HOST_APP_PATH"
  strip_app_attrs "$STAGED_HOST_APP_PATH"

  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier $STAGED_HOST_BUNDLE_ID" \
    "$STAGED_HOST_APP_PATH/Contents/Info.plist"

  cat >"$launcher_source_path" <<EOF
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
  const char *target = "$STAGED_HOST_BINARY_PATH";
  char **child_argv = calloc((size_t)argc + 1U, sizeof(char *));
  if (child_argv == NULL) {
    perror("calloc");
    return 127;
  }

  child_argv[0] = (char *)target;
  for (int index = 1; index < argc; index++) {
    child_argv[index] = argv[index];
  }
  child_argv[argc] = NULL;

  execv(target, child_argv);
  perror("execv");
  free(child_argv);
  return errno == 0 ? 127 : errno;
}
EOF

  /usr/bin/clang \
    -Os \
    -Wall \
    -Wextra \
    -Werror \
    -o "$STAGED_HOST_LAUNCHER_PATH" \
    "$launcher_source_path"
}

trace_launched_process_path() {
  local toc_path="$1"
  python3 - "$toc_path" <<'PY'
from __future__ import annotations

import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
for process in root.findall(".//processes/process"):
    if process.get("pid") != "0":
        print(process.get("path", "").strip())
        break
PY
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

prune_run_artifacts() {
  local keep_traces="$1"

  /bin/rm -rf \
    "$run_dir/exports" \
    "$run_dir/launch-host" \
    "$run_dir/app-data" \
    "$run_dir/xctrace-tmp"

  if [[ "$keep_traces" -eq 0 ]]; then
    /bin/rm -rf "$traces_root"
  fi

  find "$run_dir" -depth -type d -empty -delete 2>/dev/null || true
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

workspace_tree_fingerprint() {
  python3 - "$APP_ROOT" <<'PY'
from __future__ import annotations

import hashlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
include_paths = [
    root / "HarnessMonitor.entitlements",
    root / "HarnessMonitorUITestHost.entitlements",
    root / "HarnessMonitorDaemon.entitlements",
    root / "HarnessMonitor.xcodeproj" / "project.pbxproj",
    root / "Sources" / "HarnessMonitor",
    root / "Sources" / "HarnessMonitorKit",
    root / "Sources" / "HarnessMonitorUI",
]
digest = hashlib.sha256()

for include_path in include_paths:
    if not include_path.exists():
        continue

    if include_path.is_file():
        file_paths = [include_path]
    else:
        file_paths = sorted(
            candidate
            for candidate in include_path.rglob("*")
            if candidate.is_file()
        )

    for file_path in file_paths:
        relative_path = file_path.relative_to(root).as_posix()
        digest.update(relative_path.encode("utf-8"))
        digest.update(b"\0")
        with file_path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        digest.update(b"\0")

print(digest.hexdigest())
PY
}

assert_audit_source_unchanged() {
  local checkpoint="$1"
  local current_git_commit
  local current_workspace_fingerprint

  current_git_commit="$(git rev-parse HEAD)"
  current_workspace_fingerprint="$(workspace_tree_fingerprint)"
  if [[ "$current_git_commit" == "$git_commit" && "$current_workspace_fingerprint" == "$workspace_fingerprint" ]]; then
    return
  fi

  printf 'Audit source changed during %s. Built commit=%s fingerprint=%s; current commit=%s fingerprint=%s. Rerun the audit so Instruments measures the current checkout.\n' \
    "$checkpoint" \
    "$git_commit" \
    "$workspace_fingerprint" \
    "$current_git_commit" \
    "$current_workspace_fingerprint" >&2
  exit 1
}

label=""
compare_to=""
scenario_selection="all"
keep_traces=0

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
workspace_fingerprint="$(workspace_tree_fingerprint)"
build_started_at_utc=""
audit_commit_env="$AUDIT_COMMIT_ENV_KEY=$git_commit"
audit_dirty_env="$AUDIT_DIRTY_ENV_KEY=$git_dirty"
audit_workspace_fingerprint_env="$AUDIT_WORKSPACE_FINGERPRINT_ENV_KEY=$workspace_fingerprint"

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
  if [[ "$SKIP_DAEMON_BUNDLE" == "1" ]]; then
    printf 'Skipping daemon helper rebundle during audit builds. Set HARNESS_MONITOR_AUDIT_SKIP_DAEMON_BUNDLE=0 to force the full bundle step.\n'
  else
    printf 'Using shared daemon helper Cargo target dir during audit builds: %s\n' "$AUDIT_DAEMON_CARGO_TARGET_DIR"
  fi
  printf 'Using audit build arch: %s\n' "$AUDIT_BUILD_ARCH"
  printf 'Disabling code coverage and index-store emission for audit builds.\n'
  if [[ "$BUILD_SHIPPING" == "1" ]]; then
    printf 'Building shipping app alongside the audit host because HARNESS_MONITOR_AUDIT_BUILD_SHIPPING=1.\n'
  else
    printf 'Skipping shipping app build for faster feedback. Set HARNESS_MONITOR_AUDIT_BUILD_SHIPPING=1 when you need the extra artifact.\n'
  fi
  if [[ "$FORCE_CLEAN" == "1" ]]; then
    printf 'Forcing a clean audit build because HARNESS_MONITOR_AUDIT_FORCE_CLEAN=1.\n'
  else
    printf 'Using incremental audit builds. Set HARNESS_MONITOR_AUDIT_FORCE_CLEAN=1 to force a clean rebuild.\n'
  fi

  if [[ "$FORCE_CLEAN" != "1" ]] && release_products_are_current; then
    build_started_at_utc="$(bundle_provenance_value "$HOST_APP_PATH" "$BUILD_STARTED_AT_UTC_KEY")"
    if [[ -z "$build_started_at_utc" ]]; then
      build_started_at_utc="$(binary_mtime_utc "$HOST_BINARY_PATH")"
    fi
    printf 'Reusing current Release host build at %s\n' "$HOST_BINARY_PATH"
  else
    build_started_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    build_release_targets
  fi
fi
assert_audit_source_unchanged "Release build"

if [[ -z "$build_started_at_utc" ]]; then
  build_started_at_utc="$(binary_mtime_utc "$HOST_BINARY_PATH")"
fi
audit_build_started_at_utc_env="$AUDIT_BUILD_STARTED_AT_UTC_ENV_KEY=$build_started_at_utc"

if [[ ! -x "$HOST_BINARY_PATH" ]]; then
  printf 'Expected UI-test host binary not found at %s\n' "$HOST_BINARY_PATH" >&2
  exit 1
fi

host_embedded_commit="$(bundle_provenance_value "$HOST_APP_PATH" "$BUILD_COMMIT_KEY")"
host_embedded_dirty="$(bundle_provenance_value "$HOST_APP_PATH" "$BUILD_DIRTY_KEY")"
host_embedded_workspace_fingerprint="$(bundle_provenance_value "$HOST_APP_PATH" "$BUILD_WORKSPACE_FINGERPRINT_KEY")"
host_embedded_started_at_utc="$(bundle_provenance_value "$HOST_APP_PATH" "$BUILD_STARTED_AT_UTC_KEY")"
shipping_embedded_commit=""
shipping_embedded_dirty=""
shipping_embedded_workspace_fingerprint=""
shipping_embedded_started_at_utc=""

host_binary_sha256="$(binary_sha256 "$HOST_BINARY_PATH")"
host_bundle_sha256="$(bundle_sha256 "$HOST_APP_PATH")"
host_binary_mtime_utc="$(binary_mtime_utc "$HOST_BINARY_PATH")"
shipping_binary_sha256=""
shipping_bundle_sha256=""
shipping_binary_mtime_utc=""

if [[ "$BUILD_SHIPPING" == "1" ]]; then
  shipping_embedded_commit="$(bundle_provenance_value "$SHIPPING_APP_PATH" "$BUILD_COMMIT_KEY")"
  shipping_embedded_dirty="$(bundle_provenance_value "$SHIPPING_APP_PATH" "$BUILD_DIRTY_KEY")"
  shipping_embedded_workspace_fingerprint="$(bundle_provenance_value "$SHIPPING_APP_PATH" "$BUILD_WORKSPACE_FINGERPRINT_KEY")"
  shipping_embedded_started_at_utc="$(bundle_provenance_value "$SHIPPING_APP_PATH" "$BUILD_STARTED_AT_UTC_KEY")"
  shipping_binary_sha256="$(binary_sha256 "$SHIPPING_APP_PATH/Contents/MacOS/Harness Monitor")"
  shipping_bundle_sha256="$(bundle_sha256 "$SHIPPING_APP_PATH")"
  shipping_binary_mtime_utc="$(binary_mtime_utc "$SHIPPING_APP_PATH/Contents/MacOS/Harness Monitor")"
fi

if [[ "$host_embedded_commit" != "$git_commit" || "$host_embedded_dirty" != "$git_dirty" || "$host_embedded_workspace_fingerprint" != "$workspace_fingerprint" ]]; then
  if [[ "$SKIP_BUILD" == "1" ]]; then
    printf 'Host build provenance mismatch: expected commit=%s dirty=%s fingerprint=%s but bundle reports commit=%s dirty=%s fingerprint=%s. Continuing because HARNESS_MONITOR_AUDIT_SKIP_BUILD=1.\n' \
      "$git_commit" "$git_dirty" "$workspace_fingerprint" "$host_embedded_commit" "$host_embedded_dirty" "$host_embedded_workspace_fingerprint" >&2
  else
    printf 'Host build provenance mismatch: expected commit=%s dirty=%s fingerprint=%s but bundle reports commit=%s dirty=%s fingerprint=%s\n' \
      "$git_commit" "$git_dirty" "$workspace_fingerprint" "$host_embedded_commit" "$host_embedded_dirty" "$host_embedded_workspace_fingerprint" >&2
    exit 1
  fi
fi

if [[ "$BUILD_SHIPPING" == "1" && ( "$shipping_embedded_commit" != "$git_commit" || "$shipping_embedded_dirty" != "$git_dirty" || "$shipping_embedded_workspace_fingerprint" != "$workspace_fingerprint" ) ]]; then
  if [[ "$SKIP_BUILD" == "1" ]]; then
    printf 'Shipping build provenance mismatch: expected commit=%s dirty=%s fingerprint=%s but bundle reports commit=%s dirty=%s fingerprint=%s. Continuing because HARNESS_MONITOR_AUDIT_SKIP_BUILD=1.\n' \
      "$git_commit" "$git_dirty" "$workspace_fingerprint" "$shipping_embedded_commit" "$shipping_embedded_dirty" "$shipping_embedded_workspace_fingerprint" >&2
  else
    printf 'Shipping build provenance mismatch: expected commit=%s dirty=%s fingerprint=%s but bundle reports commit=%s dirty=%s fingerprint=%s\n' \
      "$git_commit" "$git_dirty" "$workspace_fingerprint" "$shipping_embedded_commit" "$shipping_embedded_dirty" "$shipping_embedded_workspace_fingerprint" >&2
    exit 1
  fi
fi

printf 'Using host binary: %s\n' "$HOST_BINARY_PATH"
printf 'Host SHA256: %s\n' "$host_binary_sha256"
printf 'Host bundle SHA256: %s\n' "$host_bundle_sha256"
printf 'Host mtime (UTC): %s\n' "$host_binary_mtime_utc"
printf 'Workspace fingerprint: %s\n' "$workspace_fingerprint"
printf 'Build started at (UTC): %s\n' "$build_started_at_utc"
printf 'Audit commit stamp: %s dirty=%s\n' "$git_commit" "$git_dirty"
printf 'Audit daemon bundle mode: %s\n' "$AUDIT_DAEMON_BUNDLE_MODE"
if [[ "$AUDIT_DAEMON_BUNDLE_MODE" == "shared-cargo-target" ]]; then
  printf 'Audit daemon Cargo target dir: %s\n' "$AUDIT_DAEMON_CARGO_TARGET_DIR"
fi

stage_launch_host

if [[ ! -x "$STAGED_HOST_BINARY_PATH" ]]; then
  printf 'Expected staged UI-test host binary not found at %s\n' "$STAGED_HOST_BINARY_PATH" >&2
  exit 1
fi

if [[ ! -x "$STAGED_HOST_LAUNCHER_PATH" ]]; then
  printf 'Expected staged host launcher not found at %s\n' "$STAGED_HOST_LAUNCHER_PATH" >&2
  exit 1
fi

printf 'Using staged host app: %s\n' "$STAGED_HOST_APP_PATH"
printf 'Using staged host launcher: %s\n' "$STAGED_HOST_LAUNCHER_PATH"
printf 'Staged host bundle id: %s\n' "$STAGED_HOST_BUNDLE_ID"

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
  local daemon_data_home="$run_dir/app-data/$template_slug/$scenario"
  local capture_log_dir="$run_dir/logs"
  local capture_log_path="$capture_log_dir/${template_slug}-${scenario}.log"
  mkdir -p "$template_dir"
  mkdir -p "$daemon_data_home"
  mkdir -p "$capture_log_dir"
  local trace_path="$template_dir/${scenario}.trace"
  local toc_path="$template_dir/${scenario}.toc.xml"
  local daemon_data_home_env="$DAEMON_DATA_HOME_ENV_KEY=$daemon_data_home"
  local launched_process_path

  printf 'Recording %s / %s (%ss)...\n' "$template" "$scenario" "$duration_seconds"
  assert_audit_source_unchanged "before recording $template / $scenario"
  set +e
  TMPDIR="$xctrace_tmp_root/" xcrun xctrace record \
    --template "$template" \
    --time-limit "${duration_seconds}s" \
    --output "$trace_path" \
    --env "$UI_TESTS_ENV" \
    --env "$daemon_data_home_env" \
    --env "$UI_ACCESSIBILITY_MARKERS_ENV" \
    --env "$KEEP_ANIMATIONS_ENV" \
    --env "$LAUNCH_MODE_ENV" \
    --env "$HIDE_DOCK_ENV" \
    --env "$audit_commit_env" \
    --env "$audit_dirty_env" \
    --env "$audit_run_id_env" \
    --env "$audit_label_env" \
    --env "$audit_workspace_fingerprint_env" \
    --env "$audit_build_started_at_utc_env" \
    --env "HARNESS_MONITOR_PERF_SCENARIO=$scenario" \
    --env "HARNESS_MONITOR_PREVIEW_SCENARIO=$preview_scenario" \
    --env "$WINDOW_WIDTH_ENV" \
    --env "$WINDOW_HEIGHT_ENV" \
    --launch -- "$STAGED_HOST_LAUNCHER_PATH" "$PERSISTENCE_ARG_ONE" "$PERSISTENCE_ARG_TWO" \
    >"$capture_log_path" 2>&1
  local record_status=$?
  set -e

  if [[ ! -d "$trace_path" ]]; then
    printf 'Trace bundle missing for %s / %s\n' "$template" "$scenario" >&2
    exit 1
  fi

  TMPDIR="$xctrace_tmp_root/" xcrun xctrace export --input "$trace_path" --toc >"$toc_path" 2>>"$capture_log_path"
  launched_process_path="$(trace_launched_process_path "$toc_path")"
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
    printf 'xctrace log: %s\n' "$capture_log_path" >&2
    tail -n 40 "$capture_log_path" >&2 || true
    exit "$record_status"
  fi

  if [[ "$launched_process_path" != "$STAGED_HOST_LAUNCHER_PATH" && "$launched_process_path" != "$STAGED_HOST_APP_PATH" && "$launched_process_path" != "$STAGED_HOST_BINARY_PATH" ]]; then
    printf 'xctrace launched unexpected app for %s / %s: expected %s, %s, or %s but trace recorded %s\n' \
      "$template" \
      "$scenario" \
      "$STAGED_HOST_LAUNCHER_PATH" \
      "$STAGED_HOST_APP_PATH" \
      "$STAGED_HOST_BINARY_PATH" \
      "${launched_process_path:-<missing>}" >&2
    exit 1
  fi

  cleanup_host_processes
  assert_audit_source_unchanged "after recording $template / $scenario"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$scenario" "$template" "$duration_seconds" "${trace_path#"$run_dir"/}" \
    "$record_status" "$end_reason" "$preview_scenario" "$launched_process_path" \
    "$daemon_data_home" >>"$capture_records_file"
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
assert_audit_source_unchanged "before writing summary"

xcode_version="$(xcodebuild -version | tr '\n' ';' | sed 's/;*$//')"
xctrace_version="$(xcrun xctrace version | tr '\n' ';' | sed 's/;*$//')"
macos_version="$(sw_vers -productVersion)"
macos_build="$(sw_vers -buildVersion)"
host_arch="$(uname -m)"

python3 - "$run_dir/manifest.json" "$label" "$run_id" "$timestamp" "$git_commit" "$git_dirty" "$workspace_fingerprint" "$build_started_at_utc" "$xcode_version" "$xctrace_version" "$macos_version" "$macos_build" "$host_arch" "$PROJECT_PATH" "$SHIPPING_SCHEME" "$HOST_SCHEME" "$SHIPPING_APP_PATH" "$HOST_APP_PATH" "$HOST_BUNDLE_ID" "$STAGED_HOST_APP_PATH" "$STAGED_HOST_BINARY_PATH" "$STAGED_HOST_LAUNCHER_PATH" "$STAGED_HOST_BUNDLE_ID" "$host_embedded_commit" "$host_embedded_dirty" "$host_embedded_workspace_fingerprint" "$host_embedded_started_at_utc" "$host_binary_sha256" "$host_bundle_sha256" "$host_binary_mtime_utc" "$BUILD_SHIPPING" "$shipping_embedded_commit" "$shipping_embedded_dirty" "$shipping_embedded_workspace_fingerprint" "$shipping_embedded_started_at_utc" "$shipping_binary_sha256" "$shipping_bundle_sha256" "$shipping_binary_mtime_utc" "$SKIP_DAEMON_BUNDLE" "$AUDIT_DAEMON_BUNDLE_MODE" "$AUDIT_DAEMON_CARGO_TARGET_DIR" "$capture_records_file" "$UI_TESTS_ENV" "$UI_ACCESSIBILITY_MARKERS_ENV" "$KEEP_ANIMATIONS_ENV" "$LAUNCH_MODE_ENV" "$WINDOW_WIDTH_ENV" "$WINDOW_HEIGHT_ENV" "$HIDE_DOCK_ENV" "$audit_commit_env" "$audit_dirty_env" "$audit_run_id_env" "$audit_label_env" "$audit_workspace_fingerprint_env" "$audit_build_started_at_utc_env" "$PERSISTENCE_ARG_ONE" "$PERSISTENCE_ARG_TWO" "${selected_scenarios[@]}" <<'PY'
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
    workspace_fingerprint,
    build_started_at_utc,
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
    staged_host_app_path,
    staged_host_binary_path,
    staged_host_launcher_path,
    staged_host_bundle_id,
    host_embedded_commit,
    host_embedded_dirty,
    host_embedded_workspace_fingerprint,
    host_embedded_started_at_utc,
    host_binary_sha256,
    host_bundle_sha256,
    host_binary_mtime_utc,
    shipping_built,
    shipping_embedded_commit,
    shipping_embedded_dirty,
    shipping_embedded_workspace_fingerprint,
    shipping_embedded_started_at_utc,
    shipping_binary_sha256,
    shipping_bundle_sha256,
    shipping_binary_mtime_utc,
    audit_daemon_bundle_requested_skip,
    audit_daemon_bundle_mode,
    audit_daemon_cargo_target_dir,
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
    audit_workspace_fingerprint_env,
    audit_build_started_at_utc_env,
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
        audit_workspace_fingerprint_env,
        audit_build_started_at_utc_env,
    ]
]
default_environment = {key: value for key, value in environment_pairs}
captures = []
for line in Path(capture_records_path).read_text(encoding="utf-8").splitlines():
    if not line.strip():
        continue
    (
        scenario,
        template,
        duration_seconds,
        trace_relpath,
        exit_status,
        end_reason,
        preview_scenario,
        launched_process_path,
        daemon_data_home,
    ) = line.split("\t")
    captures.append(
        {
            "scenario": scenario,
            "template": template,
            "duration_seconds": int(duration_seconds),
            "trace_relpath": trace_relpath,
            "exit_status": int(exit_status),
            "end_reason": end_reason,
            "preview_scenario": preview_scenario,
            "launched_process_path": launched_process_path,
            "environment": {
                **default_environment,
                "HARNESS_DAEMON_DATA_HOME": daemon_data_home,
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
        "workspace_fingerprint": workspace_fingerprint,
        "build_started_at_utc": build_started_at_utc,
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
        "staged_host_app_path": staged_host_app_path,
        "staged_host_binary_path": staged_host_binary_path,
        "staged_host_launcher_path": staged_host_launcher_path,
        "staged_host_bundle_id": staged_host_bundle_id,
    },
    "build_provenance": {
        "audit_daemon_bundle": {
            "requested_skip": audit_daemon_bundle_requested_skip == "1",
            "mode": audit_daemon_bundle_mode,
            "cargo_target_dir": audit_daemon_cargo_target_dir,
        },
        "host": {
            "embedded_commit": host_embedded_commit,
            "embedded_dirty": host_embedded_dirty,
            "embedded_workspace_fingerprint": host_embedded_workspace_fingerprint,
            "embedded_started_at_utc": host_embedded_started_at_utc,
            "binary_sha256": host_binary_sha256,
            "bundle_sha256": host_bundle_sha256,
            "binary_mtime_utc": host_binary_mtime_utc,
        },
        "shipping": {
            "built": shipping_built == "1",
            "embedded_commit": shipping_embedded_commit,
            "embedded_dirty": shipping_embedded_dirty,
            "embedded_workspace_fingerprint": shipping_embedded_workspace_fingerprint,
            "embedded_started_at_utc": shipping_embedded_started_at_utc,
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

prune_run_artifacts "$keep_traces"

printf '\nArtifacts written to %s\n' "$run_dir"
printf 'Summary: %s\n' "$run_dir/summary.json"
if [[ -n "$compare_to" ]]; then
  printf 'Comparison: %s\n' "$run_dir/comparison.md"
fi
printf '\n'
python3 "$SCRIPT_DIR/summarize-instruments-run.py" --run-dir "$run_dir"
