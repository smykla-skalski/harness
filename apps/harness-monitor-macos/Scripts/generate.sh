#!/bin/bash
set -euo pipefail

# Canonical Harness Monitor project generator. Runs Tuist to materialize the
# Xcode project, then post-generate.sh to write buildServer.json and sync
# version metadata. Invoked by mise (monitor:macos:generate) and by the
# scripts that need a generated project as a precondition.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$ROOT/../.." && pwd)"

TUIST_BIN="${TUIST_BIN:-$(command -v tuist || true)}"
if [ -z "$TUIST_BIN" ]; then
  echo "tuist is required on PATH (pinned via mise)" >&2
  exit 1
fi

generation_inputs=(
  "$ROOT/Project.swift"
  "$ROOT/Scripts/post-generate.sh"
  "$ROOT/Scripts/patch-tuist-pbxproj.py"
)

if [ -f "$ROOT/Tuist.swift" ]; then
  generation_inputs+=("$ROOT/Tuist.swift")
fi

while IFS= read -r path; do
  generation_inputs+=("$path")
done < <(
  /usr/bin/find "$ROOT/Tuist" \
    -path "$ROOT/Tuist/.build" -prune -o \
    -type f -print \
    | /usr/bin/sort
)

generation_outputs=(
  "$ROOT/HarnessMonitor.xcodeproj/project.pbxproj"
  "$ROOT/HarnessMonitor.xcworkspace/contents.xcworkspacedata"
  "$ROOT/HarnessMonitor.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings"
  "$ROOT/buildServer.json"
  "$REPO_ROOT/buildServer.json"
)

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

should_generate() {
  local latest_input oldest_output output

  case "${HARNESS_MONITOR_FORCE_GENERATE:-0}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
  esac

  if [ ! -d "$ROOT/Tuist/.build" ]; then
    return 0
  fi

  for output in "${generation_outputs[@]}"; do
    if [ ! -e "$output" ]; then
      return 0
    fi
  done

  latest_input="$(latest_mtime "${generation_inputs[@]}")"
  oldest_output="$(oldest_mtime "${generation_outputs[@]}")"
  (( latest_input > oldest_output ))
}

if should_generate; then
  if [ ! -d "$ROOT/Tuist/.build" ]; then
    "$TUIST_BIN" install --path "$ROOT"
  fi

  "$TUIST_BIN" generate --no-open --path "$ROOT"
  "$SCRIPT_DIR/post-generate.sh"
fi
