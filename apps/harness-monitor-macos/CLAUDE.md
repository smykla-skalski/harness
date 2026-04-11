# CLAUDE.md

This file provides guidance to Claude Code when working in the Harness Monitor macOS app. The repo-root `CLAUDE.md` covers the Rust harness CLI and everything outside this directory.

## Build and test

The Xcode project is generated from `project.yml` via XcodeGen. If you add, remove, or rename Swift files, update `project.yml` and regenerate with `Scripts/generate-project.sh`. Treat the generated `HarnessMonitor.xcodeproj` as tracked source.

Validation expectations (run from repo root):

- `xcodebuild -project 'apps/harness-monitor-macos/HarnessMonitor.xcodeproj' -scheme "HarnessMonitor" -configuration Debug -destination 'platform=macOS' -derivedDataPath tmp/xcode-derived -skipPackagePluginValidation build`
- `xcodebuild -project 'apps/harness-monitor-macos/HarnessMonitor.xcodeproj' -scheme "HarnessMonitor" -configuration Debug -destination 'platform=macOS' -derivedDataPath tmp/xcode-derived -skipPackagePluginValidation test -skip-testing:HarnessMonitorUITests`
- All xcodebuild invocations must use one of two approved `-derivedDataPath` values:
  - `tmp/xcode-derived` for quality gates, tests, and general dev builds
  - `tmp/perf/harness-monitor-instruments/xcode-derived` for the instruments audit pipeline (isolated so the provenance fingerprint match is not contaminated by quality-gate builds)

  Xcode's default `~/Library/Developer/Xcode/DerivedData/HarnessMonitor-*` is Xcode UI's private index/cache and holds its fetched SPM `SourcePackages/`. CLI workflows do not read or write it (they always pass `-derivedDataPath` explicitly), so it is not flagged by `mise run check:stale` and no harness script touches it - regens and `mise run clean:stale` leave it intact so Xcode never loses its package cache.
- Hard requirement: do not run the full macOS UI suite by default. Run only the smallest targeted build/test command needed for the current change, such as a single XCTest case, a single XCTest class, or a non-UI build lane.
- Only run the full macOS app validation lane or the full `HarnessMonitorUITests` suite after the user explicitly asks for the full suite.
- Targeted `HarnessMonitorUITests` runs must use the isolated `Harness Monitor UI Testing` host (`io.harnessmonitor.app.ui-testing`) instead of the shipping `Harness Monitor.app` bundle so local manual app usage is not interrupted.
- Keep the `-ApplePersistenceIgnoreState YES` UI-test launch argument in place for the isolated host so macOS window restoration does not make targeted UI runs flaky.
- SwiftLint runs externally via `Scripts/run-quality-gates.sh` and CI, not as an Xcode build plugin. This keeps SwiftLint out of the build graph so SwiftUI previews and local builds stay fast. Config lives in `.swiftlint.yml`.
- Prefer shared layout and control primitives for Harness Monitor UI density/readability work so button sizing and glass treatment stay consistent across screens.
- Liquid Glass (macOS 26): NavigationSplitView sidebar gets automatic Liquid Glass treatment. Use `.backgroundExtensionEffect()` on content columns so detail content extends behind the glass sidebar. Don't paint opaque backgrounds on the sidebar - use translucent tints so the system glass shows through. Use `.glassEffect(.regular.tint(color), in: shape)` for floating controls (tint takes `Color`, not `LinearGradient`). Never stack glass on glass. Glass belongs on the navigation/control layer, not on content. SwiftUI materials (`.ultraThinMaterial` etc.) blur behind the window, not sibling views. `GlassEffectContainer` groups glass elements with shared sampling; `spacing` controls morph threshold.

## Performance measurement

Two-layer system for performance regression detection and diagnostic attribution.

**Layer 1: XCTest perf tests** (`Tests/HarnessMonitorUITests/HarnessMonitorPerfTests.swift`) - CI regression gates using native XCTest metrics:

- `XCTHitchMetric(application:)` - direct hitch measurement
- `XCTOSSignpostMetric(subsystem: "io.harnessmonitor", category: "perf", name:)` - scenario-scoped frame data
- `XCTApplicationLaunchMetric(waitUntilResponsive:)` - launch time
- `XCTMemoryMetric(application:)` - memory for backdrop/background/offline scenarios only

The perf driver (`HarnessMonitorPerfDriver` in `HarnessMonitorAppSceneSupport.swift`) uses `OSSignposter.beginAnimationInterval` / `endInterval` to mark scenario boundaries for the signpost metric.

Targeted run (single scenario):

```bash
xcodebuild -project 'apps/harness-monitor-macos/HarnessMonitor.xcodeproj' \
  -scheme 'HarnessMonitor' -destination 'platform=macOS' \
  -derivedDataPath tmp/xcode-derived \
  test -only-testing:HarnessMonitorUITests/HarnessMonitorPerfTests/testLaunchDashboardHitchRate
```

**Layer 2: Instruments xctrace pipeline** (`Scripts/`) - periodic deep-dive attribution for data no public API exposes (SwiftUI body evaluations, update groups, causes, allocation call trees):

