#!/usr/bin/env bash
set -euo pipefail

# Compare recording bounds against the daemon log's app launch / terminate
# markers. Lines we look for:
#   app launched pid=...
#   app terminated reason=...

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/lib.sh
. "$SCRIPT_DIR/../lib.sh"
# shellcheck source=scripts/e2e/recording-triage/lib-recording-triage.sh
. "$SCRIPT_DIR/lib-recording-triage.sh"

usage() {
  cat <<'EOF' >&2
usage: detect-dead-head-tail.sh --run <path> [--threshold <seconds>]
  --run         triage run dir
  --threshold   leading/trailing dead-time threshold in seconds (default 5)
EOF
  exit 64
}

RUN_DIR=""
THRESHOLD="5"
while (($#)); do
  case "$1" in
    --run) RUN_DIR="$2"; shift 2 ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

recording_triage_require_run_dir "$RUN_DIR"
e2e_require_command ffprobe
REPO_ROOT="$(recording_triage_repo_root)"
BINARY="$(recording_triage_resolve_binary "$REPO_ROOT")"

RECORDING="$RUN_DIR/swarm-full-flow.mov"
DAEMON_LOG="$RUN_DIR/logs/daemon.log"
OUTPUT_DIR="$(recording_triage_output_dir "$RUN_DIR")"
mkdir -p "$OUTPUT_DIR"
REPORT="$OUTPUT_DIR/dead-head-tail.json"

if [[ ! -s "$DAEMON_LOG" ]]; then
  jq -nc --arg log "$DAEMON_LOG" \
    '{status:"skipped", reason:"daemon.log missing", log:$log}' >"$REPORT"
  printf 'detect-dead-head-tail: skipped (no daemon log)\n'
  exit 0
fi

DURATION="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$RECORDING")"
RECORDING_START="$(stat -f%B "$RECORDING" 2>/dev/null || stat -c%Y "$RECORDING")"
RECORDING_END="$(awk -v start="$RECORDING_START" -v dur="$DURATION" 'BEGIN { printf "%.6f", start + dur }')"

extract_epoch() {
  local marker="$1"
  awk -v marker="$marker" '$0 ~ marker { print $1; exit }' "$DAEMON_LOG"
}

APP_LAUNCH_RAW="$(extract_epoch 'app launched' || true)"
APP_TERMINATE_RAW="$(extract_epoch 'app terminated' || true)"

if [[ -z "$APP_LAUNCH_RAW" || -z "$APP_TERMINATE_RAW" ]]; then
  jq -nc --arg log "$DAEMON_LOG" \
    '{status:"skipped", reason:"missing launch/terminate markers", log:$log}' >"$REPORT"
  printf 'detect-dead-head-tail: skipped (no markers in daemon.log)\n'
  exit 0
fi

# Daemon timestamps are ISO-8601 UTC; convert with date -j.
to_epoch() {
  date -juf "%Y-%m-%dT%H:%M:%SZ" "$1" "+%s" 2>/dev/null \
    || date -d "$1" "+%s"
}

APP_LAUNCH_EPOCH="$(to_epoch "$APP_LAUNCH_RAW")"
APP_TERMINATE_EPOCH="$(to_epoch "$APP_TERMINATE_RAW")"

"$BINARY" recording-triage dead-head-tail \
  --recording-start "$RECORDING_START" \
  --recording-end "$RECORDING_END" \
  --app-launch "$APP_LAUNCH_EPOCH" \
  --app-terminate "$APP_TERMINATE_EPOCH" \
  --threshold "$THRESHOLD" >"$REPORT"

printf 'detect-dead-head-tail -> %s\n' "$REPORT"
