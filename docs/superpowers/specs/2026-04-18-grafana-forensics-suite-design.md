# Grafana Forensics Suite Redesign

Date: 2026-04-18
Status: Proposed
Scope: `resources/observability/grafana/dashboards/`, `resources/observability/grafana/init-star-dashboards.sh`

## Summary

Redesign the local Harness Grafana workspace from a loose set of observability dashboards into a single-host performance-forensics suite.

The new suite is optimized for short-window investigations over the last 1-6 hours.

The landing page becomes a correlation-first cockpit that answers whether a slowdown is driven by host pressure, runtime execution, daemon transport, monitor client behavior, storage pressure, or service flow.

The redesign adds one new host drilldown dashboard, replaces the current overview dashboard with a new cockpit, and refocuses the remaining dashboards into a consistent investigative workflow.

## Context

Commit `efb9afc46e9434ef352aeee9206a3d723c0db35e` added a materially larger host metrics surface to the local observability stack.

The stack now combines:

- Alloy `prometheus.exporter.unix` metrics for CPU, load, memory, disk, filesystem, network, boot time, and uname.
- `darwin-exporter` metrics for thermal pressure, CPU/GPU/disk temperatures, battery health and temperature, WiFi quality, and advanced `wdutil` wireless metrics.
- Existing Harness metrics for runtime execution, daemon transport, monitor client activity, service flow, and SQLite behavior.

The current suite does not treat these signals as one investigative system.

`Harness System Overview` is generic, host metrics live outside the first-class suite, and the existing boards behave more like parallel silos than a deliberate debugging workflow.

## Goals

- Make Grafana useful as the first stop for short-window local performance and capacity investigations.
- Correlate host-machine pressure with Harness activity without forcing the user to open multiple unrelated dashboards first.
- Promote the new host metrics surface to a first-class part of the observability workspace.
- Standardize layout, variables, links, and dashboard navigation across the suite.
- Use modern Grafana 12+ dashboard capabilities already supported by the repo constraints.

## Non-Goals

- Multi-host or fleet-ready design.
- Long-range capacity reporting for days or weeks.
- Adding dashboard-level alert rules.
- Reworking the underlying Prometheus scrape topology or exporter setup.
- Replacing Tempo Explore as the authoritative service graph surface.

## Design Principles

### Investigate Before Detail

The landing dashboard must answer "what changed in the last hour?" before showing deep evidence.

The cockpit should highlight correlation and top offenders, then link into narrower drilldowns.

### Domain-Pure Drilldowns

Each drilldown dashboard should answer one investigative question well.

Runtime, transport, monitor, storage, host, and service flow each keep a focused job instead of mixing unrelated evidence on one page.

### Single-Host Local-First

The suite should feel natural for one workstation.

It should not expose noisy multi-host controls or treat Alloy and `darwin-exporter` as separate logical machines.

### Consistent Layout Rhythm

Every dashboard follows the same four-layer structure:

1. KPI strip.
2. Correlation row.
3. Detailed trends and top offenders.
4. Evidence row for logs or explanatory tables.

## Target Dashboard Roster

### 1. Harness Investigation Cockpit

File: `resources/observability/grafana/dashboards/investigation-cockpit.json`

UID: `harness-investigation-cockpit`

This replaces `Harness System Overview` as the suite landing page.

It is intentionally small and correlation-first.

It should not contain a large logs wall.

Primary contents:

- Key short-window stats: hook latency, daemon latency, monitor latency, thermal state, memory pressure, disk pressure.
- Host correlation strip: host stress summary panels that move with local bottlenecks.
- Harness correlation strip: service or subsystem pressure panels that move with runtime slowdowns.
- Tables or ranked panels for top slow services, hot routes, busiest disks, or hottest mountpoints.
- Breadcrumb links into the focused drilldown dashboards and Explore apps.

### 2. Harness Host Machine

File: `resources/observability/grafana/dashboards/host-machine.json`

UID: `harness-host-machine`

This is a new first-class dashboard dedicated to the host workstation.

Primary contents:

- CPU busy, load normalized by core count, and per-core hot spots when useful.
- Memory pressure derived from active, wired, compressed, free, swap used, swapped in, and swapped out metrics.
- Disk throughput, busy time, read/write latency, and top devices.
- Filesystem usage and mountpoint pressure with noise filtered out.
- WiFi quality from RSSI, noise, SNR, TX rate, channel width, and `wdutil` channel utilization when present.
- Battery capacity, health, charging state, power source, remaining time, and temperature.
- Thermal pressure state plus CPU/GPU/disk temperatures.

