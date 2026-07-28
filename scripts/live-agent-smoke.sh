#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENROUTER_MODEL="deepseek/deepseek-v4-flash"
CODEX_MODEL="gpt-5.4-mini"

if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  printf 'live agent smoke stopped before network: stage=credential runtime=openrouter requested_model=%s: OPENROUTER_API_KEY is missing or empty\n' "$OPENROUTER_MODEL" >&2
  exit 1
fi
if [[ -z "${CODEX_HOME:-}" || ! -d "$CODEX_HOME" ]]; then
  printf 'live agent smoke stopped before network: stage=credential runtime=codex requested_model=%s: CODEX_HOME is missing or not a directory\n' "$CODEX_MODEL" >&2
  exit 1
fi
codex_path="$(command -v codex || true)"
if [[ -z "$codex_path" ]]; then
  printf 'live agent smoke stopped before network: stage=runtime runtime=codex requested_model=%s: codex is not on PATH\n' "$CODEX_MODEL" >&2
  exit 1
fi

"$ROOT/scripts/cargo-local.sh" build \
  -p harness \
  -p harness-daemon \
  -p harness-bridge \
  --bin harness \
  --bin harness-daemon \
  --bin harness-bridge
"$ROOT/scripts/cargo-local.sh" build --manifest-path "$ROOT/crates/harness-openrouter-agent/Cargo.toml"
target_dir="$("$ROOT/scripts/cargo-local.sh" --print-target-dir)"

export HARNESS_LIVE_CODEX_PATH="$codex_path"
PATH="$target_dir/debug:$PATH" "$ROOT/scripts/cargo-local.sh" nextest run \
  --config-file "$ROOT/.config/nextest.toml" \
  --user-config-file none \
  -p harness \
  --test integration_daemon \
  --features full-runtime \
  --run-ignored only \
  --success-output immediate \
  --failure-output immediate \
  -E 'test(=integration::daemon_control::live_agents_headless::openrouter_and_codex_complete_without_monitor)'
