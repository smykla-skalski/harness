#!/bin/sh
set -eu

repo_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
legacy_pattern='harness (mcp|hook|pre-compact|session-start|session-stop|agents (session-start|session-stop|prompt-submit)|daemon (serve|dev|remote)|bridge start)'
root_dependency_pattern='^[[:space:]]*harness[[:space:]]*='

set +e
matches=$(
  rg -n "$legacy_pattern" "$repo_root" \
    --glob '!target/**' \
    --glob '!scripts/tests/test-stale-scan.sh' \
    --glob '!scripts/tests/test-release-install.sh' \
    --glob '!scripts/lib/stale-scan.sh' \
    --glob '!apps/harness-monitor/Tools/HarnessMonitorPerf/Sources/HarnessMonitorPerfCore/AuditRunner+Support.swift'
)
status=$?
set -e

case "$status" in
  0)
    printf 'Legacy monolithic Harness executable contracts remain:\n%s\n' "$matches" >&2
    exit 1
    ;;
  1)
    ;;
  *)
    printf 'Failed to scan Harness executable contracts (rg status %s).\n' "$status" >&2
    exit "$status"
    ;;
esac

set +e
matches=$(rg -n "$root_dependency_pattern" "$repo_root/crates" --glob 'Cargo.toml')
status=$?
set -e

case "$status" in
  0)
    printf 'Standalone Harness packages depend on the root harness package:\n%s\n' \
      "$matches" >&2
    exit 1
    ;;
  1)
    ;;
  *)
    printf 'Failed to scan standalone package dependencies (rg status %s).\n' \
      "$status" >&2
    exit "$status"
    ;;
esac
