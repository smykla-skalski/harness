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

python3 - "$CODE" "$LOG_PATH" <<'PY'
import json
import sys

code, log_path = sys.argv[1:]

def message(role, content, timestamp="2026-03-28T12:00:00Z"):
    return {
        "timestamp": timestamp,
        "message": {
            "role": role,
            "content": content,
        },
    }

def text_block(text):
    return {"type": "text", "text": text}

def tool_use(tool_id, name, input_data):
    return message(
        "assistant",
        [{
            "type": "tool_use",
            "id": tool_id,
            "name": name,
            "input": input_data,
        }],
    )

def tool_result(tool_use_id, text, *, is_error=False, tool_name=None):
    block = {
        "type": "tool_result",
        "tool_use_id": tool_use_id,
        "content": [text_block(text)],
        "is_error": is_error,
    }
    if tool_name is not None:
        block["tool_name"] = tool_name
    return message("user", [block])

def assistant_text(text):
    return message("assistant", [text_block(text)])

fixtures = {
    "python_traceback_output": [
        tool_use("heuristic-python-traceback", "Bash", {"command": "python foo.py"}),
        tool_result(
            "heuristic-python-traceback",
            "Traceback (most recent call last):\n  File \"foo.py\", line 1, in <module>\n  ValueError: bad",
            is_error=True,
            tool_name="Bash",
        ),
    ],
    "unauthorized_git_commit_during_run": [
        tool_use(
            "heuristic-git-commit",
            "Bash",
            {"command": "git commit -m 'mid-run'"},
        ),
    ],
    "python_used_in_bash_tool_use": [
        tool_use(
            "heuristic-python-bash",
            "Bash",
            {"command": "python -c 'import os; print(1)'"},
        ),
    ],
    "absolute_manifest_path_used": [
        tool_use(
            "heuristic-absolute-manifest",
            "Bash",
            {"command": "harness apply /Users/bart/proj/manifest.json"},
        ),
    ],
    "jq_error_in_command_output": [
        tool_use("heuristic-jq-error", "Bash", {"command": "jq '.foo' data.json"}),
        tool_result(
            "heuristic-jq-error",
            "jq: error (at <stdin>:1): Cannot index array",
            is_error=True,
            tool_name="Bash",
        ),
    ],
    "unverified_recursive_remove": [
        tool_use(
            "heuristic-unverified-rm",
            "Bash",
            {"command": "rm -rf /tmp/some-dir"},
        ),
    ],
    "hook_denied_tool_call": [
        assistant_text(
            "The system denied this tool call because it was blocked by hook policy"
        ),
    ],
    "agent_repeated_error": [
        assistant_text("E: same"),
        assistant_text("E: same"),
    ],
    "agent_stalled_progress": [
        assistant_text("no observable progress for more than 301 seconds"),
    ],
    "cross_agent_file_conflict": [
        tool_use(
            "heuristic-cross-agent-file",
            "Write",
            {"file_path": "src/foo.rs", "content": "fn main() {}\n"},
        ),
        tool_result(
            "heuristic-cross-agent-file",
            "The file src/foo.rs has been updated successfully",
            tool_name="Write",
        ),
    ],
}

if code not in fixtures:
    raise SystemExit(f"unknown heuristic code: {code}")

with open(log_path, "a", encoding="utf-8") as handle:
    for item in fixtures[code]:
        handle.write(json.dumps(item, sort_keys=True))
        handle.write("\n")

print(json.dumps({"code": code, "log_path": log_path}, sort_keys=True))
PY
