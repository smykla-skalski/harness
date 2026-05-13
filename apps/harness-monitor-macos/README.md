# Harness Monitor macOS App

Native SwiftUI control deck for live harness daemon sessions. The Xcode project is generated from the Tuist manifests under `Project.swift` and `Tuist/`. The generated `HarnessMonitor.xcodeproj` and `HarnessMonitor.xcworkspace` are not tracked - run `mise run monitor:generate` to materialize them.

## Prerequisites

- Xcode with `xcodebuild`
- `tuist` (pinned via mise)
- `swiftlint`

## Workflows

From the repo root:

```bash
mise run monitor
mise run version:check
mise run monitor:build
mise run monitor:build:release
mise run monitor:release:external
mise run monitor:generate
mise run monitor:lint
mise run monitor:quality-gate
mise run monitor:test
mise run monitor:audit -- --label baseline
mise run monitor:test:scripts
```

For parallel development, each user/agent/session must use a separate full git worktree for Monitor edits, Tuist generation, builds/tests, daemon/bridge work, and XcodeBuildMCP. Lanes are still useful, but they only isolate build/runtime side effects inside a worktree; they do not replace a separate checkout.

Focused task entrypoints (run `mise run monitor:generate` first if the workspace is not materialized):

```bash
mise run monitor:xcodebuild -- -workspace apps/harness-monitor-macos/HarnessMonitor.xcworkspace ...
mise run monitor:audit -- --label after-fix --compare-to tmp/perf/harness-monitor-instruments/runs/<baseline-dir>
mise run monitor:audit:from-ref -- --ref <sha-or-ref> --label baseline
mise run monitor:audit -- --label regression --debug-retention
```

Audit runs now persist per-capture `launch_metrics` in the manifest/summary,
surface `launch_app_init_to_ready_ms` in `summary.csv`, and render comparison
markdown with separate hard-budget and investigative metric sections.

The audit artifact contract is:

| Artifact | Guaranteed fields / purpose |
| --- | --- |
| `manifest.json` | run provenance for the staged build, including `git`, `system`, `targets`, `build_provenance`, selected scenarios, default launch env, per-capture `preview_scenario`, `launched_process_path`, and `daemon_data_home_probe` |
| `summary.json` | `manifest.json` plus per-capture extracted `metrics`, `warnings`, `launch_metrics`, and `metric_tiers` |
| `summary.csv` | flat regression sheet with launch, SwiftUI, hitch/hang, and allocation summary columns |
| `comparison.json` / `comparison.md` | baseline/current diff, missing-capture reporting, missing-metric reporting, and hard-vs-investigative metric grouping |
| `debug-retention.json` | explicit sentinel that a regression/debug run preserved raw traces, exported XML, and extraction intermediates |

For provenance checks, treat `targets.staged_host_bundle_id`,
`targets.staged_host_binary_path`, `build_provenance.host`,
`build_provenance.shipping`, capture-level `launched_process_path`, and
capture-level `daemon_data_home_probe` as the minimum trust surface before using
the numbers in a regression review.

Field telemetry should use the same vocabulary as the local audit:

| Local audit signal | Field telemetry source |
| --- | --- |
| `launch_app_init_to_ready_ms` | MetricKit app launch metrics and Organizer launch summaries |
| `hitches` / frame pacing regressions | MetricKit animation hitch metrics and Organizer hang/hitch views |
| `potential_hangs` | MetricKit hang diagnostics plus Organizer hang-rate rollups |
| allocation growth in `summary.csv` / `comparison.json` | Organizer memory footprint trends and MetricKit memory diagnostics |
| scenario-specific regressions confirmed locally | App Store Connect Performance API or Organizer release-over-release comparisons |

When you only need part of the graph, use the manifest tags for focused generation, for example:

```bash
tuist generate tag:feature:monitor
tuist generate tag:feature:previews
tuist generate tag:feature:ui-testing
```

Native Xcode local compilation cache is enabled directly through the generated build settings with `COMPILATION_CACHE_ENABLE_CACHING=YES`. This gives the app local Xcode 26 compilation-cache reuse without requiring Tuist Cloud login or a remote cache service. The remote-plugin settings (`COMPILATION_CACHE_ENABLE_PLUGIN` / `COMPILATION_CACHE_REMOTE_SERVICE_PATH`) are intentionally not configured here.

