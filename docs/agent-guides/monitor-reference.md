# Harness Monitor Agent Reference

Load this file only when `apps/harness-monitor-macos/AGENTS.md` routes the
current task here. The app `AGENTS.md` contains the mandatory contract; this
file keeps the longer macOS reference material out of the default prompt path.

## Generation details

`mise run monitor:generate` runs `Scripts/generate.sh`, which installs Tuist
dependencies when needed, generates the project, then runs
`Scripts/post-generate.sh` for `buildServer.json` and version sync.

The manifest tags targets for focused generation, so partial graphs can use
selectors such as `tuist generate tag:feature:monitor`,
`tuist generate tag:feature:previews`, or
`tuist generate tag:feature:ui-testing`.

Native Xcode local compilation cache is enabled through generated build settings
with `COMPILATION_CACHE_ENABLE_CACHING=YES`. Remote-plugin settings are
intentionally unset so normal Tuist generation and builds stay auth-free.

## Lane details

Xcode's default `~/Library/Developer/Xcode/DerivedData/HarnessMonitor-*` is the
Xcode UI private index/cache and holds fetched SPM `SourcePackages/`. CLI
workflows pass `-derivedDataPath` explicitly and do not touch it. Regeneration
and `mise run clean:stale` leave that cache intact.

The `monitor:xcodebuild` wrapper resolves approved logical paths at the git
common root, so linked worktrees share one default CLI DerivedData tree unless a
lane is set. Set `HARNESS_MONITOR_BUILD_LANE=<name>` for an isolated lock/build
database under `xcode-derived-lanes/<name>`.

Runtime state is separate from build state. Set
`HARNESS_MONITOR_RUNTIME_LANE=<name>` for isolated daemon/bridge/MCP state.
Runtime lanes write daemon data under the app-group `runtime-lanes/<lane>`,
derive a Codex bridge port, and use a lane-specific launch-agent label.

Legacy `HARNESS_MONITOR_RUNTIME_PROFILE`,
`HARNESS_MONITOR_USER_RUNTIME_PROFILE`, and agent-profile env vars are rejected.

## UI test interaction contract

Targeted `HarnessMonitorUITests` runs must use the isolated
`Harness Monitor UI Testing` host (`io.harnessmonitor.app.ui-testing`).

If a control is visually correct but a UI test cannot find or tap it, fix the
test query or interaction path before changing product layout, copy, or
semantics. Do not introduce UI changes only to satisfy a flaky lookup unless the
product has a real visual or accessibility bug.

Reuse the existing UI-test helpers. New preflight/wait helpers for action
controls must mirror `HarnessMonitorUITestInteractionSupport.tapButton(...)`:
search button-role queries first, then the generic identified element, then the
`identifier.frame` marker via `element(in:app,identifier:)`. Do not use
`frameElement(...)` for that path; it is narrower and can miss real markers.

Do not put `.accessibilityIdentifier(...)` on a container that wraps interactive
children with their own IDs or `.accessibilityFrameMarker(...)` probes. In the
macOS accessibility tree, the container identifier can clobber the nested
button/marker contract. Use `.accessibilityTestProbe(...)` for container-level
probes and keep child control identifiers on the controls.

Prefer existing container-aware patterns before inventing gestures:
`window(in:app,containing:)`, `descendantElement(...)`,
`descendantFrameElement(...)`, and the visible-frame click flow from
`SettingsUITests+AcpPermissionLogReveal.swift`.

## Build scripts and lint

`Scripts/test-swift.sh` skips `build-for-testing` when the existing `.xctestrun`
is fresher than every Swift source, project descriptor, SPM lockfile, and the
cross-project `mcp-servers/` tree. Break-glass:
`HARNESS_MONITOR_FORCE_BUILD_FOR_TESTING=1`.

SwiftLint runs externally through `mise run monitor:lint` and CI, not as an
Xcode build plugin or part of `monitor:test`. The lint lane checks generation,
runs `swift format`, and runs SwiftLint without invoking daemon bundle logic.
Config lives in `.swiftlint.yml`.

