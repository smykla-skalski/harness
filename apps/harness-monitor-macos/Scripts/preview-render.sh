#!/usr/bin/env bash
#
# Render a single SwiftUI preview via the xcode-cli MCP bridge and write a
# PNG + metadata JSON under tmp/previews/. Exits non-zero on timeout or
# render failure, after one DerivedData-intermediates reset retry.
#
# Usage:
#   preview-render.sh --id <EntryID>
#   preview-render.sh --file <path> --index <N>
#
# Environment:
#   PREVIEW_TIMEOUT_SECONDS  render timeout (default 120)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_DIR/../.." && pwd)"
MANIFEST="$PROJECT_DIR/Previews.json"
OUT_DIR="$PROJECT_DIR/tmp/previews"
TIMEOUT="${PREVIEW_TIMEOUT_SECONDS:-120}"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required tool '$1' not installed" >&2
    echo "  xcode-cli:     npm install -g xcode-cli" >&2
    echo "  jq:            brew install jq" >&2
    exit 127
  }
}

require xcode-cli
require jq

normalize_entry_file() {
  local candidate="$1"
  local app_prefix="apps/harness-monitor-macos/"

  if [[ "$candidate" == /* ]]; then
    if [[ "$candidate" == "$PROJECT_DIR/"* ]]; then
      printf '%s\n' "${candidate#$PROJECT_DIR/}"
      return 0
    fi
    if [[ "$candidate" == "$REPO_ROOT/$app_prefix"* ]]; then
      printf '%s\n' "${candidate#"$REPO_ROOT/$app_prefix"}"
      return 0
    fi
  else
    if [[ -f "$PROJECT_DIR/$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    if [[ "$candidate" == "$app_prefix"* && -f "$REPO_ROOT/$candidate" ]]; then
      printf '%s\n' "${candidate#$app_prefix}"
      return 0
    fi
  fi

  echo "error: preview file '$candidate' must be app-relative, repo-root-relative, or absolute within this repo" >&2
  exit 1
}

entry_id=""
entry_file=""
entry_index=""

while (( $# > 0 )); do
  case "$1" in
    --id)
      entry_id="${2:?--id requires value}"
      shift 2
      ;;
    --file)
      entry_file="${2:?--file requires value}"
      shift 2
      ;;
    --index)
      entry_index="${2:?--index requires value}"
      shift 2
      ;;
    -h|--help)
      sed -n '3,18p' "$0"
      exit 0
      ;;
    *)
      echo "error: unknown arg '$1'" >&2
      exit 2
      ;;
  esac
done

if [[ -n "$entry_id" ]]; then
  [[ -f "$MANIFEST" ]] || { echo "error: manifest not found at $MANIFEST" >&2; exit 1; }
  entry_json=$(jq --arg id "$entry_id" '.entries[] | select(.id == $id)' "$MANIFEST")
  if [[ -z "$entry_json" ]]; then
    echo "error: id '$entry_id' not in $MANIFEST" >&2
    exit 1
  fi
  entry_file=$(printf '%s' "$entry_json" | jq -r '.file')
  entry_index=$(printf '%s' "$entry_json" | jq -r '.index // 0')
elif [[ -n "$entry_file" ]]; then
  entry_index="${entry_index:-0}"
else
  echo "error: must pass --id <EntryID> or --file <path>" >&2
  exit 2
fi

entry_file="$(normalize_entry_file "$entry_file")"
entry_id="${entry_id:-$(basename "$entry_file" .swift)@${entry_index:-0}}"

mkdir -p "$OUT_DIR"
png_path="$OUT_DIR/$entry_id.png"
meta_path="$OUT_DIR/$entry_id.json"

run_once() {
  local attempt="$1"
  local started
  local ended
  local duration
  local rc=0
  local classification="unknown"
  local stderr_file="$OUT_DIR/$entry_id.stderr"
  started=$(date +%s)
  if (cd "$PROJECT_DIR" && xcode-cli preview "$entry_file" \
      --index "$entry_index" \
      --render-timeout "$TIMEOUT" \
      --out "$png_path") \
      > "$stderr_file" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  ended=$(date +%s)
  duration=$((ended - started))
  if (( rc == 0 )); then
    classification="ok"
  elif grep -q -i "timeout\|AppLaunchTimeoutError" "$stderr_file"; then
    classification="timeout"
  elif grep -q -i "error:\|cannot find\|undeclared" "$stderr_file"; then
    classification="compile"
  else
    classification="runtime"
  fi
  jq -n \
    --arg id "$entry_id" \
    --arg file "$entry_file" \
    --argjson index "$entry_index" \
    --arg classification "$classification" \
    --argjson rc "$rc" \
    --argjson duration "$duration" \
    --argjson attempt "$attempt" \
    '{id:$id, file:$file, index:$index, classification:$classification, rc:$rc, duration_seconds:$duration, attempt:$attempt}' \
    > "$meta_path"
  return $rc
}

reset_intermediates() {
  local cache="$PROJECT_DIR/Build/Intermediates.noindex/HarnessMonitor.build"
  [[ -d "$cache" ]] || return 0
  echo "info: resetting $cache before retry" >&2
  rm -rf "$cache"
}

if run_once 1; then
  echo "$png_path"
  exit 0
fi

echo "warning: first attempt failed; resetting intermediates and retrying" >&2
reset_intermediates
if run_once 2; then
  echo "$png_path"
  exit 0
fi

echo "error: preview render failed for $entry_id (see $meta_path)" >&2
exit 1
