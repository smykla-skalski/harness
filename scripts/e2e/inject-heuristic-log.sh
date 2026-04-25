#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/lib.sh
. "$SCRIPT_DIR/lib.sh"

ROOT="$(e2e_repo_root)"
SESSION_ID="${HARNESS_E2E_SESSION_ID:-}"
PROJECT_DIR="${HARNESS_E2E_PROJECT_DIR:-$ROOT}"
DATA_HOME="${HARNESS_E2E_DATA_HOME:-${XDG_DATA_HOME:-${TMPDIR:-/tmp}/harness-swarm-e2e-data}}"
HARNESS_BINARY="${HARNESS_E2E_HARNESS_BINARY:-$(e2e_resolve_harness_binary "$ROOT")}"
AGENT_ID=""
RUNTIME=""
RUNTIME_SESSION_ID=""
CODE=""

while (($#)); do
  case "$1" in
    --agent) AGENT_ID="$2"; shift 2 ;;
    --code) CODE="$2"; shift 2 ;;
    --session-id) SESSION_ID="$2"; shift 2 ;;
    --project-dir) PROJECT_DIR="$2"; shift 2 ;;
    --runtime) RUNTIME="$2"; shift 2 ;;
    --runtime-session-id) RUNTIME_SESSION_ID="$2"; shift 2 ;;
    --data-home) DATA_HOME="$2"; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

if [[ -z "$AGENT_ID" || -z "$CODE" ]]; then
  printf 'usage: %s --agent <agent-id> --code <issue-code> [--session-id SID]\n' "$0" >&2
  exit 64
fi

run_harness() {
  XDG_DATA_HOME="$DATA_HOME" HARNESS_DAEMON_DATA_HOME="$DATA_HOME" "$HARNESS_BINARY" "$@"
}

if [[ -z "$RUNTIME" || -z "$RUNTIME_SESSION_ID" ]]; then
  if [[ -z "$SESSION_ID" ]]; then
    printf 'runtime lookup requires --session-id when --runtime is omitted\n' >&2
    exit 64
  fi
  agent_json="$(
    run_harness session status "$SESSION_ID" --json --project-dir "$PROJECT_DIR" \
      | jq -er --arg agent "$AGENT_ID" '.agents[] | select(.agent_id == $agent)'
  )"
  if [[ -z "$RUNTIME" ]]; then
    RUNTIME="$(printf '%s\n' "$agent_json" | jq -r '.runtime')"
  fi
  if [[ -z "$RUNTIME_SESSION_ID" || "$RUNTIME_SESSION_ID" == "null" ]]; then
    RUNTIME_SESSION_ID="$(printf '%s\n' "$agent_json" | jq -r --arg sid "$SESSION_ID" '.agent_session_id // $sid')"
  fi
fi

CONTEXT_ROOT="$(e2e_project_context_root "$PROJECT_DIR" "$DATA_HOME")"
LOG_PATH="$CONTEXT_ROOT/agents/sessions/$RUNTIME/$RUNTIME_SESSION_ID/raw.jsonl"
mkdir -p "$(dirname -- "$LOG_PATH")"

APP_E2E_TOOL_PACKAGE="$ROOT/apps/harness-monitor-macos/Tools/HarnessMonitorE2E"
APP_E2E_TOOL_BINARY="${HARNESS_MONITOR_E2E_TOOL_BINARY:-$APP_E2E_TOOL_PACKAGE/.build/release/harness-monitor-e2e}"
if [[ ! -x "$APP_E2E_TOOL_BINARY" ]]; then
  swift build -c release --package-path "$APP_E2E_TOOL_PACKAGE" >&2
fi
"$APP_E2E_TOOL_BINARY" inject-heuristic --code "$CODE" --log-path "$LOG_PATH"
