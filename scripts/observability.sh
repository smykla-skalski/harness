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
PYROSCOPE_URL="${HARNESS_PYROSCOPE_URL:-http://127.0.0.1:4040}"
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

monitor_smoke_data_home_marker_path() {
  printf '%s/tmp/observability/monitor-smoke-data-home.txt\n' "$ROOT"
}

write_shared_config() {
  local monitor_smoke_enabled="${1:-false}"
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
  "pyroscope_url": "${PYROSCOPE_URL}",
  "monitor_smoke_enabled": ${monitor_smoke_enabled},
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

write_monitor_smoke_data_home_marker() {
  local marker_path
  marker_path="$(monitor_smoke_data_home_marker_path)"
  mkdir -p "$(dirname "$marker_path")"
  printf '%s\n' "$(resolve_data_root)" >"$marker_path"
}

remove_monitor_smoke_data_home_marker() {
  rm -f "$(monitor_smoke_data_home_marker_path)"
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

grafana_api() {
  curl -fsS -u "admin:admin" "$@"
}

wait_for_file() {
  local path="$1"
  local description="$2"
  local attempt=0
  until [ -f "$path" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 60 ]; then
      printf 'timed out waiting for %s at %s\n' "$description" "$path" >&2
      exit 1
    fi
    sleep 1
  done
}

start_stack() {
  require_tool docker
  require_tool curl
  compose up -d
  wait_for_url "$PROMETHEUS_URL/-/ready" "Prometheus"
  wait_for_url "$TEMPO_URL/ready" "Tempo"
  wait_for_url "$LOKI_URL/ready" "Loki"
  wait_for_url "$PYROSCOPE_URL/ready" "Pyroscope"
  wait_for_url "$GRAFANA_URL/api/health" "Grafana"
  wait_for_url "$ALLOY_URL/-/ready" "Alloy"
  local config_path
  config_path="$(write_shared_config false)"
  printf 'Grafana: %s\n' "$GRAFANA_URL"
  printf 'Prometheus: %s\n' "$PROMETHEUS_URL"
  printf 'Tempo: %s\n' "$TEMPO_URL"
  printf 'Loki: %s\n' "$LOKI_URL"
  printf 'Pyroscope: %s\n' "$PYROSCOPE_URL"
  printf 'Alloy: %s\n' "$ALLOY_URL"
  printf 'Shared config: %s\n' "$config_path"
}

stop_stack() {
  compose down --remove-orphans
  remove_shared_config
  remove_monitor_smoke_data_home_marker
}

reset_stack() {
  compose down --volumes --remove-orphans
  remove_shared_config
  remove_monitor_smoke_data_home_marker
}

wipe_stack() {
  compose down --remove-orphans
  remove_shared_config
  remove_monitor_smoke_data_home_marker
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
  OTEL_EXPORTER_OTLP_ENDPOINT= \
  OTEL_EXPORTER_OTLP_HEADERS= \
  OTEL_EXPORTER_OTLP_PROTOCOL= \
  HARNESS_OTEL_EXPORT= \
  HARNESS_OTEL_GRAFANA_URL= \
  HARNESS_OTEL_PYROSCOPE_URL= \
  "$ROOT/scripts/cargo-local.sh" run --quiet -- session list --json >/dev/null
}

run_hook_smoke() {
  printf '%s' '{"hook_event_name":"PreToolUse","session_id":"observability-smoke-session","tool_name":"Read","tool_input":{"file_path":"Cargo.toml"}}' \
    | OTEL_EXPORTER_OTLP_ENDPOINT= \
      OTEL_EXPORTER_OTLP_HEADERS= \
      OTEL_EXPORTER_OTLP_PROTOCOL= \
      HARNESS_OTEL_EXPORT= \
      HARNESS_OTEL_GRAFANA_URL= \
      HARNESS_OTEL_PYROSCOPE_URL= \
      "$ROOT/scripts/cargo-local.sh" run --quiet -- hook --agent codex suite:run tool-guard >/dev/null
}

run_bridge_smoke() {
  OTEL_EXPORTER_OTLP_ENDPOINT= \
  OTEL_EXPORTER_OTLP_HEADERS= \
  OTEL_EXPORTER_OTLP_PROTOCOL= \
  HARNESS_OTEL_EXPORT= \
  HARNESS_OTEL_GRAFANA_URL= \
  HARNESS_OTEL_PYROSCOPE_URL= \
  "$ROOT/scripts/cargo-local.sh" run --quiet -- bridge status >/dev/null || true
}

run_daemon_server_smoke() {
  local daemon_home daemon_root manifest_path daemon_log daemon_pid endpoint token_path token
  daemon_home="$(mktemp -d "${TMPDIR:-/tmp}/harness-observability-daemon.XXXXXX")"
  daemon_root="$daemon_home/harness/daemon"
  manifest_path="$daemon_root/manifest.json"
  daemon_log="$daemon_home/daemon.log"
  daemon_pid=""

  cleanup_daemon_server_smoke() {
    if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" >/dev/null 2>&1; then
      HARNESS_DAEMON_DATA_HOME="$daemon_home" \
      "$ROOT/scripts/cargo-local.sh" run --quiet -- daemon stop --json >/dev/null 2>&1 || true
      wait_for_process_exit "$daemon_pid" 15 || kill "$daemon_pid" >/dev/null 2>&1 || true
      wait_for_process_exit "$daemon_pid" 5 || kill -9 "$daemon_pid" >/dev/null 2>&1 || true
    fi
    rm -rf "$daemon_home"
  }

  trap cleanup_daemon_server_smoke RETURN

  HARNESS_DAEMON_DATA_HOME="$daemon_home" \
  OTEL_EXPORTER_OTLP_ENDPOINT= \
  OTEL_EXPORTER_OTLP_HEADERS= \
  OTEL_EXPORTER_OTLP_PROTOCOL= \
  HARNESS_OTEL_EXPORT= \
  HARNESS_OTEL_GRAFANA_URL= \
  HARNESS_OTEL_PYROSCOPE_URL= \
  "$ROOT/scripts/cargo-local.sh" run --quiet -- daemon serve --host 127.0.0.1 --port 0 \
    >"$daemon_log" 2>&1 &
  daemon_pid="$!"

  wait_for_file "$manifest_path" "daemon manifest"
  read -r endpoint token_path < <(wait_for_daemon_ready "$manifest_path")
  token="$(tr -d '\r\n' <"$token_path")"
  curl -fsS \
    -H "Authorization: Bearer $token" \
    "$endpoint/v1/health" >/dev/null

  HARNESS_DAEMON_DATA_HOME="$daemon_home" \
  "$ROOT/scripts/cargo-local.sh" run --quiet -- daemon stop --json >/dev/null
  wait_for_process_exit "$daemon_pid" 15 || {
    printf 'daemon did not exit cleanly; log follows\n' >&2
    cat "$daemon_log" >&2
    exit 1
  }
  daemon_pid=""
  trap - RETURN
  cleanup_daemon_server_smoke
}

enumerate_monitor_test_classes() {
  local enum_json
  enum_json="$ROOT/tmp/harness-monitor-test-enumeration.json"
  mkdir -p "$(dirname "$enum_json")"
  "$ROOT/apps/harness-monitor-macos/Scripts/xcodebuild-with-lock.sh" \
    -project "$ROOT/apps/harness-monitor-macos/HarnessMonitor.xcodeproj" \
    -scheme "HarnessMonitor" \
    -configuration Debug \
    -derivedDataPath "$ROOT/tmp/xcode-derived" \
    -skipPackagePluginValidation \
    test \
    CODE_SIGNING_ALLOWED=NO \
    -destination 'platform=macOS' \
    -skip-testing:HarnessMonitorUITests \
    -only-testing:HarnessMonitorKitTests \
    -enumerate-tests \
    -test-enumeration-format json \
    -test-enumeration-style hierarchical \
    -test-enumeration-output-path "$enum_json" \
    >/dev/null
  jq -r '.. | objects | select(.kind? == "class") | .name' "$enum_json"
}

monitor_smoke_skip_args() {
  local class_name
  while IFS= read -r class_name; do
    [ -n "$class_name" ] || continue
    [ "$class_name" = "HarnessMonitorObservabilitySmokeTests" ] && continue
    printf '%s\0' "-skip-testing:HarnessMonitorKitTests/${class_name}"
  done < <(enumerate_monitor_test_classes | sort -u)
}

run_monitor_smoke() {
  local log_path
  local -a smoke_skip_args=()
  log_path="$(mktemp "${TMPDIR:-/tmp}/harness-monitor-otel-smoke.XXXXXX.log")"
  while IFS= read -r -d '' skip_arg; do
    smoke_skip_args+=("$skip_arg")
  done < <(monitor_smoke_skip_args)
  write_shared_config true >/dev/null
  write_monitor_smoke_data_home_marker
  trap 'write_shared_config false >/dev/null || true; remove_monitor_smoke_data_home_marker; rm -f "$log_path"' RETURN
  if ! XDG_DATA_HOME="$(resolve_data_root)" \
    OTEL_EXPORTER_OTLP_ENDPOINT= \
    OTEL_EXPORTER_OTLP_HEADERS= \
    OTEL_EXPORTER_OTLP_PROTOCOL= \
    HARNESS_OTEL_EXPORT= \
    HARNESS_OTEL_GRAFANA_URL= \
    HARNESS_OTEL_PYROSCOPE_URL= \
    "$ROOT/apps/harness-monitor-macos/Scripts/xcodebuild-with-lock.sh" \
      -project "$ROOT/apps/harness-monitor-macos/HarnessMonitor.xcodeproj" \
      -scheme "HarnessMonitor" \
      -configuration Debug \
      -derivedDataPath "$ROOT/tmp/xcode-derived" \
      -skipPackagePluginValidation \
      test \
      CODE_SIGNING_ALLOWED=NO \
      -destination 'platform=macOS' \
      -skip-testing:HarnessMonitorUITests \
      -only-testing:HarnessMonitorKitTests \
      "${smoke_skip_args[@]}" \
      >"$log_path" 2>&1
  then
    cat "$log_path" >&2
    exit 1
  fi
  if grep -Fq 'Cannot schedule tasks on an EventLoop that has already shut down' "$log_path"; then
    cat "$log_path" >&2
    printf 'monitor smoke emitted a SwiftNIO shutdown warning\n' >&2
    exit 1
  fi
  trap - RETURN
  write_shared_config false >/dev/null
  remove_monitor_smoke_data_home_marker
  rm -f "$log_path"
}

wait_for_process_exit() {
  local pid="$1"
  local timeout_seconds="$2"
  local started_at now
  started_at="$(date +%s)"
  while kill -0 "$pid" >/dev/null 2>&1; do
    now="$(date +%s)"
    if (( now - started_at >= timeout_seconds )); then
      return 1
    fi
    sleep 1
  done
  return 0
}

wait_for_daemon_ready() {
  local manifest_path="$1"
  local attempt=0
  local endpoint token_path token
  while true; do
    endpoint="$(jq -r '.endpoint // empty' "$manifest_path")"
    token_path="$(jq -r '.token_path // empty' "$manifest_path")"
    if [ -n "$endpoint" ] && [ -n "$token_path" ] && [ -f "$token_path" ]; then
      token="$(tr -d '\r\n' <"$token_path")"
      if [ -n "$token" ] && curl -fsS -H "Authorization: Bearer $token" "$endpoint/v1/health" >/dev/null 2>&1; then
        printf '%s %s\n' "$endpoint" "$token_path"
        return
      fi
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 60 ]; then
      printf 'timed out waiting for daemon readiness via %s\n' "$manifest_path" >&2
      exit 1
    fi
    sleep 1
  done
}

wait_for_tempo_service() {
  local service_name="$1"
  wait_for_signal \
    "$TEMPO_URL/api/search" \
    "Tempo traces for ${service_name}" \
    "q={resource.service.name=\"${service_name}\"}"
}

wait_for_loki_service() {
  local service_name="$1"
  local start_ns="$2"
  local end_ns="$3"
  wait_for_signal \
    "$LOKI_URL/loki/api/v1/query_range?start=$start_ns&end=$end_ns&limit=20" \
    "Loki logs for ${service_name}" \
    "query={service_name=\"${service_name}\"}"
}

wait_for_pyroscope_service() {
  local service_name="$1"
  local attempt=0
  local response
  local now_ms start_ms
  while true; do
    now_ms="$(( $(date +%s) * 1000 ))"
    start_ms="$(( now_ms - 3600000 ))"
    response="$(curl -fsS \
      -H 'Content-Type: application/json' \
      -d "{\"start\":${start_ms},\"end\":${now_ms},\"name\":\"service_name\"}" \
      "$PYROSCOPE_URL/querier.v1.QuerierService/LabelValues" 2>/dev/null || true)"
    if [ -n "$response" ] && printf '%s' "$response" | jq -e --arg service_name "$service_name" '.names[]? | select(. == $service_name)' >/dev/null; then
      return
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 30 ]; then
      printf 'timed out waiting for Pyroscope profiles for %s\n' "$service_name" >&2
      exit 1
    fi
    sleep 2
  done
}

