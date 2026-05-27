# AGENTS.md

This file governs the Harness Monitor macOS app. The repo-root `AGENTS.md`
still applies; this file adds app-specific build, lane, SwiftUI, and daemon
rules.

## How to use this file

1. Apply the repo-root contract first, especially worktrees, `mise`, signed
   path-limited commits, and final replay to local `main`.
2. Use this file for mandatory Monitor rules: Tuist generation, lanes,
   validation, SwiftUI/UX, and daemon ownership.
3. Load `../../docs/agent-guides/monitor-reference.md` only for detailed lane,
   daemon, performance, preview, or SwiftUI rationale. Load
   `../../docs/agent-guides/monitor-mobile-reference.md` only for iOS, watch,
   CloudKit, or mobile mirror work.

## Task routing

| Work area | Start here |
| --- | --- |
| Tuist generation, build, test, lanes | This file |
| Performance and Instruments work | `../../docs/agent-guides/monitor-reference.md` |
| Daemon ownership modes | `../../docs/agent-guides/monitor-reference.md` |
| iOS app, watch app, CloudMirror/Crypto/MacRelay frameworks | `../../docs/agent-guides/monitor-mobile-reference.md` |
| Previewable SwiftUI structure | `Sources/HarnessMonitorUIPreviewable/AGENTS.md` |
| SwiftUI/API/UX rule detail | The skills listed in this file, then `docs/research/` when rationale is needed |

## Project generation

Optional app features are gated by `HARNESS_FEATURE_<NAME>` env vars consumed at
Tuist generation time. The all-features-OFF graph is the canonical baseline.

The Xcode project is generated from `Project.swift` and `Tuist/Package.swift`
with Tuist 4. Existing source roots use globs, so new Swift files in an existing
root need no manifest edit. New targets, dependencies, build phases, schemes, or
compilation conditions belong in the manifests.

Use:

```bash
mise run monitor:generate
```

The generated `HarnessMonitor.xcodeproj` and `HarnessMonitor.xcworkspace` are
not tracked. The tracked root and app-local `buildServer.json` files are shared
defaults pinned to `xcode-derived`; active build lanes belong only in untracked
workspace settings and explicit CLI env.

## Worktrees and lanes

Full git worktrees are mandatory for parallel Monitor work. Any agent or user
that edits Monitor files, regenerates Tuist projects, builds/tests, launches a
daemon/bridge, or uses XcodeBuildMCP needs a separate checkout.

For any goal or longer work split into smaller chunks, keep using one assigned
custom worktree and one lane. After every commit in that worktree, rebase the
worktree branch onto current local `main` and resolve conflicts in the worktree
before replaying to `main`; this keeps the final replay simple. Reusing the
same build/test/runtime lane keeps DerivedData, daemon state, and ports warm
instead of forcing cold rebuilds.

Those worktrees are temporary isolation only. Finished Monitor work must be
replayed into the local `main` checkout before handoff. If the work is fully in
local `main`, remove the temporary worktree and branch afterward.

Inside a worktree:

- `HARNESS_MONITOR_BUILD_LANE=<name>` isolates DerivedData under
  `xcode-derived-lanes/<name>`.
- `HARNESS_MONITOR_RUNTIME_LANE=<name>` isolates daemon roots, ports, launchd
  labels, bridge state, and MCP runtime state.

There are no agent-specific `monitor:agent:*` tasks. Use the normal
`mise run monitor:*` tasks and add the lane env vars above when an agent needs
isolated build or runtime state.

Do not use legacy runtime-profile env vars. Do not hardcode shared lane names
such as `claude-main`.

The xcodebuild wrapper enforces a hardcoded host-wide concurrency cap
(currently 8). Do not try to raise it with env vars. Lane cache routing,
isolated app identity, IDE Run discovery, and slot-reaper details live in
`../../docs/agent-guides/monitor-reference.md`.

## Validation

Run from the repo root:

```bash
mise run monitor:lint
mise run monitor:quality-gate
mise run monitor:build
mise run monitor:build:release
mise run monitor:release:external
mise run monitor:test
mise run monitor:xcodebuild -- -workspace apps/harness-monitor/HarnessMonitor.xcworkspace ...
```

Approved `-derivedDataPath` values:

- `xcode-derived` for quality gates, tests, and general local builds.
- `xcode-derived-e2e` for swarm and agents e2e/UI lanes.
- `xcode-derived-instruments` for Instruments audit work.
- `xcode-derived-lanes/<lane>` when `HARNESS_MONITOR_BUILD_LANE=<lane>` is set.

`mise run clean:stale` is the safe shared scrub and must not quit a live
Harness Monitor session or stop live daemon work. Use
`mise run clean:stale:full` or `mise run monitor:reset` only for an
explicit live reset.

For local macOS `xcodebuild`, never use bare `-destination 'platform=macOS'`.
Use:

```bash
-destination "platform=macOS,arch=$(uname -m),name=My Mac"
```

## Test scope

Do not run the full macOS UI suite by default. Run the smallest targeted
build/test command needed for the current change: a single XCTest case, a single
XCTest class, or a non-UI build lane.

Only run the full app validation lane or full `HarnessMonitorUITests` suite when
the user explicitly asks for it.