When you need a raw local build command, prefer the lane-aware wrapper so concurrent monitor lanes do not corrupt or lock the same build database:

```bash
mise run monitor:build
mise run monitor:build:release
```

To build and immediately open the resulting app bundle from the resolved build lane, use:

```bash
mise run monitor
mise run monitor:release:external
```

`monitor:release:external` regenerates the project, builds the signed Release
bundle, persists `HarnessMonitor.DaemonOwnership=external`, and opens the built
app with `open -na` so the exact Release bundle launches even if another
Harness Monitor instance is already running.

The wrapper and repo scripts resolve `xcode-derived` at the git common root, so linked worktrees reuse one default CLI DerivedData tree instead of bloating each checkout. For an isolated CLI build/test lane, set `HARNESS_MONITOR_BUILD_LANE=<name>`; that moves the build root to `xcode-derived-lanes/<slug>` and gives the lane its own wrapper lock.

Runtime state is separate. `mise run monitor:runtime` prints the current daemon data home, Codex port, launch-agent label, and XcodeBuildMCP socket. Set `HARNESS_MONITOR_RUNTIME_LANE=<name>` for an isolated daemon/bridge/MCP lane; otherwise the scripts derive a stable per-checkout runtime lane. Runtime lanes write under `~/Library/Group Containers/Q498EB36N4.io.harnessmonitor/runtime-lanes/<slug>`.

Legacy profile env vars such as `HARNESS_MONITOR_RUNTIME_PROFILE` are rejected. Use `HARNESS_MONITOR_BUILD_LANE` for DerivedData isolation and `HARNESS_MONITOR_RUNTIME_LANE` for daemon/bridge isolation.

General monitor build/test lanes keep using the shared `xcode-derived` root unless `HARNESS_MONITOR_BUILD_LANE` is set. The swarm full-flow and agents e2e/UI lanes intentionally use the shared `xcode-derived-e2e` root so they do not contend with normal monitor builds.

Generated Xcode projects stay under `apps/harness-monitor-macos`; only build-output roots are marked for Spotlight exclusion. `Scripts/post-generate.sh` and the lane-aware xcodebuild wrapper create `.metadata_never_index` inside `xcode-derived`, `xcode-derived-lanes/*`, `xcode-derived-e2e`, and `xcode-derived-instruments` without moving source or generated project metadata into a hidden mirror directory. For the strongest Apple-supported exclusion, add those ignored build roots to Spotlight Privacy in System Settings.

`monitor:lint` is the fast non-build lane. It generate-checks the workspace, runs strict `swift format` over Sources and Tests, and runs `swiftlint lint` with a cache rooted in the shared `tmp/swiftlint-cache/harness-monitor-macos`. It never invokes `xcodebuild`, daemon pre-actions, or daemon bundle validation.

`monitor:quality-gate` is the slower build-based validation lane. It runs `build-for-testing` against `xcode-derived` (or `xcode-derived-lanes/<slug>` when `HARNESS_MONITOR_BUILD_LANE` is set) with daemon embedding enabled, scans sandbox logs, and verifies the checked-in app/daemon entitlements expected by the built product.

`monitor:test` performs `build-for-testing` with daemon embedding disabled by default, then executes:

```bash
mise run monitor:xcodebuild -- \
  -workspace apps/harness-monitor-macos/HarnessMonitor.xcworkspace \
  -scheme HarnessMonitor \
  -destination "platform=macOS,arch=$(uname -m),name=My Mac" \
  -derivedDataPath xcode-derived \
  CODE_SIGNING_ALLOWED=NO \
  test-without-building
```

For routine work, prefer the smallest targeted command instead of the full `monitor:test` lane. Stay on the `mise` path and pass the selector through `XCODE_ONLY_TESTING`, for example:

```bash
XCODE_ONLY_TESTING=HarnessMonitorKitTests/PolicyGapRuleTests mise run monitor:test
```

For a fully isolated local CLI/dev-daemon lane, set build and runtime lanes explicitly:

```bash
HARNESS_MONITOR_BUILD_LANE=bart-dev mise run monitor:build
HARNESS_MONITOR_RUNTIME_LANE=bart-dev mise run monitor:daemon:dev
```

