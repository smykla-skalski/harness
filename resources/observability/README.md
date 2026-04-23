# Local Observability Stack

This stack exists for local debugging only.
Rust CI does not enforce contracts for the shell helpers, dashboards, or Docker/Grafana/Tempo provisioning under `resources/observability/`.
When you change this area, validate it manually with the repo-local scripts and whichever app-level checks matter for your workflow.

Tempo Explore's Service Graph is the authoritative service map for the local Harness observability stack.
Use the provisioned `Harness Service Map` dashboard as the landing page for supporting RED metrics, then jump into Tempo Explore for the built-in graph and span table.

Tempo metrics-generator owns the `traces_service_graph_*` and `traces_spanmetrics_*` metrics that power the service map.
Alloy still exports the repo's `harness.spanmetrics_*` metrics for the existing custom dashboards, but it should not emit duplicate `traces_service_graph_*` series.

The local Grafana Tempo data source is already provisioned with `serviceMap.datasourceUid: prometheus`, so Tempo Explore can render the built-in Service Graph as soon as Prometheus receives the Tempo-generated metrics.

## macOS host metrics

Three native services collect local workstation metrics from your Mac and feed them into the local Prometheus:

Grafana Alloy runs as a Homebrew service and collects standard node_exporter-style machine metrics via its `prometheus.exporter.unix` component. It remote-writes CPU, load, memory, disk, filesystem, and network metrics directly into Prometheus.

A repo-managed Alloy OTel launch agent exposes low-cardinality process metrics on port `10103` using the `hostmetrics` receiver's `processes` and `process` scrapers. The shipped config keeps only stable executable-name labels and deletes PID, parent PID, full command line, and executable path before Prometheus ingestion.

darwin-exporter runs as a launchd daemon and collects macOS-specific metrics that node_exporter cannot provide: CPU/GPU/disk temperatures, battery health and cycle count, WiFi signal strength and connection details, and thermal pressure state. Prometheus scrapes it on port `10102`.

### Installation

```bash
mise run host-metrics:install
```

This installs all three services:
- Alloy via Homebrew with a config at `/opt/homebrew/etc/alloy/config.alloy`
- a repo-managed Alloy OTel launch agent with config at `/opt/homebrew/etc/alloy/harness-host-processes.otel.yaml`
- darwin-exporter built from `vendor/darwin-exporter` (requires Go), installed to `/usr/local/bin/darwin-exporter`

### Management commands

```bash
mise run host-metrics:status   # show service status and Prometheus targets
mise run host-metrics:metrics  # query current host metrics
mise run host-metrics:logs     # tail recent logs from all host-metrics services
mise run host-metrics:start    # start all host-metrics services
mise run host-metrics:stop     # stop all host-metrics services
mise run host-metrics:restart  # restart all host-metrics services
```

### Metrics available

From Alloy (node_exporter):
- `node_cpu_seconds_total` - CPU time per mode
- `node_load1`, `node_load5`, `node_load15` - system load averages
- `node_filesystem_avail_bytes` - available disk space
- `node_disk_*` - disk I/O statistics
- `node_network_*` - network interface statistics

From the Alloy OTel host-process exporter:
- `system_processes_count` - process state counts across the whole workstation
- `process_cpu_utilization_ratio` - tracked-process CPU utilization
- `process_memory_usage_bytes` - tracked-process resident memory
- `process_memory_virtual_bytes` - tracked-process virtual memory
- `process_threads` - tracked-process thread counts
- `process_open_file_descriptors` - tracked-process open file descriptors
- `process_uptime_seconds` - tracked-process uptime

From darwin-exporter:
- `darwin_cpu_temperature_celsius` - CPU die temperature
- `darwin_gpu_temperature_celsius` - GPU temperature
- `darwin_disk_temperature_celsius` - SSD/NAND temperature
- `darwin_battery_health_percent` - battery health as fraction of design capacity
- `darwin_battery_cycle_count` - charge cycle count
- `darwin_battery_temperature_celsius` - battery temperature
- `darwin_thermal_pressure` - thermal throttling state (nominal/fair/serious/critical)
- `darwin_wifi_rssi_dbm` - WiFi signal strength
- `darwin_wifi_connected` - connection status
- `darwin_wifi_info` - SSID, band, security, PHY mode

### Grafana dashboards

The local stack now provisions a repo-managed forensic suite into the `Harness Observability` folder:

- `Harness Investigation Cockpit` - the landing page for short-window local slowdowns
- `Harness Investigation Cockpit` now uses a v2 tabs-and-rows layout with auto-grid summary KPIs, activity and reliability trends, and a separate workstation tab so the landing page behaves more like an operator cockpit than a flat wall of charts
- `AI Agents Cockpit` - shared Claude, Codex, Copilot, and Gemini landing dashboard with a cross-agent cockpit first, then agent-specific tabs for Claude cost and productivity, Codex runtime and logs, Copilot activity, and Gemini spanmetrics plus logs backed by live `claude_code_*`, `codex_*`, `github_copilot_*`, Loki, and Tempo spanmetrics signals
- `Harness Host Machine` - CPU, load, memory, swap, disk, filesystem, network, process states, tracked-process CPU/RSS/VM/thread/fd/uptime, WiFi, battery, and thermal drilldown
- `Harness Host Processes` - low-cardinality process triage with top offenders, process-state pressure, per-process CPU/RSS/VM/thread/fd/uptime trends, and current rankings
- `Harness Runtime & Hooks` - CLI and hook execution bottlenecks
- `Harness Daemon Transport` - HTTP and WS transport bottlenecks
- `Harness Monitor Client` - monitor memory, websocket, cache, and client API pressure
- `Harness Storage & SQLite` - storage and SQLite forensic analysis
- `Harness Service Flow` - service-edge metrics plus Tempo Explore pivots

`sqlite-exporter` now builds from a tiny repo-managed wrapper image that adds `curl` on top of `adonato/query-exporter:5.0.2`, keeping the Docker healthcheck deterministic without changing exporter behavior.

Use Tempo Explore's Service Graph for the authoritative topology view and use the suite dashboards for metric correlation, ranked offenders, and log or trace pivots.

Native OTLP logs in Loki keep most OpenTelemetry log attributes as structured metadata, not indexed stream labels.
For Codex logs specifically, the environment field currently arrives as `env`, and level arrives as `detected_level`, so dashboard log queries must use pipeline metadata filters such as `| env=~"..."`
and `| detected_level=~"..."` instead of stream selectors like `{deployment_environment=...}`.

### Submodule

darwin-exporter source lives in `vendor/darwin-exporter` as a git submodule pointing to [timansky/darwin-exporter](https://github.com/timansky/darwin-exporter). To update:

```bash
git submodule update --remote vendor/darwin-exporter
mise run host-metrics:build-darwin-exporter
mise run host-metrics:install
```
