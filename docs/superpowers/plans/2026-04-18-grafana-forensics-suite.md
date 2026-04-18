# Grafana Forensics Suite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current Grafana overview flow with a short-window, single-host performance-forensics suite built around a new investigation cockpit and host machine drilldown.

**Architecture:** Add two new repo-managed dashboards (`investigation-cockpit.json` and `host-machine.json`), remove `system-overview.json`, and refocus the remaining dashboards into one workflow with consistent Grafana 12 auto-grid layout, breadcrumb links, and domain-specific PromQL. Bump the repo version from `25.3.4` to `25.4.0` at the start so the feature work ships under one minor release and keep the existing UIDs only where the dashboard domain stays the same.

**Tech Stack:** Grafana 12 dashboard JSON, Prometheus, Loki, Tempo, shell scripts, `jq`, `curl`, repo version-sync script, local Harness observability stack

---

## File structure

- `resources/observability/grafana/dashboards/investigation-cockpit.json`
  - New landing dashboard that replaces the current overview and correlates host pressure with harness latency.
- `resources/observability/grafana/dashboards/host-machine.json`
  - New host-focused drilldown for CPU, memory, swap, disk, filesystem, WiFi, battery, and thermal state.
- `resources/observability/grafana/dashboards/system-overview.json`
  - Remove this file after the cockpit exists and all incoming links point at the new dashboard.
- `resources/observability/grafana/dashboards/runtime-execution.json`
  - Keep the UID, retitle to `Harness Runtime & Hooks`, normalize layout, and add breadcrumb links.
- `resources/observability/grafana/dashboards/daemon-transport.json`
  - Keep the UID, strengthen transport-forensics framing, and add breadcrumb links.
- `resources/observability/grafana/dashboards/monitor-client.json`
  - Keep the UID, fix the `w: 4` stat density, and re-order panels around memory, websocket, cache, and API pain.
- `resources/observability/grafana/dashboards/sqlite-forensics.json`
  - Keep the UID, retitle to `Harness Storage & SQLite`, and align links/layout with the suite.
- `resources/observability/grafana/dashboards/service-map.json`
  - Keep the UID, retitle to `Harness Service Flow`, and replace the overview link with the cockpit link.
- `resources/observability/grafana/init-star-dashboards.sh`
  - Update the starred dashboard order so the cockpit is the landing favorite.
- `resources/observability/README.md`
  - Replace the external dashboard-import guidance with the repo-managed suite roster.
- `Cargo.toml`
  - Canonical version source; bump from `25.3.4` to `25.4.0`.
- `testkit/Cargo.toml`
  - Derived version surface updated by `./scripts/version.sh set 25.4.0`.
- `Cargo.lock`
  - Derived version surface updated by `./scripts/version.sh set 25.4.0`.
- `apps/harness-monitor-macos/project.yml`
  - Derived version surface updated by `./scripts/version.sh set 25.4.0`.
- `apps/harness-monitor-macos/HarnessMonitor.xcodeproj/project.pbxproj`
  - Derived version surface updated by `./scripts/version.sh set 25.4.0`.
- `apps/harness-monitor-macos/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist`
  - Derived version surface updated by `./scripts/version.sh set 25.4.0`.
- `tmp/reports/2026-04-18-grafana-forensics-suite-validation.md`
  - Validation artifact capturing the live Grafana/Prometheus proof after implementation.

> **Implementation note:** execute this plan from a dedicated worktree off `main`. The current checkout already has unrelated dirty changes in monitor and versioned files, so the feature work should run in isolation and stage only the files listed in each task.

### Task 1: Bump the version and replace the overview with the investigation cockpit

**Files:**
- Create: `resources/observability/grafana/dashboards/investigation-cockpit.json`
- Modify: `Cargo.toml`
- Modify: `testkit/Cargo.toml`
- Modify: `Cargo.lock`
- Modify: `apps/harness-monitor-macos/project.yml`
- Modify: `apps/harness-monitor-macos/HarnessMonitor.xcodeproj/project.pbxproj`
- Modify: `apps/harness-monitor-macos/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist`
- Test: `resources/observability/grafana/dashboards/investigation-cockpit.json`

- [ ] **Step 1: Confirm the starting version and the missing cockpit file**

Run:

```bash
./scripts/version.sh show
test ! -f resources/observability/grafana/dashboards/investigation-cockpit.json
```

Expected:

- `./scripts/version.sh show` prints `25.3.4`
- `test ! -f ...` exits `0` because the cockpit dashboard does not exist yet

- [ ] **Step 2: Bump the canonical version to `25.4.0` before the feature work**

Run:

```bash
./scripts/version.sh set 25.4.0
./scripts/version.sh check
```

Expected:

- `./scripts/version.sh set 25.4.0` updates `Cargo.toml`, `testkit/Cargo.toml`, `Cargo.lock`, `apps/harness-monitor-macos/project.yml`, `apps/harness-monitor-macos/HarnessMonitor.xcodeproj/project.pbxproj`, and `apps/harness-monitor-macos/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist`
- `./scripts/version.sh check` exits `0`

- [ ] **Step 3: Create the cockpit dashboard by copying the overview file and replacing the root metadata**

Run:

```bash
cp resources/observability/grafana/dashboards/system-overview.json \
  resources/observability/grafana/dashboards/investigation-cockpit.json
```

Replace the copied root metadata with:

