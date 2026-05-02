# Harness Monitor macOS App

Native SwiftUI control deck for live harness daemon sessions. The Xcode project is generated from the Tuist manifests under `Project.swift` and `Tuist/`. The generated `HarnessMonitor.xcodeproj` and `HarnessMonitor.xcworkspace` are not tracked - run `mise run monitor:generate` to materialize them.

## Prerequisites

- Xcode with `xcodebuild`
- `tuist` (pinned via mise)
- `swiftlint`

## Workflows

From the repo root:

```bash
mise run version:check
mise run monitor:build
mise run monitor:generate
mise run monitor:lint
mise run monitor:quality-gate
mise run monitor:test
mise run monitor:audit -- --label baseline
mise run monitor:test:scripts
```

Focused task entrypoints (run `mise run monitor:generate` first if the workspace is not materialized):

```bash
mise run monitor:xcodebuild -- -workspace apps/harness-monitor-macos/HarnessMonitor.xcworkspace ...
mise run monitor:audit -- --label after-fix --compare-to tmp/perf/harness-monitor-instruments/runs/<baseline-dir>
mise run monitor:audit:from-ref -- --ref <sha-or-ref> --label baseline
```

When you only need part of the graph, use the manifest tags for focused generation, for example:

```bash
tuist generate tag:feature:monitor
tuist generate tag:feature:previews
tuist generate tag:feature:ui-testing
```

Native Xcode local compilation cache is enabled directly through the generated build settings with `COMPILATION_CACHE_ENABLE_CACHING=YES`. This gives the app local Xcode 26 compilation-cache reuse without requiring Tuist Cloud login or a remote cache service. The remote-plugin settings (`COMPILATION_CACHE_ENABLE_PLUGIN` / `COMPILATION_CACHE_REMOTE_SERVICE_PATH`) are intentionally not configured here.

When you need a raw local build command, prefer the lock-aware wrapper so concurrent monitor lanes do not corrupt or lock the shared `xcode-derived` build database:

```bash
mise run monitor:build
```

The wrapper and repo scripts resolve `xcode-derived` at the git common root, so linked worktrees reuse one DerivedData tree instead of bloating each checkout. For a personal non-interfering dev lane, set `HARNESS_MONITOR_RUNTIME_PROFILE=<name>`. That moves the default local build root to `xcode-derived/profiles/<slug>`, gives the app/daemon/bridge a profile-owned daemon data home under `~/Library/Group Containers/Q498EB36N4.io.harnessmonitor/runtime-profiles/<slug>`, derives a profile-owned Codex bridge port, and uses a profile-specific managed launch-agent label. The wrapper no longer re-runs Tuist after every successful `xcodebuild`; set `HARNESS_MONITOR_REGENERATE_AFTER_XCODEBUILD=1` only when you explicitly need to rewrite generated shared scheme metadata after a CLI lane.

General monitor build/test lanes keep using the shared `xcode-derived` root unless `HARNESS_MONITOR_RUNTIME_PROFILE` is set. The swarm full-flow and agents e2e/UI lanes intentionally use the shared `xcode-derived-e2e` root so they do not contend with normal monitor builds.

Generated Xcode projects stay under `apps/harness-monitor-macos`; only build-output roots are marked for Spotlight exclusion. `Scripts/post-generate.sh` and the lock-aware xcodebuild wrapper create `.metadata_never_index` inside `xcode-derived`, `xcode-derived/profiles/*`, `xcode-derived-e2e`, and `xcode-derived-instruments` without moving source or generated project metadata into a hidden mirror directory. For the strongest Apple-supported exclusion, add those ignored build roots to Spotlight Privacy in System Settings.

`monitor:lint` is the fast non-build lane. It generate-checks the workspace, runs strict `swift format` over Sources and Tests, and runs `swiftlint lint` with a cache rooted in the shared `tmp/swiftlint-cache/harness-monitor-macos`. It never invokes `xcodebuild`, daemon pre-actions, or daemon bundle validation.

`monitor:quality-gate` is the slower build-based validation lane. It runs `build-for-testing` against `xcode-derived` (or `xcode-derived/profiles/<slug>` when `HARNESS_MONITOR_RUNTIME_PROFILE` is set) with daemon embedding enabled, scans sandbox logs, and verifies the checked-in app/daemon entitlements expected by the built product.

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

For a fully isolated local Xcode/dev-daemon lane, export a personal profile before generating or building:

```bash
export HARNESS_MONITOR_RUNTIME_PROFILE=bart-dev
mise run monitor:generate
mise run monitor:build
```

Use the same env prefix when starting an external daemon or manual bridge from another terminal. Running `clean:stale` without the profile env still performs the broader shared-root cleanup.

If you do not want to manage that env manually, use the user-scoped tasks instead:

```bash
mise run monitor:user
```

That one command regenerates the workspace for your personal isolated profile and prints the exact next commands to use from then on.

If you want the individual follow-up tasks explicitly, they are:

```bash
mise run monitor:user:bootstrap
mise run monitor:user:build
mise run monitor:user:test
mise run monitor:user:daemon:dev
mise run monitor:user:bridge:start
```

`monitor:user:bootstrap` does the same setup as `monitor:user`; `monitor:user:profile` just reprints the chosen profile info later without regenerating anything.

`XCODE_ONLY_TESTING` also accepts a comma-separated list when you need more than one focused selector. Class-level selectors are expanded through Xcode test enumeration before execution so the lane fails instead of reporting a misleading zero-test pass when Xcode does not run class selectors directly. `HarnessMonitorUITests` run against the isolated `Harness Monitor UI Testing` host (`io.harnessmonitor.app.ui-testing`) and launch with `-ApplePersistenceIgnoreState YES`, so targeted UI checks do not interfere with a manually running `Harness Monitor.app`.

Versioning for the monitor app is derived from the repo root `Cargo.toml`. Use `mise run version:set -- <version>` from the repo root when you bump a release. `mise run monitor:generate` regenerates the Xcode project via Tuist, then `Scripts/post-generate.sh` resyncs the marker-anchored version literals in `Tuist/ProjectDescriptionHelpers/BuildSettings.swift` (the `// VERSION_MARKER_CURRENT` and `// VERSION_MARKER_MARKETING` lines), the repo-root and app-local `buildServer.json` SourceKit configs, and the bundled daemon helper Info.plist from that canonical version.

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
