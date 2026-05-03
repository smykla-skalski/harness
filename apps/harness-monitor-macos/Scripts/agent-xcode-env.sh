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

HARNESS_MONITOR_AGENT_SAFE_XCODEBUILDMCP_WORKFLOWS="coverage,debugging,device,logging,macos,project-discovery,project-scaffolding,simulator,simulator-management,swift-package,ui-automation,utilities"
AGENT_DEVELOPER_DIR=""

env_flag_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_agent_runtime_profile() {
  local profile
  profile="$(harness_monitor_sanitize_profile "${HARNESS_MONITOR_RUNTIME_PROFILE:-}")"
  if [[ -n "$profile" ]]; then
    printf '%s\n' "$profile"
    return 0
  fi

  profile="$(harness_monitor_default_agent_runtime_profile || true)"
  if [[ -z "$profile" ]]; then
    printf '%s\n' \
      'Unable to derive an agent runtime profile. Set HARNESS_MONITOR_RUNTIME_PROFILE or one of HARNESS_AGENT_ID / CODEX_SESSION_ID / CLAUDE_SESSION_ID / GEMINI_SESSION_ID / COPILOT_SESSION_ID / OPENCODE_SESSION_ID / VIBE_SESSION_ID.' \
      >&2
    exit 1
  fi
  printf '%s\n' "$profile"
}

configured_xcode_ide_session() {
  [[ -n "${XCODEBUILDMCP_XCODE_PID:-${MCP_XCODE_PID:-}}" ]] \
    || [[ -n "${XCODEBUILDMCP_XCODE_SESSION_ID:-${MCP_XCODE_SESSION_ID:-}}" ]]
}

agent_xcode_ide_allowed() {
  env_flag_enabled "${HARNESS_MONITOR_AGENT_ALLOW_XCODE_IDE:-0}" \
    && [[ -n "${DEVELOPER_DIR:-}" ]] \
    && configured_xcode_ide_session
}

selected_developer_dir() {
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    printf '%s\n' "$DEVELOPER_DIR"
    return 0
  fi
  /usr/bin/xcode-select -p 2>/dev/null || true
}

configure_agent_xcode_environment() {
  local derived_data_path socket_path

  export HARNESS_MONITOR_RUNTIME_PROFILE
  HARNESS_MONITOR_RUNTIME_PROFILE="$(resolve_agent_runtime_profile)"
  harness_monitor_apply_runtime_profile_environment

  derived_data_path="$(harness_monitor_runtime_derived_data_path "$COMMON_REPO_ROOT" "xcode-derived")"
  export XCODEBUILD_DERIVED_DATA_PATH="$derived_data_path"
  export XCODEBUILDMCP_WORKSPACE_PATH="${XCODEBUILDMCP_WORKSPACE_PATH:-$ROOT/HarnessMonitor.xcworkspace}"
  export XCODEBUILDMCP_SCHEME="${XCODEBUILDMCP_SCHEME:-HarnessMonitor}"
  export XCODEBUILDMCP_CONFIGURATION="${XCODEBUILDMCP_CONFIGURATION:-Debug}"
  export XCODEBUILDMCP_DERIVED_DATA_PATH="$derived_data_path"

  socket_path="$(harness_monitor_runtime_xcodebuildmcp_socket_path)"
  mkdir -p "$(dirname "$socket_path")"
  export XCODEBUILDMCP_SOCKET="$socket_path"
  export XCODEBUILDCLI_SOCKET="$socket_path"

  AGENT_DEVELOPER_DIR="$(harness_monitor_resolve_agent_developer_dir || true)"
  if [[ -z "${DEVELOPER_DIR:-}" ]] && [[ -n "$AGENT_DEVELOPER_DIR" ]]; then
    export DEVELOPER_DIR="$AGENT_DEVELOPER_DIR"
  fi

  if [[ -z "${XCODEBUILDMCP_ENABLED_WORKFLOWS:-}" ]] && ! agent_xcode_ide_allowed; then
    export XCODEBUILDMCP_ENABLED_WORKFLOWS="$HARNESS_MONITOR_AGENT_SAFE_XCODEBUILDMCP_WORKFLOWS"
  fi
}

ensure_safe_xcode_ide_usage() {
  if [[ "${1:-}" == "xcodebuildmcp" ]] && [[ "${2:-}" == "xcode-ide" ]] && ! agent_xcode_ide_allowed; then
    printf '%s\n' \
      'agent Xcode IDE tools are disabled by default to avoid attaching to the user'\''s running Xcode. Set HARNESS_MONITOR_AGENT_ALLOW_XCODE_IDE=1, point HARNESS_MONITOR_AGENT_DEVELOPER_DIR at a separate Xcode install, and provide XCODEBUILDMCP_XCODE_PID or XCODEBUILDMCP_XCODE_SESSION_ID for that dedicated Xcode session before using xcodebuildmcp xcode-ide.' \
      >&2
    exit 1
  fi
}

configure_agent_xcode_environment
ensure_safe_xcode_ide_usage "$@"

if (( $# == 0 )); then
  printf 'Harness Monitor agent profile: %s\n' "$HARNESS_MONITOR_RUNTIME_PROFILE"
  printf 'DerivedData: %s\n' "${XCODEBUILD_DERIVED_DATA_PATH:-}"
  printf 'Daemon data home: %s\n' "${HARNESS_DAEMON_DATA_HOME:-}"
  printf 'Codex WS port: %s\n' "${HARNESS_CODEX_WS_PORT:-}"
  printf 'Launch agent label: %s\n' "${HARNESS_MONITOR_DAEMON_LAUNCH_AGENT_LABEL:-}"
  printf 'XcodeBuildMCP socket: %s\n' "${XCODEBUILDMCP_SOCKET:-}"
  printf 'Xcode developer dir: %s\n' "$(selected_developer_dir)"
  if [[ -n "$AGENT_DEVELOPER_DIR" ]]; then
    printf 'Agent Xcode install: isolated via DEVELOPER_DIR\n'
  else
    printf 'Agent Xcode install: shared default (no alternate /Applications/Xcode*.app detected)\n'
  fi
  if agent_xcode_ide_allowed; then
    printf 'Xcode IDE tools: enabled with explicit dedicated session\n'
  else
    printf 'Xcode IDE tools: disabled for agent isolation\n'
  fi
  printf '\nNext commands:\n'
  printf '  mise run monitor:agent:build\n'
  printf '  mise run monitor:agent:test\n'
  printf '  mise run monitor:agent:daemon:dev\n'
  printf '  mise run monitor:agent:bridge:start\n'
  printf '  mise run monitor:agent:xcodebuild -- ...\n'
  printf '  mise run monitor:agent:xcodebuildmcp -- macos build --scheme HarnessMonitor\n'
  printf '  mise run monitor:agent:mcp\n'
  exit 0
fi

exec "$@"