```json
{
  "title": "Harness Investigation Cockpit",
  "uid": "harness-investigation-cockpit",
  "tags": ["harness", "observability", "forensics", "cockpit"],
  "refresh": "10s",
  "time": {
    "from": "now-3h",
    "to": "now"
  },
  "links": [
    {
      "title": "Host Machine",
      "type": "link",
      "url": "/d/harness-host-machine",
      "keepTime": true,
      "includeVars": false,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    },
    {
      "title": "Runtime & Hooks",
      "type": "link",
      "url": "/d/harness-runtime-execution",
      "keepTime": true,
      "includeVars": true,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    },
    {
      "title": "Daemon Transport",
      "type": "link",
      "url": "/d/harness-daemon-transport",
      "keepTime": true,
      "includeVars": true,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    },
    {
      "title": "Monitor Client",
      "type": "link",
      "url": "/d/harness-monitor-client",
      "keepTime": true,
      "includeVars": true,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    },
    {
      "title": "Storage & SQLite",
      "type": "link",
      "url": "/d/harness-sqlite-forensics",
      "keepTime": true,
      "includeVars": true,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    },
    {
      "title": "Service Flow",
      "type": "link",
      "url": "/d/harness-service-map",
      "keepTime": true,
      "includeVars": true,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    },
    {
      "title": "Metrics Drilldown",
      "type": "link",
      "url": "/a/grafana-metricsdrilldown-app/drilldown",
      "keepTime": true,
      "includeVars": false,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    },
    {
      "title": "Logs Drilldown",
      "type": "link",
      "url": "/a/grafana-lokiexplore-app/explore",
      "keepTime": true,
      "includeVars": false,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    },
    {
      "title": "Traces Breakdown",
      "type": "link",
      "url": "/a/grafana-exploretraces-app/explore?from=now-30m&to=now&timezone=browser&var-ds=tempo&var-primarySignal=nestedSetParent%3C0&var-filters=&var-metric=rate&var-groupBy=resource.service.name&var-spanListColumns=&var-latencyThreshold=&var-partialLatencyThreshold=&var-durationPercentiles=0.9&actionView=breakdown",
      "keepTime": false,
      "includeVars": false,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    }
  ]
}
```

- [ ] **Step 4: Replace the panel list with the cockpit-specific KPI strip and correlation rows**

Use this exact panel set as the first pass in `resources/observability/grafana/dashboards/investigation-cockpit.json`:

```json
[
  {
    "id": 1,
    "title": "Hook p95",
    "type": "stat",
    "gridPos": { "h": 4, "w": 6, "x": 0, "y": 0 },
    "datasource": { "type": "prometheus", "uid": "prometheus" },
    "fieldConfig": {
      "defaults": {
        "unit": "ms",
        "color": { "mode": "thresholds" },
        "thresholds": {
          "mode": "absolute",
          "steps": [
            { "color": "green", "value": 0 },
            { "color": "orange", "value": 150 },
            { "color": "red", "value": 500 }
          ]
        }
      },
      "overrides": []
    },
    "options": {
      "colorMode": "value",
      "graphMode": "area",
      "justifyMode": "auto",
      "orientation": "auto",
      "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false },
      "textMode": "value"
    },
    "targets": [
      {
        "editorMode": "code",
        "expr": "((histogram_quantile(0.95, sum by (le) (rate(harness_spanmetrics_duration_milliseconds_bucket{service_name=\"harness-hook\"}[5m]))) and on() (sum(rate(harness_spanmetrics_calls_total{service_name=\"harness-hook\"}[5m])) > 0)) or on() vector(0))",
        "refId": "A"
      }
    ]
  },
  {
    "id": 2,
    "title": "Daemon HTTP p95",
    "type": "stat",
    "gridPos": { "h": 4, "w": 6, "x": 6, "y": 0 },
    "datasource": { "type": "prometheus", "uid": "prometheus" },
    "fieldConfig": {
      "defaults": {
        "unit": "ms",
        "color": { "mode": "thresholds" },
        "thresholds": {
          "mode": "absolute",
          "steps": [
            { "color": "green", "value": 0 },
            { "color": "orange", "value": 100 },
            { "color": "red", "value": 300 }
          ]
        }
      },
      "overrides": []
    },
    "options": {
      "colorMode": "value",
      "graphMode": "area",
      "justifyMode": "auto",
      "orientation": "auto",
      "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false },
      "textMode": "value"
    },
    "targets": [
      {
        "editorMode": "code",
        "expr": "((histogram_quantile(0.95, sum by (le) (rate(harness_daemon_http_duration_milliseconds_bucket[5m]))) and on() (sum(rate(harness_daemon_http_duration_milliseconds_count[5m])) > 0)) or on() vector(0))",
        "refId": "A"
      }
    ]
  },
  {
    "id": 3,
    "title": "Monitor HTTP p95",
    "type": "stat",
    "gridPos": { "h": 4, "w": 6, "x": 12, "y": 0 },
    "datasource": { "type": "prometheus", "uid": "prometheus" },
    "fieldConfig": {
      "defaults": {
        "unit": "ms",
        "color": { "mode": "thresholds" },
        "thresholds": {
          "mode": "absolute",
          "steps": [
            { "color": "green", "value": 0 },
            { "color": "orange", "value": 150 },
            { "color": "red", "value": 500 }
          ]
        }
      },
      "overrides": []
    },
    "options": {
      "colorMode": "value",
      "graphMode": "area",
      "justifyMode": "auto",
      "orientation": "auto",
      "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false },
      "textMode": "value"
    },
    "targets": [
      {
        "editorMode": "code",
        "expr": "((histogram_quantile(0.95, sum by (le) (rate(harness_monitor_http_request_duration_ms_bucket[5m]))) and on() (sum(rate(harness_monitor_http_request_duration_ms_count[5m])) > 0)) or on() vector(0))",
        "refId": "A"
      }
    ]
  },
  {
    "id": 4,
    "title": "Thermal Pressure Active",
    "type": "stat",
    "gridPos": { "h": 4, "w": 6, "x": 18, "y": 0 },
    "datasource": { "type": "prometheus", "uid": "prometheus" },
    "fieldConfig": {
      "defaults": {
        "unit": "none",
        "color": { "mode": "thresholds" },
        "thresholds": {
          "mode": "absolute",
          "steps": [
            { "color": "green", "value": 0 },
            { "color": "red", "value": 1 }
          ]
        }
      },
      "overrides": []
    },
    "options": {
      "colorMode": "value",
      "graphMode": "area",
      "justifyMode": "auto",
      "orientation": "auto",
      "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false },
      "textMode": "value"
    },
    "targets": [
      {
        "editorMode": "code",
        "expr": "max(darwin_thermal_pressure{state=~\"fair|serious|critical\"}) or on() vector(0)",
        "refId": "A"
      }
    ]
  },
  {
    "id": 5,
    "title": "Host Stress Correlation",
    "type": "timeseries",
    "gridPos": { "h": 8, "w": 12, "x": 0, "y": 4 },
    "datasource": { "type": "prometheus", "uid": "prometheus" },
    "fieldConfig": { "defaults": { "color": { "mode": "palette-classic" } }, "overrides": [] },
    "options": { "legend": { "displayMode": "table", "placement": "bottom" } },
    "targets": [
      {
        "editorMode": "code",
        "expr": "(1 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m]))) * 100",
        "legendFormat": "cpu busy %",
        "refId": "A"
      },
      {
        "editorMode": "code",
        "expr": "((node_memory_active_bytes + node_memory_wired_bytes + node_memory_compressed_bytes) / clamp_min(node_memory_total_bytes, 1)) * 100",
        "legendFormat": "memory pressure %",
        "refId": "B"
      },
      {
        "editorMode": "code",
        "expr": "clamp_max(sum(rate(node_disk_read_time_seconds_total[5m]) + rate(node_disk_write_time_seconds_total[5m])), 1) * 100",
        "legendFormat": "disk busy %",
        "refId": "C"
      }
    ]
  },
  {
    "id": 6,
    "title": "Harness Stress Correlation",
    "type": "timeseries",
    "gridPos": { "h": 8, "w": 12, "x": 12, "y": 4 },
    "datasource": { "type": "prometheus", "uid": "prometheus" },
    "fieldConfig": { "defaults": { "color": { "mode": "palette-classic" } }, "overrides": [] },
    "options": { "legend": { "displayMode": "table", "placement": "bottom" } },
    "targets": [
      {
        "editorMode": "code",
        "expr": "sum(rate(harness_spanmetrics_calls_total[5m]))",
        "legendFormat": "span rate",
        "refId": "A"
      },
      {
        "editorMode": "code",
        "expr": "((histogram_quantile(0.95, sum by (le) (rate(harness_daemon_http_duration_milliseconds_bucket[5m]))) and on() (sum(rate(harness_daemon_http_duration_milliseconds_count[5m])) > 0)) or on() vector(0))",
        "legendFormat": "daemon p95",
        "refId": "B"
      },
      {
        "editorMode": "code",
        "expr": "((histogram_quantile(0.95, sum by (le) (rate(harness_monitor_http_request_duration_ms_bucket[5m]))) and on() (sum(rate(harness_monitor_http_request_duration_ms_count[5m])) > 0)) or on() vector(0))",
        "legendFormat": "monitor p95",
        "refId": "C"
      }
    ]
  },
  {
    "id": 7,
    "title": "Top Slow Routes",
    "type": "timeseries",
    "gridPos": { "h": 8, "w": 12, "x": 0, "y": 12 },
    "datasource": { "type": "prometheus", "uid": "prometheus" },
    "fieldConfig": { "defaults": { "color": { "mode": "palette-classic" }, "unit": "ms" }, "overrides": [] },
    "options": { "legend": { "displayMode": "table", "placement": "bottom" } },
    "targets": [
      {
        "editorMode": "code",
        "expr": "topk(8, histogram_quantile(0.95, sum by (le, http_route) (rate(harness_daemon_http_duration_milliseconds_bucket[5m]))))",
        "legendFormat": "daemon {{http_route}}",
        "refId": "A"
      },
      {
        "editorMode": "code",
        "expr": "topk(8, histogram_quantile(0.95, sum by (le, url_path) (rate(harness_monitor_http_request_duration_ms_bucket[5m]))))",
        "legendFormat": "monitor {{url_path}}",
        "refId": "B"
      }
    ]
  },
  {
    "id": 8,
    "title": "Hot Mountpoints",
    "type": "timeseries",
    "gridPos": { "h": 8, "w": 12, "x": 12, "y": 12 },
    "datasource": { "type": "prometheus", "uid": "prometheus" },
    "fieldConfig": { "defaults": { "color": { "mode": "palette-classic" }, "unit": "percent" }, "overrides": [] },
    "options": { "legend": { "displayMode": "table", "placement": "bottom" } },
    "targets": [
      {
        "editorMode": "code",
        "expr": "topk(8, (1 - node_filesystem_avail_bytes{fstype!~\"autofs|procfs|devfs|fdescfs|tmpfs\"} / node_filesystem_size_bytes{fstype!~\"autofs|procfs|devfs|fdescfs|tmpfs\"}) * 100)",
        "legendFormat": "{{mountpoint}}",
        "refId": "A"
      }
    ]
  }
]
```

