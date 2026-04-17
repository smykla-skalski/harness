#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
STACK_ROOT="$ROOT/resources/observability"
COMPOSE_FILE="$STACK_ROOT/docker-compose.yml"
PROJECT_NAME="${HARNESS_OBSERVABILITY_PROJECT_NAME:-harness-observability}"
GRAFANA_URL="${HARNESS_GRAFANA_URL:-http://127.0.0.1:3000}"
PROMETHEUS_URL="${HARNESS_PROMETHEUS_URL:-http://127.0.0.1:9090}"
TEMPO_URL="${HARNESS_TEMPO_URL:-http://127.0.0.1:3200}"
LOKI_URL="${HARNESS_LOKI_URL:-http://127.0.0.1:3100}"
ALLOY_URL="${HARNESS_ALLOY_URL:-http://127.0.0.1:12345}"
OTLP_GRPC_ENDPOINT="${HARNESS_OTLP_GRPC_ENDPOINT:-http://127.0.0.1:4317}"
OTLP_HTTP_ENDPOINT="${HARNESS_OTLP_HTTP_ENDPOINT:-http://127.0.0.1:4318}"

compose() {
  docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
}

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'required tool not found: %s\n' "$tool" >&2
    exit 1
  fi
}

resolve_data_root() {
  if [ -n "${XDG_DATA_HOME:-}" ]; then
    printf '%s\n' "$XDG_DATA_HOME"
    return
  fi
  if [ "$(uname -s)" = "Darwin" ]; then
    printf '%s\n' "$HOME/Library/Application Support"
    return
  fi
  printf '%s\n' "${HOME}/.local/share"
}

shared_config_path() {
  printf '%s/harness/observability/config.json\n' "$(resolve_data_root)"
}

write_shared_config() {
  local config_path
  config_path="$(shared_config_path)"
  mkdir -p "$(dirname "$config_path")"
  cat >"$config_path" <<EOF
{
  "enabled": true,
  "grpc_endpoint": "${OTLP_GRPC_ENDPOINT}",
  "http_endpoint": "${OTLP_HTTP_ENDPOINT}",
  "grafana_url": "${GRAFANA_URL}",
  "tempo_url": "${TEMPO_URL}",
  "loki_url": "${LOKI_URL}",
  "prometheus_url": "${PROMETHEUS_URL}",
  "headers": {}
}
EOF
  printf '%s\n' "$config_path"
}

remove_shared_config() {
  local config_path
  config_path="$(shared_config_path)"
  rm -f "$config_path"
}

wait_for_url() {
  local url="$1"
  local description="$2"
  local attempt=0
  until curl -fsS "$url" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 60 ]; then
      printf 'timed out waiting for %s at %s\n' "$description" "$url" >&2
      exit 1
    fi
    sleep 2
  done
}

start_stack() {
  require_tool docker
  require_tool curl
  compose up -d
  wait_for_url "$PROMETHEUS_URL/-/ready" "Prometheus"
  wait_for_url "$TEMPO_URL/ready" "Tempo"
  wait_for_url "$LOKI_URL/ready" "Loki"
  wait_for_url "$GRAFANA_URL/api/health" "Grafana"
  wait_for_url "$ALLOY_URL/-/ready" "Alloy"
  local config_path
  config_path="$(write_shared_config)"
  printf 'Grafana: %s\n' "$GRAFANA_URL"
  printf 'Prometheus: %s\n' "$PROMETHEUS_URL"
  printf 'Tempo: %s\n' "$TEMPO_URL"
  printf 'Loki: %s\n' "$LOKI_URL"
  printf 'Alloy: %s\n' "$ALLOY_URL"
  printf 'Shared config: %s\n' "$config_path"
}

stop_stack() {
  compose down --remove-orphans
  remove_shared_config
}

reset_stack() {
  compose down --volumes --remove-orphans
  remove_shared_config
}

show_status() {
  compose ps
  printf '\nShared config: %s\n' "$(shared_config_path)"
}

