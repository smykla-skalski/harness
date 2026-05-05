#!/usr/bin/env bash
# Prune stale agent DerivedData profiles under xcode-derived/profiles/.
#
# Each Harness Monitor agent session writes a fresh
# `xcode-derived/profiles/agent-<session-uuid>/` tree (~2GB Debug build,
# .swiftmodule, intermediate .o, .dia, .xctestrun). The agent UUID changes
# every Claude/Codex/Copilot session so old profiles accumulate forever.
# This script deletes profiles whose newest file mtime is older than the
# configured TTL.
#
# Defaults are conservative: only `agent-*` profiles are touched, and the
# active profile derived from HARNESS_MONITOR_RUNTIME_PROFILE (or the
# *_SESSION_ID env vars consumed by lib/runtime-profile.sh) is always
# preserved regardless of mtime.
#
# Env knobs:
#   HARNESS_MONITOR_PROFILE_TTL_SECONDS   - staleness threshold in seconds
#                                           (default: 7200 = 2h)
#   HARNESS_MONITOR_PROFILE_DRY_RUN       - 1 to print would-delete and skip
#                                           the actual /bin/rm
#   HARNESS_MONITOR_PROFILE_PRESERVE_GLOB - extra shell glob (relative to
#                                           xcode-derived/profiles/) of
#                                           profile names to keep
#
# Exit status: 0 on success (including no-op), non-zero on hard error.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/common-repo-root.sh
source "$REPO_ROOT/scripts/lib/common-repo-root.sh"
COMMON_REPO_ROOT="$(resolve_common_repo_root "$REPO_ROOT")"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/runtime-profile.sh
source "$REPO_ROOT/apps/harness-monitor-macos/Scripts/lib/runtime-profile.sh"

PROFILES_ROOT="$COMMON_REPO_ROOT/xcode-derived/profiles"
TTL_SECONDS="${HARNESS_MONITOR_PROFILE_TTL_SECONDS:-7200}"
DRY_RUN="${HARNESS_MONITOR_PROFILE_DRY_RUN:-0}"
PRESERVE_GLOB="${HARNESS_MONITOR_PROFILE_PRESERVE_GLOB:-}"

if [[ ! -d "$PROFILES_ROOT" ]]; then
  printf 'prune-xcode-derived-profiles: nothing to do, %s missing\n' "$PROFILES_ROOT"
  exit 0
fi

# Resolve the active profile so we never delete what the current shell would
# build into. resolve via the same library xcodebuild uses.
active_profile=""
if profile="$(harness_monitor_sanitize_profile "${HARNESS_MONITOR_RUNTIME_PROFILE:-}")" \
    && [[ -n "$profile" ]]; then
  active_profile="$profile"
elif profile="$(harness_monitor_default_agent_runtime_profile 2>/dev/null || true)" \
    && [[ -n "$profile" ]]; then
  active_profile="$profile"
fi

now_epoch="$(date +%s)"
threshold_epoch=$((now_epoch - TTL_SECONDS))
removed_count=0
preserved_count=0
total_freed_kb=0

profile_newest_epoch() {
  local path="$1"
  /usr/bin/find "$path" -type f -print0 2>/dev/null \
    | /usr/bin/xargs -0 /usr/bin/stat -f '%m' 2>/dev/null \
    | /usr/bin/sort -n \
    | /usr/bin/tail -n 1
}

profile_disk_usage_kb() {
  local path="$1"
  /usr/bin/du -sk "$path" 2>/dev/null | /usr/bin/awk '{ print $1 }'
}

shopt -s nullglob
for profile_path in "$PROFILES_ROOT"/agent-*; do
  [[ -d "$profile_path" ]] || continue
  profile_name="$(basename "$profile_path")"

  if [[ -n "$active_profile" && "$profile_name" == "$active_profile" ]]; then
    preserved_count=$((preserved_count + 1))
    continue
  fi

  if [[ -n "$PRESERVE_GLOB" ]]; then
    # shellcheck disable=SC2053
    if [[ "$profile_name" == $PRESERVE_GLOB ]]; then
      preserved_count=$((preserved_count + 1))
      continue
    fi
  fi

  newest_epoch="$(profile_newest_epoch "$profile_path")"
  if [[ -z "$newest_epoch" ]]; then
    newest_epoch=0
  fi

  if (( newest_epoch >= threshold_epoch )); then
    preserved_count=$((preserved_count + 1))
    continue
  fi

  size_kb="$(profile_disk_usage_kb "$profile_path")"
  total_freed_kb=$((total_freed_kb + ${size_kb:-0}))
  age_seconds=$((now_epoch - newest_epoch))

  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'would-prune %s (age=%ss size=%sKB)\n' "$profile_name" "$age_seconds" "${size_kb:-?}"
  else
    printf 'prune %s (age=%ss size=%sKB)\n' "$profile_name" "$age_seconds" "${size_kb:-?}"
    /bin/rm -rf "$profile_path"
  fi
  removed_count=$((removed_count + 1))
done
shopt -u nullglob

printf 'prune-xcode-derived-profiles: removed=%s preserved=%s freed_kb=%s ttl=%ss active=%s\n' \
  "$removed_count" "$preserved_count" "$total_freed_kb" "$TTL_SECONDS" "${active_profile:-<none>}"