- [ ] **Step 5: Validate the new cockpit JSON and commit the version bump with the landing dashboard**

Run:

```bash
jq empty resources/observability/grafana/dashboards/investigation-cockpit.json
rg -n '25.4.0|harness-investigation-cockpit|Harness Investigation Cockpit' \
  Cargo.toml \
  testkit/Cargo.toml \
  Cargo.lock \
  apps/harness-monitor-macos/project.yml \
  apps/harness-monitor-macos/HarnessMonitor.xcodeproj/project.pbxproj \
  apps/harness-monitor-macos/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist \
  resources/observability/grafana/dashboards/investigation-cockpit.json
git add \
  Cargo.toml \
  testkit/Cargo.toml \
  Cargo.lock \
  apps/harness-monitor-macos/project.yml \
  apps/harness-monitor-macos/HarnessMonitor.xcodeproj/project.pbxproj \
  apps/harness-monitor-macos/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist \
  resources/observability/grafana/dashboards/investigation-cockpit.json
git commit -m "feat(observability): add investigation cockpit"
```

Expected:

- `jq empty ...` exits `0`
- `rg -n ...` shows the new version and dashboard UID/title

### Task 2: Add the dedicated host machine dashboard

**Files:**
- Create: `resources/observability/grafana/dashboards/host-machine.json`
- Test: `resources/observability/grafana/dashboards/host-machine.json`

- [ ] **Step 1: Create the dashboard skeleton with host-specific variables**

Create `resources/observability/grafana/dashboards/host-machine.json` with this root block:

```json
{
  "layout": {
    "kind": "auto-grid",
    "spec": {
      "maxColumns": 4,
      "minColumnWidth": 300
    }
  },
  "editable": true,
  "graphTooltip": 1,
  "refresh": "10s",
  "time": {
    "from": "now-3h",
    "to": "now"
  },
  "title": "Harness Host Machine",
  "uid": "harness-host-machine",
  "tags": ["harness", "observability", "host", "forensics"],
  "links": [
    {
      "title": "Investigation Cockpit",
      "type": "link",
      "url": "/d/harness-investigation-cockpit",
      "keepTime": true,
      "includeVars": false,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    },
    {
      "title": "Runtime & Hooks",
      "type": "link",
      "url": "/d/harness-runtime-execution",
      "keepTime": true,
      "includeVars": true,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    },
    {
      "title": "Daemon Transport",
      "type": "link",
      "url": "/d/harness-daemon-transport",
      "keepTime": true,
      "includeVars": true,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    },
    {
      "title": "Monitor Client",
      "type": "link",
      "url": "/d/harness-monitor-client",
      "keepTime": true,
      "includeVars": true,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    },
    {
      "title": "Storage & SQLite",
      "type": "link",
      "url": "/d/harness-sqlite-forensics",
      "keepTime": true,
      "includeVars": true,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    },
    {
      "title": "Service Flow",
      "type": "link",
      "url": "/d/harness-service-map",
      "keepTime": true,
      "includeVars": true,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    }
  ],
  "templating": {
    "list": [
      {
        "name": "disk_device",
        "type": "query",
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "query": { "query": "label_values(node_disk_read_bytes_total, device)" },
        "includeAll": true,
        "multi": true,
        "refresh": 1
      },
      {
        "name": "mountpoint",
        "type": "query",
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "query": {
          "query": "label_values(node_filesystem_size_bytes{fstype!~\"autofs|procfs|devfs|fdescfs|tmpfs\"}, mountpoint)"
        },
        "includeAll": true,
        "multi": true,
        "refresh": 1
      },
      {
        "name": "wifi_interface",
        "type": "query",
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "query": { "query": "label_values(darwin_wifi_info, interface)" },
        "includeAll": true,
        "multi": true,
        "refresh": 1
      }
    ]
  }
}
```

- [ ] **Step 2: Add the CPU, memory, swap, disk, and filesystem panels**

Use these exact panels first:

```json
[
  {
    "id": 1,
    "title": "CPU Busy",
    "type": "stat",
    "gridPos": { "h": 4, "w": 6, "x": 0, "y": 0 },
    "datasource": { "type": "prometheus", "uid": "prometheus" },
    "fieldConfig": {
      "defaults": {
        "unit": "percentunit",
        "color": { "mode": "thresholds" },
        "thresholds": {
          "mode": "absolute",
          "steps": [
            { "color": "green", "value": 0 },
            { "color": "orange", "value": 0.6 },
            { "color": "red", "value": 0.85 }
          ]
        }
      },
      "overrides": []
    },
    "options": {
      "colorMode": "value",
      "graphMode": "area",
      "justifyMode": "auto",
      "orientation": "auto",
      "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false },
      "textMode": "value"
    },
    "targets": [
      {
        "editorMode": "code",
        "expr": "1 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m]))",
        "refId": "A"
      }
    ]
  },
  {
    "id": 2,
    "title": "Load / Core",
    "type": "stat",
    "gridPos": { "h": 4, "w": 6, "x": 6, "y": 0 },
    "datasource": { "type": "prometheus", "uid": "prometheus" },
    "fieldConfig": {
      "defaults": {
        "unit": "none",
        "color": { "mode": "thresholds" },
        "thresholds": {
          "mode": "absolute",
          "steps": [
            { "color": "green", "value": 0 },
            { "color": "orange", "value": 0.7 },
            { "color": "red", "value": 1 }
          ]
        }
      },
      "overrides": []
    },
    "options": {
      "colorMode": "value",
      "graphMode": "area",
      "justifyMode": "auto",
      "orientation": "auto",
      "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false },
      "textMode": "value"
    },
    "targets": [
      {
        "editorMode": "code",
        "expr": "node_load1 / clamp_min(count(count by (cpu) (node_cpu_seconds_total{mode=\"idle\"})), 1)",
        "refId": "A"
      }
    ]
  },
  {
    "id": 3,
    "title": "Memory Pressure",
    "type": "stat",
    "gridPos": { "h": 4, "w": 6, "x": 12, "y": 0 },
    "datasource": { "type": "prometheus", "uid": "prometheus" },
    "fieldConfig": {
      "defaults": {
        "unit": "percentunit",
        "color": { "mode": "thresholds" },
        "thresholds": {
          "mode": "absolute",
          "steps": [
            { "color": "green", "value": 0 },
            { "color": "orange", "value": 0.7 },
            { "color": "red", "value": 0.85 }
          ]
        }
      },
      "overrides": []
    },
    "options": {
      "colorMode": "value",
      "graphMode": "area",
      "justifyMode": "auto",
      "orientation": "auto",
      "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false },
      "textMode": "value"
    },
    "targets": [
      {
        "editorMode": "code",
        "expr": "(node_memory_active_bytes + node_memory_wired_bytes + node_memory_compressed_bytes) / clamp_min(node_memory_total_bytes, 1)",
        "refId": "A"
      }
    ]
  },
  {
    "id": 4,
    "title": "Swap Activity",
    "type": "stat",
    "gridPos": { "h": 4, "w": 6, "x": 18, "y": 0 },
    "datasource": { "type": "prometheus", "uid": "prometheus" },
    "fieldConfig": {
      "defaults": {
        "unit": "Bps",
        "color": { "mode": "thresholds" },
        "thresholds": {
          "mode": "absolute",
          "steps": [
            { "color": "green", "value": 0 },
            { "color": "orange", "value": 1048576 },
            { "color": "red", "value": 10485760 }
          ]
        }
      },
      "overrides": []
    },
    "options": {
      "colorMode": "value",
      "graphMode": "area",
      "justifyMode": "auto",
      "orientation": "auto",
      "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false },
      "textMode": "value"
    },
    "targets": [
      {
        "editorMode": "code",
        "expr": "sum(rate(node_memory_swapped_in_bytes_total[5m]) + rate(node_memory_swapped_out_bytes_total[5m]))",
        "refId": "A"
      }
    ]
  },
  {
    "id": 5,
    "title": "Disk Busy by Device",
    "type": "timeseries",
    "gridPos": { "h": 8, "w": 12, "x": 0, "y": 4 },
    "datasource": { "type": "prometheus", "uid": "prometheus" },
    "fieldConfig": { "defaults": { "unit": "percentunit", "color": { "mode": "palette-classic" } }, "overrides": [] },
    "options": { "legend": { "displayMode": "table", "placement": "bottom" } },
    "targets": [
      {
        "editorMode": "code",
        "expr": "clamp_max(rate(node_disk_read_time_seconds_total{device=~\"${disk_device:regex}\"}[5m]) + rate(node_disk_write_time_seconds_total{device=~\"${disk_device:regex}\"}[5m]), 1)",
        "legendFormat": "{{device}}",
        "refId": "A"
      }
    ]
  },
  {
    "id": 6,
    "title": "Filesystem Fill by Mountpoint",
    "type": "timeseries",
    "gridPos": { "h": 8, "w": 12, "x": 12, "y": 4 },
    "datasource": { "type": "prometheus", "uid": "prometheus" },
    "fieldConfig": { "defaults": { "unit": "percent", "color": { "mode": "palette-classic" } }, "overrides": [] },
    "options": { "legend": { "displayMode": "table", "placement": "bottom" } },
    "targets": [
      {
        "editorMode": "code",
        "expr": "(1 - node_filesystem_avail_bytes{mountpoint=~\"${mountpoint:regex}\",fstype!~\"autofs|procfs|devfs|fdescfs|tmpfs\"} / node_filesystem_size_bytes{mountpoint=~\"${mountpoint:regex}\",fstype!~\"autofs|procfs|devfs|fdescfs|tmpfs\"}) * 100",
        "legendFormat": "{{mountpoint}}",
        "refId": "A"
      }
    ]
  }
]
```

