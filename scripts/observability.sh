#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/xcodebuild-destination.sh
source "$ROOT/apps/harness-monitor-macos/Scripts/lib/xcodebuild-destination.sh"
STACK_ROOT="$ROOT/resources/observability"
COMPOSE_FILE="$STACK_ROOT/docker-compose.yml"
PROJECT_NAME="${HARNESS_OBSERVABILITY_PROJECT_NAME:-harness-observability}"
GRAFANA_URL="${HARNESS_GRAFANA_URL:-http://127.0.0.1:3000}"
PROMETHEUS_URL="${HARNESS_PROMETHEUS_URL:-http://127.0.0.1:9090}"
TEMPO_URL="${HARNESS_TEMPO_URL:-http://127.0.0.1:3200}"
LOKI_URL="${HARNESS_LOKI_URL:-http://127.0.0.1:3100}"
PYROSCOPE_URL="${HARNESS_PYROSCOPE_URL:-http://127.0.0.1:4040}"
ALLOY_URL="${HARNESS_ALLOY_URL:-http://127.0.0.1:12345}"
SQLITE_EXPORTER_URL="${HARNESS_SQLITE_EXPORTER_URL:-http://127.0.0.1:9560}"
OTLP_GRPC_ENDPOINT="${HARNESS_OTLP_GRPC_ENDPOINT:-http://127.0.0.1:4317}"
OTLP_HTTP_ENDPOINT="${HARNESS_OTLP_HTTP_ENDPOINT:-http://127.0.0.1:4318}"
HARNESS_MONITOR_APP_GROUP_ID_DEFAULT="${HARNESS_MONITOR_APP_GROUP_ID_DEFAULT:-Q498EB36N4.io.harnessmonitor}"

load_stack_env_defaults() {
  local env_file="$STACK_ROOT/.env"
  local had_grafana_user=false
  local had_grafana_password=false
  local saved_grafana_user=""
  local saved_grafana_password=""

  [ -f "$env_file" ] || return

  if [ "${GF_SECURITY_ADMIN_USER+x}" = x ]; then
    had_grafana_user=true
    saved_grafana_user="$GF_SECURITY_ADMIN_USER"
  fi
  if [ "${GF_SECURITY_ADMIN_PASSWORD+x}" = x ]; then
    had_grafana_password=true
    saved_grafana_password="$GF_SECURITY_ADMIN_PASSWORD"
  fi

  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a

  if [ "$had_grafana_user" = true ]; then
    export GF_SECURITY_ADMIN_USER="$saved_grafana_user"
  fi
  if [ "$had_grafana_password" = true ]; then
    export GF_SECURITY_ADMIN_PASSWORD="$saved_grafana_password"
  fi
}

load_stack_env_defaults