wait_for_grafana_datasource() {
  local uid="$1"
  local description="$2"
  local attempt=0
  local response
  while true; do
    response="$(grafana_api "$GRAFANA_URL/api/datasources" 2>/dev/null || true)"
    if [ -n "$response" ] && printf '%s' "$response" | jq -e --arg uid "$uid" '.[] | select(.uid == $uid)' >/dev/null; then
      return
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 30 ]; then
      printf 'timed out waiting for Grafana datasource %s (%s)\n' "$uid" "$description" >&2
      exit 1
    fi
    sleep 2
  done
}

wait_for_grafana_dashboard() {
  local title="$1"
  local attempt=0
  local response
  while true; do
    response="$(grafana_api "$GRAFANA_URL/api/search?type=dash-db" 2>/dev/null || true)"
    if [ -n "$response" ] && printf '%s' "$response" | jq -e --arg title "$title" '.[] | select(.title == $title)' >/dev/null; then
      return
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 30 ]; then
      printf 'timed out waiting for Grafana dashboard %s\n' "$title" >&2
      exit 1
    fi
    sleep 2
  done
}

wait_for_grafana_resource() {
  local path="$1"
  local description="$2"
  local attempt=0
  while true; do
    if grafana_api "$GRAFANA_URL$path" >/dev/null 2>&1; then
      return
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 30 ]; then
      printf 'timed out waiting for Grafana resource %s (%s)\n' "$path" "$description" >&2
      exit 1
    fi
    sleep 2
  done
}