Use the same runtime-lane env prefix when starting an external daemon, manual bridge, or XcodeBuildMCP from another terminal. `mise run clean:stale` is the safe shared scrub: it removes orphan/temp pollution but does not quit a live Harness Monitor session or stop live daemon work. When you want a full reset of the current runtime lane, use:

```bash
mise run monitor:reset
```

If you explicitly want the broader destructive shared reset, use `mise run clean:stale:full`.

Production builds support both managed and external daemon ownership. The app
defaults to managed mode; switch future launches to external mode in
**Settings > General > Startup daemon mode**, or set
`HARNESS_MONITOR_EXTERNAL_DAEMON=1` before launch. For sandboxed production
external mode, prefer `HARNESS_MONITOR_RUNTIME_LANE`,
`HARNESS_DAEMON_DATA_HOME`, or a daemon started through `mise run monitor:daemon:dev`
so the manifest stays inside the shared app-group runtime roots.

Common runtime-lane commands:

```bash
mise run monitor:runtime
mise run monitor:daemon:dev
mise run monitor:bridge:start
mise run monitor:xcodebuildmcp -- macos build --scheme HarnessMonitor
mise run monitor:mcp
```

When agents need to use local Xcode wrappers or XcodeBuildMCP, give each session its own full git worktree and its own build/runtime lane:

```bash
HARNESS_MONITOR_BUILD_LANE=agent-<session> XCODE_ONLY_TESTING=HarnessMonitorKitTests/PolicyGapRuleTests mise run monitor:test
HARNESS_MONITOR_RUNTIME_LANE=agent-<session> mise run monitor:xcodebuildmcp -- macos build --scheme HarnessMonitor
```

Do not reuse broad names like `claude-main`; use a stable session-derived slug.

`XCODE_ONLY_TESTING` also accepts a comma-separated list when you need more than one focused selector. Class-level selectors are expanded through Xcode test enumeration before execution so the lane fails instead of reporting a misleading zero-test pass when Xcode does not run class selectors directly. `HarnessMonitorUITests` run against the isolated `Harness Monitor UI Testing` host (`io.harnessmonitor.app.ui-testing`) and launch with `-ApplePersistenceIgnoreState YES`, so targeted UI checks do not interfere with a manually running `Harness Monitor.app`.

Versioning for the monitor app is derived from the repo root `Cargo.toml`. Use `mise run version:set -- <version>` from the repo root when you bump a release. `mise run monitor:generate` regenerates the Xcode project via Tuist, then `Scripts/post-generate.sh` resyncs the marker-anchored version literals in `Tuist/ProjectDescriptionHelpers/BuildSettings.swift` (the `// VERSION_MARKER_CURRENT` and `// VERSION_MARKER_MARKETING` lines), the repo-root and app-local `buildServer.json` SourceKit configs, and the bundled daemon helper Info.plist from that canonical version. Those tracked `buildServer.json` files intentionally stay pinned to the shared `xcode-derived` root; lane-specific DerivedData belongs in workspace settings and explicit CLI env, not in checked-in files.

Do not pass `CODE_SIGNING_ALLOWED=NO` to `HarnessMonitorUITests`. macOS UI tests need Xcode to re-sign the generated `HarnessMonitorUITests-Runner.app`; otherwise Gatekeeper can reject the copied `com.apple.XCTRunner` runner before the test bundle bootstraps.

Example targeted UI regression:

```bash
XCODE_ONLY_TESTING=HarnessMonitorUITests/HarnessMonitorUITests/testToolbarOpensSettingsWindow mise run monitor:test
```

The generated project intentionally keeps SwiftLint out of the Xcode build graph so SwiftUI previews and routine local builds stay responsive. The fast lint lane owns `swift format` + `swiftlint`; the slower `monitor:quality-gate` task owns build-based validation and daemon checks.

For SwiftUI canvas previews, open `HarnessMonitor.xcodeproj` and select the shared `HarnessMonitorUIPreviews` scheme. It uses the `Preview` configuration, builds only the UI framework graph, and avoids launching the full `Harness Monitor.app` as the preview host.

Regenerate the project after target or configuration changes:

```bash
mise run monitor:generate
```
