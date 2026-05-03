#!/bin/bash

HARNESS_MONITOR_RUNTIME_PROFILE_DIR="profiles"
HARNESS_MONITOR_RUNTIME_DATA_HOME_DIR="runtime-profiles"
HARNESS_MONITOR_RUNTIME_LABEL_BASE="io.harnessmonitor.daemon"
HARNESS_MONITOR_RUNTIME_APP_GROUP_DEFAULT="Q498EB36N4.io.harnessmonitor"
HARNESS_MONITOR_RUNTIME_CODEX_PORT_BASE=4600
HARNESS_MONITOR_RUNTIME_CODEX_PORT_SPAN=20000
HARNESS_MONITOR_RUNTIME_USER_DERIVED_DATA_FILE=".xcode-user-derived-data-path"
HARNESS_MONITOR_RUNTIME_PORT_REGISTRY_FILE="profile-ports.list"
HARNESS_MONITOR_RUNTIME_PORT_LOCK_RETRIES=200
HARNESS_MONITOR_RUNTIME_PORT_LOCK_SLEEP="0.05"

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
    harness_monitor_validate_resolved_runtime_profile "$candidate" || return 1
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
      harness_monitor_validate_resolved_runtime_profile "$candidate" || return 1
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  candidate="$(harness_monitor_default_agent_runtime_profile || true)"
  if [[ -n "$candidate" ]]; then
    harness_monitor_validate_resolved_runtime_profile "$candidate" || return 1
    printf '%s\n' "$candidate"
    return 0
  fi

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

harness_monitor_agent_session_id() {
  local env_name value
  for env_name in \
    HARNESS_AGENT_ID \
    CODEX_SESSION_ID \
    CODEX_THREAD_ID \
    CLAUDE_SESSION_ID \
    GEMINI_SESSION_ID \
    COPILOT_SESSION_ID \
    OPENCODE_SESSION_ID \
    VIBE_SESSION_ID; do
    value="${!env_name:-}"
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  done
  return 1
}

harness_monitor_default_agent_runtime_profile() {
  local session_id profile
  session_id="$(harness_monitor_agent_session_id || true)"
  [[ -n "$session_id" ]] || return 1
  profile="$(harness_monitor_sanitize_profile "agent-$session_id")"
  [[ -n "$profile" ]] || return 1
  printf '%s\n' "$profile"
}

harness_monitor_env_flag_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

harness_monitor_allow_non_agent_runtime_profile() {
  harness_monitor_env_flag_enabled "${HARNESS_MONITOR_ALLOW_NON_AGENT_RUNTIME_PROFILE:-0}"
}

harness_monitor_is_agent_runtime_profile() {
  local profile
  profile="$(harness_monitor_sanitize_profile "$1")"
  [[ -n "$profile" && "$profile" == agent-* ]]
}

