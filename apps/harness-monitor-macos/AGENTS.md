# AGENTS.md

This file provides guidance to coding agents when working in the Harness Monitor macOS app. The repo-root `AGENTS.md` covers the Rust harness CLI and everything outside this directory.

## Build and test

Optional features (Lottie dancing-llama, future OTel/observability slices, etc.) are gated by `HARNESS_FEATURE_<NAME>` env vars consumed at project-generation time. The Tuist `FeatureFlags` helper (`Tuist/ProjectDescriptionHelpers/FeatureFlags.swift`) reads them and adds the matching Swift compilation conditions. The all-features-OFF graph is the canonical baseline.

The Xcode project is generated from `Project.swift` (and `Tuist/Package.swift`) via Tuist 4. Sources are declared as globs in `Project.swift`, so adding a Swift file in an existing source root needs no manifest edit, but new targets, dependencies, build phases, schemes, or compilation conditions land in the manifests. Regenerate with `mise run monitor:generate` (`Scripts/generate.sh` under the hood: `tuist install` when needed, `tuist generate`, then `Scripts/post-generate.sh` for `buildServer.json` and version sync). The generated `HarnessMonitor.xcodeproj` and `HarnessMonitor.xcworkspace` are not tracked.
The manifest tags targets for focused generation, so partial graphs can use selectors such as `tuist generate tag:feature:monitor`, `tuist generate tag:feature:previews`, or `tuist generate tag:feature:ui-testing`.
Native Xcode local compilation cache is enabled directly through the generated build settings with `COMPILATION_CACHE_ENABLE_CACHING=YES`. This keeps the project auth-free for normal Tuist generation/builds; the remote-plugin settings (`COMPILATION_CACHE_ENABLE_PLUGIN` / `COMPILATION_CACHE_REMOTE_SERVICE_PATH`) are intentionally left unset here.

Task closeout follows the repo-root rule: finished monitor work must be replayed onto `main` with a clean, flat history. Rebase or cherry-pick; never merge. Resolve conflicts by triaging the current `main` behavior against the monitor task intent, then rerun the smallest relevant monitor validation.

Full git worktrees are mandatory for parallel monitor work. Any agent/user that edits Monitor files, regenerates Tuist projects, builds/tests, launches a daemon/bridge, or uses XcodeBuildMCP needs its own worktree. `HARNESS_MONITOR_BUILD_LANE` and `HARNESS_MONITOR_RUNTIME_LANE` isolate DerivedData, daemon roots, ports, launchd labels, and sockets inside that worktree; they are not a substitute for a separate checkout.

Validation expectations (run from repo root):

- `mise run monitor:lint`
- `mise run monitor:quality-gate`
- `mise run monitor:build`
- `mise run monitor:test`
- `mise run monitor:xcodebuild -- -workspace apps/harness-monitor-macos/HarnessMonitor.xcworkspace ...` for custom lane-aware `xcodebuild` invocations that need flags not covered by the canned tasks
- All xcodebuild invocations must use one of the approved `-derivedDataPath` values:
  - `xcode-derived` for quality gates, tests, and general dev builds
  - `xcode-derived-e2e` for swarm + agents e2e/UI lanes
  - `xcode-derived-instruments` for the instruments audit pipeline (isolated so the provenance fingerprint match is not contaminated by quality-gate builds)
  - `xcode-derived-lanes/<lane>` when `HARNESS_MONITOR_BUILD_LANE=<lane>` is set for an isolated CLI build lane

  Xcode's default `~/Library/Developer/Xcode/DerivedData/HarnessMonitor-*` is Xcode UI's private index/cache and holds its fetched SPM `SourcePackages/`. CLI workflows do not read or write it (they always pass `-derivedDataPath` explicitly), so it is not flagged by `mise run check:stale` and no harness script touches it - regens and `mise run clean:stale` leave it intact so Xcode never loses its package cache.
  `mise run clean:stale` is the safe shared scrub: it must not quit a live Harness Monitor session or stop live daemon work. Use `mise run clean:stale:full` or `mise run monitor:reset` only when an explicit live reset is intended.
  The `mise run monitor:xcodebuild` wrapper resolves approved logical paths at the git common root, so linked worktrees share one default CLI DerivedData tree instead of creating one per checkout. Set `HARNESS_MONITOR_BUILD_LANE=<name>` when an agent or long-running task needs its own lock/build database under `xcode-derived-lanes/<name>`.
  Runtime state is separate from build state. Set `HARNESS_MONITOR_RUNTIME_LANE=<name>` for an isolated daemon/bridge/MCP lane; otherwise the scripts derive a stable per-checkout runtime lane. Runtime lanes write daemon data under the app-group `runtime-lanes/<lane>`, derive a Codex bridge port, and use a lane-specific launch-agent label.
  Legacy `HARNESS_MONITOR_RUNTIME_PROFILE`, `HARNESS_MONITOR_USER_RUNTIME_PROFILE`, and agent-profile env vars are intentionally rejected. Use `HARNESS_MONITOR_BUILD_LANE` for DerivedData isolation and `HARNESS_MONITOR_RUNTIME_LANE` for daemon/bridge isolation.