`mise run monitor:quality-gate` owns build-based sandbox and daemon
validation.

## Performance measurement

Layer 1 is the XCTest performance test suite in
`Tests/HarnessMonitorUITests/HarnessMonitorPerfTests.swift`:

- `XCTHitchMetric(application:)`.
- `XCTOSSignpostMetric(subsystem: "io.harnessmonitor", category: "perf", name:)`.
- `XCTApplicationLaunchMetric(waitUntilResponsive:)`.
- `XCTMemoryMetric(application:)` for backdrop/background/offline scenarios.

Audit-backed scenarios live in `HarnessMonitorPerfScenario` plus
`Tools/HarnessMonitorPerf/.../ScenarioCatalog.swift`. The
`settings-database-scroll` hitch test is intentionally UI-test-only until the
app-side perf driver can script that settings-window scroll path without
runtime event injection.

The perf driver in `HarnessMonitorAppSceneSupport.swift` uses
`OSSignposter.beginAnimationInterval` / `endInterval` to mark scenario
boundaries.

Targeted run:

```bash
XCODE_ONLY_TESTING=HarnessMonitorUITests/HarnessMonitorPerfTests/testOpenRecentWindowHitchRate \
  mise run monitor:test
```

Layer 2 is the Instruments `xctrace` pipeline:

```bash
mise run monitor:audit -- --label baseline
mise run monitor:audit -- --label after-fix --compare-to tmp/perf/harness-monitor-instruments/runs/<baseline-dir>
mise run monitor:audit -- --label regression --debug-retention
mise run monitor:test:scripts
mise run monitor:tools:test:perf
```

Run both validation suites together with `mise run monitor:audit:validation`
(fail-fast, prints a summary line at the end).

Artifacts land in `tmp/perf/harness-monitor-instruments/runs/` with
`manifest.json`, `summary.json`, `summary.csv`, per-scenario metrics, and
optional comparison reports. The summary model now carries per-capture
`launch_metrics`, `summary.csv` includes `launch_app_init_to_ready_ms`, and
comparison markdown separates hard-budget metrics from investigative metrics.

Treat those files as a stable contract:

| Artifact | Guaranteed fields / purpose |
| --- | --- |
| `manifest.json` | run provenance for the staged build: `git`, `system`, `targets`, `build_provenance`, selected scenarios, default launch env, and per-capture `preview_scenario`, `launched_process_path`, `daemon_data_home_probe`, `app_trace_relpath` |
| `summary.json` | `manifest.json` plus extracted per-capture `metrics`, `warnings`, `launch_metrics`, `metric_tiers`, parsed `app_trace`, and normalized `findings` |
| `summary.csv` | flat regression sheet for launch, SwiftUI, hitch/hang, and allocation metrics |
| `comparison.json` / `comparison.md` | baseline/current diff with missing-capture, missing-metric, hard-vs-investigative sections, findings deltas, and an app-trace pair/diff section |
| `debug-retention.json` | sentinel proving the run intentionally retained raw traces, exported XML, and extraction intermediates |

Machine-readable schema snapshots for the JSON outputs live under
`apps/harness-monitor-macos/Tools/HarnessMonitorPerf/Schemas/`.
Regenerate them with `mise run monitor:tools:generate:schemas`.

Before trusting a regression result, verify at least:

- `targets.staged_host_bundle_id`
- `targets.staged_host_binary_path`
- `build_provenance.host`
- `build_provenance.shipping`
- capture `launched_process_path`
- capture `daemon_data_home_probe`

For release validation, align local and field telemetry with the same labels:

| Local audit signal | Field telemetry source |
| --- | --- |
| `launch_app_init_to_ready_ms` | MetricKit launch metrics and Organizer launch summaries |
| `hitches` / frame pacing | MetricKit animation hitch metrics and Organizer hitch dashboards |
| `potential_hangs` | MetricKit hang diagnostics and Organizer hang-rate summaries |
| allocation growth in audit outputs | Organizer memory trends and MetricKit memory diagnostics |
| scenario-specific regressions | App Store Connect Performance API / Organizer release-over-release comparisons |

