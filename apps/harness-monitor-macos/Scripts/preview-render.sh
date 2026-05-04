#!/usr/bin/env bash
#
# Render a single SwiftUI preview via the xcode-cli MCP bridge and write a
# PNG + metadata JSON under tmp/previews/. Exits non-zero on timeout or
# render failure, after one DerivedData-intermediates reset retry.
#
# Usage:
#   preview-render.sh --list
#   preview-render.sh --id <EntryID>
#   preview-render.sh --file <path> --index <N> [--out <png-path>]
#                     [--theme auto|light|dark]
#                     [--text-size 0-6|xs|small|medium|default|large|xl|largest]
#                     [--time-zone local|utc|<IANA-zone>]
#
# Environment:
#   PREVIEW_TIMEOUT_SECONDS  render timeout (default 240)
#   PREVIEW_CALL_TIMEOUT_MS  xcode-cli call timeout in ms (default: render timeout + 30s)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_DIR/../.." && pwd)"
MANIFEST="$PROJECT_DIR/Previews.json"
OUT_DIR="$PROJECT_DIR/tmp/previews"
TIMEOUT="${PREVIEW_TIMEOUT_SECONDS:-240}"
CALL_TIMEOUT_MS="${PREVIEW_CALL_TIMEOUT_MS:-$(((TIMEOUT * 1000) + 30000))}"
XCODE_PROJECT_PATH_PREFIX="apps/HarnessMonitor/Project/"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required tool '$1' not installed" >&2
    echo "  xcode-cli:     npm install -g xcode-cli" >&2
    echo "  jq:            brew install jq" >&2
    exit 127
  }
}

require jq