- In each parallel worktree, agent-driven local Xcode and XcodeBuildMCP work must also set explicit lane names. Use `HARNESS_MONITOR_BUILD_LANE=agent-<session> mise run monitor:test` for isolated focused tests, and `HARNESS_MONITOR_RUNTIME_LANE=agent-<session> mise run monitor:xcodebuildmcp -- ...` or `mise run monitor:mcp` for XcodeBuildMCP. Do not hardcode shared names like `claude-main`.
- For local macOS Harness Monitor lanes, never use bare `-destination 'platform=macOS'`. Xcode sees both `My Mac` and `Any Mac`, prints `Using the first of multiple matching destinations`, and silently picks one. On Apple Silicon, even `name=My Mac` is still ambiguous because Xcode exposes both `arm64` and `x86_64` destinations. Use `-destination "platform=macOS,arch=$(uname -m),name=My Mac"` unless you intentionally need a stricter `id=...` selector.
- Hard requirement: do not run the full macOS UI suite by default. Run only the smallest targeted build/test command needed for the current change, such as a single XCTest case, a single XCTest class, or a non-UI build lane.
- Only run the full macOS app validation lane or the full `HarnessMonitorUITests` suite after the user explicitly asks for the full suite.
- Targeted `HarnessMonitorUITests` runs must use the isolated `Harness Monitor UI Testing` host (`io.harnessmonitor.app.ui-testing`) instead of the shipping `Harness Monitor.app` bundle so local manual app usage is not interrupted.
- Keep the `-ApplePersistenceIgnoreState YES` UI-test launch argument in place for the isolated host so macOS window restoration does not make targeted UI runs flaky.
- If a control is visually correct in the app but a macOS UI test cannot find or tap it, fix the test query/interaction path before changing product layout, copy, or semantics. Do not introduce UI changes just to make a flaky lookup pass unless the product truly has a visual or accessibility bug.
- Reuse the existing UI-test helpers exactly. New preflight/wait helpers for action controls must mirror `HarnessMonitorUITestInteractionSupport.tapButton(...)`: search button-role queries first, then the generic identified element, then the `identifier.frame` marker via `element(in:app,identifier:)` (not `frameElement(...)`, which is narrower and can miss real markers).
- Do not put `.accessibilityIdentifier(...)` on a container that wraps interactive children with their own IDs or `.accessibilityFrameMarker(...)` probes. In the macOS accessibility tree, the container identifier can clobber the nested button/marker contract. Use `.accessibilityTestProbe(...)` for container-level probes and keep child control identifiers on the controls themselves.
- Prefer existing container-aware patterns before inventing new gestures: `window(in:app,containing:)`, `descendantElement(...)`, `descendantFrameElement(...)`, and the visible-frame click flow from `SettingsUITests+AcpPermissionLogReveal.swift` for controls inside scroll views or secondary windows.
- SwiftLint runs externally via `mise run monitor:lint` and CI, not as an Xcode build plugin or part of `mise run monitor:test`. The lint lane is intentionally non-build-only: it generate-checks the workspace, runs `swift format`, and runs `swiftlint` without invoking `xcodebuild` or daemon bundle logic. Config lives in `.swiftlint.yml`.
- `mise run monitor:quality-gate` owns the slower build-based sandbox and daemon validation that used to be bundled into the lint lane.
- Prefer shared layout and control primitives for Harness Monitor UI density/readability work so button sizing and glass treatment stay consistent across screens.
- Liquid Glass (macOS 26): NavigationSplitView sidebar gets automatic Liquid Glass treatment. Use `.backgroundExtensionEffect()` on content columns so detail content extends behind the glass sidebar. Don't paint opaque backgrounds on the sidebar - use translucent tints so the system glass shows through. Use `.glassEffect(.regular.tint(color), in: shape)` for floating controls (tint takes `Color`, not `LinearGradient`). Never stack glass on glass. Glass belongs on the navigation/control layer, not on content. SwiftUI materials (`.ultraThinMaterial` etc.) blur behind the window, not sibling views. `GlassEffectContainer` groups glass elements with shared sampling; `spacing` controls morph threshold.

### Fast test iteration