compose() {
  prepare_sqlite_exporter_env
  if [ $# -gt 0 ] && command -v rtk >/dev/null 2>&1; then
    case "$1" in
      logs|ps|up)
        rtk docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
        return
        ;;
    esac
  fi
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

resolve_config_root() {
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then
    printf '%s\n' "$XDG_CONFIG_HOME"
    return
  fi
  printf '%s\n' "${HOME}/.config"
}

normalize_env_value() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

resolve_daemon_db_path() {
  local daemon_data_home app_group_id
  daemon_data_home="$(normalize_env_value "${HARNESS_DAEMON_DATA_HOME:-}" || true)"
  app_group_id="$(normalize_env_value "${HARNESS_APP_GROUP_ID:-}" || true)"
  if [ -n "$daemon_data_home" ]; then
    printf '%s/harness/daemon/harness.db\n' "$daemon_data_home"
    return
  fi
  if [ -n "$app_group_id" ]; then
    printf '%s/Library/Group Containers/%s/harness/daemon/harness.db\n' "$HOME" "$app_group_id"
    return
  fi
  printf '%s/harness/daemon/harness.db\n' "$(resolve_data_root)"
}

resolve_monitor_data_root() {
  local daemon_data_home xdg_data_home app_group_id
  daemon_data_home="$(normalize_env_value "${HARNESS_DAEMON_DATA_HOME:-}" || true)"
  xdg_data_home="$(normalize_env_value "${XDG_DATA_HOME:-}" || true)"
  app_group_id="$(normalize_env_value "${HARNESS_APP_GROUP_ID:-}" || true)"
  if [ -n "$daemon_data_home" ]; then
    printf '%s\n' "$daemon_data_home"
    return
  fi
  if [ -n "$xdg_data_home" ]; then
    printf '%s\n' "$xdg_data_home"
    return
  fi
  if [ "$(uname -s)" = "Darwin" ]; then
    if [ -z "$app_group_id" ]; then
      app_group_id="$HARNESS_MONITOR_APP_GROUP_ID_DEFAULT"
    fi
    printf '%s/Library/Group Containers/%s\n' "$HOME" "$app_group_id"
    return
  fi
  printf '%s\n' "$(resolve_data_root)"
}

resolve_monitor_cache_path() {
  printf '%s/harness/harness-cache.store\n' "$(resolve_monitor_data_root)"
}

sqlite_exporter_runtime_root() {
  printf '%s/tmp/observability/query-exporter\n' "$ROOT"
}

prepare_sqlite_exporter_env() {
  local runtime_root missing_root snapshot_root daemon_db_path monitor_db_path daemon_source_dir monitor_source_dir
  runtime_root="$(sqlite_exporter_runtime_root)"
  missing_root="$runtime_root/missing"
  snapshot_root="$runtime_root/snapshots"
  daemon_db_path="$(resolve_daemon_db_path)"
  monitor_db_path="$(resolve_monitor_cache_path)"

  mkdir -p "$missing_root/daemon" "$missing_root/monitor" "$snapshot_root/daemon" "$snapshot_root/monitor"

  if [ -d "$(dirname "$daemon_db_path")" ]; then
    daemon_source_dir="$(dirname "$daemon_db_path")"
  else
    daemon_source_dir="$missing_root/daemon"
  fi

  if [ -d "$(dirname "$monitor_db_path")" ]; then
    monitor_source_dir="$(dirname "$monitor_db_path")"
  else
    monitor_source_dir="$missing_root/monitor"
  fi

  export HARNESS_SQLITE_SOURCE_DAEMON_DIR="$daemon_source_dir"
  export HARNESS_SQLITE_SOURCE_MONITOR_DIR="$monitor_source_dir"
  export HARNESS_SQLITE_SNAPSHOT_DAEMON_DIR="$snapshot_root/daemon"
  export HARNESS_SQLITE_SNAPSHOT_MONITOR_DIR="$snapshot_root/monitor"
  export HARNESS_SQLITE_DAEMON_DB_PATH="$daemon_db_path"
  export HARNESS_SQLITE_MONITOR_DB_PATH="$monitor_db_path"
  export HARNESS_SQLITE_SOURCE_DAEMON_DB_PATH="$daemon_db_path"
  export HARNESS_SQLITE_SOURCE_MONITOR_DB_PATH="$monitor_db_path"
  export HARNESS_SQLITE_SNAPSHOT_DAEMON_DB_PATH="$snapshot_root/daemon/harness.db"
  export HARNESS_SQLITE_SNAPSHOT_MONITOR_DB_PATH="$snapshot_root/monitor/harness-cache.store"
}

runtime_shared_config_path() {
  printf '%s/harness/observability/config.json\n' "$(resolve_data_root)"
}

grafana_mcp_token_path() {
  printf '%s/harness/observability/grafana-mcp.token\n' "$(resolve_config_root)"
}

grafana_mcp_launcher_path() {
  printf '%s\n' "${HARNESS_GRAFANA_MCP_LAUNCHER_PATH:-$HOME/.local/bin/codex-grafana-mcp}"
}

monitor_shared_config_path() {
  printf '%s/harness/observability/config.json\n' "$(resolve_monitor_data_root)"
}

shared_config_paths() {
  local monitor_path runtime_path
  monitor_path="$(monitor_shared_config_path)"
  runtime_path="$(runtime_shared_config_path)"
  printf '%s\n' "$monitor_path"
  if [ "$runtime_path" != "$monitor_path" ]; then
    printf '%s\n' "$runtime_path"
  fi
}

shared_config_read_candidates() {
  local runtime_path monitor_path
  runtime_path="$(runtime_shared_config_path)"
  monitor_path="$(monitor_shared_config_path)"
  printf '%s\n' "$runtime_path"
  if [ "$monitor_path" != "$runtime_path" ]; then
    printf '%s\n' "$monitor_path"
  fi
}

first_existing_shared_config_path() {
  local config_path
  while IFS= read -r config_path; do
    [ -n "$config_path" ] || continue
    if [ -f "$config_path" ]; then
      printf '%s\n' "$config_path"
      return 0
    fi
  done < <(shared_config_read_candidates)
  return 1
}

repair_runtime_shared_config_from() {
  local source_path="$1"
  local runtime_path
  runtime_path="$(runtime_shared_config_path)"
  if [ "$source_path" = "$runtime_path" ]; then
    return
  fi
  mkdir -p "$(dirname "$runtime_path")"
  cp "$source_path" "$runtime_path"
}

monitor_smoke_data_home_marker_path() {
  printf '%s/tmp/observability/monitor-smoke-data-home.txt\n' "$ROOT"
}

write_shared_config() {
  local monitor_smoke_enabled="${1:-false}"
  local config_path first_config_path
  first_config_path=""
  while IFS= read -r config_path; do
    [ -n "$config_path" ] || continue
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
    if [ -z "$first_config_path" ]; then
      first_config_path="$config_path"
    fi
  done < <(shared_config_paths)
  printf '%s\n' "$first_config_path"
}

remove_shared_config() {
  local config_path
  while IFS= read -r config_path; do
    [ -n "$config_path" ] || continue
    rm -f "$config_path"
  done < <(shared_config_paths)
}

python_json_eval() {
  local input_json="$1"
  local expression="$2"

  python3 - "$input_json" "$expression" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
expression = sys.argv[2]

if expression == "grafana_url":
    value = payload.get("grafana_url")
    if not value:
        raise SystemExit("grafana_url missing from observability config")
    print(value)
elif expression == "service_account_id":
    for item in payload.get("serviceAccounts", []):
        if item.get("name") == "codex-grafana-mcp":
            print(item["id"])
            break
elif expression == "created_service_account_id":
    value = payload.get("id")
    if value is None:
        raise SystemExit("missing service account id in Grafana response")
    print(value)
elif expression == "token_key":
    value = payload.get("key")
    if not value:
        raise SystemExit("missing token key in Grafana response")
    print(value)
else:
    raise SystemExit(f"unsupported json expression: {expression}")
PY
}

read_grafana_url_from_shared_config() {
  local config_path runtime_path
  runtime_path="$(runtime_shared_config_path)"
  config_path="$(first_existing_shared_config_path || true)"
  if [ -z "$config_path" ]; then
    printf 'missing observability config: %s\n' "$runtime_path" >&2
    printf 'start the local stack with scripts/observability.sh start first\n' >&2
    exit 1
  fi
  repair_runtime_shared_config_from "$config_path"
  python_json_eval "$(tr -d '\n' <"$config_path")" "grafana_url"
}

grafana_mcp_api_call() {
  local grafana_url="$1"
  local method="$2"
  local path="$3"
  shift 3

  curl -fsS \
    -u "${GF_SECURITY_ADMIN_USER:-admin}:${GF_SECURITY_ADMIN_PASSWORD:-harness}" \
    -H 'Content-Type: application/json' \
    -X "$method" \
    "$grafana_url$path" \
    "$@"
}

grafana_mcp_token_is_valid() {
  local grafana_url="$1"
  local token="$2"

  curl -fsS \
    -H "Authorization: Bearer $token" \
    "$grafana_url/api/search?type=dash-db&limit=1" \
    >/dev/null 2>&1
}

ensure_grafana_mcp_token() {
  local grafana_url="$1"
  local path cached_token response service_account_id token_name token

  path="$(grafana_mcp_token_path)"
  if [ -f "$path" ]; then
    cached_token="$(tr -d '\r\n' <"$path")"
    if [ -n "$cached_token" ] && grafana_mcp_token_is_valid "$grafana_url" "$cached_token"; then
      printf '%s' "$cached_token"
      return
    fi
  fi

  mkdir -p "$(dirname "$path")"
  response="$(grafana_mcp_api_call "$grafana_url" GET "/api/serviceaccounts/search?query=codex-grafana-mcp")"
  service_account_id="$(python_json_eval "$(tr -d '\n' <<<"$response")" "service_account_id" || true)"

  if [ -z "$service_account_id" ]; then
    response="$(
      grafana_mcp_api_call \
        "$grafana_url" \
        POST \
        "/api/serviceaccounts" \
        --data '{"name":"codex-grafana-mcp","role":"Editor","isDisabled":false}'
    )"
    service_account_id="$(python_json_eval "$(tr -d '\n' <<<"$response")" "created_service_account_id")"
  fi

  token_name="codex-$(hostname -s)-$(date +%Y%m%d%H%M%S)"
  response="$(
    grafana_mcp_api_call \
      "$grafana_url" \
      POST \
      "/api/serviceaccounts/${service_account_id}/tokens" \
      --data "{\"name\":\"${token_name}\"}"
  )"
  token="$(python_json_eval "$(tr -d '\n' <<<"$response")" "token_key")"

  umask 077
  printf '%s' "$token" >"$path"
  printf '%s' "$token"
}

