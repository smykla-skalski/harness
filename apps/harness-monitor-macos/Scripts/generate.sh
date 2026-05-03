#!/bin/bash
set -euo pipefail

# Canonical Harness Monitor project generator. Runs Tuist to materialize the
# Xcode project, then post-generate.sh to write buildServer.json and sync
# version metadata. Invoked by mise (monitor:generate) and by the
# scripts that need a generated project as a precondition.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$ROOT/../.." && pwd)"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/swift-tool-env.sh
source "$SCRIPT_DIR/lib/swift-tool-env.sh"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/runtime-profile.sh
source "$SCRIPT_DIR/lib/runtime-profile.sh"
sanitize_xcode_only_swift_environment

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

# `contents.xcworkspacedata` is effectively static for this single-project
# workspace and often remains untouched across legitimate Tuist refreshes.
# Using its mtime as a freshness oracle over-blocks non-owner agent lanes, so
# track the pbxproj instead.
tuist_generation_freshness_outputs=(
  "$ROOT/HarnessMonitor.xcodeproj/project.pbxproj"
)

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

latest_mtime() {
  local latest=0 path mtime
  for path in "$@"; do
    mtime="$(/usr/bin/stat -f '%m' "$path")"
    if (( mtime > latest )); then
      latest="$mtime"
    fi
  done
  printf '%s\n' "$latest"
}

oldest_mtime() {
  local oldest=0 first=1 path mtime
  for path in "$@"; do
    mtime="$(/usr/bin/stat -f '%m' "$path")"
    if (( first )) || (( mtime < oldest )); then
      oldest="$mtime"
      first=0
    fi
  done
  printf '%s\n' "$oldest"
}

profiled_non_owner_lane() {
  local profile
  profile="$(harness_monitor_runtime_profile || true)"
  [[ -n "$profile" && "${HARNESS_MONITOR_OWNS_WORKSPACE:-0}" != "1" ]]
}

should_generate() {
  local latest_input oldest_output output

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

  latest_input="$(latest_mtime "${tuist_generation_inputs[@]}")"
  oldest_output="$(oldest_mtime "${tuist_generation_freshness_outputs[@]}")"
  (( latest_input > oldest_output ))
}

if should_generate; then
  # The generated project lives in the shared checkout. Profile-scoped lanes
  # that do not own the workspace may consume existing outputs, but only the
  # workspace owner (or an unscoped maintenance lane) may refresh them.
  if profiled_non_owner_lane; then
    echo "profile-scoped non-owner lanes must not regenerate the shared Harness Monitor Xcode project; run apps/harness-monitor-macos/Scripts/user-runtime-profile.sh apps/harness-monitor-macos/Scripts/generate.sh from the workspace-owning user lane first" >&2
    exit 1
  fi

  TUIST_BIN="${TUIST_BIN:-$(type -P tuist || true)}"
  if [ -z "$TUIST_BIN" ]; then
    echo "tuist is required on PATH (pinned via mise)" >&2
    exit 1
  fi

  if [ ! -d "$ROOT/Tuist/.build" ]; then
    run_with_sanitized_xcode_only_swift_environment "$TUIST_BIN" install --path "$ROOT"
  fi

  run_with_sanitized_xcode_only_swift_environment "$TUIST_BIN" generate --no-open --path "$ROOT"
fi

"$SCRIPT_DIR/post-generate.sh"