Normalize those sources into audit-vocabulary outputs with:

```bash
mise run monitor:tools:field-telemetry -- --input <field-telemetry-input.json> --output-dir <dir>
```

## SwiftUI rules and research

Rule content lives in skills under `.claude/skills/`, loaded on demand:

- `swiftui-design-rules` - accessibility, visual design, interaction patterns,
  and performance targets.
- `swiftui-api-patterns` - state wrappers, view composition, identity, layout,
  navigation, windows, commands, and control styles.
- `swiftui-performance-macos` - view-body allocation rules, cached formatters,
  animation constraints, geometry feedback loops, signposter contracts, and
  isolated worktree requirements for audits.
- `swiftui-platform-rules` - macOS conventions, iOS conventions, and XCUITest
  reliability patterns.

Research backing lives under `apps/harness-monitor-macos/docs/research/`:

- `docs/research/ux/` - HIG principles, interaction patterns, visual design,
  accessibility, SwiftUI practices, psychology, performance, error handling,
  data display, and onboarding.
- `docs/research/xcuitest-speed.md` - XCUITest reliability and timing research.

## Liquid Glass notes

NavigationSplitView sidebar gets automatic Liquid Glass treatment. Use
one stable `.backgroundExtensionEffect()` host per session surface so detail
content extends behind glass without stacking duplicated effects on individual
content/detail panes. Keep session scroll-edge treatment soft. Do not paint
opaque sidebar backgrounds; use translucent tints so system glass shows through.

Use `.glassEffect(.regular.tint(color), in: shape)` for floating controls. Tint
takes `Color`, not `LinearGradient`. Never stack glass on glass. Glass belongs
on navigation/control layers, not content. SwiftUI materials blur behind the
window, not sibling views. `GlassEffectContainer` groups glass elements with
shared sampling; `spacing` controls morph threshold.

## Session pane dividers

Use native SwiftUI split containers for resizable session panes. The outer
session shell owns navigation with `NavigationSplitView`; nested content/detail
and inspector panes should use `HSplitView` so SwiftUI owns divider hit testing,
cursor behavior, accessibility, and layout invalidation. Avoid custom
`DragGesture` dividers, manual `NSCursor.push/pop`, and live per-drag width
bindings unless a profiled platform gap proves they are necessary.

## Daemon modes

Harness Monitor has two daemon ownership modes, and both are supported in
production builds.

External daemon is the fastest local workflow and remains available in shipping
builds. Launch the app under `HarnessMonitor (External Daemon)` and run:

```bash
mise run monitor:daemon:dev
```

The dev daemon runs unsandboxed, writes its manifest into the
`Q498EB36N4.io.harnessmonitor` app group container, and spawns Codex as its own
stdio child. No host bridge is required unless you explicitly test the
WebSocket path. For an isolated runtime lane, prefix daemon and bridge commands with
`HARNESS_MONITOR_RUNTIME_LANE=<name>`. For isolated CLI builds/tests, use
`HARNESS_MONITOR_BUILD_LANE=<name>`.

Debug the dev daemon with `lldb -- harness daemon dev` or
`cargo run --bin harness -- daemon dev`. The scheme sets
`HARNESS_MONITOR_EXTERNAL_DAEMON=1` and a 60s warm-up timeout. Starting the app
before the daemon also works; the manifest watcher reconnects on first manifest
write. Production builds can also switch future launches to external mode in
**Settings > General > Startup daemon mode**, or by setting
`HARNESS_MONITOR_EXTERNAL_DAEMON=1` before launch.