### 3. Harness Runtime & Hooks

File: keep `resources/observability/grafana/dashboards/runtime-execution.json`

UID: keep `harness-runtime-execution`

This remains the runtime execution dashboard, but it is reframed explicitly around execution bottlenecks and hook behavior.

Primary contents:

- CLI and hook span rates.
- Hook p95 and p99.
- Span and hook latency percentiles by service and span name.
- Hook outcomes, blocked operations, and runtime logs.

### 4. Harness Daemon Transport

File: keep `resources/observability/grafana/dashboards/daemon-transport.json`

UID: keep `harness-daemon-transport`

This remains the daemon transport dashboard, but it is tightened around API and transport bottlenecks.

Primary contents:

- Server and client request rate.
- Server and client p95.
- Route and status breakdowns.
- Transport error bursts, reconnect turbulence, and daemon logs.

### 5. Harness Monitor Client

File: keep `resources/observability/grafana/dashboards/monitor-client.json`

UID: keep `harness-monitor-client`

This remains the monitor dashboard, but it should emphasize forensic questions instead of breadth-first coverage.

Primary contents:

- HTTP and WebSocket latency and rate.
- Active tasks and WS connections.
- Resident and virtual memory.
- Bootstrap latency, cache behavior, API error bursts, lifecycle churn, and user interaction spikes.
- Monitor logs and quick pivots into traces and metrics drilldown.

### 6. Harness Storage & SQLite

File: keep `resources/observability/grafana/dashboards/sqlite-forensics.json`

UID: keep `harness-sqlite-forensics`

The UID remains stable, but the visible framing changes from SQLite specialty to storage drilldown.

Primary contents:

- Existing SQLite forensic depth.
- Any top-level framing or panel order changes needed so the dashboard fits a storage-pressure investigation path.

### 7. Harness Service Flow

File: keep `resources/observability/grafana/dashboards/service-map.json`

UID: keep `harness-service-map`

Tempo Explore remains the authoritative service graph surface.

This dashboard becomes the suite's trace and service-flow explanation board instead of the starting point.

Primary contents:

- Edge request rate, failed edge rate, observed edges, and server span rate.
- Rate and latency by edge.
- Links into Tempo Explore for deeper trace analysis.

## Retired Dashboard

### Harness System Overview

File to remove: `resources/observability/grafana/dashboards/system-overview.json`

This concept is replaced by `Harness Investigation Cockpit`.

The redesign should not keep two competing entry dashboards.

## Layout Standard

All dashboards under `resources/observability/grafana/dashboards/` must use the repo-mandated Grafana 12+ responsive layout:

- Dashboard root `layout` block with `kind: "auto-grid"`, `maxColumns: 4`, `minColumnWidth: 300`.
- `gridPos.w: 6` for stat panels.
- `gridPos.w: 12` for charts, state timelines, and most tables.
- `gridPos.w: 24` only when a panel genuinely needs full width, such as a wide logs panel.

The redesign should normalize older dashboards to this standard instead of carrying forward mismatched widths such as `w: 4`.

## Variable Model

### Exposed Variables

- `service_name` for service-focused dashboards.
- `url_path` or route-specific equivalents on transport and monitor dashboards.
- `disk_device` on host dashboards with per-disk analysis.
- `mountpoint` on host dashboards with filesystem analysis.
- WiFi interface when needed.
- `level` only on dashboards with logs panels.

### Hidden or Avoided Variables

- Do not expose a default `instance` picker across the suite.
- Do not treat `bartsmykla` and `host.docker.internal:10102` as separate logical hosts for the local workflow.
- Do not create dashboard-specific naming drift for equivalent filters across boards.

The cockpit should expose the fewest variables of any dashboard.

It is the entry point for diagnosis, not a filter-heavy analysis surface.

## Modern Grafana Features To Standardize

### Dashboard Links

Each dashboard should have breadcrumb-style links that reflect the investigation workflow:

- Cockpit.
- Host Machine.
- Runtime & Hooks.
- Daemon Transport.
- Monitor Client.
- Storage & SQLite.
- Service Flow.