`XCODE_ONLY_TESTING` accepts comma-separated selectors. Batch focused reruns into one call instead of chaining N invocations - each call costs two xcodebuild cold starts plus a tuist graph parse:

```bash
XCODE_ONLY_TESTING='HarnessMonitorKitTests/A/test1(),HarnessMonitorKitTests/A/test2()' \
  HARNESS_MONITOR_BUILD_LANE=agent-<uuid> mise run monitor:test
```

`Scripts/test-swift.sh` defaults to skipping `build-for-testing` when the existing `.xctestrun` is fresher than every Swift source, project descriptor, SPM lockfile, and the cross-project `mcp-servers/` tree. Break-glass: set `HARNESS_MONITOR_FORCE_BUILD_FOR_TESTING=1` to always rebuild (use after .xcconfig edits, environment switches, or external package updates outside the scoped freshness roots).

### Lane Cleanup

Named build lanes live under `xcode-derived-lanes/<lane>` and are safe to delete when no process is using that lane. `mise run clean:stale` handles stale process/socket cleanup without killing live Monitor work; `mise run clean:stale:full` and `mise run monitor:reset` are explicit live-reset paths.

## Debugging discipline

For Harness Monitor macOS and UI regressions:

- Start with real data. Reproduce with the smallest targeted build/test command and collect the preserved app/UI traces, screenshots, and failure artifacts before changing behavior.
- For live `AttributeGraph: cycle detected through attribute` warnings, use `mise run monitor:debug:attributegraph` to attach LLDB, break on `print_cycle`, print all thread backtraces, and leave the app stopped for copy/paste inspection.
- If the signal path is weak - bare `XCTAssertTrue`, missing preserved traces, cleaned-up artifacts, or ambiguous failures - stop and improve observability first. Fix the test/tracing surface before patching product code.
- Correlate the failure across layers before editing: UI-test host trace, preserved app trace, and the concrete source path that emitted the event.
- Reuse known-good setups. Compare against existing passing tests, fixtures, preview scenarios, and launch helpers before inventing a new launch path or interaction flow.
- Do not trust preview-scenario names or assumed UI state. Trace the recognized scenario and the actual mounted surface (`dashboard` vs `cockpit`) and patch the proven cause only.
- Avoid infer -> patch -> rerun loops. The correct loop is observe -> instrument -> prove -> patch -> rerun.
- Keep each iteration single-cause and targeted: one hypothesis, one instrumentation or code change, one narrow rerun.

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
XCODE_ONLY_TESTING=HarnessMonitorUITests/HarnessMonitorPerfTests/testLaunchDashboardHitchRate \
  mise run monitor:test
```

**Layer 2: Instruments xctrace pipeline** (`mise run monitor:audit`) - periodic deep-dive attribution for data no public API exposes (SwiftUI body evaluations, update groups, causes, allocation call trees):

```bash
# Full baseline capture
mise run monitor:audit -- --label baseline

# Compare against baseline
mise run monitor:audit -- \
  --label after-fix --compare-to tmp/perf/harness-monitor-instruments/runs/<baseline-dir>

# Parser regression tests
mise run monitor:test:scripts
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

Launch the app under the `HarnessMonitor (External Daemon)` scheme in Xcode and run `mise run monitor:daemon:dev` in a terminal. The dev daemon runs unsandboxed, writes its manifest into the `Q498EB36N4.io.harnessmonitor` app group container so the sandboxed Monitor app can read it, and spawns codex as its own stdio child - no `harness codex-bridge` process required. For an isolated runtime lane, prefix the daemon and bridge commands with `HARNESS_MONITOR_RUNTIME_LANE=<name>`. For isolated CLI builds/tests, use `HARNESS_MONITOR_BUILD_LANE=<name>` separately.

Debugging is `lldb -- harness daemon dev` or `cargo run --bin harness -- daemon dev` in a terminal. The scheme sets `HARNESS_MONITOR_EXTERNAL_DAEMON=1` and a 60s warm-up timeout so the app can wait for you to start the daemon after launch. Starting the app before the daemon also works: the manifest watcher fires on the first manifest write and auto-reconnects within ~250ms.

If you previously ran `harness codex-bridge`, stop it before using dev mode - the dev daemon would otherwise route codex over the old bridge instead of spawning stdio.

The `HARNESS_MONITOR_EXTERNAL_DAEMON` flag is gated behind `#if DEBUG` in `DaemonOwnership`, so release builds always fall back to managed mode regardless of environment.

### Managed daemon (release and distribution)