Targeted `HarnessMonitorUITests` runs must use the isolated
`Harness Monitor UI Testing` host (`io.harnessmonitor.app.ui-testing`) so local
manual app usage is not interrupted. Keep `-ApplePersistenceIgnoreState YES` in
place for that host.

For non-UI focused tests, `XCODE_ONLY_TESTING` accepts comma-separated
selectors:

```bash
XCODE_ONLY_TESTING='HarnessMonitorKitTests/A/test1(),HarnessMonitorKitTests/A/test2()' \
  HARNESS_MONITOR_BUILD_LANE=agent-<id> mise run monitor:test
```

If a UI test cannot find or tap a visually correct control, fix the test query
or interaction path before changing product layout, copy, or semantics. New
action-control helpers must mirror
`HarnessMonitorUITestInteractionSupport.tapButton(...)`. For failing UI tests,
run one selector at a time. See `../../docs/agent-guides/monitor-reference.md`
for the full interaction contract.

## SwiftUI and UX

Prefer shared layout and control primitives for density/readability work so
button sizing and glass treatment stay consistent across screens.

Use native SwiftUI split containers (`NavigationSplitView`, `HSplitView`) for
resizable panes. Do not hand-roll pane dividers with `DragGesture`, manual
cursor stacks, or per-drag width state unless a native split cannot express the
behavior and the performance tradeoff is proven.

Liquid Glass summary: let `NavigationSplitView` sidebars use the system glass,
use one stable `.backgroundExtensionEffect()` host per session surface, avoid
duplicating that effect on individual content/detail panes, keep session scroll
edges soft, apply glass to navigation/control surfaces only, and never stack
glass on glass. See
`../../docs/agent-guides/monitor-reference.md` for the full macOS 26 notes.

Use the relevant skill before writing or reviewing Swift code here:

- `swiftui-design-rules`
- `swiftui-api-patterns`
- `swiftui-performance-macos`
- `swiftui-platform-rules`
- `xcodebuildmcp-cli` before XcodeBuildMCP tools

Research backing lives under `docs/research/`.

## Debugging

Start with real data. Reproduce with the smallest targeted command and collect
preserved app/UI traces, screenshots, and failure artifacts before changing
behavior. If the signal path is weak, improve observability first. Patch the
proven cause only.

For live `AttributeGraph: cycle detected through attribute` warnings:

```bash
mise run monitor:debug:attributegraph
```

The command attaches LLDB, breaks on `print_cycle`, prints all thread
backtraces, and leaves the app stopped for copy/paste inspection.

## Daemon modes

Harness Monitor supports both managed and external daemon ownership in
production builds. For the external-daemon path, the fastest local workflow
uses the `HarnessMonitor (External Daemon)` scheme plus:

```bash
mise run monitor:daemon:dev
```

Production external launches should keep the daemon in an app-group runtime
root (for example via `HARNESS_MONITOR_RUNTIME_LANE`,
`HARNESS_DAEMON_DATA_HOME`, or the `monitor:daemon:dev` wrapper) so the
sandboxed app can resolve the manifest. The default `HarnessMonitor` scheme
keeps managed mode enabled and is still the shipping validation lane. Details
and bridge behavior live in `../../docs/agent-guides/monitor-reference.md`.

## Feature references

Load detailed references only when the task touches the feature:

- Lane cache routing, isolated app identity, IDE Run discovery, daemon cargo
  cache, Supervisor audit, performance, preview authoring, and Swift 6 traps:
  `../../docs/agent-guides/monitor-reference.md`.
- iOS app, watch app, CloudKit, NeedsMe, CloudMirror, pairing, mobile widgets,
  and companion build commands:
  `../../docs/agent-guides/monitor-mobile-reference.md`.

## Preview authoring

All `#Preview` blocks live in `HarnessMonitorUIPreviewable` and render through
the `HarnessMonitorPreviewHost` app target via the `HarnessMonitorUIPreviews`
scheme. For structure and naming rules, follow
`Sources/HarnessMonitorUIPreviewable/AGENTS.md`.

Preview render scripts are not part of the current lane model. Use Xcode canvas
or a targeted `monitor:build` / `monitor:test` lane for compile verification.

## Gotchas

- Keep `HarnessMonitor.xcodeproj`, shared workspace/scheme files, and Swift
  source membership in sync when project metadata is regenerated.
- For Swift-only verification in a tree with dirty Rust changes, build with the
  `HarnessMonitor (External Daemon)` scheme. The default scheme runs the daemon
  build phase and can fail on unrelated Rust breakage.
- Dense Monitor surfaces often mount MCP-tracked controls through shared action
  helpers, and the registry host is enabled in normal app flows. When Settings,
  toolbar, or similar interactions feel slow, inspect the tracking probe before
  rewriting the visible SwiftUI tree. Do not use `accessibilityFrame()` or an
  unthrottled `NSWindow.didUpdateNotification` fan-out in tracked-element hot
  paths; use clip-aware AppKit geometry conversion and throttle `didUpdate`
  refreshes.
- Never wrap `deinit` cleanup in `MainActor.assumeIsolated { ... }` on
  `@MainActor` classes or SDK-overlay MainActor types under Swift 6 strict
  concurrency on macOS 26. Use nonisolated thread-safe cleanup and move
  MainActor-only work to representable dismantle hooks. Full rationale lives in
  `../../docs/agent-guides/monitor-reference.md`.