refresh_grafana_mcp_token() {
  local grafana_url

  require_tool curl
  require_tool python3
  grafana_url="$(read_grafana_url_from_shared_config)"
  ensure_grafana_mcp_token "$grafana_url" >/dev/null
}

install_grafana_mcp_launcher() {
  local launcher_path
  launcher_path="$(grafana_mcp_launcher_path)"
  mkdir -p "$(dirname "$launcher_path")"
  cat >"$launcher_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec python3 "$ROOT/scripts/grafana_mcp_supervisor.py" "\$@"
EOF
  chmod 755 "$launcher_path"
  printf '%s\n' "$launcher_path"
}

launch_grafana_mcp_child() {
  local grafana_url

  require_tool curl
  require_tool python3
  require_tool uvx
  grafana_url="$(read_grafana_url_from_shared_config)"
  export GRAFANA_URL="$grafana_url"
  export GRAFANA_SERVICE_ACCOUNT_TOKEN
  GRAFANA_SERVICE_ACCOUNT_TOKEN="$(ensure_grafana_mcp_token "$grafana_url")"
  exec uvx mcp-grafana "$@"
}

write_monitor_smoke_data_home_marker() {
  local marker_path
  marker_path="$(monitor_smoke_data_home_marker_path)"
  mkdir -p "$(dirname "$marker_path")"
  printf '%s\n' "$(resolve_monitor_data_root)" >"$marker_path"
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
  curl -fsS -u "${GF_SECURITY_ADMIN_USER:-admin}:${GF_SECURITY_ADMIN_PASSWORD:-harness}" "$@"
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

verify_sqlite_exporter_visibility() {
  local host_path="$1"
  local container_path="$2"
  local description="$3"
  [ -f "$host_path" ] || return 0
  if ! compose exec -T sqlite-exporter sh -c "test -f '$container_path'"; then
    printf 'sqlite exporter cannot see %s: host=%s container=%s\n' \
      "$description" "$host_path" "$container_path" >&2
    exit 1
  fi
}

remove_sqlite_snapshot_file() {
  local path="$1"
  rm -f "$path" "${path}-shm" "${path}-wal"
}

reset_sqlite_snapshots() {
  remove_sqlite_snapshot_file "$HARNESS_SQLITE_SNAPSHOT_DAEMON_DB_PATH"
  remove_sqlite_snapshot_file "$HARNESS_SQLITE_SNAPSHOT_MONITOR_DB_PATH"
}

wait_for_sqlite_snapshot() {
  local source_path="$1"
  local snapshot_path="$2"
  local description="$3"
  [ -f "$source_path" ] || return 0
  wait_for_file "$snapshot_path" "$description"
}

wait_for_sqlite_snapshots() {
  wait_for_sqlite_snapshot \
    "$HARNESS_SQLITE_DAEMON_DB_PATH" \
    "$HARNESS_SQLITE_SNAPSHOT_DAEMON_DB_PATH" \
    "daemon SQLite snapshot"
  wait_for_sqlite_snapshot \
    "$HARNESS_SQLITE_MONITOR_DB_PATH" \
    "$HARNESS_SQLITE_SNAPSHOT_MONITOR_DB_PATH" \
    "monitor SQLite snapshot"
}

sqlite_mount_consumer_services() {
  printf '%s\n' sqlite-snapshot
  printf '%s\n' sqlite-exporter
  printf '%s\n' grafana
}

recreate_sqlite_mount_consumers() {
  local services=()
  local service

  prepare_sqlite_exporter_env
  while IFS= read -r service; do
    [ -n "$service" ] || continue
    services+=("$service")
  done < <(sqlite_mount_consumer_services)

  reset_sqlite_snapshots
  compose up -d --build --force-recreate "${services[@]}" >/dev/null
  wait_for_sqlite_snapshots
  wait_for_url "$SQLITE_EXPORTER_URL/metrics" "SQLite query exporter"
  wait_for_url "$GRAFANA_URL/api/health" "Grafana"
}

require_sqlite_smoke_target() {
  local path="$1"
  local description="$2"
  if [ ! -f "$path" ]; then
    printf 'expected %s for observability smoke at %s\n' "$description" "$path" >&2
    exit 1
  fi
}

start_stack() {
  require_tool docker
  require_tool curl
  prepare_sqlite_exporter_env
  reset_sqlite_snapshots
  compose up -d --build
  wait_for_url "$PROMETHEUS_URL/-/ready" "Prometheus"
  wait_for_url "$TEMPO_URL/ready" "Tempo"
  wait_for_url "$LOKI_URL/ready" "Loki"
  wait_for_url "$PYROSCOPE_URL/ready" "Pyroscope"
  wait_for_sqlite_snapshots
  wait_for_url "$GRAFANA_URL/api/health" "Grafana"
  wait_for_url "$ALLOY_URL/-/ready" "Alloy"
  wait_for_url "$SQLITE_EXPORTER_URL/metrics" "SQLite query exporter"
  verify_sqlite_exporter_visibility \
    "$HARNESS_SQLITE_SNAPSHOT_DAEMON_DB_PATH" \
    "/srv/sqlite/daemon/harness.db" \
    "daemon SQLite snapshot"
  verify_sqlite_exporter_visibility \
    "$HARNESS_SQLITE_SNAPSHOT_MONITOR_DB_PATH" \
    "/srv/sqlite/monitor/harness-cache.store" \
    "monitor SQLite snapshot"
  local config_path
  local launcher_path
  config_path="$(write_shared_config false)"
  launcher_path="$(install_grafana_mcp_launcher)"
  refresh_grafana_mcp_token
  printf 'Grafana: %s\n' "$GRAFANA_URL"
  printf 'Prometheus: %s\n' "$PROMETHEUS_URL"
  printf 'Tempo: %s\n' "$TEMPO_URL"
  printf 'Loki: %s\n' "$LOKI_URL"
  printf 'Pyroscope: %s\n' "$PYROSCOPE_URL"
  printf 'Alloy: %s\n' "$ALLOY_URL"
  printf 'SQLite Exporter: %s\n' "$SQLITE_EXPORTER_URL"
  printf 'Shared config: %s\n' "$config_path"
  printf 'Grafana MCP Launcher: %s\n' "$launcher_path"
}

cleanup_stale_network() {
  local network="${PROJECT_NAME}_default"
  local endpoints
  endpoints="$(docker network inspect "$network" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || true)"
  for endpoint in $endpoints; do
    docker network disconnect -f "$network" "$endpoint" 2>/dev/null || true
  done
  docker network rm "$network" 2>/dev/null || true
}

stop_stack() {
  compose down --remove-orphans --timeout 5
  cleanup_stale_network
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
  printf '\nShared config paths:\n'
  shared_config_paths
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
  local max_attempts="${4:-$(signal_max_attempts)}"
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
    if [ "$attempt" -ge "$max_attempts" ]; then
      printf 'timed out waiting for %s\n' "$description" >&2
      exit 1
    fi
    sleep 2
  done
}

signal_max_attempts() {
  local value="${HARNESS_OBSERVABILITY_SIGNAL_MAX_ATTEMPTS:-30}"
  case "$value" in
    ''|*[!0-9]*|0)
      printf '30\n'
      ;;
    *)
      printf '%s\n' "$value"
      ;;
  esac
}