Use the default `HarnessMonitor` scheme. This exercises the shipping path: the daemon runs under the macOS App Sandbox via `SMAppService`, and the launch agent plist sets `HARNESS_SANDBOXED=1` and `HARNESS_APP_GROUP_ID=Q498EB36N4.io.harnessmonitor`. With `HARNESS_MONITOR_RUNTIME_LANE=<name>` set during the build, the bundled launch agent also gets a lane-specific label plus matching `HARNESS_DAEMON_DATA_HOME` and `HARNESS_CODEX_WS_PORT` env so concurrent managed dev builds stay isolated. Subprocess-spawning code paths (launchd management, codex stdio transport, daemon restart) are gated off in sandboxed mode and surface structured errors.

Run this scheme before cutting a TestFlight / notarized build - it's the only way to validate the release code path end-to-end.

Codex threads inside Agents use WebSocket transport when sandboxed. The daemon connects to an externally-managed `codex app-server` on loopback. Users start the bridge with `harness codex-bridge start` in a terminal or install it as a login item with `harness codex-bridge install-launch-agent`. The bridge writes `codex-endpoint.json` to the daemon data root; the daemon watches it and updates the manifest live so the Swift UI reflects bridge status without restart.

When no codex bridge is running in managed mode, `POST /v1/sessions/{id}/managed-agents/codex` returns 503 with `{"error": "codex-unavailable"}`. The Swift store sets `codexUnavailable = true` and the unified Workspace window shows a recovery banner with a copy-to-clipboard command. The flag clears on reconnect.

Minimum codex version for WebSocket transport: `rust-v0.102.0+`.

## Preview authoring

All `#Preview` blocks live in `HarnessMonitorUIPreviewable`. Previews render through the dedicated `HarnessMonitorPreviewHost` app target via the `HarnessMonitorUIPreviews` scheme. The host links only `HarnessMonitorKit` + `HarnessMonitorUIPreviewable` - no Lottie, no daemon signaling, no main-app dependencies.

Rules:

- Previewable views must NOT take closure properties (`let onTap: () -> Void`). Use `HarnessAsyncActionButton.StoreAction` or `@Environment(\.openWindow)` for actions.
- Every `#Preview` that exercises `@Query` or other SwiftData-backed views must inject `.modelContainer(PreviewFixtures.previewContainer())` (or equivalent fixture container).
- Allocate no `DateFormatter`/`JSONEncoder`/`NumberFormatter` in view bodies - use static `@MainActor` lets.
- Never wrap `#Preview` in `#if DEBUG` - DEBUG is already defined in preview builds, this is noise.
- Add canonical screens to `Previews.json` when you add a new top-level surface.
- If a `#Preview` crashes with `TableViewListCore_Mac2.swift:5170`, mark with a TODO referencing the macOS 26 SwiftUI bug and comment out the offending preview - don't hack around it.

Preview render scripts are not part of the current lane model. Use the Xcode canvas or a targeted `monitor:build`/`monitor:test` lane for compile verification.

## Gotchas

- `HarnessMonitor.xcodeproj` is repo-owned metadata; keep `project.pbxproj`, shared workspace/scheme files, and Swift source membership in sync.
- For Swift-only verification when the working tree carries dirty Rust changes, build with the `HarnessMonitor (External Daemon)` scheme; the default `HarnessMonitor` scheme runs a `Build harness daemon (parallel)` script phase that fails on broken Rust. The default scheme is required only when validating the shipping managed-daemon path.
- **Never wrap `deinit` cleanup in `MainActor.assumeIsolated { ... }`** on a `@MainActor` class (or `NSView` / `NSObject` subclass that's MainActor in the SDK overlay) under Swift 6 strict concurrency on macOS 26. ARC routinely drops the last reference on `com.apple.SwiftUI.DisplayLink` (notably during dashboard ↔ cockpit transitions or any SwiftUI view-tree rebuild), and `assumeIsolated` traps with `BUG IN CLIENT OF LIBDISPATCH: Block was expected to execute on queue [com.apple.main-thread]`. Confirmed crashes in `KeyWindowObserver.deinit`, `WindowCommandScopeTrackingNSView.deinit`, and an earlier `HarnessMonitorStore.deinit`. Required pattern: mark the storage `nonisolated(unsafe) var` so the nonisolated deinit can read it without the non-Sendable error, inline only thread-safe cleanup (`NotificationCenter.removeObserver(_:)` and `IOPMAssertionRelease` are documented thread-safe; treat `NSEvent.removeMonitor` as MainActor-only), and move any MainActor-only step (e.g. clearing routing state on a `@MainActor @Observable`) into the NSViewRepresentable's static `dismantleNSView(_:coordinator:)`, which SwiftUI guarantees runs on the MainActor when the representable is removed. Do not reach for `isolated deinit` (SE-0371) — the upcoming feature is not enabled in this project.