- [ ] **Step 3: Add the WiFi, battery, and thermal panels**

Append these panels after the storage row:

```json
[
  {
    "id": 7,
    "title": "WiFi Quality",
    "type": "timeseries",
    "gridPos": { "h": 8, "w": 12, "x": 0, "y": 12 },
    "datasource": { "type": "prometheus", "uid": "prometheus" },
    "fieldConfig": { "defaults": { "color": { "mode": "palette-classic" } }, "overrides": [] },
    "options": { "legend": { "displayMode": "table", "placement": "bottom" } },
    "targets": [
      {
        "editorMode": "code",
        "expr": "darwin_wifi_rssi_dbm{interface=~\"${wifi_interface:regex}\"}",
        "legendFormat": "RSSI {{interface}}",
        "refId": "A"
      },
      {
        "editorMode": "code",
        "expr": "darwin_wifi_snr_db{interface=~\"${wifi_interface:regex}\"}",
        "legendFormat": "SNR {{interface}}",
        "refId": "B"
      },
      {
        "editorMode": "code",
        "expr": "darwin_wifi_tx_rate_mbps{interface=~\"${wifi_interface:regex}\"}",
        "legendFormat": "TX rate {{interface}}",
        "refId": "C"
      },
      {
        "editorMode": "code",
        "expr": "darwin_wdutil_wifi_cca_percent{interface=~\"${wifi_interface:regex}\"} or vector(0)",
        "legendFormat": "CCA {{interface}}",
        "refId": "D"
      }
    ]
  },
  {
    "id": 8,
    "title": "Battery and Temperatures",
    "type": "timeseries",
    "gridPos": { "h": 8, "w": 12, "x": 12, "y": 12 },
    "datasource": { "type": "prometheus", "uid": "prometheus" },
    "fieldConfig": { "defaults": { "color": { "mode": "palette-classic" } }, "overrides": [] },
    "options": { "legend": { "displayMode": "table", "placement": "bottom" } },
    "targets": [
      {
        "editorMode": "code",
        "expr": "node_power_supply_current_capacity / 100",
        "legendFormat": "battery capacity",
        "refId": "A"
      },
      {
        "editorMode": "code",
        "expr": "darwin_battery_health_percent / 100",
        "legendFormat": "battery health",
        "refId": "B"
      },
      {
        "editorMode": "code",
        "expr": "darwin_cpu_temperature_celsius",
        "legendFormat": "cpu temp",
        "refId": "C"
      },
      {
        "editorMode": "code",
        "expr": "darwin_battery_temperature_celsius",
        "legendFormat": "battery temp",
        "refId": "D"
      }
    ]
  },
  {
    "id": 9,
    "title": "Thermal Pressure States",
    "type": "state-timeline",
    "gridPos": { "h": 8, "w": 12, "x": 0, "y": 20 },
    "datasource": { "type": "prometheus", "uid": "prometheus" },
    "fieldConfig": { "defaults": { "unit": "none", "color": { "mode": "palette-classic" } }, "overrides": [] },
    "options": { "legend": { "displayMode": "table", "placement": "bottom" } },
    "targets": [
      {
        "editorMode": "code",
        "expr": "darwin_thermal_pressure",
        "legendFormat": "{{state}}",
        "refId": "A"
      }
    ]
  },
  {
    "id": 10,
    "title": "Power and WiFi State",
    "type": "state-timeline",
    "gridPos": { "h": 8, "w": 12, "x": 12, "y": 20 },
    "datasource": { "type": "prometheus", "uid": "prometheus" },
    "fieldConfig": { "defaults": { "unit": "none", "color": { "mode": "palette-classic" } }, "overrides": [] },
    "options": { "legend": { "displayMode": "table", "placement": "bottom" } },
    "targets": [
      {
        "editorMode": "code",
        "expr": "node_power_supply_charging",
        "legendFormat": "charging",
        "refId": "A"
      },
      {
        "editorMode": "code",
        "expr": "darwin_wifi_connected{interface=~\"${wifi_interface:regex}\"}",
        "legendFormat": "wifi connected {{interface}}",
        "refId": "B"
      }
    ]
  }
]
```

- [ ] **Step 4: Validate the host dashboard JSON and prove the key queries already resolve**

Run:

```bash
jq empty resources/observability/grafana/dashboards/host-machine.json
curl -sf 'http://127.0.0.1:9090/api/v1/query?query=darwin_cpu_temperature_celsius' | jq -r '.data.result[0].metric.__name__'
curl -sf 'http://127.0.0.1:9090/api/v1/query?query=node_load1' | jq -r '.data.result[0].metric.__name__'
curl -sf 'http://127.0.0.1:9090/api/v1/query?query=darwin_wifi_rssi_dbm' | jq -r '.data.result[0].metric.__name__'
```

