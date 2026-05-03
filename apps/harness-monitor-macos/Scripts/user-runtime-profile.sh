#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
CHECKOUT_ROOT="$(CDPATH='' cd -- "$ROOT/../.." && pwd)"
# shellcheck source=scripts/lib/common-repo-root.sh
source "$CHECKOUT_ROOT/scripts/lib/common-repo-root.sh"
COMMON_REPO_ROOT="$(resolve_common_repo_root "$CHECKOUT_ROOT")"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/runtime-profile.sh
source "$SCRIPT_DIR/lib/runtime-profile.sh"

allow_agent_user_lane() {
  harness_monitor_env_flag_enabled "${HARNESS_MONITOR_ALLOW_AGENT_USER_PROFILE:-0}"
}

reject_agent_user_lane() {
  if allow_agent_user_lane; then
    return 0
  fi
  if harness_monitor_agent_session_id >/dev/null 2>&1; then
    printf '%s\n' \
      "Agent sessions must not use the Harness Monitor user profile lane. Use 'mise run monitor:agent:*' or 'apps/harness-monitor-macos/Scripts/agent-xcode-env.sh ...' instead. If you intentionally need the user lane from an agent, set HARNESS_MONITOR_ALLOW_AGENT_USER_PROFILE=1." \
      >&2
    exit 1
  fi
}

resolve_user_runtime_profile() {
  local profile
  profile="$(harness_monitor_sanitize_profile "${HARNESS_MONITOR_RUNTIME_PROFILE:-}")"
  if [[ -n "$profile" ]]; then
    printf '%s\n' "$profile"
    return 0
  fi

  profile="$(harness_monitor_default_user_runtime_profile)"
  if [[ -z "$profile" ]]; then
    echo "Unable to derive a personal Harness Monitor runtime profile. Set HARNESS_MONITOR_RUNTIME_PROFILE." >&2
    exit 1
  fi
  printf '%s\n' "$profile"
}

reject_agent_user_lane

export HARNESS_MONITOR_RUNTIME_PROFILE
HARNESS_MONITOR_RUNTIME_PROFILE="$(resolve_user_runtime_profile)"
harness_monitor_apply_runtime_profile_environment

# Mark this lane as the workspace owner so the post-generate hook writes
# the shared WorkspaceSettings.xcsettings to the user profile's
# DerivedData. Agent lanes (agent-xcode-env.sh) intentionally leave this
# unset so their `tuist generate` does not overwrite the user's shared
# Xcode workspace state.
export HARNESS_MONITOR_OWNS_WORKSPACE=1

persist_user_derived_data_path() {
  harness_monitor_store_user_derived_data_path \
    "$ROOT" \
    "$(harness_monitor_runtime_derived_data_path "$COMMON_REPO_ROOT" "xcode-derived")"
}

refresh_user_workspace_settings_if_generated() {
  local workspace_root="$ROOT/HarnessMonitor.xcworkspace"
  local project_workspace_root="$ROOT/HarnessMonitor.xcodeproj/project.xcworkspace"
  if [[ ! -d "$workspace_root" ]] && [[ ! -d "$project_workspace_root" ]]; then
    return 0
  fi

  harness_monitor_write_user_workspace_settings \
    "$ROOT" \
    "$(harness_monitor_runtime_derived_data_path "$COMMON_REPO_ROOT" "xcode-derived")"
}

persist_user_derived_data_path
refresh_user_workspace_settings_if_generated

if (( $# == 0 )); then
  printf 'Harness Monitor user profile: %s\n' "$HARNESS_MONITOR_RUNTIME_PROFILE"
  printf 'DerivedData: %s\n' "$(harness_monitor_runtime_derived_data_path "$COMMON_REPO_ROOT" "xcode-derived")"
  printf 'Daemon data home: %s\n' "${HARNESS_DAEMON_DATA_HOME:-}"
  printf 'Codex WS port: %s\n' "${HARNESS_CODEX_WS_PORT:-}"
  printf 'Launch agent label: %s\n' "${HARNESS_MONITOR_DAEMON_LAUNCH_AGENT_LABEL:-}"
  printf '\nNext commands:\n'
  printf '  mise run monitor:user:build\n'
  printf '  mise run monitor:user:test\n'
  printf '  mise run monitor:user:daemon:dev\n'
  printf '  mise run monitor:user:bridge:start\n'
  printf '  mise run monitor:user:reset\n'
  exit 0
fi

exec "$@"
