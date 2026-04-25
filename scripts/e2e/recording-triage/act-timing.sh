#!/usr/bin/env bash
set -euo pipefail

# Convert per-act marker mtimes inside `<run-dir>/context/sync-root/e2e-sync`
# into recording-relative offsets. Reads the recording start from the first
# `recording-started` line in `<run-dir>/screen-recording.log` and the app
# launch time from the first ISO timestamp in `<run-dir>/logs/daemon.log`.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/recording-triage/lib-recording-triage.sh
. "$SCRIPT_DIR/lib-recording-triage.sh"

usage() {
  cat <<'EOF' >&2
usage: act-timing.sh --run <path>
  --run     triage run dir containing context/sync-root/e2e-sync, logs/, screen-recording.log
EOF
  exit 64
}

RUN_DIR=""
while (($#)); do
  case "$1" in
    --run) RUN_DIR="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

recording_triage_require_run_dir "$RUN_DIR"
REPO_ROOT="$(recording_triage_repo_root)"
BINARY="$(recording_triage_resolve_binary "$REPO_ROOT")"

MARKER_DIR="$RUN_DIR/context/sync-root/e2e-sync"
SCREEN_LOG="$RUN_DIR/screen-recording.log"
DAEMON_LOG="$RUN_DIR/logs/daemon.log"
for required in "$MARKER_DIR" "$SCREEN_LOG" "$DAEMON_LOG"; do
  if [[ ! -e "$required" ]]; then
    printf 'error: missing input: %s\n' "$required" >&2
    exit 1
  fi
done

# Strip ANSI escape sequences (\x1b[...m) before grepping; tracing output in
# daemon.log wraps the leading ISO timestamp in colour codes.
strip_ansi() {
  sed -E 's/\x1b\[[0-9;]*m//g'
}

iso_to_epoch() {
  local iso="$1"
  python3 - "$iso" <<'PY'
import datetime
import sys

raw = sys.argv[1]
if raw.endswith("Z"):
    raw = raw[:-1] + "+00:00"
# Drop sub-second precision below microseconds; fromisoformat tolerates 6-digit
# fractions but anything finer fails.
if "." in raw:
    head, frac = raw.split(".", 1)
    if "+" in frac or "-" in frac:
        # frac is like "123456+00:00"; preserve offset
        for sep in ("+", "-"):
            idx = frac.find(sep, 1)
            if idx != -1:
                digits = frac[:idx]
                offset = frac[idx:]
                break
        digits = digits[:6]
        frac = digits + offset
    else:
        frac = frac[:6]
    raw = head + "." + frac
print(datetime.datetime.fromisoformat(raw).timestamp())
PY
}

REC_LINE="$(grep -m1 'recording-started' "$SCREEN_LOG" || true)"
if [[ -z "$REC_LINE" ]]; then
  printf 'error: no recording-started line in %s\n' "$SCREEN_LOG" >&2
  exit 1
fi
REC_ISO="${REC_LINE%% *}"

LAUNCH_LINE="$(strip_ansi <"$DAEMON_LOG" | grep -m1 -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' || true)"
if [[ -z "$LAUNCH_LINE" ]]; then
  printf 'error: no ISO timestamp in %s\n' "$DAEMON_LOG" >&2
  exit 1
fi
LAUNCH_ISO="${LAUNCH_LINE%% *}"

REC_EPOCH="$(iso_to_epoch "$REC_ISO")"
LAUNCH_EPOCH="$(iso_to_epoch "$LAUNCH_ISO")"

OUTPUT_DIR="$(recording_triage_output_dir "$RUN_DIR")"
mkdir -p "$OUTPUT_DIR"
REPORT="$OUTPUT_DIR/act-timing.json"

"$BINARY" recording-triage act-timing \
  --marker-dir "$MARKER_DIR" \
  --recording-start "$REC_EPOCH" \
  --app-launch "$LAUNCH_EPOCH" >"$REPORT"

printf 'act-timing -> %s\n' "$REPORT"
