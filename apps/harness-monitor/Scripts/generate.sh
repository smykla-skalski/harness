#!/bin/bash
set -euo pipefail

# Canonical Harness Monitor project generator. Runs Tuist to materialize the
# Xcode project, then post-generate.sh to write buildServer.json and sync
# version metadata. Invoked by mise (monitor:generate) and by the
# scripts that need a generated project as a precondition.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$ROOT/../.." && pwd)"
# shellcheck source=apps/harness-monitor/Scripts/lib/swift-tool-env.sh
source "$SCRIPT_DIR/lib/swift-tool-env.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/monitor-lanes.sh
source "$SCRIPT_DIR/lib/monitor-lanes.sh"
sanitize_xcode_only_swift_environment
harness_monitor_apply_runtime_lane_environment "$REPO_ROOT"

tuist_generation_inputs=(
  "$ROOT/Project.swift"
)

if [ -f "$ROOT/Tuist.swift" ]; then
  tuist_generation_inputs+=("$ROOT/Tuist.swift")
fi

while IFS= read -r path; do
  tuist_generation_inputs+=("$path")
done < <(
  /usr/bin/find "$ROOT/Tuist" \
    -path "$ROOT/Tuist/.build" -prune -o \
    -type f -print \
    | /usr/bin/sort
)

# These outputs are materialized by `tuist generate` itself. `post-generate.sh`
# always runs below and patches/syncs shared metadata in-place, so script-only
# changes must not force a full regenerate.
tuist_generation_required_outputs=(
  "$ROOT/HarnessMonitor.xcodeproj/project.pbxproj"
  "$ROOT/HarnessMonitor.xcworkspace/contents.xcworkspacedata"
)

tuist_generation_state_path="$ROOT/Tuist/.build/.generate-source-state"

remove_legacy_spotlight_link() {
  local path="$1"
  local link_target

  link_target="$(readlink "$path" || true)"
  if [[ "$link_target" == *".spotlight-build-artifacts.noindex"* ]]; then
    /bin/rm -f "$path"
  fi
}

remove_legacy_spotlight_link "$ROOT/HarnessMonitor.xcodeproj"
remove_legacy_spotlight_link "$ROOT/HarnessMonitor.xcworkspace"
remove_legacy_spotlight_link "$ROOT/.build"
remove_legacy_spotlight_link "$ROOT/.sourcekit-lsp"
remove_legacy_spotlight_link "$ROOT/Derived"
remove_legacy_spotlight_link "$ROOT/DerivedData"
remove_legacy_spotlight_link "$ROOT/build"
remove_legacy_spotlight_link "$ROOT/tmp"
remove_legacy_spotlight_link "$ROOT/xcode-derived"
remove_legacy_spotlight_link "$ROOT/Tuist/.build"
remove_legacy_spotlight_link "$ROOT/Tools/HarnessMonitorE2E/.build"
remove_legacy_spotlight_link "$ROOT/Tools/HarnessMonitorPerf/.build"
remove_legacy_spotlight_link "$REPO_ROOT/.cache"
remove_legacy_spotlight_link "$REPO_ROOT/.claude/worktrees/tmp/xcode-derived"
remove_legacy_spotlight_link "$REPO_ROOT/.claude/worktrees/xcode-derived"
remove_legacy_spotlight_link "$REPO_ROOT/.opencode/node_modules"
remove_legacy_spotlight_link "$REPO_ROOT/.playwright-cli"
remove_legacy_spotlight_link "$REPO_ROOT/_artifacts"
remove_legacy_spotlight_link "$REPO_ROOT/mcp-servers/harness-monitor-registry/.build"
remove_legacy_spotlight_link "$REPO_ROOT/output"