```bash
# Full baseline capture
apps/harness-monitor-macos/Scripts/run-instruments-audit.sh --label baseline

# Compare against baseline
apps/harness-monitor-macos/Scripts/run-instruments-audit.sh \
  --label after-fix --compare-to tmp/perf/harness-monitor-instruments/runs/<baseline-dir>

# Parser regression tests
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s apps/harness-monitor-macos/Scripts/tests -p 'test_*.py'
```

Artifacts land in `tmp/perf/harness-monitor-instruments/runs/`. Each run produces `manifest.json`, `summary.json`, `summary.csv`, per-scenario metrics, and optional comparison reports.

## UX and SwiftUI rules

Rule content lives in skills under `.claude/skills/` (lazy-loaded on demand, not at session start):

- `swiftui-design-rules` - accessibility (VoiceOver, Dynamic Type, contrast, target sizes), visual design (typography, 8pt spacing, color, dark mode, motion timing), interaction patterns (feedback, loading states, destructive actions, forms), and performance targets (60fps, launch time, scroll, memory)
- `swiftui-api-patterns` - state wrappers (@State/@Binding/@Observable/@Bindable), view composition, ForEach identity, modifier branches, Picker/selection identity, button styles (.glass/.glassProminent, no .plain, AccentColor), drag-and-drop (.draggable/.dropDestination, DragSession.Phase), navigation, lists, animations, layout, keyboard/focus, window management, commands
- `swiftui-performance-macos` - no object creation in view body, cached @MainActor formatters, no .repeatForever on always-visible views, no geometry feedback loops, no persisted state in .inspector/.searchable on first frame, OSSignposter contract (io.harnessmonitor/perf), perf test env vars, isolated worktree requirements for instruments audits
- `swiftui-platform-rules` - macOS conventions (menu bar, windows, toolbar, sidebar, settings, dock, keyboard shortcuts), iOS conventions (tab bar, safe areas, gestures), and XCUITest reliability patterns (.firstMatch, animation suppression, single-launch tests, dragUp scroll helper)

Invoke the relevant skill when writing or reviewing Swift code in this directory. The skills collectively replace the former `apps/harness-monitor-macos/.claude/rules/` and root `.claude/rules/` files.

Research backing these rules lives under `apps/harness-monitor-macos/docs/research/`:

- `docs/research/ux/` - 10 numbered research docs covering HIG principles, interaction patterns, visual design, accessibility, SwiftUI best practices, psychology, performance, error handling, data display, and onboarding
- `docs/research/xcuitest-speed.md` - XCUITest reliability and speed investigation

Consult these for rationale and edge cases when a skill's rule text isn't enough.

## Daemon modes

Harness Monitor supports two daemon ownership modes. Pick the right one for the work you're doing.

### External daemon (recommended dev workflow)

Launch the app under the `HarnessMonitor (External Daemon)` scheme in Xcode and run `harness daemon dev` in a terminal. The dev daemon runs unsandboxed, writes its manifest into the `Q498EB36N4.io.harnessmonitor` app group container so the sandboxed Monitor app can read it, and spawns codex as its own stdio child - no `harness codex-bridge` process required.

Debugging is `lldb -- harness daemon dev` or `cargo run --bin harness -- daemon dev` in a terminal. The scheme sets `HARNESS_MONITOR_EXTERNAL_DAEMON=1` and a 60s warm-up timeout so the app can wait for you to start the daemon after launch. Starting the app before the daemon also works: the manifest watcher fires on the first manifest write and auto-reconnects within ~250ms.

If you previously ran `harness codex-bridge`, stop it before using dev mode - the dev daemon would otherwise route codex over the old bridge instead of spawning stdio.

The `HARNESS_MONITOR_EXTERNAL_DAEMON` flag is gated behind `#if DEBUG` in `DaemonOwnership`, so release builds always fall back to managed mode regardless of environment.

### Managed daemon (release and distribution)

Use the default `HarnessMonitor` scheme. This exercises the shipping path: the daemon runs under the macOS App Sandbox via `SMAppService`, and the launch agent plist sets `HARNESS_SANDBOXED=1` and `HARNESS_APP_GROUP_ID=Q498EB36N4.io.harnessmonitor`. Subprocess-spawning code paths (launchd management, codex stdio transport, daemon restart) are gated off in sandboxed mode and surface structured errors.

Run this scheme before cutting a TestFlight / notarized build - it's the only way to validate the release code path end-to-end.

Codex Runs use WebSocket transport when sandboxed. The daemon connects to an externally-managed `codex app-server` on loopback. Users start the bridge with `harness codex-bridge start` in a terminal or install it as a login item with `harness codex-bridge install-launch-agent`. The bridge writes `codex-endpoint.json` to the daemon data root; the daemon watches it and updates the manifest live so the Swift UI reflects bridge status without restart.

When no codex bridge is running in managed mode, `POST /v1/sessions/{id}/codex-runs` returns 503 with `{"error": "codex-unavailable"}`. The Swift store sets `codexUnavailable = true` and the Codex Flow sheet shows a recovery banner with a copy-to-clipboard command. The flag clears on reconnect.

Minimum codex version for WebSocket transport: `rust-v0.102.0+`.

## Gotchas

- `HarnessMonitor.xcodeproj` is repo-owned metadata; keep `project.pbxproj`, shared workspace/scheme files, and Swift source membership in sync.
