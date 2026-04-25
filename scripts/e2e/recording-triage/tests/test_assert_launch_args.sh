#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/recording-triage/tests/lib-test.sh
. "$SCRIPT_DIR/lib-test.sh"

REPO_ROOT="$(recording_triage_test_repo_root)"
WRAPPER="$REPO_ROOT/scripts/e2e/recording-triage/assert-launch-args.sh"

WORK_DIR="$(recording_triage_test_make_run_dir launchargs)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Synthetic repo root with two source files: one carries the persistence
# launch argument, the other forgot it. The wrapper must emit a verdict per
# file plus an `allConfigured` aggregate that flips to false when any source
# is missing the arg.
SYNTH_REPO="$WORK_DIR/synthetic-repo"
TESTS_DIR="$SYNTH_REPO/apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests"
SUPPORT_DIR="$SYNTH_REPO/apps/harness-monitor-macos/Tests/HarnessMonitorUITestSupport"
mkdir -p "$TESTS_DIR" "$SUPPORT_DIR"
cat >"$TESTS_DIR/HarnessMonitorAgentsE2ETests+Support.swift" <<'EOM'
import XCTest

func configure(app: XCUIApplication) {
  app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
}
EOM
cat >"$TESTS_DIR/SwarmFixture.swift" <<'EOM'
import XCTest

func boot(app: XCUIApplication) {
  app.launchArguments += ["-SomeOtherArg", "value"]
  app.launch()
}
EOM
cat >"$SUPPORT_DIR/HarnessMonitorUITestSupport.swift" <<'EOM'
import XCTest

func arrange(app: XCUIApplication) {
  app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
}
EOM

RUN_DIR="$WORK_DIR/run"
mkdir -p "$RUN_DIR"
"$WRAPPER" --run "$RUN_DIR" --repo-root "$SYNTH_REPO" >/dev/null

REPORT="$RUN_DIR/recording-triage/launch-args.json"
if [[ ! -s "$REPORT" ]]; then
  printf 'launch-args.json missing: %s\n' "$REPORT" >&2
  exit 1
fi

all_configured="$(jq '.allConfigured' "$REPORT")"
if [[ "$all_configured" != "false" ]]; then
  printf 'expected allConfigured=false, got %s\n' "$all_configured" >&2
  exit 1
fi

missing="$(jq -r '[.files[] | select(.hasPersistenceIgnoreState == false) | .path] | join(",")' "$REPORT")"
case "$missing" in
  *"SwarmFixture.swift"*) : ;;
  *)
    printf 'expected SwarmFixture.swift in missing list; got %s\n' "$missing" >&2
    exit 1
    ;;
esac

# Drop the missing-arg file and re-run; verdict should flip to true.
echo 'app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]' \
  >>"$TESTS_DIR/SwarmFixture.swift"
"$WRAPPER" --run "$RUN_DIR" --repo-root "$SYNTH_REPO" >/dev/null
all_configured="$(jq '.allConfigured' "$REPORT")"
if [[ "$all_configured" != "true" ]]; then
  printf 'expected allConfigured=true after fix, got %s\n' "$all_configured" >&2
  exit 1
fi

printf 'assert-launch-args test ok\n'