service_graph_signal_max_attempts() {
  local value="${HARNESS_OBSERVABILITY_SERVICE_GRAPH_MAX_ATTEMPTS:-90}"
  case "$value" in
    ''|*[!0-9]*|0)
      printf '90\n'
      ;;
    *)
      printf '%s\n' "$value"
      ;;
  esac
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

OBSERVABILITY_LOCAL_HARNESS_BINARY=""

resolve_local_cargo_target_dir() {
  local target_dir
  target_dir="$(normalize_env_value "${CARGO_TARGET_DIR:-}" || true)"
  if [ -n "$target_dir" ]; then
    printf '%s\n' "$target_dir"
    return
  fi

  target_dir="$(
    "$ROOT/scripts/cargo-local.sh" --print-env \
      | awk -F= '/^CARGO_TARGET_DIR=/{print $2}'
  )"
  if [ -z "$target_dir" ]; then
    printf 'failed to resolve CARGO_TARGET_DIR via scripts/cargo-local.sh --print-env\n' >&2
    exit 1
  fi

  printf '%s\n' "$target_dir"
}

resolve_local_harness_binary() {
  local binary_path target_dir
  if [ -n "${OBSERVABILITY_LOCAL_HARNESS_BINARY:-}" ]; then
    printf '%s\n' "$OBSERVABILITY_LOCAL_HARNESS_BINARY"
    return
  fi

  binary_path="$(normalize_env_value "${HARNESS_OBSERVABILITY_HARNESS_BIN:-}" || true)"
  if [ -n "$binary_path" ]; then
    if [ ! -x "$binary_path" ]; then
      printf 'configured harness smoke binary is not executable: %s\n' "$binary_path" >&2
      exit 1
    fi
    OBSERVABILITY_LOCAL_HARNESS_BINARY="$binary_path"
    printf '%s\n' "$OBSERVABILITY_LOCAL_HARNESS_BINARY"
    return
  fi

  target_dir="$(resolve_local_cargo_target_dir)"
  "$ROOT/scripts/cargo-local.sh" build --quiet --bin harness >/dev/null
  binary_path="$target_dir/debug/harness"
  if [ ! -x "$binary_path" ]; then
    printf 'failed to resolve built local harness binary at %s\n' "$binary_path" >&2
    exit 1
  fi
  OBSERVABILITY_LOCAL_HARNESS_BINARY="$binary_path"
  printf '%s\n' "$OBSERVABILITY_LOCAL_HARNESS_BINARY"
}