normalize_entry_file() {
  local candidate="$1"
  local app_prefix="apps/harness-monitor-macos/"

  if [[ "$candidate" == "$XCODE_PROJECT_PATH_PREFIX"* ]]; then
    candidate="${candidate#"$XCODE_PROJECT_PATH_PREFIX"}"
  fi

  if [[ "$candidate" == /* ]]; then
    if [[ "$candidate" == "$PROJECT_DIR/"* ]]; then
      printf '%s\n' "${candidate#"$PROJECT_DIR"/}"
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
      printf '%s\n' "${candidate#"$app_prefix"}"
      return 0
    fi
  fi

  echo "error: preview file '$candidate' must be app-relative, repo-root-relative, or absolute within this repo" >&2
  exit 1
}

xcode_project_file() {
  local app_relative="$1"
  printf '%s%s\n' "$XCODE_PROJECT_PATH_PREFIX" "$app_relative"
}

resolve_output_path() {
  local candidate="$1"

  if [[ "$candidate" != *.png ]]; then
    candidate="${candidate}.png"
  fi

  if [[ "$candidate" != /* ]]; then
    candidate="$(pwd)/$candidate"
  fi

  printf '%s\n' "$candidate"
}

resolve_text_size_index() {
  local raw
  raw="$(printf '%s' "$1" | /usr/bin/tr '[:upper:]' '[:lower:]')"

  case "$raw" in
    0|xs|extra-small|extra_small)
      printf '0\n'
      ;;
    1|small|sm)
      printf '1\n'
      ;;
    2|medium|md)
      printf '2\n'
      ;;
    3|default|normal)
      printf '3\n'
      ;;
    4|large|lg)
      printf '4\n'
      ;;
    5|xl|extra-large|extra_large)
      printf '5\n'
      ;;
    6|largest|xxl)
      printf '6\n'
      ;;
    *)
      echo "error: unsupported text size '$1' (use 0-6, xs, small, medium, default, large, xl, or largest)" >&2
      exit 2
      ;;
  esac
}

print_manifest_entries() {
  [[ -f "$MANIFEST" ]] || { echo "error: manifest not found at $MANIFEST" >&2; exit 1; }
  jq -r '.entries[] | [.id, (.index | tostring), .file, .description] | @tsv' "$MANIFEST" \
    | /usr/bin/awk -F '\t' '
      BEGIN {
        printf "%-38s %-5s %-72s %s\n", "ID", "IDX", "FILE", "DESCRIPTION"
      }
      {
        printf "%-38s %-5s %-72s %s\n", $1, $2, $3, $4
      }
    '
}

list_entries=0
entry_id=""
entry_file=""
entry_index=""
output_path=""
theme_mode=""
text_size_index=""
time_zone_mode=""
custom_time_zone=""

while (( $# > 0 )); do
  case "$1" in
    --list)
      list_entries=1
      shift
      ;;
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
    --out)
      output_path="${2:?--out requires value}"
      shift 2
      ;;
    --theme)
      theme_mode="${2:?--theme requires value}"
      case "$theme_mode" in
        auto|light|dark)
          ;;
        *)
          echo "error: unsupported theme '$theme_mode' (use auto, light, or dark)" >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    --text-size)
      text_size_index="$(resolve_text_size_index "${2:?--text-size requires value}")"
      shift 2
      ;;
    --time-zone)
      case "${2:?--time-zone requires value}" in
        local|utc)
          time_zone_mode="$2"
          custom_time_zone=""
          ;;
        *)
          time_zone_mode="custom"
          custom_time_zone="$2"
          ;;
      esac
      shift 2
      ;;
    -h|--help)
      sed -n '3,22p' "$0"
      exit 0
      ;;
    *)
      echo "error: unknown arg '$1'" >&2
      exit 2
      ;;
  esac
done

if (( list_entries )); then
  print_manifest_entries
  exit 0
fi

require xcode-cli

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

if [[ -n "$output_path" ]]; then
  png_path="$(resolve_output_path "$output_path")"
  meta_path="${png_path%.png}.json"
else
  mkdir -p "$OUT_DIR"
  png_path="$OUT_DIR/$entry_id.png"
  meta_path="$OUT_DIR/$entry_id.json"
fi
stderr_path="${png_path%.png}.stderr"
mkdir -p "$(dirname "$png_path")"

run_once() {
  local attempt="$1"
  local started
  local ended
  local duration
  local rc=0
  local classification="unknown"
  local stderr_file="$stderr_path"
  local xcode_entry_file
  local -a preview_env=("XCODE_BUILD_SERVER_SCHEME=HarnessMonitorUIPreviews")
  [[ -n "$theme_mode" ]] && preview_env+=("HARNESS_MONITOR_THEME_MODE_OVERRIDE=$theme_mode")
  [[ -n "$text_size_index" ]] && preview_env+=("HARNESS_MONITOR_TEXT_SIZE_OVERRIDE=$text_size_index")
  [[ -n "$time_zone_mode" ]] && preview_env+=("HARNESS_MONITOR_TIME_ZONE_MODE_OVERRIDE=$time_zone_mode")
  [[ -n "$custom_time_zone" ]] && preview_env+=("HARNESS_MONITOR_CUSTOM_TIME_ZONE_OVERRIDE=$custom_time_zone")
  xcode_entry_file="$(xcode_project_file "$entry_file")"
  started=$(date +%s)
  if (cd "$PROJECT_DIR" && env "${preview_env[@]}" xcode-cli --timeout "$CALL_TIMEOUT_MS" preview "$xcode_entry_file" \
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
  elif grep -q -i "error:\|cannot find\|undeclared\|CompileDylibError\|File not found in project structure" "$stderr_file"; then
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
    --arg output_png "$png_path" \
    --arg theme_mode "$theme_mode" \
    --arg text_size_index "$text_size_index" \
    --arg time_zone_mode "$time_zone_mode" \
    --arg custom_time_zone "$custom_time_zone" \
    '{
      id:$id,
      file:$file,
      index:$index,
      classification:$classification,
      rc:$rc,
      duration_seconds:$duration,
      attempt:$attempt,
      output_png:$output_png,
      theme_mode:(if $theme_mode == "" then null else $theme_mode end),
      text_size_index:(if $text_size_index == "" then null else ($text_size_index | tonumber) end),
      time_zone_mode:(if $time_zone_mode == "" then null else $time_zone_mode end),
      custom_time_zone:(if $custom_time_zone == "" then null else $custom_time_zone end)
    }' \
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
