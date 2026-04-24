#!/usr/bin/env bash
# Regression tests for the local Harness Monitor MCP helper scripts.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"

RUN_ID="$$"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/mcp-scripts-test-$RUN_ID.XXXXXX")"
PASS_COUNT=0
FAIL_COUNT=0
FAIL_NAMES=()
CURRENT_TEST=""

cleanup() {
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

log() {
  printf '%s\n' "$*" >&2
}

start_test() {
  CURRENT_TEST="$1"
  log "RUN:  $CURRENT_TEST"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAIL_NAMES+=("$CURRENT_TEST")
  log "  FAIL: $CURRENT_TEST - $*"
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  log "  PASS: $CURRENT_TEST"
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  if grep -Fq -- "$needle" <<<"$haystack"; then
    return 0
  fi
  fail "missing '$needle' in output: $haystack"
  return 1
}

make_stale_socket() {
  local socket_path="$1"
  python3 - "$socket_path" <<'PY'
import socket
import sys

path = sys.argv[1]
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind(path)
sock.close()
PY
}

write_fake_harness() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/harness" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
  printf 'harness 0.0.0-test\n'
  exit 0
fi

if [[ "${1:-}" == "mcp" && "${2:-}" == "serve" ]]; then
  while IFS= read -r line; do
    case "$line" in
      *'"method":"initialize"'*)
        printf '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","serverInfo":{"name":"fake","version":"0"},"capabilities":{"tools":{}}}}\n'
        ;;
      *'"method":"tools/list"'*)
        printf '{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}\n'
        ;;
      *'"method":"tools/call"'*)
        printf '{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"socket unavailable"}],"isError":true}}\n'
        ;;
    esac
  done
  exit 0
fi

printf 'unexpected fake harness args: %s\n' "$*" >&2
exit 2
EOF
  chmod +x "$bin_dir/harness"
}

scenario_wait_socket_rejects_stale_socket() {
  start_test "wait-socket rejects stale socket file"
  local socket_path="$SANDBOX/stale.sock"
  make_stale_socket "$socket_path"

  local output status=0
  output="$(HARNESS_MONITOR_MCP_SOCKET="$socket_path" \
    "$ROOT/scripts/mcp-wait-socket.sh" 1 2>&1)" || status=$?

  if (( status == 0 )); then
    fail "expected nonzero status for stale socket, got 0 (output: $output)"
    return
  fi

  local ok=1
  if [[ "$output" != *"not accepting connections"* && "$output" != *"exists but is not a socket"* ]]; then
    fail "expected stale socket rejection, got: $output"
    ok=0
  fi
  assert_contains "$socket_path" "$output" || ok=0
  if (( ok )); then pass; fi
}

scenario_doctor_fails_stale_socket() {
  start_test "doctor fails stale socket file"
  local socket_path="$SANDBOX/doctor-stale.sock"
  local fake_bin="$SANDBOX/fake-bin"
  make_stale_socket "$socket_path"
  write_fake_harness "$fake_bin"

  local output status=0
  output="$(PATH="$fake_bin:$PATH" HARNESS_MONITOR_MCP_SOCKET="$socket_path" \
    "$ROOT/scripts/mcp-doctor.sh" 2>&1)" || status=$?

  if (( status == 0 )); then
    fail "expected doctor to fail stale socket, got 0 (output: $output)"
    return
  fi

  local ok=1
  assert_contains "socket is not accepting connections" "$output" || ok=0
  assert_contains "FAIL:" "$output" || ok=0
  if (( ok )); then pass; fi
}

scenario_smoke_fails_tool_error_result() {
  start_test "smoke fails when tool call returns isError"
  local fake_bin="$SANDBOX/smoke-bin"
  write_fake_harness "$fake_bin"

  local output status=0
  output="$(
    HARNESS_MCP_SMOKE_HARNESS_BIN="$fake_bin/harness" \
      "$ROOT/scripts/mcp-smoke.sh" list_windows 2>&1
  )" || status=$?

  if (( status == 0 )); then
    fail "expected smoke to fail tool error result, got 0 (output: $output)"
    return
  fi

  local ok=1
  assert_contains '"isError": true' "$output" || ok=0
  assert_contains "error: MCP smoke received an error response" "$output" || ok=0
  if (( ok )); then pass; fi
}

run_all() {
  scenario_wait_socket_rejects_stale_socket
  scenario_doctor_fails_stale_socket
  scenario_smoke_fails_tool_error_result
}

run_all

log "----"
log "mcp script tests: $PASS_COUNT passed, $FAIL_COUNT failed"
if (( FAIL_COUNT > 0 )); then
  log "failures:"
  for name in "${FAIL_NAMES[@]}"; do
    log "  - $name"
  done
  exit 1
fi