tuist_env_fingerprint() {
  local tuist_bin="${TUIST_BIN:-$(type -P tuist || true)}"
  local tuist_bin_digest="missing"

  if [ -n "$tuist_bin" ] && [ -x "$tuist_bin" ]; then
    tuist_bin_digest="$(
      /usr/bin/shasum -a 256 "$tuist_bin" 2>/dev/null \
        | /usr/bin/awk '{print $1}' \
        || true
    )"
  fi

  {
    printf 'TUIST_BIN=%s\n' "${tuist_bin:-missing}"
    printf 'TUIST_BIN_DIGEST=%s\n' "${tuist_bin_digest:-unknown}"
    printf 'DEVELOPER_DIR=%s\n' "${DEVELOPER_DIR:-}"
    printf 'XCODEBUILD_DERIVED_DATA_PATH=%s\n' "${XCODEBUILD_DERIVED_DATA_PATH:-}"
  } | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

tuist_generation_input_fingerprint() {
  local path rel_path file_digest
  local env_fingerprint
  env_fingerprint="$(tuist_env_fingerprint)"

  {
    printf 'ENV %s\n' "$env_fingerprint"
    for path in "${tuist_generation_inputs[@]}"; do
      rel_path="${path#$ROOT/}"
      file_digest="$(
        /usr/bin/shasum -a 256 "$path" \
          | /usr/bin/awk '{print $1}'
      )"
      printf '%s %s\n' "$rel_path" "$file_digest"
    done
  } | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

tuist_generation_state_matches() {
  local expected_fingerprint="$1"
  local recorded_fingerprint

  if [ ! -f "$tuist_generation_state_path" ]; then
    return 1
  fi

  recorded_fingerprint="$(/bin/cat "$tuist_generation_state_path" 2>/dev/null || true)"
  [ "$recorded_fingerprint" = "$expected_fingerprint" ]
}

write_tuist_generation_state() {
  local fingerprint="$1"
  local temp_state

  /bin/mkdir -p "$ROOT/Tuist/.build"
  temp_state="${tuist_generation_state_path}.tmp.$$"
  printf '%s\n' "$fingerprint" > "$temp_state"
  /bin/mv "$temp_state" "$tuist_generation_state_path"
}

should_generate() {
  local output current_fingerprint

  case "${HARNESS_MONITOR_FORCE_GENERATE:-0}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
  esac

  if [ ! -d "$ROOT/Tuist/.build" ]; then
    return 0
  fi

  for output in "${tuist_generation_required_outputs[@]}"; do
    if [ ! -e "$output" ]; then
      return 0
    fi
  done

  current_fingerprint="$(tuist_generation_input_fingerprint)"
  if tuist_generation_state_matches "$current_fingerprint"; then
    return 1
  fi

  return 0
}

should_install_tuist_dependencies() {
  local checkouts_root repositories_root
  checkouts_root="$ROOT/Tuist/.build/checkouts"
  repositories_root="$ROOT/Tuist/.build/repositories"

  if [ ! -d "$ROOT/Tuist/.build" ]; then
    return 0
  fi

  if [ ! -d "$checkouts_root" ] || [ ! -d "$repositories_root" ]; then
    return 0
  fi

  if [ ! -f "$ROOT/Tuist/.build/workspace-state.json" ]; then
    return 0
  fi

  if [ -z "$(/usr/bin/find "$checkouts_root" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    return 0
  fi

  return 1
}

if should_generate; then
  harness_monitor_reject_legacy_profile_env

  TUIST_BIN="${TUIST_BIN:-$(type -P tuist || true)}"
  if [ -z "$TUIST_BIN" ]; then
    echo "tuist is required on PATH (pinned via mise)" >&2
    exit 1
  fi

  if should_install_tuist_dependencies; then
    run_with_sanitized_xcode_only_swift_environment "$TUIST_BIN" install --path "$ROOT"
  fi

  run_with_sanitized_xcode_only_swift_environment "$TUIST_BIN" generate --no-open --path "$ROOT"

  write_tuist_generation_state "$(tuist_generation_input_fingerprint)"
fi

"$SCRIPT_DIR/post-generate.sh"