# Use the built binary directly so long-lived smoke commands do not hold cargo-run locks.
run_with_cleared_otel_env() {
  OTEL_EXPORTER_OTLP_ENDPOINT='' \
  OTEL_EXPORTER_OTLP_HEADERS='' \
  OTEL_EXPORTER_OTLP_PROTOCOL='' \
  HARNESS_OTEL_EXPORT='' \
  HARNESS_OTEL_GRAFANA_URL='' \
  HARNESS_OTEL_PYROSCOPE_URL='' \
  "$@"
}

run_local_harness() {
  local binary_path
  binary_path="$(resolve_local_harness_binary)"
  run_with_cleared_otel_env "$binary_path" "$@"
}

run_cli_smoke() {
  run_local_harness session list --json >/dev/null
}

run_hook_smoke() {
  printf '%s' '{"hook_event_name":"PreToolUse","session_id":"observability-smoke-session","tool_name":"Read","tool_input":{"file_path":"Cargo.toml"}}' \
    | run_local_harness hook --agent codex suite:run tool-guard >/dev/null
}

run_bridge_smoke() {
  run_local_harness bridge status >/dev/null || true
}

run_daemon_server_smoke() {
  local daemon_home daemon_root manifest_path daemon_log daemon_pid endpoint token_path token cleanup_home
  daemon_home="$(normalize_env_value "${HARNESS_DAEMON_DATA_HOME:-}" || true)"
  cleanup_home=false
  if [ -z "$daemon_home" ]; then
    daemon_home="$(mktemp -d "${TMPDIR:-/tmp}/harness-observability-daemon.XXXXXX")"
    cleanup_home=true
  else
    mkdir -p "$daemon_home"
  fi
  daemon_root="$daemon_home/harness/daemon"
  manifest_path="$daemon_root/manifest.json"
  daemon_log="$daemon_home/daemon.log"
  daemon_pid=""

  cleanup_daemon_server_smoke() {
    if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" >/dev/null 2>&1; then
      HARNESS_DAEMON_DATA_HOME="$daemon_home" \
      run_local_harness daemon stop --json >/dev/null 2>&1 || true
      wait_for_process_exit "$daemon_pid" 15 || kill "$daemon_pid" >/dev/null 2>&1 || true
      wait_for_process_exit "$daemon_pid" 5 || kill -9 "$daemon_pid" >/dev/null 2>&1 || true
    fi
    if [ "$cleanup_home" = true ]; then
      rm -rf "$daemon_home"
    fi
  }

  trap cleanup_daemon_server_smoke RETURN

  HARNESS_DAEMON_DATA_HOME="$daemon_home" \
  run_local_harness daemon serve --host 127.0.0.1 --port 0 \
    >"$daemon_log" 2>&1 &
  daemon_pid="$!"

  wait_for_file "$manifest_path" "daemon manifest"
  read -r endpoint token_path < <(wait_for_daemon_ready "$manifest_path")
  token="$(tr -d '\r\n' <"$token_path")"
  curl -fsS \
    -H "Authorization: Bearer $token" \
    "$endpoint/v1/health" >/dev/null

  HARNESS_DAEMON_DATA_HOME="$daemon_home" \
  run_local_harness daemon stop --json >/dev/null
  wait_for_process_exit "$daemon_pid" 15 || {
    printf 'daemon did not exit cleanly; log follows\n' >&2
    cat "$daemon_log" >&2
    exit 1
  }
  daemon_pid=""
  trap - RETURN
  cleanup_daemon_server_smoke
}

