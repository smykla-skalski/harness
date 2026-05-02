#!/bin/bash

HARNESS_MONITOR_RUNTIME_PROFILE_DIR="profiles"
HARNESS_MONITOR_RUNTIME_DATA_HOME_DIR="runtime-profiles"
HARNESS_MONITOR_RUNTIME_LABEL_BASE="io.harnessmonitor.daemon"
HARNESS_MONITOR_RUNTIME_APP_GROUP_DEFAULT="Q498EB36N4.io.harnessmonitor"
HARNESS_MONITOR_RUNTIME_CODEX_PORT_BASE=4600
HARNESS_MONITOR_RUNTIME_CODEX_PORT_SPAN=20000
HARNESS_MONITOR_RUNTIME_USER_DERIVED_DATA_FILE=".xcode-user-derived-data-path"

harness_monitor_trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

harness_monitor_sanitize_profile() {
  local raw="$1"
  local lowered sanitized
  raw="$(harness_monitor_trim_whitespace "$raw")"
  lowered="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  sanitized="$(
    printf '%s' "$lowered" \
      | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
  )"
  if [[ -z "$sanitized" ]]; then
    return 0
  fi
  sanitized="${sanitized:0:48}"
  sanitized="$(printf '%s' "$sanitized" | sed -E 's/-+$//')"
  printf '%s\n' "$sanitized"
}