verify_grafana_provisioning() {
  grafana_api "$GRAFANA_URL/api/health" >/dev/null
  wait_for_grafana_datasource prometheus "Prometheus"
  wait_for_grafana_datasource loki "Loki"
  wait_for_grafana_datasource tempo "Tempo"
  wait_for_grafana_datasource pyroscope "Pyroscope"
  wait_for_grafana_resource "/api/datasources/uid/loki/resources/drilldown-limits" "Loki drilldown limits"
  wait_for_grafana_dashboard "Harness System Overview"
  wait_for_grafana_dashboard "Harness Runtime Execution"
  wait_for_grafana_dashboard "Harness Daemon Transport"
  wait_for_grafana_dashboard "Harness Monitor Client"
}

smoke_stack() {
  local now_seconds
  local loki_start
  local loki_end

  require_tool jq
  start_stack
  run_cli_smoke
  run_hook_smoke
  run_bridge_smoke
  run_daemon_server_smoke
  run_monitor_smoke

  now_seconds="$(date +%s)"
  loki_start="$((now_seconds - 600))000000000"
  loki_end="${now_seconds}000000000"

  wait_for_signal \
    "$PROMETHEUS_URL/api/v1/query" \
    "Prometheus hook metrics" \
    "query=sum(harness_hook_outcomes_total)"
  wait_for_signal \
    "$PROMETHEUS_URL/api/v1/query" \
    "Prometheus daemon client metrics" \
    "query=sum(harness_daemon_client_requests_total)"
  wait_for_signal \
    "$PROMETHEUS_URL/api/v1/query" \
    "Prometheus daemon server metrics" \
    "query=sum(harness_daemon_http_requests_total)"
  wait_for_signal \
    "$PROMETHEUS_URL/api/v1/query" \
    "Prometheus monitor metrics" \
    "query=sum(harness_monitor_http_requests_total)"

  wait_for_tempo_service "harness-cli"
  wait_for_tempo_service "harness-hook"
  wait_for_tempo_service "harness-bridge"
  wait_for_tempo_service "harness-daemon"
  wait_for_tempo_service "harness-monitor"

  wait_for_loki_service "harness-cli" "$loki_start" "$loki_end"
  wait_for_loki_service "harness-hook" "$loki_start" "$loki_end"
  wait_for_loki_service "harness-bridge" "$loki_start" "$loki_end"
  wait_for_loki_service "harness-daemon" "$loki_start" "$loki_end"
  wait_for_loki_service "harness-monitor" "$loki_start" "$loki_end"
  wait_for_pyroscope_service "harness-daemon"

  verify_grafana_provisioning

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
  wipe)
    wipe_stack
    ;;
  smoke)
    smoke_stack
    ;;
  *)
    cat <<'EOF' >&2
usage: scripts/observability.sh <start|stop|status|logs|open|reset|wipe|smoke>
EOF
    exit 1
    ;;
esac
