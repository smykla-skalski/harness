#!/usr/bin/env bash
set -euo pipefail

# Verify every UI-test source helper that boots the Monitor app passes
# `-ApplePersistenceIgnoreState YES`. xctestrun captures only authored
# CommandLineArguments; the launch arg is appended at runtime in the swift
# test sources, so the proof is a static grep over those files.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/recording-triage/lib-recording-triage.sh
. "$SCRIPT_DIR/lib-recording-triage.sh"

usage() {
  cat <<'EOF' >&2
usage: assert-launch-args.sh --run <path> [--repo-root <path>]
  --run         triage run dir; report lands in <run>/recording-triage/
  --repo-root   alternate repo root (defaults to the active checkout)
EOF
  exit 64
}

RUN_DIR=""
REPO_ROOT_OVERRIDE=""
while (($#)); do
  case "$1" in
    --run) RUN_DIR="$2"; shift 2 ;;
    --repo-root) REPO_ROOT_OVERRIDE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

recording_triage_require_run_dir "$RUN_DIR"
REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(recording_triage_repo_root)}"

# Every Swift source under these test roots that calls launchArguments must
# pass the persistence flag. Add new roots here as they appear.
declare -a SEARCH_ROOTS=(
  "$REPO_ROOT/apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests"
  "$REPO_ROOT/apps/harness-monitor-macos/Tests/HarnessMonitorUITestSupport"
)

WORK_DIR="$(mktemp -d -t recording-triage-launch-args.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT
ENTRIES_FILE="$WORK_DIR/entries.json"
printf '[]' >"$ENTRIES_FILE"

shopt -s nullglob
all_configured=true
any_match=false
for root in "${SEARCH_ROOTS[@]}"; do
  if [[ ! -d "$root" ]]; then
    continue
  fi
  while IFS= read -r -d '' file; do
    # Only flag files that actually call launchArguments; helpers without that
    # API don't need the flag.
    if ! grep -q "launchArguments" "$file"; then
      continue
    fi
    any_match=true
    if grep -q '"-ApplePersistenceIgnoreState"' "$file" \
      && grep -q '"YES"' "$file"; then
      verdict=true
    else
      verdict=false
      all_configured=false
    fi
    rel="${file#"$REPO_ROOT/"}"
    next="$WORK_DIR/entries-next.json"
    jq --arg path "$rel" --argjson hasFlag "$verdict" \
      '. + [{ path: $path, hasPersistenceIgnoreState: $hasFlag }]' \
      "$ENTRIES_FILE" >"$next"
    mv "$next" "$ENTRIES_FILE"
  done < <(find "$root" -type f -name '*.swift' -print0)
done

if [[ "$any_match" != "true" ]]; then
  all_configured=false
fi

OUTPUT_DIR="$(recording_triage_output_dir "$RUN_DIR")"
mkdir -p "$OUTPUT_DIR"
REPORT="$OUTPUT_DIR/launch-args.json"

jq --argjson allConfigured "$all_configured" \
  '{ allConfigured: $allConfigured, files: . }' \
  "$ENTRIES_FILE" >"$REPORT"

printf 'assert-launch-args -> %s (allConfigured=%s)\n' "$REPORT" "$all_configured"