Expected:

- `jq empty ...` exits `0`
- the three `curl` commands print `darwin_cpu_temperature_celsius`, `node_load1`, and `darwin_wifi_rssi_dbm`

- [ ] **Step 5: Commit the host dashboard**

Run:

```bash
git add resources/observability/grafana/dashboards/host-machine.json
git commit -m "feat(observability): add host machine dashboard"
```

### Task 3: Refocus the runtime and daemon dashboards around the new suite

**Files:**
- Modify: `resources/observability/grafana/dashboards/runtime-execution.json`
- Modify: `resources/observability/grafana/dashboards/daemon-transport.json`
- Test: `resources/observability/grafana/dashboards/runtime-execution.json`
- Test: `resources/observability/grafana/dashboards/daemon-transport.json`

- [ ] **Step 1: Replace both dashboards’ top-level links with the shared breadcrumb set**

In both files, replace the existing `links` array with:

```json
[
  {
    "title": "Investigation Cockpit",
    "type": "link",
    "url": "/d/harness-investigation-cockpit",
    "keepTime": true,
    "includeVars": false,
    "targetBlank": false,
    "asDropdown": false,
    "icon": "external link",
    "tags": []
  },
  {
    "title": "Host Machine",
    "type": "link",
    "url": "/d/harness-host-machine",
    "keepTime": true,
    "includeVars": false,
    "targetBlank": false,
    "asDropdown": false,
    "icon": "external link",
    "tags": []
  },
  {
    "title": "Monitor Client",
    "type": "link",
    "url": "/d/harness-monitor-client",
    "keepTime": true,
    "includeVars": true,
    "targetBlank": false,
    "asDropdown": false,
    "icon": "external link",
    "tags": []
  },
  {
    "title": "Storage & SQLite",
    "type": "link",
    "url": "/d/harness-sqlite-forensics",
    "keepTime": true,
    "includeVars": true,
    "targetBlank": false,
    "asDropdown": false,
    "icon": "external link",
    "tags": []
  },
  {
    "title": "Service Flow",
    "type": "link",
    "url": "/d/harness-service-map",
    "keepTime": true,
    "includeVars": true,
    "targetBlank": false,
    "asDropdown": false,
    "icon": "external link",
    "tags": []
  },
  {
    "title": "Logs Drilldown",
    "type": "link",
    "url": "/a/grafana-lokiexplore-app/explore",
    "keepTime": true,
    "includeVars": false,
    "targetBlank": false,
    "asDropdown": false,
    "icon": "external link",
    "tags": []
  },
  {
    "title": "Traces Breakdown",
    "type": "link",
    "url": "/a/grafana-exploretraces-app/explore?from=now-30m&to=now&timezone=browser&var-ds=tempo&var-primarySignal=nestedSetParent%3C0&var-filters=&var-metric=rate&var-groupBy=resource.service.name&var-spanListColumns=&var-latencyThreshold=&var-partialLatencyThreshold=&var-durationPercentiles=0.9&actionView=breakdown",
    "keepTime": false,
    "includeVars": false,
    "targetBlank": false,
    "asDropdown": false,
    "icon": "external link",
    "tags": []
  }
]
```

- [ ] **Step 2: Retitle the runtime dashboard and preserve the focused panel order**

In `resources/observability/grafana/dashboards/runtime-execution.json`, replace the dashboard title and the first four panel titles with:

```json
{
  "title": "Harness Runtime & Hooks",
  "panels": [
    { "id": 1, "title": "CLI Span Rate", "gridPos": { "h": 4, "w": 6, "x": 0, "y": 0 } },
    { "id": 2, "title": "Hook Span Rate", "gridPos": { "h": 4, "w": 6, "x": 6, "y": 0 } },
    { "id": 3, "title": "Hook p95", "gridPos": { "h": 4, "w": 6, "x": 12, "y": 0 } },
    { "id": 4, "title": "Hook p99", "gridPos": { "h": 4, "w": 6, "x": 18, "y": 0 } }
  ]
}
```

Also update panel descriptions where they still describe “runtime” generically so they explicitly mention CLI spans, hook spans, hook failures, and runtime execution bottlenecks.

- [ ] **Step 3: Keep the daemon dashboard domain-pure and add direct drill links from the hot stats**

In `resources/observability/grafana/dashboards/daemon-transport.json`, keep the current PromQL expressions but add panel links like this to the first four stat panels:

```json
[
  {
    "title": "Open Investigation Cockpit",
    "url": "/d/harness-investigation-cockpit",
    "keepTime": true,
    "targetBlank": false
  },
  {
    "title": "Open Logs Drilldown",
    "url": "/a/grafana-lokiexplore-app/explore",
    "keepTime": true,
    "targetBlank": false
  }
]
```

Also update the dashboard title and descriptions so the page reads as transport forensics rather than generic daemon telemetry:

```json
{
  "title": "Harness Daemon Transport"
}
```

Description examples:

```json
{
  "description": "Server-side Harness daemon API latency over the current short-window investigation range."
}
```

- [ ] **Step 4: Validate both JSON files and confirm the shared links exist**

Run:

```bash
jq empty resources/observability/grafana/dashboards/runtime-execution.json
jq empty resources/observability/grafana/dashboards/daemon-transport.json
rg -n 'harness-investigation-cockpit|harness-host-machine|Harness Runtime & Hooks' \
  resources/observability/grafana/dashboards/runtime-execution.json \
  resources/observability/grafana/dashboards/daemon-transport.json
```

Expected:

- both `jq empty ...` commands exit `0`
- `rg -n ...` shows the new breadcrumb links and runtime title

- [ ] **Step 5: Commit the runtime and daemon transport refocus**

Run:

```bash
git add \
  resources/observability/grafana/dashboards/runtime-execution.json \
  resources/observability/grafana/dashboards/daemon-transport.json
git commit -m "feat(observability): refocus runtime and transport dashboards"
```

### Task 4: Refocus the monitor dashboard and remove the dense `w: 4` stat band

**Files:**
- Modify: `resources/observability/grafana/dashboards/monitor-client.json`
- Test: `resources/observability/grafana/dashboards/monitor-client.json`