# Agent sessions may only resolve onto their own `agent-<session>` lane by
# default. Apply the rule uniformly whether the profile came from env, an
# inherited path, or fallback, and require an explicit opt-in for shared/user
# lanes instead of silently reusing someone else's state.
harness_monitor_validate_resolved_runtime_profile() {
  local profile="$1"
  local default_profile

  profile="$(harness_monitor_sanitize_profile "$profile")"
  [[ -n "$profile" ]] || return 1

  if ! harness_monitor_agent_session_id >/dev/null 2>&1; then
    return 0
  fi

  default_profile="$(harness_monitor_default_agent_runtime_profile || true)"
  if [[ -z "$default_profile" ]]; then
    printf '%s\n' \
      "Unable to derive the current agent runtime profile while validating resolved profile '$profile'." \
      >&2
    return 1
  fi
  if [[ "$profile" == "$default_profile" ]]; then
    return 0
  fi

  if harness_monitor_is_agent_runtime_profile "$profile"; then
    printf '%s\n' \
      "Agent sessions must stay on their own isolated runtime profile '$default_profile'. Resolved profile '$profile' targets a different agent session and is not allowed. Unset HARNESS_MONITOR_RUNTIME_PROFILE or clear inherited build-path env to use '$default_profile' automatically." \
      >&2
    return 1
  fi

  if harness_monitor_allow_non_agent_runtime_profile; then
    return 0
  fi

  printf '%s\n' \
    "Agent sessions must use their own isolated runtime profile '$default_profile'. Resolved profile '$profile' is not allowed. Unset HARNESS_MONITOR_RUNTIME_PROFILE or clear inherited build-path env to use '$default_profile' automatically, or set HARNESS_MONITOR_ALLOW_NON_AGENT_RUNTIME_PROFILE=1 only for an intentional shared/user lane." \
    >&2
  return 1
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

harness_monitor_port_registry_path() {
  local app_group_id
  app_group_id="$(harness_monitor_runtime_app_group_id)"
  printf '%s/Library/Group Containers/%s/%s\n' \
    "${HOME:?missing HOME}" \
    "$app_group_id" \
    "$HARNESS_MONITOR_RUNTIME_PORT_REGISTRY_FILE"
}

harness_monitor_port_registry_lock_path() {
  printf '%s.lock\n' "$(harness_monitor_port_registry_path)"
}

harness_monitor_port_lock_holder_path() {
  printf '%s/holder.pid\n' "$1"
}

harness_monitor_port_lock_record_holder() {
  local lock_path="$1"
  local holder_path
  holder_path="$(harness_monitor_port_lock_holder_path "$lock_path")"
  printf '%s\n' "$$" > "$holder_path" 2>/dev/null || true
}

# Best-effort stale-lock recovery: if the holder PID stored inside the
# lock directory belongs to a process that no longer exists, drop the
# stale lock so the current caller can retry. Without this a crashed
# bridge wedges every subsequent `bridge start` for `lock_retries *
# lock_sleep` seconds.
harness_monitor_port_lock_reclaim_if_stale() {
  local lock_path="$1"
  local holder_path holder_pid
  holder_path="$(harness_monitor_port_lock_holder_path "$lock_path")"
  [[ -f "$holder_path" ]] || return 1
  holder_pid="$(cat "$holder_path" 2>/dev/null || true)"
  [[ "$holder_pid" =~ ^[0-9]+$ ]] || return 1
  if kill -0 "$holder_pid" 2>/dev/null; then
    return 1
  fi
  rm -rf "$lock_path" 2>/dev/null || true
  return 0
}

harness_monitor_acquire_port_lock() {
  local lock_path attempt
  lock_path="$(harness_monitor_port_registry_lock_path)"
  mkdir -p "$(dirname "$lock_path")"
  for ((attempt = 0; attempt < HARNESS_MONITOR_RUNTIME_PORT_LOCK_RETRIES; attempt += 1)); do
    if mkdir "$lock_path" 2>/dev/null; then
      harness_monitor_port_lock_record_holder "$lock_path"
      printf '%s\n' "$lock_path"
      return 0
    fi
    if harness_monitor_port_lock_reclaim_if_stale "$lock_path"; then
      continue
    fi
    sleep "$HARNESS_MONITOR_RUNTIME_PORT_LOCK_SLEEP"
  done
  echo "Unable to acquire profile-port registry lock at $lock_path (delete the directory if no harness process holds it)" >&2
  return 1
}

harness_monitor_release_port_lock() {
  local lock_path="$1"
  [[ -n "$lock_path" ]] || return 0
  rm -f "$(harness_monitor_port_lock_holder_path "$lock_path")" 2>/dev/null || true
  rmdir "$lock_path" 2>/dev/null || true
}

harness_monitor_port_registry_lookup() {
  local registry_path="$1" profile="$2" line key value
  [[ -f "$registry_path" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(harness_monitor_trim_whitespace "$line")"
    [[ -n "$line" ]] || continue
    [[ "$line" != \#* ]] || continue
    key="${line%% *}"
    value="${line#* }"
    if [[ "$key" == "$profile" ]] && [[ "$value" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  done < "$registry_path"
  return 1
}

harness_monitor_port_registry_owner() {
  local registry_path="$1" target_port="$2" line key value
  [[ -f "$registry_path" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(harness_monitor_trim_whitespace "$line")"
    [[ -n "$line" ]] || continue
    [[ "$line" != \#* ]] || continue
    key="${line%% *}"
    value="${line#* }"
    if [[ "$value" == "$target_port" ]]; then
      printf '%s\n' "$key"
      return 0
    fi
  done < "$registry_path"
  return 1
}

harness_monitor_port_hash_candidate() {
  local profile="$1" hex_prefix hash_value
  hex_prefix="$(
    printf '%s' "$profile" \
      | shasum -a 256 \
      | awk '{ print substr($1, 1, 8) }'
  )"
  hash_value=$((16#$hex_prefix))
  printf '%s\n' "$((HARNESS_MONITOR_RUNTIME_CODEX_PORT_BASE + (hash_value % HARNESS_MONITOR_RUNTIME_CODEX_PORT_SPAN)))"
}

harness_monitor_port_registry_persist() {
  local registry_path="$1" profile="$2" port="$3" tmp
  mkdir -p "$(dirname "$registry_path")"
  tmp="$registry_path.tmp.$$"
  if [[ -f "$registry_path" ]]; then
    awk -v profile="$profile" '
      { sub(/[[:space:]]+$/, "") }
      $0 == "" { next }
      $0 ~ /^#/ { print; next }
      $1 == profile { next }
      { print }
    ' "$registry_path" > "$tmp"
  else
    printf '# Harness Monitor profile port registry\n' > "$tmp"
  fi
  printf '%s %s\n' "$profile" "$port" >> "$tmp"
  mv "$tmp" "$registry_path"
}

harness_monitor_port_registry_resolve() {
  local registry_path="$1" profile="$2" candidate port owner upper
  upper=$((HARNESS_MONITOR_RUNTIME_CODEX_PORT_BASE + HARNESS_MONITOR_RUNTIME_CODEX_PORT_SPAN))
  candidate="$(harness_monitor_port_hash_candidate "$profile")"
  port="$candidate"
  while :; do
    owner="$(harness_monitor_port_registry_owner "$registry_path" "$port" || true)"
    if [[ -z "$owner" ]] || [[ "$owner" == "$profile" ]]; then
      harness_monitor_port_registry_persist "$registry_path" "$profile" "$port" || return 1
      printf '%s\n' "$port"
      return 0
    fi
    port=$((port + 1))
    if (( port >= upper )); then
      port=$HARNESS_MONITOR_RUNTIME_CODEX_PORT_BASE
    fi
    if (( port == candidate )); then
      echo "Profile port registry exhausted (range $HARNESS_MONITOR_RUNTIME_CODEX_PORT_BASE-$upper)" >&2
      return 1
    fi
  done
}

harness_monitor_runtime_codex_ws_port() {
  local profile registry_path port lock_path
  if [[ -n "${HARNESS_CODEX_WS_PORT:-}" ]]; then
    printf '%s\n' "$HARNESS_CODEX_WS_PORT"
    return 0
  fi

  profile="$(harness_monitor_runtime_profile || true)"
  [[ -n "$profile" ]] || return 1
  registry_path="$(harness_monitor_port_registry_path)"

  port="$(harness_monitor_port_registry_lookup "$registry_path" "$profile" || true)"
  if [[ -n "$port" ]]; then
    printf '%s\n' "$port"
    return 0
  fi

  lock_path="$(harness_monitor_acquire_port_lock)" || return 1
  port="$(harness_monitor_port_registry_lookup "$registry_path" "$profile" || true)"
  if [[ -z "$port" ]]; then
    port="$(harness_monitor_port_registry_resolve "$registry_path" "$profile" || true)"
  fi
  harness_monitor_release_port_lock "$lock_path"

  if [[ -z "$port" ]]; then
    echo "Unable to assign codex WS port for profile $profile" >&2
    return 1
  fi
  printf '%s\n' "$port"
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
  # Strip an email-style suffix and reduce to lowercase alphanumerics so
  # the .xcuserdatad directory name follows the same shape as the
  # runtime profile name (e.g. `bartsmykla`, never
  # `bart.smykla@konghq.com`). The /Users/<USER>/ home prefix is fixed
  # by the OS and remains the only place the raw account name appears.
  if [[ "$user_name" == *"@"* ]]; then
    user_name="${user_name%%@*}"
  fi
  user_name="$(
    printf '%s' "$user_name" \
      | tr '[:upper:]' '[:lower:]' \
      | tr -cd '[:alnum:]'
  )"
  if [[ -z "$user_name" ]]; then
    user_name="user"
  fi
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

harness_monitor_runtime_xcodebuildmcp_socket_path() {
  local profile
  profile="$(harness_monitor_runtime_profile || true)"
  [[ -n "$profile" ]] || return 1
  printf '%s/.xcodebuildmcp/agents/%s.sock\n' "${HOME:?missing HOME}" "$profile"
}

harness_monitor_normalize_developer_dir() {
  local candidate="$1"
  candidate="$(harness_monitor_trim_whitespace "$candidate")"
  [[ -n "$candidate" ]] || return 1
  if [[ -d "$candidate/Contents/Developer" ]]; then
    printf '%s/Contents/Developer\n' "$candidate"
    return 0
  fi
  if [[ -d "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

harness_monitor_resolve_agent_developer_dir() {
  local candidate developer_dir
  if [[ -n "${HARNESS_MONITOR_AGENT_DEVELOPER_DIR:-}" ]]; then
    harness_monitor_normalize_developer_dir "$HARNESS_MONITOR_AGENT_DEVELOPER_DIR"
    return $?
  fi

  shopt -s nullglob
  local -a candidates=(/Applications/Xcode-*.app /Applications/Xcode*.app)
  shopt -u nullglob
  for candidate in "${candidates[@]}"; do
    if [[ "$candidate" == "/Applications/Xcode.app" ]]; then
      continue
    fi
    developer_dir="$(harness_monitor_normalize_developer_dir "$candidate" || true)"
    if [[ -n "$developer_dir" ]]; then
      printf '%s\n' "$developer_dir"
      return 0
    fi
  done
  return 1
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
