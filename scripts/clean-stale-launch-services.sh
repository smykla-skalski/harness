#!/usr/bin/env bash
# Purge stale Launch Services registrations of Harness Monitor app bundles.
#
# Every Debug build of the app - in any worktree, lane, or ephemeral /tmp
# build dir - registers its `io.harnessmonitor.*` bundle into Launch Services
# and never cleans up. Dead-path entries accumulate without bound (1300+ have
# been observed on a busy dev machine). Because Background Task Management
# resolves the managed daemon's SMAppService container by bundle identifier
# through Launch Services, that ambiguity makes the lookup fail with
# `container=(null)`, and the daemon's launchd job then dies with `EX_CONFIG`
# (exit 78) in a spawn-fail loop the app cannot recover from.
#
# This removes only registrations whose on-disk path no longer exists; live
# build products are never touched (they re-register themselves on launch).
# Pass --dry-run to report what would be removed without changing anything.
set -euo pipefail

readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
readonly APP_PATH_PATTERN='path: +/.*Harness Monitor[^/]*[.]app'

dry_run=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    -h | --help)
      echo "usage: $(basename "$0") [--dry-run]" >&2
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if [[ ! -x "$LSREGISTER" ]]; then
  echo "lsregister not found at $LSREGISTER" >&2
  exit 1
fi

total=0
stale=0
removed=0
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  total=$((total + 1))
  [[ -e "$path" ]] && continue
  stale=$((stale + 1))
  if [[ "$dry_run" == "1" ]]; then
    echo "would unregister stale: $path" >&2
  elif "$LSREGISTER" -u "$path" >/dev/null 2>&1; then
    removed=$((removed + 1))
  fi
done < <(
  "$LSREGISTER" -dump 2>/dev/null \
    | grep -oE "$APP_PATH_PATTERN" \
    | sed 's/^path: *//' \
    | sort -u
)

if [[ "$dry_run" == "1" ]]; then
  echo "launch-services scan: $total Harness Monitor registrations, $stale stale (dry-run, none removed)" >&2
else
  echo "launch-services purge: $total registrations, $stale stale, $removed removed" >&2
fi
