#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
DARWIN_EXPORTER_SRC="$ROOT/vendor/darwin-exporter"
DARWIN_EXPORTER_BIN="/usr/local/bin/darwin-exporter"
DARWIN_EXPORTER_CONFIG="/etc/darwin-exporter/config.yml"
DARWIN_EXPORTER_PLIST="/Library/LaunchDaemons/io.darwin-exporter.plist"
DARWIN_EXPORTER_PORT="${DARWIN_EXPORTER_PORT:-10102}"

ALLOY_CONFIG="/opt/homebrew/etc/alloy/config.alloy"
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

install_alloy() {
  require_tool brew

  if brew list grafana/grafana/alloy >/dev/null 2>&1; then
    printf 'alloy already installed\n'
  else
    printf 'installing grafana alloy via homebrew...\n'
    brew install grafana/grafana/alloy
  fi

  write_alloy_config
  printf 'starting alloy service...\n'
  brew services start grafana/grafana/alloy || brew services restart grafana/grafana/alloy
  printf 'alloy installed and running\n'
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
  install_darwin_exporter
  printf '\nhost metrics installation complete\n'
  show_status
}

uninstall_all() {
  require_macos

  printf 'stopping alloy...\n'
  brew services stop grafana/grafana/alloy 2>/dev/null || true

  printf 'stopping darwin-exporter...\n'
  unload_darwin_exporter
  sudo rm -f "$DARWIN_EXPORTER_BIN" "$DARWIN_EXPORTER_PLIST"
  sudo rm -rf "$(dirname "$DARWIN_EXPORTER_CONFIG")"

  printf 'host metrics services stopped and removed\n'
}

start_services() {
  require_macos
  printf 'starting alloy...\n'
  brew services start grafana/grafana/alloy || true
  printf 'starting darwin-exporter...\n'
  load_darwin_exporter || true
  printf 'host metrics services started\n'
}

stop_services() {
  require_macos
  printf 'stopping alloy...\n'
  brew services stop grafana/grafana/alloy 2>/dev/null || true
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

  printf '=== Grafana Alloy ===\n'
  if brew services list | grep -q "alloy.*started"; then
    printf 'status: running\n'
    printf 'config: %s\n' "$ALLOY_CONFIG"
    printf 'logs: /opt/homebrew/var/log/alloy.log\n'
  else
    printf 'status: stopped\n'
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
      | jq -r '.data.activeTargets[] | select(.labels.job | test("darwin|integrations/unix")) | "\(.labels.job): \(.health)"' 2>/dev/null \
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
  printf '=== Alloy logs ===\n'
  tail -20 /opt/homebrew/var/log/alloy.log 2>/dev/null || printf 'no alloy logs\n'
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
  install              Install and start Alloy and darwin-exporter
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