run_monitor_smoke() {
  local destination
  local log_path
  destination="$(harness_monitor_xcodebuild_destination)"
  log_path="$(mktemp "${TMPDIR:-/tmp}/harness-monitor-otel-smoke.XXXXXX.log")"
  write_shared_config true >/dev/null
  write_monitor_smoke_data_home_marker
  trap 'write_shared_config false >/dev/null || true; remove_monitor_smoke_data_home_marker; rm -f "$log_path"' RETURN
  if ! XDG_DATA_HOME="$(resolve_data_root)" \
    run_with_cleared_otel_env \
      "$ROOT/apps/harness-monitor-macos/Scripts/xcodebuild-with-lock.sh" \
        -project "$ROOT/apps/harness-monitor-macos/HarnessMonitor.xcodeproj" \
        -scheme "HarnessMonitor" \
        -configuration Debug \
        -derivedDataPath "$ROOT/xcode-derived" \
        -skipPackagePluginValidation \
        test \
        CODE_SIGNING_ALLOWED=NO \
        -destination "$destination" \
        -skip-testing:HarnessMonitorUITests \
        -only-testing:HarnessMonitorKitTests/HarnessMonitorObservabilitySmokeTests \
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

wait_for_tempo_span() {
  local service_name="$1"
  local span_name="$2"
  wait_for_signal \
    "$TEMPO_URL/api/search" \
    "Tempo span ${span_name} for ${service_name}" \
    "q={resource.service.name=\"${service_name}\" && name=\"${span_name}\"}"
}

wait_for_service_graph_edge() {
  local client_name="$1"
  local server_name="$2"
  local connection_type="${3:-}"
  local query="query=sum(traces_service_graph_request_total{client=\"${client_name}\",server=\"${server_name}\""
  if [ -n "$connection_type" ]; then
    query+=",connection_type=\"${connection_type}\""
  fi
  query+="})"
  wait_for_signal \
    "$PROMETHEUS_URL/api/v1/query" \
    "Prometheus service graph ${client_name} -> ${server_name}" \
    "$query" \
    "$(service_graph_signal_max_attempts)"
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

wait_for_grafana_v2_dashboard() {
  local uid="$1"
  local title="$2"
  local attempt=0
  local v2_response classic_response
  while true; do
    v2_response="$(
      grafana_api \
        "$GRAFANA_URL/apis/dashboard.grafana.app/v2/namespaces/default/dashboards/$uid" \
        2>/dev/null || true
    )"
    classic_response="$(
      grafana_api \
        "$GRAFANA_URL/api/dashboards/uid/$uid" \
        2>/dev/null || true
    )"
    if [ -n "$v2_response" ] \
      && [ -n "$classic_response" ] \
      && printf '%s' "$v2_response" | jq -e --arg title "$title" '
        .apiVersion == "dashboard.grafana.app/v2"
        and .kind == "Dashboard"
        and .spec.title == $title
        and (((.spec.elements // {}) | keys | length) > 0)
        and (
          (.spec.layout.kind == "GridLayout" and (((.spec.layout.spec.items // []) | length) > 0))
          or (.spec.layout.kind == "TabsLayout" and (((.spec.layout.spec.tabs // []) | length) > 0))
          or (.spec.layout.kind == "RowsLayout" and (((.spec.layout.spec.rows // []) | length) > 0))
          or (.spec.layout.kind == "AutoGridLayout" and (((.spec.layout.spec.items // []) | length) > 0))
        )
      ' >/dev/null \
      && printf '%s' "$classic_response" | jq -e --arg uid "$uid" --arg title "$title" '
        .dashboard.uid == $uid
        and .dashboard.title == $title
        and (((.dashboard.panels // []) | length) > 0)
      ' >/dev/null; then
      return
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 30 ]; then
      printf 'timed out waiting for provisioned Grafana v2 dashboard %s (%s)\n' "$uid" "$title" >&2
      if [ -n "$v2_response" ]; then
        printf '%s\n' "$v2_response" \
          | jq '{apiVersion,kind,title:.spec.title,layoutKind:.spec.layout.kind,elementCount:(((.spec.elements // {}) | keys) | length)}' >&2 \
          || true
      fi
      if [ -n "$classic_response" ]; then
        printf '%s\n' "$classic_response" \
          | jq '{uid:.dashboard.uid,provisioned:.meta.provisioned,title:.dashboard.title,panelCount:(((.dashboard.panels // []) | length))}' >&2 \
          || true
      fi
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

wait_for_grafana_plugin() {
  local plugin_id="$1"
  local description="$2"
  local attempt=0
  while true; do
    if grafana_api "$GRAFANA_URL/api/plugins/$plugin_id/settings" >/dev/null 2>&1; then
      return
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 30 ]; then
      printf 'timed out waiting for Grafana plugin %s (%s)\n' "$plugin_id" "$description" >&2
      exit 1
    fi
    sleep 2
  done
}

verify_grafana_provisioning() {
  grafana_api "$GRAFANA_URL/api/health" >/dev/null
  wait_for_grafana_plugin grafana-llm-app "Grafana LLM app"
  wait_for_grafana_datasource prometheus "Prometheus"
  wait_for_grafana_datasource loki "Loki"
  wait_for_grafana_datasource tempo "Tempo"
  wait_for_grafana_datasource pyroscope "Pyroscope"
  wait_for_grafana_resource "/api/datasources/uid/loki/resources/drilldown-limits" "Loki drilldown limits"
  wait_for_grafana_v2_dashboard harness-investigation-cockpit "Harness Investigation Cockpit"
  wait_for_grafana_v2_dashboard harness-host-machine "Harness Host Machine"
  wait_for_grafana_v2_dashboard harness-host-processes "Harness Host Processes"
  wait_for_grafana_v2_dashboard harness-runtime-execution "Harness Runtime & Hooks"
  wait_for_grafana_v2_dashboard harness-daemon-transport "Harness Daemon Transport"
  wait_for_grafana_v2_dashboard harness-monitor-client "Harness Monitor Client"
  wait_for_grafana_v2_dashboard harness-sqlite-forensics "Harness Storage & SQLite"
  wait_for_grafana_v2_dashboard harness-service-map "Harness Service Flow"
}

smoke_stack() {
  local now_seconds
  local loki_start
  local loki_end
  local smoke_root
  local saved_harness_daemon_data_home="${HARNESS_DAEMON_DATA_HOME-}"
  local saved_xdg_data_home="${XDG_DATA_HOME-}"
  local saved_harness_app_group_id="${HARNESS_APP_GROUP_ID-}"
  local had_harness_daemon_data_home=false
  local had_xdg_data_home=false
  local had_harness_app_group_id=false

  if [ "${HARNESS_DAEMON_DATA_HOME+x}" = x ]; then
    had_harness_daemon_data_home=true
  fi
  if [ "${XDG_DATA_HOME+x}" = x ]; then
    had_xdg_data_home=true
  fi
  if [ "${HARNESS_APP_GROUP_ID+x}" = x ]; then
    had_harness_app_group_id=true
  fi

  restore_smoke_stack() {
    local status="$?"

    trap - RETURN
    remove_shared_config
    remove_monitor_smoke_data_home_marker

    if [ "$had_harness_daemon_data_home" = true ]; then
      export HARNESS_DAEMON_DATA_HOME="$saved_harness_daemon_data_home"
    else
      unset HARNESS_DAEMON_DATA_HOME
    fi

    if [ "$had_xdg_data_home" = true ]; then
      export XDG_DATA_HOME="$saved_xdg_data_home"
    else
      unset XDG_DATA_HOME
    fi

    if [ "$had_harness_app_group_id" = true ]; then
      export HARNESS_APP_GROUP_ID="$saved_harness_app_group_id"
    else
      unset HARNESS_APP_GROUP_ID
    fi

    recreate_sqlite_mount_consumers
    write_shared_config false >/dev/null

    return "$status"
  }

  require_tool jq
  trap restore_smoke_stack RETURN
  smoke_root="$ROOT/tmp/observability/smoke-data"
  export HARNESS_DAEMON_DATA_HOME="$smoke_root/daemon-data"
  export XDG_DATA_HOME="$smoke_root/monitor-data"
  mkdir -p "$HARNESS_DAEMON_DATA_HOME" "$XDG_DATA_HOME"
  start_stack
  run_cli_smoke
  run_hook_smoke
  run_bridge_smoke
  run_daemon_server_smoke
  run_monitor_smoke
  require_sqlite_smoke_target \
    "$HARNESS_SQLITE_DAEMON_DB_PATH" \
    "daemon SQLite database"
  require_sqlite_smoke_target \
    "$HARNESS_SQLITE_MONITOR_DB_PATH" \
    "monitor SQLite cache"

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
  wait_for_signal \
    "$PROMETHEUS_URL/api/v1/query" \
    "Prometheus daemon SQLite metrics" \
    "query=sum(harness_daemon_db_operations_total)"
  wait_for_signal \
    "$PROMETHEUS_URL/api/v1/query" \
    "Prometheus monitor SQLite metrics" \
    "query=sum(harness_monitor_sqlite_operations_total)"
  wait_for_signal \
    "$PROMETHEUS_URL/api/v1/query" \
    "Prometheus SQLite exporter daemon target" \
    "query=sum(queries_total{job=\"sqlite-exporter\",database=\"daemon_db\",status=\"success\"})"
  wait_for_signal \
    "$PROMETHEUS_URL/api/v1/query" \
    "Prometheus SQLite exporter monitor target" \
    "query=sum(queries_total{job=\"sqlite-exporter\",database=\"monitor_cache\",status=\"success\"})"
  wait_for_signal \
    "$PROMETHEUS_URL/api/v1/query" \
    "Prometheus SQLite table metrics" \
    "query=sum(harness_sqlite_table_rows{database=~\"daemon_db|monitor_cache\"})"
  wait_for_service_graph_edge "harness-monitor" "harness-daemon"
  wait_for_service_graph_edge "harness-daemon" "sqlite" "database"
  wait_for_service_graph_edge "harness-monitor" "monitor-cache" "database"

  wait_for_tempo_service "harness-cli"
  wait_for_tempo_service "harness-hook"
  wait_for_tempo_service "harness-bridge"
  wait_for_tempo_service "harness-daemon"
  wait_for_tempo_service "harness-monitor"
  wait_for_tempo_span "harness-daemon" "daemon.db.async.list_session_summaries"
  wait_for_tempo_span "harness-monitor" "monitor.sqlite.record_counts"

  wait_for_loki_service "harness-cli" "$loki_start" "$loki_end"
  wait_for_loki_service "harness-hook" "$loki_start" "$loki_end"
  wait_for_loki_service "harness-bridge" "$loki_start" "$loki_end"
  wait_for_loki_service "harness-daemon" "$loki_start" "$loki_end"
  wait_for_loki_service "harness-monitor" "$loki_start" "$loki_end"
  wait_for_pyroscope_service "harness-daemon"

  verify_grafana_provisioning

  printf 'observability smoke passed\n'
}

write_shared_config_fixture() {
  local monitor_smoke_enabled="${1:-false}"
  write_shared_config "$monitor_smoke_enabled" >/dev/null
  shared_config_paths
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
  --print-shared-config-paths)
    shared_config_paths
    ;;
  --write-shared-config-fixture)
    write_shared_config_fixture "${2:-false}"
    ;;
  --install-grafana-mcp-launcher-fixture)
    install_grafana_mcp_launcher
    ;;
  --launch-grafana-mcp-child)
    shift
    launch_grafana_mcp_child "$@"
    ;;
  --refresh-grafana-mcp-token-fixture)
    refresh_grafana_mcp_token
    ;;
  --run-local-harness-fixture)
    shift
    run_local_harness "$@"
    ;;
  --restore-smoke-stack-fixture)
    recreate_sqlite_mount_consumers
    ;;
  --wait-for-service-graph-edge-fixture)
    wait_for_service_graph_edge "$2" "$3" "${4:-}"
    ;;
  *)
    cat <<'EOF' >&2
usage: scripts/observability.sh <start|stop|status|logs|open|reset|wipe|smoke>
EOF
    exit 1
    ;;
esac
