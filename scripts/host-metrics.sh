#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
DARWIN_EXPORTER_SRC="$ROOT/vendor/darwin-exporter"
DARWIN_EXPORTER_BIN="/usr/local/bin/darwin-exporter"
DARWIN_EXPORTER_CONFIG="/etc/darwin-exporter/config.yml"
DARWIN_EXPORTER_PLIST="/Library/LaunchDaemons/io.darwin-exporter.plist"
DARWIN_EXPORTER_PORT="${DARWIN_EXPORTER_PORT:-10102}"

ALLOY_BIN="${ALLOY_BIN:-$(command -v alloy 2>/dev/null || printf '%s' /opt/homebrew/bin/alloy)}"
ALLOY_CONFIG="/opt/homebrew/etc/alloy/config.alloy"
ALLOY_UNIX_LABEL="io.harness.alloy-unix"
ALLOY_UNIX_PLIST="$HOME/Library/LaunchAgents/${ALLOY_UNIX_LABEL}.plist"
ALLOY_UNIX_PORT="${ALLOY_UNIX_PORT:-12346}"
ALLOY_UNIX_STORAGE="/opt/homebrew/var/lib/alloy/data"
ALLOY_PROCESS_CONFIG_SOURCE="$ROOT/resources/observability/alloy/host-processes.otel.yaml"
ALLOY_PROCESS_CONFIG="/opt/homebrew/etc/alloy/harness-host-processes.otel.yaml"
ALLOY_PROCESS_LABEL="io.harness.alloy-host-processes"
ALLOY_PROCESS_PLIST="$HOME/Library/LaunchAgents/${ALLOY_PROCESS_LABEL}.plist"
ALLOY_PROCESS_PORT="10103"
ALLOY_PROCESS_HEALTH_URL="http://127.0.0.1:10104"
ALLOY_PROCESS_LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/harness/observability"
ALLOY_PROCESS_LOG="$ALLOY_PROCESS_LOG_DIR/alloy-host-processes.log"
ALLOY_PROCESS_ERR="$ALLOY_PROCESS_LOG_DIR/alloy-host-processes.err"
ALLOY_UNIX_LOG="$ALLOY_PROCESS_LOG_DIR/alloy-unix.log"
ALLOY_UNIX_ERR="$ALLOY_PROCESS_LOG_DIR/alloy-unix.err"
PROMETHEUS_URL="${HARNESS_PROMETHEUS_URL:-http://127.0.0.1:9090}"

require_macos() {
  if [ "$(uname -s)" != "Darwin" ]; then
    printf 'host-metrics commands are macOS-only\n' >&2
    exit 1
  fi
}

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'required tool not found: %s\n' "$tool" >&2
    exit 1
  fi
}

copy_alloy_process_config() {
  if [ ! -f "$ALLOY_PROCESS_CONFIG_SOURCE" ]; then
    printf 'missing Alloy host-process config source at %s\n' "$ALLOY_PROCESS_CONFIG_SOURCE" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$ALLOY_PROCESS_CONFIG")"
  cp "$ALLOY_PROCESS_CONFIG_SOURCE" "$ALLOY_PROCESS_CONFIG"
  alloy otel validate --config "file:${ALLOY_PROCESS_CONFIG}" >/dev/null
  printf 'wrote Alloy host-process config to %s\n' "$ALLOY_PROCESS_CONFIG"
}

