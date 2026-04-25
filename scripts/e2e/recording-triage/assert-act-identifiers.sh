#!/usr/bin/env bash
set -euo pipefail

# Walk the run's per-act marker payloads + ui-snapshots hierarchies and emit
# act-identifiers.json with per-act ChecklistFinding rows + whole-run invariant
# verdicts. The wrapper is a thin dispatch over `harness-monitor-e2e
# recording-triage act-identifiers`.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/recording-triage/lib-recording-triage.sh
. "$SCRIPT_DIR/lib-recording-triage.sh"

usage() {
  cat <<'EOF' >&2
usage: assert-act-identifiers.sh --run <path>
  --run     triage run dir containing context/sync-root/e2e-sync and ui-snapshots
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
SNAPSHOT_DIR="$RUN_DIR/ui-snapshots"
if [[ ! -d "$MARKER_DIR" ]]; then
  printf 'error: marker dir missing: %s\n' "$MARKER_DIR" >&2
  exit 1
fi
if [[ ! -d "$SNAPSHOT_DIR" ]]; then
  printf 'error: ui-snapshots dir missing: %s\n' "$SNAPSHOT_DIR" >&2
  exit 1
fi

OUTPUT_DIR="$(recording_triage_output_dir "$RUN_DIR")"
mkdir -p "$OUTPUT_DIR"
REPORT="$OUTPUT_DIR/act-identifiers.json"

"$BINARY" recording-triage act-identifiers \
  --marker-dir "$MARKER_DIR" \
  --ui-snapshots-dir "$SNAPSHOT_DIR" >"$REPORT"

printf 'act-identifiers -> %s\n' "$REPORT"