harness_monitor_profile_from_path() {
  local raw_path="$1"
  local normalized candidate
  local -a components=()
  local idx

  [[ -n "$raw_path" ]] || return 1
  normalized="${raw_path%/}"
  IFS='/' read -r -a components <<<"${normalized#/}"

  for ((idx = 0; idx < ${#components[@]} - 1; idx += 1)); do
    case "${components[idx]}" in
      xcode-derived|xcode-derived-e2e|xcode-derived-instruments)
        if (( idx + 2 < ${#components[@]} )) \
          && [[ "${components[idx + 1]}" == "$HARNESS_MONITOR_RUNTIME_PROFILE_DIR" ]]; then
          candidate="$(harness_monitor_sanitize_profile "${components[idx + 2]}")"
          if [[ -n "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
          fi
        fi
        ;;
      "$HARNESS_MONITOR_RUNTIME_DATA_HOME_DIR")
        if (( idx + 1 < ${#components[@]} )); then
          candidate="$(harness_monitor_sanitize_profile "${components[idx + 1]}")"
          if [[ -n "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
          fi
        fi
        ;;
    esac
  done

  return 1
}

harness_monitor_runtime_profile() {
  local candidate path
  candidate="$(harness_monitor_sanitize_profile "${HARNESS_MONITOR_RUNTIME_PROFILE:-}")"
  if [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  for path in \
    "${HARNESS_DAEMON_DATA_HOME:-}" \
    "${XCODEBUILD_DERIVED_DATA_PATH:-}" \
    "${TARGET_BUILD_DIR:-}" \
    "${BUILT_PRODUCTS_DIR:-}" \
    "${BUILD_DIR:-}" \
    "${PROJECT_TEMP_DIR:-}" \
    "${TARGET_TEMP_DIR:-}"; do
    candidate="$(harness_monitor_profile_from_path "$path" || true)"
    if [[ -n "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

harness_monitor_default_user_runtime_profile() {
  local raw_profile
  if [[ -n "${HARNESS_MONITOR_USER_RUNTIME_PROFILE:-}" ]]; then
    harness_monitor_sanitize_profile "$HARNESS_MONITOR_USER_RUNTIME_PROFILE"
    return 0
  fi

  raw_profile="${USER:-}"
  if [[ -z "$raw_profile" ]]; then
    raw_profile="$(id -un 2>/dev/null || true)"
  fi
  if [[ "$raw_profile" == *"@"* ]]; then
    raw_profile="${raw_profile%%@*}"
  fi
  raw_profile="$(
    printf '%s' "$raw_profile" \
      | tr '[:upper:]' '[:lower:]' \
      | tr -cd '[:alnum:]'
  )"
  if [[ -n "$raw_profile" ]]; then
    printf '%s\n' "$raw_profile"
    return 0
  fi

  harness_monitor_sanitize_profile "${USER:-}"
}

harness_monitor_runtime_app_group_id() {
  local app_group_id
  app_group_id="$(harness_monitor_trim_whitespace "${HARNESS_APP_GROUP_ID:-$HARNESS_MONITOR_RUNTIME_APP_GROUP_DEFAULT}")"
  printf '%s\n' "$app_group_id"
}

harness_monitor_runtime_daemon_data_home() {
  local profile app_group_id
  if [[ -n "${HARNESS_DAEMON_DATA_HOME:-}" ]]; then
    printf '%s\n' "$HARNESS_DAEMON_DATA_HOME"
    return 0
  fi

  profile="$(harness_monitor_runtime_profile || true)"
  [[ -n "$profile" ]] || return 1
  app_group_id="$(harness_monitor_runtime_app_group_id)"
  printf '%s/Library/Group Containers/%s/%s/%s\n' \
    "${HOME:?missing HOME}" \
    "$app_group_id" \
    "$HARNESS_MONITOR_RUNTIME_DATA_HOME_DIR" \
    "$profile"
}

harness_monitor_runtime_codex_ws_port() {
  local profile hex_prefix hash_value
  if [[ -n "${HARNESS_CODEX_WS_PORT:-}" ]]; then
    printf '%s\n' "$HARNESS_CODEX_WS_PORT"
    return 0
  fi

  profile="$(harness_monitor_runtime_profile || true)"
  [[ -n "$profile" ]] || return 1
  hex_prefix="$(
    printf '%s' "$profile" \
      | shasum -a 256 \
      | awk '{ print substr($1, 1, 8) }'
  )"
  hash_value=$((16#$hex_prefix))
  printf '%s\n' "$((HARNESS_MONITOR_RUNTIME_CODEX_PORT_BASE + (hash_value % HARNESS_MONITOR_RUNTIME_CODEX_PORT_SPAN)))"
}

harness_monitor_runtime_launch_agent_label() {
  local profile
  if [[ -n "${HARNESS_MONITOR_DAEMON_LAUNCH_AGENT_LABEL:-}" ]]; then
    printf '%s\n' "$HARNESS_MONITOR_DAEMON_LAUNCH_AGENT_LABEL"
    return 0
  fi

  profile="$(harness_monitor_runtime_profile || true)"
  if [[ -z "$profile" ]]; then
    printf '%s\n' "$HARNESS_MONITOR_RUNTIME_LABEL_BASE"
    return 0
  fi
  printf '%s.%s\n' "$HARNESS_MONITOR_RUNTIME_LABEL_BASE" "$profile"
}

harness_monitor_runtime_derived_data_path() {
  local common_repo_root="$1"
  local root_name="${2:-xcode-derived}"
  local profile
  if [[ -n "${XCODEBUILD_DERIVED_DATA_PATH:-}" ]]; then
    printf '%s\n' "$XCODEBUILD_DERIVED_DATA_PATH"
    return 0
  fi

  profile="$(harness_monitor_runtime_profile || true)"
  if [[ -z "$profile" ]]; then
    printf '%s/%s\n' "$common_repo_root" "$root_name"
    return 0
  fi

  printf '%s/%s/%s/%s\n' \
    "$common_repo_root" \
    "$root_name" \
    "$HARNESS_MONITOR_RUNTIME_PROFILE_DIR" \
    "$profile"
}

harness_monitor_runtime_user_derived_data_path_file() {
  local app_root="$1"
  printf '%s/%s\n' "${app_root%/}" "$HARNESS_MONITOR_RUNTIME_USER_DERIVED_DATA_FILE"
}

harness_monitor_current_xcode_user_data_dir() {
  local user_name
  user_name="${USER:-}"
  if [[ -z "$user_name" ]]; then
    user_name="$(id -un 2>/dev/null || true)"
  fi
  user_name="$(harness_monitor_trim_whitespace "$user_name")"
  if [[ -z "$user_name" ]]; then
    user_name="user"
  fi
  user_name="${user_name//\//-}"
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

harness_monitor_store_user_derived_data_path() {
  local app_root="$1"
  local derived_data_path="$2"
  local state_path
  derived_data_path="$(harness_monitor_trim_whitespace "$derived_data_path")"
  [[ -n "$derived_data_path" ]] || return 1
  state_path="$(harness_monitor_runtime_user_derived_data_path_file "$app_root")"
  mkdir -p "$(dirname "$state_path")"
  printf '%s\n' "$derived_data_path" > "$state_path"
}

harness_monitor_saved_user_derived_data_path() {
  local app_root="$1"
  local state_path derived_data_path
  state_path="$(harness_monitor_runtime_user_derived_data_path_file "$app_root")"
  [[ -f "$state_path" ]] || return 1
  IFS= read -r derived_data_path < "$state_path" || true
  derived_data_path="$(harness_monitor_trim_whitespace "$derived_data_path")"
  if [[ -z "$derived_data_path" ]] || [[ "$derived_data_path" != /* ]]; then
    return 1
  fi
  printf '%s\n' "$derived_data_path"
}

harness_monitor_restore_saved_user_workspace_settings() {
  local app_root="$1"
  local derived_data_path
  derived_data_path="$(harness_monitor_saved_user_derived_data_path "$app_root" || true)"
  [[ -n "$derived_data_path" ]] || return 1
  harness_monitor_write_user_workspace_settings "$app_root" "$derived_data_path"
}

harness_monitor_apply_runtime_profile_environment() {
  local profile
  profile="$(harness_monitor_runtime_profile || true)"
  if [[ -z "$profile" ]]; then
    return 0
  fi

  export HARNESS_MONITOR_RUNTIME_PROFILE="$profile"
  if [[ -z "${HARNESS_DAEMON_DATA_HOME:-}" ]]; then
    export HARNESS_DAEMON_DATA_HOME
    HARNESS_DAEMON_DATA_HOME="$(harness_monitor_runtime_daemon_data_home)"
  fi
  if [[ -z "${HARNESS_CODEX_WS_PORT:-}" ]]; then
    export HARNESS_CODEX_WS_PORT
    HARNESS_CODEX_WS_PORT="$(harness_monitor_runtime_codex_ws_port)"
  fi
  export HARNESS_MONITOR_DAEMON_LAUNCH_AGENT_LABEL
  HARNESS_MONITOR_DAEMON_LAUNCH_AGENT_LABEL="$(harness_monitor_runtime_launch_agent_label)"
}
