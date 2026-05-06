#!/bin/bash

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'error: monitor-lanes.sh must be sourced, not executed directly\n' >&2
  exit 1
fi

HARNESS_MONITOR_LANE_APP_GROUP_DEFAULT="Q498EB36N4.io.harnessmonitor"
HARNESS_MONITOR_LANE_LABEL_BASE="io.harnessmonitor.daemon"
HARNESS_MONITOR_LANE_CODEX_PORT_BASE=4600
HARNESS_MONITOR_LANE_CODEX_PORT_SPAN=20000

harness_monitor_trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

harness_monitor_sanitize_lane() {
  local raw="$1"
  local lowered sanitized
  raw="$(harness_monitor_trim_whitespace "$raw")"
  lowered="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  sanitized="$(
    printf '%s' "$lowered" \
      | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
  )"
  [[ -n "$sanitized" ]] || return 1
  sanitized="${sanitized:0:48}"
  sanitized="$(printf '%s' "$sanitized" | sed -E 's/-+$//')"
  [[ -n "$sanitized" ]] || return 1
  printf '%s\n' "$sanitized"
}

harness_monitor_reject_legacy_profile_env() {
  local key
  for key in \
    HARNESS_MONITOR_RUNTIME_PROFILE \
    HARNESS_MONITOR_USER_RUNTIME_PROFILE \
    HARNESS_MONITOR_ALLOW_NON_AGENT_RUNTIME_PROFILE \
    HARNESS_MONITOR_ALLOW_AGENT_USER_PROFILE \
    HARNESS_MONITOR_AGENT_DEVELOPER_DIR; do
    if [[ -n "${!key:-}" ]]; then
      printf 'error: %s is no longer supported. Use HARNESS_MONITOR_BUILD_LANE for DerivedData or HARNESS_MONITOR_RUNTIME_LANE for daemon/bridge state.\n' "$key" >&2
      return 1
    fi
  done
}

harness_monitor_env_flag_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

harness_monitor_hash_prefix() {
  printf '%s' "$1" | shasum -a 256 | awk '{ print substr($1, 1, 8) }'
}

harness_monitor_default_runtime_lane() {
  local checkout_root="$1"
  local base hash slug
  checkout_root="$(cd "$checkout_root" && pwd -P)"
  base="$(basename "$checkout_root")"
  slug="$(harness_monitor_sanitize_lane "$base" || printf 'worktree')"
  hash="$(harness_monitor_hash_prefix "$checkout_root")"
  printf '%s-%s\n' "$slug" "$hash"
}

harness_monitor_build_lane() {
  local lane
  if [[ -z "${HARNESS_MONITOR_BUILD_LANE:-}" ]]; then
    printf 'default\n'
    return 0
  fi
  lane="$(harness_monitor_sanitize_lane "$HARNESS_MONITOR_BUILD_LANE")" || {
    printf 'error: HARNESS_MONITOR_BUILD_LANE must contain at least one alphanumeric character\n' >&2
    return 1
  }
  printf '%s\n' "$lane"
}

harness_monitor_runtime_lane() {
  local checkout_root="$1"
  local lane
  harness_monitor_reject_legacy_profile_env || return 1
  if [[ -n "${HARNESS_MONITOR_RUNTIME_LANE:-}" ]]; then
    lane="$(harness_monitor_sanitize_lane "$HARNESS_MONITOR_RUNTIME_LANE")" || {
      printf 'error: HARNESS_MONITOR_RUNTIME_LANE must contain at least one alphanumeric character\n' >&2
      return 1
    }
    printf '%s\n' "$lane"
    return 0
  fi
  harness_monitor_default_runtime_lane "$checkout_root"
}

harness_monitor_lane_from_path() {
  local raw_path="$1"
  local normalized candidate
  [[ -n "$raw_path" ]] || return 1
  normalized="${raw_path%/}"
  case "$normalized" in
    */runtime-lanes/*)
      candidate="${normalized#*/runtime-lanes/}"
      candidate="${candidate%%/*}"
      harness_monitor_sanitize_lane "$candidate"
      ;;
    *)
      return 1
      ;;
  esac
}

harness_monitor_build_derived_data_path() {
  local common_repo_root="$1"
  local lane
  harness_monitor_reject_legacy_profile_env || return 1
  if [[ -n "${XCODEBUILD_DERIVED_DATA_PATH:-}" ]]; then
    printf '%s\n' "$XCODEBUILD_DERIVED_DATA_PATH"
    return 0
  fi
  lane="$(harness_monitor_build_lane)"
  case "$lane" in
    default) printf '%s/xcode-derived\n' "$common_repo_root" ;;
    e2e) printf '%s/xcode-derived-e2e\n' "$common_repo_root" ;;
    instruments) printf '%s/xcode-derived-instruments\n' "$common_repo_root" ;;
    *) printf '%s/xcode-derived-lanes/%s\n' "$common_repo_root" "$lane" ;;
  esac
}

harness_monitor_runtime_app_group_id() {
  harness_monitor_trim_whitespace "${HARNESS_APP_GROUP_ID:-$HARNESS_MONITOR_LANE_APP_GROUP_DEFAULT}"
}