If a `harness bridge start` process is already running for the same runtime
lane, stop it before using dev mode unless you are intentionally testing the
WebSocket bridge path. In sandboxed production builds, keep external daemons in
an app-group-accessible runtime root by using `HARNESS_MONITOR_RUNTIME_LANE`,
`HARNESS_DAEMON_DATA_HOME`, or the `monitor:daemon:dev` wrapper so manifest
discovery stays on the shared container roots.

Managed daemon is the default release/distribution path. Use the default
`HarnessMonitor` scheme. The daemon runs under the macOS App Sandbox through
`SMAppService`, and the launch agent plist sets `HARNESS_SANDBOXED=1` and
`HARNESS_APP_GROUP_ID=Q498EB36N4.io.harnessmonitor`. With
`HARNESS_MONITOR_RUNTIME_LANE=<name>` set during the build, the bundled launch
agent gets a lane-specific label plus matching daemon data home and Codex bridge
port env.

Codex threads inside Agents use WebSocket transport when sandboxed. The daemon
connects to a Codex capability published by the unified host bridge. Users start
the bridge with `harness bridge start` or install it as a login item with
`harness bridge install-launch-agent`. The bridge publishes capability state in
the daemon manifest; the Monitor app and daemon use that state to reconfigure
and surface recovery hints.

When no Codex bridge is running in managed mode,
`POST /v1/sessions/{id}/managed-agents/codex` returns 503 with
`{"error": "codex-unavailable"}`. The Swift store sets `codexUnavailable = true`
and the workspace window shows a recovery banner. Minimum Codex version for
WebSocket transport: `rust-v0.102.0+`.

## Preview authoring detail

All `#Preview` blocks live in `HarnessMonitorUIPreviewable`. Previews render
through the dedicated `HarnessMonitorPreviewHost` app target via the
`HarnessMonitorUIPreviews` scheme. The host links only `HarnessMonitorKit` and
`HarnessMonitorUIPreviewable`; it has no daemon signaling or main-app
dependencies.

Previewable views must not take closure properties such as
`let onTap: () -> Void`. Use `HarnessAsyncActionButton.StoreAction` or
`@Environment(\.openWindow)` for actions.

Every `#Preview` that exercises `@Query` or other SwiftData-backed views must
inject `.modelContainer(PreviewFixtures.previewContainer())` or an equivalent
fixture container. Do not allocate `DateFormatter`, `JSONEncoder`, or
`NumberFormatter` in view bodies; use static `@MainActor` lets.

Never wrap `#Preview` in `#if DEBUG`. Add canonical screens to `Previews.json`
when adding a new top-level surface. If a `#Preview` crashes with
`TableViewListCore_Mac2.swift:5170`, mark it with a TODO referencing the macOS
26 SwiftUI bug and comment out the offending preview.

## Swift 6 deinit trap

Never wrap `deinit` cleanup in `MainActor.assumeIsolated { ... }` on a
`@MainActor` class, `NSView`, or `NSObject` subclass that is MainActor in the SDK
overlay under Swift 6 strict concurrency on macOS 26.

ARC can drop the last reference on `com.apple.SwiftUI.DisplayLink`, notably
during dashboard/cockpit transitions or SwiftUI view-tree rebuilds. In that
context, `assumeIsolated` traps with:

```text
BUG IN CLIENT OF LIBDISPATCH: Block was expected to execute on queue [com.apple.main-thread]
```

Confirmed crash sites included `KeyWindowObserver.deinit`,
`WindowCommandScopeTrackingNSView.deinit`, and `HarnessMonitorStore.deinit`.

Required pattern: mark storage `nonisolated(unsafe) var` so nonisolated `deinit`
can read it without non-Sendable errors, inline only thread-safe cleanup
(`NotificationCenter.removeObserver(_)` and `IOPMAssertionRelease` are
documented thread-safe), treat `NSEvent.removeMonitor` as MainActor-only, and
move MainActor-only cleanup into `NSViewRepresentable.dismantleNSView`, which
SwiftUI guarantees runs on the MainActor when removed. Do not use isolated
`deinit`; that feature is not enabled in this project.
