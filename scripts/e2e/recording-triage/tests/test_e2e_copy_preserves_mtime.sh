#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/recording-triage/tests/lib-test.sh
. "$SCRIPT_DIR/lib-test.sh"

REPO_ROOT="$(recording_triage_test_repo_root)"
# shellcheck source=scripts/e2e/lib.sh
. "$REPO_ROOT/scripts/e2e/lib.sh"

WORKDIR="$(mktemp -d -t triage-run-copy-mtime.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

SRC_DIR="$WORKDIR/src"
SRC_FILE="$SRC_DIR/act1.ready"
DEST_DIR="$WORKDIR/dest"

mkdir -p "$SRC_DIR"
printf 'ready\n' >"$SRC_FILE"

# Stamp source file with a deterministic mtime well in the past so any
# copy that drops the timestamp immediately fails the assertion.
TARGET_TS='200001020304.05'
touch -t "$TARGET_TS" "$SRC_FILE"
EXPECTED_MTIME="$(/usr/bin/stat -f '%m' "$SRC_FILE")"

if ! command -v e2e_copy_path_if_exists >/dev/null 2>&1; then
  printf 'expected e2e_copy_path_if_exists to be defined in scripts/e2e/lib.sh\n' >&2
  exit 1
fi

e2e_copy_path_if_exists "$SRC_DIR" "$DEST_DIR"

if [[ ! -f "$DEST_DIR/act1.ready" ]]; then
  printf 'copy did not produce expected file\n' >&2
  exit 1
fi

ACTUAL_MTIME="$(/usr/bin/stat -f '%m' "$DEST_DIR/act1.ready")"
if [[ "$ACTUAL_MTIME" != "$EXPECTED_MTIME" ]]; then
  printf 'mtime not preserved: expected=%s actual=%s\n' \
    "$EXPECTED_MTIME" "$ACTUAL_MTIME" >&2
  exit 1
fi

# Also exercise the single-file branch.
SINGLE_DEST="$WORKDIR/single.ready"
e2e_copy_path_if_exists "$SRC_FILE" "$SINGLE_DEST"
ACTUAL_SINGLE_MTIME="$(/usr/bin/stat -f '%m' "$SINGLE_DEST")"
if [[ "$ACTUAL_SINGLE_MTIME" != "$EXPECTED_MTIME" ]]; then
  printf 'single-file mtime not preserved: expected=%s actual=%s\n' \
    "$EXPECTED_MTIME" "$ACTUAL_SINGLE_MTIME" >&2
  exit 1
fi

printf 'ok: e2e_copy_path_if_exists preserves mtime for files and directories\n'