harness_monitor_runtime_daemon_data_home() {
  local checkout_root="$1"
  local lane app_group_id
  if [[ -n "${HARNESS_DAEMON_DATA_HOME:-}" ]]; then
    printf '%s\n' "$HARNESS_DAEMON_DATA_HOME"
    return 0
  fi
  lane="$(harness_monitor_runtime_lane "$checkout_root")"
  app_group_id="$(harness_monitor_runtime_app_group_id)"
  printf '%s/Library/Group Containers/%s/runtime-lanes/%s\n' \
    "${HOME:?missing HOME}" \
    "$app_group_id" \
    "$lane"
}

harness_monitor_runtime_codex_ws_port() {
  local checkout_root="$1"
  local lane hex_prefix hash_value
  if [[ -n "${HARNESS_CODEX_WS_PORT:-}" ]]; then
    printf '%s\n' "$HARNESS_CODEX_WS_PORT"
    return 0
  fi
  lane="$(harness_monitor_runtime_lane "$checkout_root")"
  hex_prefix="$(harness_monitor_hash_prefix "$lane")"
  hash_value=$((16#$hex_prefix))
  printf '%s\n' "$((HARNESS_MONITOR_LANE_CODEX_PORT_BASE + (hash_value % HARNESS_MONITOR_LANE_CODEX_PORT_SPAN)))"
}

harness_monitor_runtime_launch_agent_label() {
  local checkout_root="$1"
  local lane
  if [[ -n "${HARNESS_MONITOR_DAEMON_LAUNCH_AGENT_LABEL:-}" ]]; then
    printf '%s\n' "$HARNESS_MONITOR_DAEMON_LAUNCH_AGENT_LABEL"
    return 0
  fi
  lane="$(harness_monitor_runtime_lane "$checkout_root")"
  printf '%s.%s\n' "$HARNESS_MONITOR_LANE_LABEL_BASE" "$lane"
}

harness_monitor_runtime_xcodebuildmcp_socket_path() {
  local checkout_root="$1"
  local lane
  lane="$(harness_monitor_runtime_lane "$checkout_root")"
  printf '%s/.xcodebuildmcp/harness-monitor-%s.sock\n' "${HOME:?missing HOME}" "$lane"
}

harness_monitor_apply_runtime_lane_environment() {
  local checkout_root="$1"
  local lane
  lane="$(harness_monitor_runtime_lane "$checkout_root")"
  export HARNESS_MONITOR_RUNTIME_LANE="$lane"
  export HARNESS_DAEMON_DATA_HOME
  HARNESS_DAEMON_DATA_HOME="$(harness_monitor_runtime_daemon_data_home "$checkout_root")"
  export HARNESS_CODEX_WS_PORT
  HARNESS_CODEX_WS_PORT="$(harness_monitor_runtime_codex_ws_port "$checkout_root")"
  export HARNESS_MONITOR_DAEMON_LAUNCH_AGENT_LABEL
  HARNESS_MONITOR_DAEMON_LAUNCH_AGENT_LABEL="$(harness_monitor_runtime_launch_agent_label "$checkout_root")"
}

harness_monitor_current_xcode_user_data_dir() {
  local user_name
  user_name="${USER:-}"
  if [[ -z "$user_name" ]]; then
    user_name="$(id -un 2>/dev/null || true)"
  fi
  user_name="$(harness_monitor_trim_whitespace "$user_name")"
  if [[ "$user_name" == *"@"* ]]; then
    user_name="${user_name%%@*}"
  fi
  user_name="$(
    printf '%s' "$user_name" \
      | tr '[:upper:]' '[:lower:]' \
      | tr -cd '[:alnum:]'
  )"
  [[ -n "$user_name" ]] || user_name="user"
  printf '%s.xcuserdatad\n' "$user_name"
}

harness_monitor_write_workspace_settings() {
  local settings_path="$1"
  local derived_data_path="$2"
  mkdir -p "$(dirname "$settings_path")"
  cat > "$settings_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>BuildLocationStyle</key>
	<string>CustomLocation</string>
	<key>DerivedDataCustomLocation</key>
	<string>${derived_data_path}</string>
	<key>IDESourceControlEnabled</key>
	<false/>
	<key>IDEWorkspaceSharedSettings_AutocreateContextsIfNeeded</key>
	<false/>
</dict>
</plist>
EOF
}

harness_monitor_write_user_workspace_settings() {
  local app_root="$1"
  local derived_data_path="$2"
  local user_data_dir
  user_data_dir="$(harness_monitor_current_xcode_user_data_dir)"
  harness_monitor_write_workspace_settings \
    "$app_root/HarnessMonitor.xcworkspace/xcuserdata/$user_data_dir/WorkspaceSettings.xcsettings" \
    "$derived_data_path"
  harness_monitor_write_workspace_settings \
    "$app_root/HarnessMonitor.xcodeproj/project.xcworkspace/xcuserdata/$user_data_dir/WorkspaceSettings.xcsettings" \
    "$derived_data_path"
}