write_alloy_process_plist() {
  mkdir -p "$(dirname "$ALLOY_PROCESS_PLIST")" "$ALLOY_PROCESS_LOG_DIR"
  cat >"$ALLOY_PROCESS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${ALLOY_PROCESS_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${ALLOY_BIN}</string>
        <string>otel</string>
        <string>--config</string>
        <string>file:${ALLOY_PROCESS_CONFIG}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${ALLOY_PROCESS_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${ALLOY_PROCESS_ERR}</string>
</dict>
</plist>
EOF
}

load_alloy_process_exporter() {
  launchctl unload "$ALLOY_PROCESS_PLIST" 2>/dev/null || true
  launchctl load "$ALLOY_PROCESS_PLIST"
}

unload_alloy_process_exporter() {
  launchctl unload "$ALLOY_PROCESS_PLIST" 2>/dev/null || true
}

install_alloy_process_exporter() {
  require_tool alloy

  copy_alloy_process_config
  write_alloy_process_plist
  load_alloy_process_exporter

  printf 'alloy host-process exporter installed and listening on port %s\n' "$ALLOY_PROCESS_PORT"
}

disable_brew_alloy_service() {
  if command -v brew >/dev/null 2>&1; then
    brew services stop grafana/grafana/alloy >/dev/null 2>&1 || true
  fi
}

write_alloy_unix_plist() {
  mkdir -p "$(dirname "$ALLOY_UNIX_PLIST")" "$ALLOY_PROCESS_LOG_DIR" "$ALLOY_UNIX_STORAGE"
  cat >"$ALLOY_UNIX_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${ALLOY_UNIX_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${ALLOY_BIN}</string>
        <string>run</string>
        <string>${ALLOY_CONFIG}</string>
        <string>--server.http.listen-addr=127.0.0.1:${ALLOY_UNIX_PORT}</string>
        <string>--storage.path=${ALLOY_UNIX_STORAGE}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${ALLOY_UNIX_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${ALLOY_UNIX_ERR}</string>
</dict>
</plist>
EOF
}

load_alloy_unix() {
  launchctl unload "$ALLOY_UNIX_PLIST" 2>/dev/null || true
  launchctl load "$ALLOY_UNIX_PLIST"
}

unload_alloy_unix() {
  launchctl unload "$ALLOY_UNIX_PLIST" 2>/dev/null || true
}

install_alloy() {
  require_tool brew

  if brew list grafana/grafana/alloy >/dev/null 2>&1; then
    printf 'alloy already installed\n'
  else
    printf 'installing grafana alloy via homebrew...\n'
    brew install grafana/grafana/alloy
  fi

  disable_brew_alloy_service
  write_alloy_config
  write_alloy_unix_plist
  load_alloy_unix
  printf 'alloy host exporter running on 127.0.0.1:%s\n' "$ALLOY_UNIX_PORT"
}

write_alloy_config() {
  mkdir -p "$(dirname "$ALLOY_CONFIG")"
  cat >"$ALLOY_CONFIG" <<'EOF'
// macOS system metrics via unix exporter
prometheus.exporter.unix "macos" {
  enable_collectors = [
    "cpu",
    "disk",
    "filesystem",
    "loadavg",
    "meminfo",
    "netdev",
    "uname",
    "boottime",
  ]
}

prometheus.scrape "macos" {
  targets    = prometheus.exporter.unix.macos.targets
  forward_to = [prometheus.remote_write.local.receiver]
  scrape_interval = "10s"
}

prometheus.remote_write "local" {
  endpoint {
    url = "http://127.0.0.1:9090/api/v1/write"
  }
}
EOF
  printf 'wrote alloy config to %s\n' "$ALLOY_CONFIG"
}

build_darwin_exporter() {
  require_tool go

  if [ ! -d "$DARWIN_EXPORTER_SRC" ]; then
    printf 'darwin-exporter submodule not found at %s\n' "$DARWIN_EXPORTER_SRC" >&2
    printf 'run: git submodule update --init --recursive\n' >&2
    exit 1
  fi

  printf 'building darwin-exporter from source...\n'
  (
    cd "$DARWIN_EXPORTER_SRC"
    CGO_ENABLED=1 go build -o darwin-exporter .
  )
  printf 'built darwin-exporter binary\n'
}

install_darwin_exporter() {
  if [ ! -f "$DARWIN_EXPORTER_SRC/darwin-exporter" ]; then
    build_darwin_exporter
  fi

  printf 'installing darwin-exporter to %s (requires sudo)...\n' "$DARWIN_EXPORTER_BIN"
  sudo cp "$DARWIN_EXPORTER_SRC/darwin-exporter" "$DARWIN_EXPORTER_BIN"
  sudo chmod +x "$DARWIN_EXPORTER_BIN"

  write_darwin_exporter_config
  write_darwin_exporter_plist
  load_darwin_exporter

  printf 'darwin-exporter installed and running on port %s\n' "$DARWIN_EXPORTER_PORT"
}

write_darwin_exporter_config() {
  printf 'writing darwin-exporter config (requires sudo)...\n'
  sudo mkdir -p "$(dirname "$DARWIN_EXPORTER_CONFIG")"
  sudo tee "$DARWIN_EXPORTER_CONFIG" >/dev/null <<EOF
server:
  listen-address: "127.0.0.1:${DARWIN_EXPORTER_PORT}"
  metrics-path: "/metrics"
  health-path: "/health"
  ready-path: "/ready"

logging:
  level: "info"
  format: "logfmt"

collectors:
  battery:
    enabled: true
  thermal:
    enabled: true
  wifi:
    enabled: true
EOF
}

write_darwin_exporter_plist() {
  printf 'writing darwin-exporter launchd plist (requires sudo)...\n'
  sudo tee "$DARWIN_EXPORTER_PLIST" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.darwin-exporter</string>
    <key>ProgramArguments</key>
    <array>
        <string>${DARWIN_EXPORTER_BIN}</string>
        <string>run</string>
        <string>--config</string>
        <string>${DARWIN_EXPORTER_CONFIG}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/darwin-exporter.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/darwin-exporter.err</string>
</dict>
</plist>
EOF
}

load_darwin_exporter() {
  sudo launchctl unload "$DARWIN_EXPORTER_PLIST" 2>/dev/null || true
  sudo launchctl load "$DARWIN_EXPORTER_PLIST"
}

unload_darwin_exporter() {
  sudo launchctl unload "$DARWIN_EXPORTER_PLIST" 2>/dev/null || true
}

install_all() {
  require_macos
  install_alloy
  install_alloy_process_exporter
  install_darwin_exporter
  printf '\nhost metrics installation complete\n'
  show_status
}

uninstall_all() {
  require_macos

  printf 'stopping alloy (host)...\n'
  disable_brew_alloy_service
  unload_alloy_unix
  rm -f "$ALLOY_UNIX_PLIST" "$ALLOY_UNIX_LOG" "$ALLOY_UNIX_ERR"

  printf 'stopping Alloy host-process exporter...\n'
  unload_alloy_process_exporter
  rm -f "$ALLOY_PROCESS_PLIST" "$ALLOY_PROCESS_CONFIG" "$ALLOY_PROCESS_LOG" "$ALLOY_PROCESS_ERR"

  printf 'stopping darwin-exporter...\n'
  unload_darwin_exporter
  sudo rm -f "$DARWIN_EXPORTER_BIN" "$DARWIN_EXPORTER_PLIST"
  sudo rm -rf "$(dirname "$DARWIN_EXPORTER_CONFIG")"

  printf 'host metrics services stopped and removed\n'
}

start_services() {
  require_macos
  disable_brew_alloy_service
  printf 'starting alloy (host) on 127.0.0.1:%s...\n' "$ALLOY_UNIX_PORT"
  write_alloy_unix_plist
  load_alloy_unix || true
  printf 'starting Alloy host-process exporter...\n'
  load_alloy_process_exporter || true
  printf 'starting darwin-exporter...\n'
  load_darwin_exporter || true
  printf 'host metrics services started\n'
}

stop_services() {
  require_macos
  printf 'stopping alloy (host)...\n'
  disable_brew_alloy_service
  unload_alloy_unix
  printf 'stopping Alloy host-process exporter...\n'
  unload_alloy_process_exporter
  printf 'stopping darwin-exporter...\n'
  unload_darwin_exporter
  printf 'host metrics services stopped\n'
}

restart_services() {
  require_macos
  stop_services
  start_services
}

show_status() {
  require_macos

  printf '=== Grafana Alloy (host) ===\n'
  if launchctl list 2>/dev/null | grep -q "$ALLOY_UNIX_LABEL"; then
    alloy_unix_pid="$(launchctl list | grep "$ALLOY_UNIX_LABEL" | awk '{print $1}')"
    if [ "$alloy_unix_pid" != "-" ] && [ -n "$alloy_unix_pid" ]; then
      printf 'status: running (pid %s)\n' "$alloy_unix_pid"
    else
      printf 'status: loaded but not running\n'
    fi
    printf 'config: %s\n' "$ALLOY_CONFIG"
    printf 'debug: http://127.0.0.1:%s\n' "$ALLOY_UNIX_PORT"
    printf 'logs: %s\n' "$ALLOY_UNIX_LOG"
  else
    printf 'status: not installed\n'
  fi

  printf '\n=== Alloy Host Processes ===\n'
  if launchctl list 2>/dev/null | grep -q "$ALLOY_PROCESS_LABEL"; then
    local pid
    pid="$(launchctl list | grep "$ALLOY_PROCESS_LABEL" | awk '{print $1}')"
    if [ "$pid" != "-" ] && [ -n "$pid" ]; then
      printf 'status: running (pid %s)\n' "$pid"
    else
      printf 'status: loaded but not running\n'
    fi
    printf 'config: %s\n' "$ALLOY_PROCESS_CONFIG"
    printf 'metrics: http://127.0.0.1:%s/metrics\n' "$ALLOY_PROCESS_PORT"
    printf 'health: %s\n' "$ALLOY_PROCESS_HEALTH_URL"
    printf 'logs: %s\n' "$ALLOY_PROCESS_LOG"
  else
    printf 'status: not installed\n'
  fi

  printf '\n=== darwin-exporter ===\n'
  if sudo launchctl list 2>/dev/null | grep -q "io.darwin-exporter"; then
    local pid
    pid="$(sudo launchctl list | grep io.darwin-exporter | awk '{print $1}')"
    if [ "$pid" != "-" ] && [ -n "$pid" ]; then
      printf 'status: running (pid %s)\n' "$pid"
    else
      printf 'status: loaded but not running\n'
    fi
    printf 'port: %s\n' "$DARWIN_EXPORTER_PORT"
    printf 'config: %s\n' "$DARWIN_EXPORTER_CONFIG"
    printf 'logs: /tmp/darwin-exporter.log\n'
  else
    printf 'status: not installed\n'
  fi

  printf '\n=== Prometheus Targets ===\n'
  if curl -fsS "$PROMETHEUS_URL/-/healthy" >/dev/null 2>&1; then
    curl -fsS "$PROMETHEUS_URL/api/v1/targets" 2>/dev/null \
      | jq -r '.data.activeTargets[] | select(.labels.job | test("darwin|integrations/unix|alloy-host-processes")) | "\(.labels.job): \(.health)"' 2>/dev/null \
      || printf 'could not query targets\n'
  else
    printf 'prometheus not reachable at %s\n' "$PROMETHEUS_URL"
  fi
}

show_metrics() {
  require_macos
  require_tool curl
  require_tool jq

  printf '=== System Metrics (Alloy) ===\n'
  local cpu_usage
  cpu_usage="$(curl -fsS "$PROMETHEUS_URL/api/v1/query?query=100-(avg(rate(node_cpu_seconds_total{mode=\"idle\"}[1m]))*100)" 2>/dev/null \
    | jq -r '.data.result[0].value[1] // "N/A"' 2>/dev/null || echo "N/A")"
  printf 'CPU usage: %s%%\n' "$cpu_usage"

  local load1
  load1="$(curl -fsS "$PROMETHEUS_URL/api/v1/query?query=node_load1" 2>/dev/null \
    | jq -r '.data.result[0].value[1] // "N/A"' 2>/dev/null || echo "N/A")"
  printf 'Load (1m): %s\n' "$load1"

  printf '\n=== Process Metrics (Alloy OTel) ===\n'
  local running_processes
  running_processes="$(curl -fsS "$PROMETHEUS_URL/api/v1/query?query=sum(system_processes_count%7Bstatus%3D%22running%22%7D)" 2>/dev/null \
    | jq -r '.data.result[0].value[1] // "N/A"' 2>/dev/null || echo "N/A")"
  printf 'Running processes: %s\n' "$running_processes"

  local tracked_process_groups
  tracked_process_groups="$(curl -fsS "$PROMETHEUS_URL/api/v1/query?query=count(count%20by%20(process_executable_name)(process_memory_usage_bytes))" 2>/dev/null \
    | jq -r '.data.result[0].value[1] // "N/A"' 2>/dev/null || echo "N/A")"
  printf 'Tracked process groups: %s\n' "$tracked_process_groups"

  local top_rss_name top_rss_value
  top_rss_name="$(curl -fsS "$PROMETHEUS_URL/api/v1/query?query=topk(1%2Csum%20by%20(process_executable_name)(process_memory_usage_bytes))" 2>/dev/null \
    | jq -r '.data.result[0].metric.process_executable_name // "N/A"' 2>/dev/null || echo "N/A")"
  top_rss_value="$(curl -fsS "$PROMETHEUS_URL/api/v1/query?query=topk(1%2Csum%20by%20(process_executable_name)(process_memory_usage_bytes))" 2>/dev/null \
    | jq -r '.data.result[0].value[1] // "N/A"' 2>/dev/null || echo "N/A")"
  printf 'Top tracked RSS: %s (%s bytes)\n' "$top_rss_name" "$top_rss_value"

  local top_cpu_name top_cpu_value
  top_cpu_name="$(curl -fsS "$PROMETHEUS_URL/api/v1/query?query=topk(1%2Csum%20by%20(process_executable_name)(process_cpu_utilization_ratio%7Bstate%3D~%22system%7Cuser%22%7D))" 2>/dev/null \
    | jq -r '.data.result[0].metric.process_executable_name // "N/A"' 2>/dev/null || echo "N/A")"
  top_cpu_value="$(curl -fsS "$PROMETHEUS_URL/api/v1/query?query=topk(1%2Csum%20by%20(process_executable_name)(process_cpu_utilization_ratio%7Bstate%3D~%22system%7Cuser%22%7D))" 2>/dev/null \
    | jq -r '.data.result[0].value[1] // "N/A"' 2>/dev/null || echo "N/A")"
  printf 'Top tracked CPU: %s (%s)\n' "$top_cpu_name" "$top_cpu_value"

  printf '\n=== macOS Metrics (darwin-exporter) ===\n'
  local cpu_temp
  cpu_temp="$(curl -fsS "$PROMETHEUS_URL/api/v1/query?query=darwin_cpu_temperature_celsius" 2>/dev/null \
    | jq -r '.data.result[0].value[1] // "N/A"' 2>/dev/null || echo "N/A")"
  printf 'CPU temp: %s°C\n' "$cpu_temp"

  local battery_health
  battery_health="$(curl -fsS "$PROMETHEUS_URL/api/v1/query?query=darwin_battery_health_percent*100" 2>/dev/null \
    | jq -r '.data.result[0].value[1] // "N/A"' 2>/dev/null || echo "N/A")"
  printf 'Battery health: %s%%\n' "$battery_health"

  local wifi_rssi
  wifi_rssi="$(curl -fsS "$PROMETHEUS_URL/api/v1/query?query=darwin_wifi_rssi_dbm" 2>/dev/null \
    | jq -r '.data.result[0].value[1] // "N/A"' 2>/dev/null || echo "N/A")"
  printf 'WiFi RSSI: %s dBm\n' "$wifi_rssi"

  local thermal_state
  thermal_state="$(curl -fsS "$PROMETHEUS_URL/api/v1/query?query=darwin_thermal_pressure{state!=\"nominal\"}==1" 2>/dev/null \
    | jq -r '.data.result[0].metric.state // "nominal"' 2>/dev/null || echo "nominal")"
  printf 'Thermal pressure: %s\n' "$thermal_state"
}

show_logs() {
  require_macos
  printf '=== Alloy host logs ===\n'
  tail -20 "$ALLOY_UNIX_LOG" 2>/dev/null || printf 'no alloy logs\n'
  printf '\n=== Alloy host-process exporter logs ===\n'
  tail -20 "$ALLOY_PROCESS_LOG" 2>/dev/null || printf 'no Alloy host-process exporter logs\n'
  printf '\n=== darwin-exporter logs ===\n'
  tail -20 /tmp/darwin-exporter.log 2>/dev/null || printf 'no darwin-exporter logs\n'
}

command="${1:-}"

case "$command" in
  install)
    install_all
    ;;
  uninstall)
    uninstall_all
    ;;
  start)
    start_services
    ;;
  stop)
    stop_services
    ;;
  restart)
    restart_services
    ;;
  status)
    show_status
    ;;
  metrics)
    show_metrics
    ;;
  logs)
    show_logs
    ;;
  build-darwin-exporter)
    require_macos
    build_darwin_exporter
    ;;
  *)
    cat <<'EOF' >&2
usage: scripts/host-metrics.sh <install|uninstall|start|stop|restart|status|metrics|logs|build-darwin-exporter>

commands:
  install              Install and start Alloy, the Alloy host-process exporter, and darwin-exporter
  uninstall            Stop and remove host metrics services
  start                Start host metrics services
  stop                 Stop host metrics services
  restart              Restart host metrics services
  status               Show service status and Prometheus targets
  metrics              Query current host metrics from Prometheus
  logs                 Show recent logs from both services
  build-darwin-exporter  Build darwin-exporter from vendor submodule
EOF
    exit 1
    ;;
esac