show_logs() {
  compose logs -f
}

open_grafana() {
  if [ "$(uname -s)" = "Darwin" ] && command -v open >/dev/null 2>&1; then
    open "$GRAFANA_URL"
    return
  fi
  printf '%s\n' "$GRAFANA_URL"
}

wait_for_signal() {
  local url="$1"
  local description="$2"
  local query="$3"
  local attempt=0
  local response
  local compact_response
  while true; do
    response="$(curl -fsS -G --data-urlencode "$query" "$url" 2>/dev/null || true)"
    compact_response="$(printf '%s' "$response" | tr -d '\n\r')"
    if [ -n "$compact_response" ] && response_contains_signal "$compact_response"; then
      return
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 30 ]; then
      printf 'timed out waiting for %s\n' "$description" >&2
      exit 1
    fi
    sleep 2
  done
}

response_contains_signal() {
  local response="$1"

  if printf '%s' "$response" | grep -Eq '"traces":[[:space:]]*\[[[:space:]]*\{'; then
    return 0
  fi

  if ! printf '%s' "$response" | grep -Eq '"status":"success"'; then
    return 1
  fi

  printf '%s' "$response" | grep -Eq '"result":[[:space:]]*\[[[:space:]]*\{'
}

run_cli_smoke() {
  HARNESS_OTEL_EXPORT=1 \
  OTEL_EXPORTER_OTLP_ENDPOINT="$OTLP_GRPC_ENDPOINT" \
  "$ROOT/scripts/cargo-local.sh" run --quiet -- daemon status >/dev/null
}

run_hook_smoke() {
  printf '%s' '{"hook_event_name":"PreToolUse","session_id":"observability-smoke-session","tool_name":"Read","tool_input":{"file_path":"Cargo.toml"}}' \
    | HARNESS_OTEL_EXPORT=1 \
      OTEL_EXPORTER_OTLP_ENDPOINT="$OTLP_GRPC_ENDPOINT" \
      "$ROOT/scripts/cargo-local.sh" run --quiet -- hook --agent codex suite:run tool-guard >/dev/null
}

run_bridge_smoke() {
  HARNESS_OTEL_EXPORT=1 \
  OTEL_EXPORTER_OTLP_ENDPOINT="$OTLP_GRPC_ENDPOINT" \
  "$ROOT/scripts/cargo-local.sh" run --quiet -- bridge status >/dev/null || true
}

smoke_stack() {
  local now_seconds
  local loki_start
  local loki_end

  start_stack
  run_cli_smoke
  run_hook_smoke
  run_bridge_smoke

  now_seconds="$(date +%s)"
  loki_start="$((now_seconds - 600))000000000"
  loki_end="${now_seconds}000000000"

  wait_for_signal \
    "$PROMETHEUS_URL/api/v1/query" \
    "Prometheus harness metrics" \
    "query=sum(harness_hook_outcomes_total)+sum(harness_daemon_client_requests_total)"
  wait_for_signal \
    "$LOKI_URL/loki/api/v1/query_range?start=$loki_start&end=$loki_end&limit=20" \
    "Loki harness logs" \
    "query={service_name=~\"harness-cli|harness-hook|harness-bridge\"}"
  wait_for_signal \
    "$TEMPO_URL/api/search" \
    "Tempo traces" \
    "q={resource.service.name=~\"harness-cli|harness-hook|harness-bridge\"}"

  printf 'observability smoke passed\n'
}

command="${1:-}"

case "$command" in
  start)
    start_stack
    ;;
  stop)
    stop_stack
    ;;
  status)
    show_status
    ;;
  logs)
    show_logs
    ;;
  open)
    open_grafana
    ;;
  reset)
    reset_stack
    ;;
  smoke)
    smoke_stack
    ;;
  *)
    cat <<'EOF' >&2
usage: scripts/observability.sh <start|stop|status|logs|open|reset|smoke>
EOF
    exit 1
    ;;
esac
