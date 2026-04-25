#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/lib.sh
. "$SCRIPT_DIR/../../lib.sh"

REPO_ROOT="$(e2e_repo_root)"
BUILD_FIXTURE="$REPO_ROOT/scripts/e2e/recording-triage/build-fixture.sh"

if ! command -v ffmpeg >/dev/null 2>&1; then
  printf 'skipping: ffmpeg unavailable\n'
  exit 0
fi
if ! command -v ffprobe >/dev/null 2>&1; then
  printf 'skipping: ffprobe unavailable\n'
  exit 0
fi

WORK_DIR="$(mktemp -d -t recording-triage-fixture.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

"$BUILD_FIXTURE" "$WORK_DIR"

for fixture in tiny.mov transition.mov freeze.mov; do
  output="$WORK_DIR/$fixture"
  if [[ ! -s "$output" ]]; then
    printf 'fixture missing or empty: %s\n' "$output" >&2
    exit 1
  fi

  size_bytes="$(stat -f%z "$output" 2>/dev/null || stat -c%s "$output")"
  if (( size_bytes > 204800 )); then
    printf 'fixture too large: %s (%s bytes > 200 KB)\n' "$output" "$size_bytes" >&2
    exit 1
  fi

  duration="$(ffprobe -loglevel error -show_entries format=duration -of csv=p=0 "$output")"
  if [[ -z "$duration" ]]; then
    printf 'ffprobe failed for %s\n' "$output" >&2
    exit 1
  fi
done

printf 'build_fixture ok\n'
