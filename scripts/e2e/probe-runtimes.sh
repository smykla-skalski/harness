#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/lib.sh
. "$SCRIPT_DIR/lib.sh"

RESULTS_FILE="$(mktemp "${TMPDIR:-/tmp}/harness-swarm-runtimes.XXXXXX")"
trap 'rm -f "$RESULTS_FILE"' EXIT

record_runtime() {
  local name="$1"
  local required="$2"
  local available="$3"
  local reason="$4"
  printf '%s\t%s\t%s\t%s\n' "$name" "$required" "$available" "$reason" >>"$RESULTS_FILE"
}

probe_versioned_binary() {
  local name="$1"
  local required="$2"
  local binary="$3"
  local auth_ok="$4"
  local auth_reason="$5"

  if ! command -v "$binary" >/dev/null 2>&1; then
    record_runtime "$name" "$required" "false" "binary '$binary' not found"
    return
  fi
  if [[ "$auth_ok" != "true" ]]; then
    record_runtime "$name" "$required" "false" "$auth_reason"
    return
  fi
  if portable_timeout 3 "$binary" --version >/dev/null 2>&1; then
    record_runtime "$name" "$required" "true" "available"
  else
    record_runtime "$name" "$required" "false" "'$binary --version' failed or timed out"
  fi
}

CLAUDE_AUTH="false"
[[ -s "$HOME/.config/claude-code/config.json" ]] && CLAUDE_AUTH="true"
probe_versioned_binary "claude" "true" "claude" "$CLAUDE_AUTH" "missing ~/.config/claude-code/config.json"

CODEX_AUTH="false"
[[ -s "$HOME/.codex/auth.json" ]] && CODEX_AUTH="true"
probe_versioned_binary "codex" "true" "codex" "$CODEX_AUTH" "missing ~/.codex/auth.json"

GEMINI_AUTH="false"
if [[ -n "${GEMINI_API_KEY:-}" || -s "$HOME/.config/gemini/credentials" ]]; then
  GEMINI_AUTH="true"
fi
probe_versioned_binary "gemini" "false" "gemini" "$GEMINI_AUTH" "missing GEMINI_API_KEY or ~/.config/gemini/credentials"

if command -v gh >/dev/null 2>&1 && gh copilot --help >/dev/null 2>&1; then
  record_runtime "copilot" "false" "true" "available"
else
  record_runtime "copilot" "false" "false" "gh copilot unavailable"
fi

probe_versioned_binary "vibe" "false" "vibe" "true" "available"
probe_versioned_binary "opencode" "false" "opencode" "true" "available"

python3 - "$RESULTS_FILE" <<'PY'
import json
import sys

runtimes = {}
required_missing = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        name, required_raw, available_raw, reason = line.rstrip("\n").split("\t", 3)
        required = required_raw == "true"
        available = available_raw == "true"
        runtimes[name] = {
            "available": available,
            "required": required,
            "reason": reason,
        }
        if required and not available:
            required_missing.append(name)

print(json.dumps({"runtimes": runtimes, "required_missing": required_missing}, indent=2, sort_keys=True))
PY
