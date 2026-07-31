#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENROUTER_MODEL="deepseek/deepseek-v4-flash"

if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  printf 'live review stopped before network: stage=credential runtime=openrouter requested_model=%s: OPENROUTER_API_KEY is missing or empty\n' "$OPENROUTER_MODEL" >&2
  exit 1
fi
if [[ -z "${HARNESS_LIVE_REVIEW_PR_URL:-}" ]]; then
  printf 'live review stopped before network: stage=target: HARNESS_LIVE_REVIEW_PR_URL is missing or empty\n' >&2
  exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
  printf 'live review stopped before network: stage=credential runtime=github: gh is not on PATH\n' >&2
  exit 1
fi
github_token="$(gh auth token 2>/dev/null || true)"
if [[ -z "$github_token" ]]; then
  printf 'live review stopped before network: stage=credential runtime=github: gh has no authenticated token\n' >&2
  exit 1
fi

"$ROOT/scripts/cargo-local.sh" build \
  -p harness \
  -p harness-daemon-bin \
  -p harness-bridge \
  --bin harness \
  --bin harness-daemon \
  --bin harness-bridge
"$ROOT/scripts/cargo-local.sh" build --manifest-path "$ROOT/crates/harness-openrouter-agent/Cargo.toml"
target_dir="$("$ROOT/scripts/cargo-local.sh" --print-target-dir)"

export HARNESS_LIVE_GITHUB_TOKEN="$github_token"
export HARNESS_LIVE_REVIEW_SOURCE_REPO="$ROOT"
PATH="$target_dir/debug:$PATH" "$ROOT/scripts/cargo-local.sh" nextest run \
  --config-file "$ROOT/.config/nextest.toml" \
  --user-config-file none \
  -p harness \
  --test integration_daemon \
  --features full-runtime \
  --run-ignored only \
  --success-output immediate \
  --failure-output immediate \
  -E 'test(=integration::daemon_control::live_report_only_review::requested_review_reaches_a_durable_report_without_mutation)'
