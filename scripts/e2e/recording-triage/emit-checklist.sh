#!/usr/bin/env bash
set -euo pipefail

# Aggregate every detector JSON under <run>/recording-triage/ into one
# checklist.md formatted exactly as `references/recording-checklist.md`
# expects. The skill agent reads the emitted file instead of hand-typing
# verdicts; tier-4 rows always emit `needs-verification` so the agent still
# re-watches them.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/recording-triage/lib-recording-triage.sh
. "$SCRIPT_DIR/lib-recording-triage.sh"

usage() {
  cat <<'EOF' >&2
usage: emit-checklist.sh --run <path>
  --run     triage run dir; reads recording-triage/*.json and writes checklist.md
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

OUTPUT_DIR="$(recording_triage_output_dir "$RUN_DIR")"
mkdir -p "$OUTPUT_DIR"
REPORT="$OUTPUT_DIR/checklist.md"

"$BINARY" recording-triage emit-checklist --run "$RUN_DIR" >"$REPORT"

printf 'emit-checklist -> %s\n' "$REPORT"