Dashboard links should preserve time range.

### Data Links

Key panels should link directly into supporting investigative surfaces:

- Metrics panels -> Metrics Drilldown app.
- Error and latency panels -> Loki Explore with time range preserved.
- Service and route latency panels -> Tempo Explore or Traces Breakdown.

### State Timeline Panels

Use state timeline panels where categorical state changes matter more than line charts:

- Thermal pressure.
- Charging or power-source state.
- WiFi connected state.
- WebSocket reconnect turbulence when represented categorically.

### Ranked Tables

Use tables for the small number of rankings that help forensic work:

- Top slow routes.
- Top slow services.
- Hottest disks.
- Most pressured mountpoints.

### Consistent Panel Semantics

- `stat` panels use sparklines and thresholds.
- `timeseries` panels use bottom legends in table mode where ranking matters.
- `logs` panels live on drilldowns, not on the cockpit.

## Threshold Strategy

Thresholds must be domain-specific rather than copied across dashboards.

### Host Domain

Examples:

- Load normalized by available cores.
- Memory compression ratio and swap activity.
- Disk busy time and latency.
- Thermal pressure state.
- WiFi RSSI, SNR, and `wdutil` channel utilization.

### Harness Domain

Examples:

- Hook p95 and p99.
- Daemon HTTP p95.
- Monitor HTTP p95.
- WebSocket reconnect bursts.
- Cache miss percentage.
- API error bursts.

Thresholds should be tuned for local forensics.

They are visual triage aids, not paging criteria.

## Navigation and Starring

`resources/observability/grafana/init-star-dashboards.sh` should be updated so the starred order matches the intended workflow:

1. `harness-investigation-cockpit`
2. `harness-host-machine`
3. `harness-daemon-transport`
4. `harness-monitor-client`
5. `harness-runtime-execution`
6. `harness-sqlite-forensics`
7. `harness-service-map`

`harness-system-overview` should be removed from the starred set.

## Migration Strategy

### New Files

- Add `resources/observability/grafana/dashboards/investigation-cockpit.json`
- Add `resources/observability/grafana/dashboards/host-machine.json`

### Removed Files

- Remove `resources/observability/grafana/dashboards/system-overview.json`

### Existing Files To Refocus

- `resources/observability/grafana/dashboards/runtime-execution.json`
- `resources/observability/grafana/dashboards/daemon-transport.json`
- `resources/observability/grafana/dashboards/monitor-client.json`
- `resources/observability/grafana/dashboards/sqlite-forensics.json`
- `resources/observability/grafana/dashboards/service-map.json`

### UID Policy

Keep existing UIDs where the domain remains the same.

Create new UIDs only for the new cockpit and host dashboards.

This reduces churn in links, stars, and local operator habits.

## Verification Plan

Implementation should be verified with the smallest useful repo-local checks plus Grafana-aware validation.

Minimum verification:

- Validate dashboard JSON syntax.
- Confirm all dashboards still provision into the `Harness Observability` folder.
- Confirm the new and renamed dashboards appear in Grafana with the expected titles and UIDs.
- Confirm the starred order matches the intended landing flow.
- Confirm key Prometheus queries resolve against the local datasource.
- Confirm panel links and dashboard links preserve time range and open the intended target.

Recommended live checks after implementation:

- Open the cockpit and verify it makes host pressure visible alongside harness latency within the same time window.
- Open the host machine board and confirm real values for CPU, memory, disk, WiFi, battery, and thermal panels.
- Spot-check data links from latency or error panels into Explore.

## Tradeoff Decisions

### Why Not a Single Super-Dashboard

One dense dashboard would be fast for a glance but poor for actual investigation once traces, logs, host details, and subsystem-specific metrics all matter at once.

The redesign prefers a strong cockpit plus narrow drilldowns.

### Why Not Trace-First Navigation

Service flow is important, but the new value from `efb9afc4` is local host pressure visibility.

A trace-first home page would underweight thermal, disk, memory, and WiFi bottlenecks.

### Why No Dashboard Alerts

This local stack is meant to support investigation.

Visual correlation and fast pivots are the goal.

Dashboard alerts would add noise without improving the local performance-forensics workflow.

## Open Questions

None for the approved design scope.

The remaining work is implementation detail, not product-shape uncertainty.
