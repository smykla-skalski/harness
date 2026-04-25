#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/recording-triage/tests/lib-test.sh
. "$SCRIPT_DIR/lib-test.sh"

REPO_ROOT="$(recording_triage_test_repo_root)"
recording_triage_test_skip_unless_binary "$REPO_ROOT"
WRAPPER="$REPO_ROOT/scripts/e2e/recording-triage/emit-checklist.sh"

WORK_DIR="$(recording_triage_test_make_run_dir checklist)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Synthetic run dir holding only the launch-args report; every other detector
# input is absent so the emitter must still produce a complete checklist with
# tier-4 rows defaulted to needs-verification.
RUN_DIR="$WORK_DIR/run"
TRIAGE_DIR="$RUN_DIR/recording-triage"
mkdir -p "$TRIAGE_DIR"
cat >"$TRIAGE_DIR/launch-args.json" <<'EOM'
{
  "allConfigured": true,
  "files": [
    {
      "path": "apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/SwarmFixture.swift",
      "hasPersistenceIgnoreState": true
    }
  ]
}
EOM

"$WRAPPER" --run "$RUN_DIR" >/dev/null

CHECKLIST="$TRIAGE_DIR/checklist.md"
if [[ ! -s "$CHECKLIST" ]]; then
  printf 'checklist.md missing: %s\n' "$CHECKLIST" >&2
  exit 1
fi

required_phrases=(
  "## A. Process and lifecycle"
  "## H. Swarm-specific UI"
  "## I. Recording artifact integrity"
  "## Suite-speed prompts"
  "\`lifecycle.persistence\`: \`not-found\`"
  "\`artifact.size\`: \`needs-verification\`"
)
for phrase in "${required_phrases[@]}"; do
  if ! grep -qF "$phrase" "$CHECKLIST"; then
    printf 'missing phrase in checklist.md: %s\n' "$phrase" >&2
    exit 1
  fi
done

# Flip the input file and re-run; persistence row must transition to found.
cat >"$TRIAGE_DIR/launch-args.json" <<'EOM'
{
  "allConfigured": false,
  "files": []
}
EOM

"$WRAPPER" --run "$RUN_DIR" >/dev/null
# shellcheck disable=SC2016 # grep pattern uses literal backticks from the
# markdown checklist; no shell expansion intended.
if ! grep -qF '`lifecycle.persistence`: `found`' "$CHECKLIST"; then
  printf 'expected lifecycle.persistence to flip to found after rewrite\n' >&2
  exit 1
fi

printf 'emit-checklist test ok\n'