- [ ] **Step 1: Replace the dashboard links with the shared breadcrumb set**

Use the exact `links` array from Task 3 Step 1, but keep the existing `Profiles Drilldown` link at the end because the monitor board already uses it.

- [ ] **Step 2: Retitle the KPI strip and normalize the dense stat row to `w: 6`**

In `resources/observability/grafana/dashboards/monitor-client.json`, keep the existing first eight stat panels as the top two rows, then replace the current dense third row (`id` 13-18) with two half-width trend panels and two quarter-width summary stats:

```json
[
  {
    "id": 13,
    "title": "Lifecycle Events / 5m",
    "type": "timeseries",
    "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 }
  },
  {
    "id": 14,
    "title": "Cache and API Pressure",
    "type": "timeseries",
    "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 }
  },
  {
    "id": 15,
    "title": "Bootstrap p95",
    "type": "stat",
    "gridPos": { "h": 4, "w": 6, "x": 0, "y": 16 }
  },
  {
    "id": 16,
    "title": "Cache Miss %",
    "type": "stat",
    "gridPos": { "h": 4, "w": 6, "x": 6, "y": 16 }
  },
  {
    "id": 17,
    "title": "API Errors / 5m",
    "type": "stat",
    "gridPos": { "h": 4, "w": 6, "x": 12, "y": 16 }
  },
  {
    "id": 18,
    "title": "User Interactions / 5m",
    "type": "stat",
    "gridPos": { "h": 4, "w": 6, "x": 18, "y": 16 }
  }
]
```

- [ ] **Step 3: Replace the dense stat-band queries with trend panels that carry the same signals**

For `id` 13 and `id` 14, use these exact targets:

```json
[
  {
    "id": 13,
    "targets": [
      {
        "editorMode": "code",
        "expr": "sum by (lifecycle_event) (rate(harness_monitor_app_lifecycle_total[5m]))",
        "legendFormat": "{{lifecycle_event}}",
        "refId": "A"
      },
      {
        "editorMode": "code",
        "expr": "sum(rate(harness_monitor_user_interactions_total[5m]))",
        "legendFormat": "user interactions",
        "refId": "B"
      }
    ]
  },
  {
    "id": 14,
    "targets": [
      {
        "editorMode": "code",
        "expr": "sum(rate(harness_monitor_api_errors_total[5m]))",
        "legendFormat": "api errors",
        "refId": "A"
      },
      {
        "editorMode": "code",
        "expr": "(sum(rate(harness_monitor_cache_misses_total[5m])) / clamp_min(sum(rate(harness_monitor_cache_hits_total[5m])) + sum(rate(harness_monitor_cache_misses_total[5m])), 0.000001)) * 100",
        "legendFormat": "cache miss %",
        "refId": "B"
      },
      {
        "editorMode": "code",
        "expr": "histogram_quantile(0.95, sum by (le) (rate(harness_monitor_cache_read_duration_ms_bucket[5m])))",
        "legendFormat": "cache read p95",
        "refId": "C"
      }
    ]
  }
]
```

- [ ] **Step 4: Validate the JSON and confirm there are no remaining `gridPos.w: 4` stats**

Run:

```bash
jq empty resources/observability/grafana/dashboards/monitor-client.json
rg -n '"w": 4' resources/observability/grafana/dashboards/monitor-client.json
```

Expected:

- `jq empty ...` exits `0`
- `rg -n '"w": 4' ...` prints nothing

- [ ] **Step 5: Commit the monitor dashboard refocus**

Run:

```bash
git add resources/observability/grafana/dashboards/monitor-client.json
git commit -m "feat(observability): refocus monitor dashboard"
```

### Task 5: Refocus storage and service flow, remove the old overview, update docs and starring, then validate the live suite

**Files:**
- Modify: `resources/observability/grafana/dashboards/sqlite-forensics.json`
- Modify: `resources/observability/grafana/dashboards/service-map.json`
- Delete: `resources/observability/grafana/dashboards/system-overview.json`
- Modify: `resources/observability/grafana/init-star-dashboards.sh`
- Modify: `resources/observability/README.md`
- Create: `tmp/reports/2026-04-18-grafana-forensics-suite-validation.md`
- Test: `resources/observability/grafana/dashboards/sqlite-forensics.json`
- Test: `resources/observability/grafana/dashboards/service-map.json`

- [ ] **Step 1: Retitle the remaining drilldowns and replace the old overview links**

In `resources/observability/grafana/dashboards/sqlite-forensics.json`, set:

```json
{
  "title": "Harness Storage & SQLite",
  "links": [
    {
      "title": "Investigation Cockpit",
      "type": "link",
      "url": "/d/harness-investigation-cockpit",
      "keepTime": true,
      "includeVars": false,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    },
    {
      "title": "Host Machine",
      "type": "link",
      "url": "/d/harness-host-machine",
      "keepTime": true,
      "includeVars": false,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    },
    {
      "title": "Runtime & Hooks",
      "type": "link",
      "url": "/d/harness-runtime-execution",
      "keepTime": true,
      "includeVars": true,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    },
    {
      "title": "Daemon Transport",
      "type": "link",
      "url": "/d/harness-daemon-transport",
      "keepTime": true,
      "includeVars": true,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    },
    {
      "title": "Monitor Client",
      "type": "link",
      "url": "/d/harness-monitor-client",
      "keepTime": true,
      "includeVars": true,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    },
    {
      "title": "Service Flow",
      "type": "link",
      "url": "/d/harness-service-map",
      "keepTime": true,
      "includeVars": true,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    }
  ]
}
```

In `resources/observability/grafana/dashboards/service-map.json`, set:

```json
{
  "title": "Harness Service Flow",
  "links": [
    {
      "title": "Investigation Cockpit",
      "type": "link",
      "url": "/d/harness-investigation-cockpit",
      "keepTime": true,
      "includeVars": true,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    },
    {
      "title": "Tempo Explore Service Graph",
      "type": "link",
      "url": "/explore?schemaVersion=1&panes=%7B%22A%22%3A%7B%22datasource%22%3A%22tempo%22%2C%22queries%22%3A%5B%7B%22refId%22%3A%22A%22%2C%22datasource%22%3A%7B%22uid%22%3A%22tempo%22%2C%22type%22%3A%22tempo%22%7D%2C%22queryType%22%3A%22serviceMap%22%2C%22filters%22%3A%5B%5D%7D%5D%2C%22range%22%3A%7B%22from%22%3A%22now-30m%22%2C%22to%22%3A%22now%22%7D%7D%7D",
      "keepTime": false,
      "includeVars": false,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    },
    {
      "title": "Traces Breakdown",
      "type": "link",
      "url": "/a/grafana-exploretraces-app/explore?from=now-30m&to=now&timezone=browser&var-ds=tempo&var-primarySignal=nestedSetParent%3C0&var-filters=&var-metric=rate&var-groupBy=resource.service.name&var-spanListColumns=&var-latencyThreshold=&var-partialLatencyThreshold=&var-durationPercentiles=0.9&actionView=breakdown",
      "keepTime": false,
      "includeVars": false,
      "targetBlank": false,
      "asDropdown": false,
      "icon": "external link",
      "tags": []
    }
  ]
}
```

- [ ] **Step 2: Remove the old overview file and update the starred order**

Delete `resources/observability/grafana/dashboards/system-overview.json`.

Then replace the `DASHBOARDS=` line in `resources/observability/grafana/init-star-dashboards.sh` with:

```sh
DASHBOARDS="harness-investigation-cockpit harness-host-machine harness-daemon-transport harness-monitor-client harness-runtime-execution harness-sqlite-forensics harness-service-map"
```

- [ ] **Step 3: Replace the README dashboard guidance with the repo-managed suite roster**

In `resources/observability/README.md`, replace the current “Import these dashboards for visualization” subsection with:

```md
### Grafana dashboards

The local stack now provisions a repo-managed forensic suite into the `Harness Observability` folder:

- `Harness Investigation Cockpit` - the landing page for short-window local slowdowns
- `Harness Host Machine` - CPU, memory, swap, disk, filesystem, WiFi, battery, and thermal drilldown
- `Harness Runtime & Hooks` - CLI and hook execution bottlenecks
- `Harness Daemon Transport` - HTTP and WS transport bottlenecks
- `Harness Monitor Client` - monitor memory, websocket, cache, and client API pressure
- `Harness Storage & SQLite` - storage and SQLite forensic analysis
- `Harness Service Flow` - service-edge metrics plus Tempo Explore pivots

Use Tempo Explore's Service Graph for the authoritative topology view and use the suite dashboards for metric correlation, ranked offenders, and log or trace pivots.
```

- [ ] **Step 4: Validate the live suite and capture the proof artifact**

Run:

```bash
jq empty resources/observability/grafana/dashboards/*.json
./scripts/observability.sh reset
curl -sf -u admin:harness 'http://127.0.0.1:3000/api/search?query=Harness' | jq -r '.[].uid'
curl -sf -u admin:harness 'http://127.0.0.1:3000/api/dashboards/uid/harness-investigation-cockpit' | jq -r '.dashboard.title'
curl -sf -u admin:harness 'http://127.0.0.1:3000/api/dashboards/uid/harness-host-machine' | jq -r '.dashboard.title'
curl -sf 'http://127.0.0.1:9090/api/v1/query?query=up{job=~"darwin-exporter|integrations/unix"}' | jq -r '.data.result[] | "\(.metric.job)=\(.value[1])"'
mkdir -p tmp/reports
cat > tmp/reports/2026-04-18-grafana-forensics-suite-validation.md <<'EOF'
# Grafana Forensics Suite Validation

- Dashboard JSON syntax validated with `jq empty resources/observability/grafana/dashboards/*.json`.
- Local observability stack reset with `./scripts/observability.sh reset`.
- Grafana search confirmed the presence of:
  - `harness-investigation-cockpit`
  - `harness-host-machine`
  - `harness-daemon-transport`
  - `harness-monitor-client`
  - `harness-runtime-execution`
  - `harness-sqlite-forensics`
  - `harness-service-map`
- Dashboard UID checks confirmed:
  - `harness-investigation-cockpit` => `Harness Investigation Cockpit`
  - `harness-host-machine` => `Harness Host Machine`
- Prometheus target proof confirmed:
  - `integrations/unix=1`
  - `darwin-exporter=1`
EOF
```

Expected:

- `jq empty resources/observability/grafana/dashboards/*.json` exits `0`
- Grafana search returns the seven UIDs listed above
- the two dashboard UID lookups print `Harness Investigation Cockpit` and `Harness Host Machine`
- the Prometheus query prints `integrations/unix=1` and `darwin-exporter=1`

- [ ] **Step 5: Commit the suite completion**

Run:

```bash
git add \
  resources/observability/grafana/dashboards/host-machine.json \
  resources/observability/grafana/dashboards/investigation-cockpit.json \
  resources/observability/grafana/dashboards/runtime-execution.json \
  resources/observability/grafana/dashboards/daemon-transport.json \
  resources/observability/grafana/dashboards/monitor-client.json \
  resources/observability/grafana/dashboards/sqlite-forensics.json \
  resources/observability/grafana/dashboards/service-map.json \
  resources/observability/grafana/init-star-dashboards.sh \
  resources/observability/README.md \
  Cargo.toml \
  testkit/Cargo.toml \
  Cargo.lock \
  apps/harness-monitor-macos/project.yml \
  apps/harness-monitor-macos/HarnessMonitor.xcodeproj/project.pbxproj \
  apps/harness-monitor-macos/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist
git rm resources/observability/grafana/dashboards/system-overview.json
git commit -m "feat(observability): ship grafana forensics suite"
```

## Self-review checklist

- **Spec coverage:** Task 1 creates the cockpit and version bump. Task 2 creates the host board. Tasks 3 and 4 refocus runtime, daemon, and monitor. Task 5 refocuses storage and service flow, removes the overview, updates starring and docs, and validates the live stack.
- **Placeholder scan:** no `TODO`, `TBD`, or “similar to Task N” shortcuts are allowed during execution. If a panel title, query, or link differs from this plan, update the plan first.
- **Type consistency:** use the exact dashboard UIDs from the approved spec: `harness-investigation-cockpit`, `harness-host-machine`, `harness-runtime-execution`, `harness-daemon-transport`, `harness-monitor-client`, `harness-sqlite-forensics`, `harness-service-map`.
