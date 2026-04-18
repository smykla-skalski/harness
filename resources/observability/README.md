# Local Observability Stack

Tempo Explore's Service Graph is the authoritative service map for the local Harness observability stack.
Use the provisioned `Harness Service Map` dashboard as the landing page for supporting RED metrics, then jump into Tempo Explore for the built-in graph and span table.

Tempo metrics-generator owns the `traces_service_graph_*` and `traces_spanmetrics_*` metrics that power the service map.
Alloy still exports the repo's `harness.spanmetrics_*` metrics for the existing custom dashboards, but it should not emit duplicate `traces_service_graph_*` series.

The local Grafana Tempo data source is already provisioned with `serviceMap.datasourceUid: prometheus`, so Tempo Explore can render the built-in Service Graph as soon as Prometheus receives the Tempo-generated metrics.

## macOS host metrics

Two native services collect host-level metrics from your Mac and feed them into the local Prometheus:

Grafana Alloy runs as a homebrew service and collects standard node_exporter-style metrics via its `prometheus.exporter.unix` component. It remote-writes directly to Prometheus.

darwin-exporter runs as a launchd daemon and collects macOS-specific metrics that node_exporter cannot provide: CPU/GPU/disk temperatures, battery health and cycle count, WiFi signal strength and connection details, and thermal pressure state. Prometheus scrapes it on port 10102.

### Installation

```bash
mise run host-metrics:install
```

This installs both services:
- Alloy via homebrew with a config at `/opt/homebrew/etc/alloy/config.alloy`
- darwin-exporter built from `vendor/darwin-exporter` (requires Go), installed to `/usr/local/bin/darwin-exporter`

### Management commands

```bash
mise run host-metrics:status   # show service status and Prometheus targets
mise run host-metrics:metrics  # query current host metrics
mise run host-metrics:logs     # tail recent logs from both services
mise run host-metrics:start    # start both services
mise run host-metrics:stop     # stop both services
mise run host-metrics:restart  # restart both services
```

### Metrics available

From Alloy (node_exporter):
- `node_cpu_seconds_total` - CPU time per mode
- `node_load1`, `node_load5`, `node_load15` - system load averages
- `node_filesystem_avail_bytes` - available disk space
- `node_disk_*` - disk I/O statistics
- `node_network_*` - network interface statistics

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

Import these dashboards for visualization:
- [Node Exporter Mac OSX](https://grafana.com/grafana/dashboards/15797) (ID: 15797) - for Alloy metrics
- [macOS Process Metrics](https://grafana.com/grafana/dashboards/24129) (ID: 24129) - for darwin-exporter metrics

### Submodule

darwin-exporter source lives in `vendor/darwin-exporter` as a git submodule pointing to [timansky/darwin-exporter](https://github.com/timansky/darwin-exporter). To update:

```bash
git submodule update --remote vendor/darwin-exporter
mise run host-metrics:build-darwin-exporter
mise run host-metrics:install
```
