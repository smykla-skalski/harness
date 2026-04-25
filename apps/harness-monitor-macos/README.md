# Harness Monitor macOS App

Native SwiftUI control deck for live harness daemon sessions. The Xcode project is generated from the Tuist manifests under `Project.swift` and `Tuist/`. The generated `HarnessMonitor.xcodeproj` and `HarnessMonitor.xcworkspace` are not tracked - run `mise run monitor:macos:generate` to materialize them.

## Prerequisites

- Xcode with `xcodebuild`
- `tuist` (pinned via mise)
- `swiftlint`

## Workflows

From the repo root:

```bash
mise run version:check
mise run monitor:macos:build
mise run monitor:macos:generate
mise run monitor:macos:lint
mise run monitor:macos:test
mise run monitor:macos:audit -- --label baseline
mise run monitor:macos:test:scripts
```

Focused task entrypoints (run `mise run monitor:macos:generate` first if the workspace is not materialized):

```bash
mise run monitor:macos:xcodebuild -- -workspace apps/harness-monitor-macos/HarnessMonitor.xcworkspace ...
mise run monitor:macos:audit -- --label after-fix --compare-to tmp/perf/harness-monitor-instruments/runs/<baseline-dir>
mise run monitor:macos:audit:from-ref -- --ref <sha-or-ref> --label baseline
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
mise run monitor:macos:build
```

The wrapper and repo scripts resolve `xcode-derived` at the git common root, so linked worktrees reuse one DerivedData tree instead of bloating each checkout. The wrapper no longer re-runs Tuist after every successful `xcodebuild`; set `HARNESS_MONITOR_REGENERATE_AFTER_XCODEBUILD=1` only when you explicitly need to rewrite generated shared scheme metadata after a CLI lane.

`monitor:macos:lint` regenerates the project, runs strict `swift format` over Sources and Tests, runs `swiftlint lint` with a cache rooted in the shared `tmp/swiftlint-cache/harness-monitor-macos`, then runs `xcodebuild build-for-testing` against the shared `xcode-derived`.

`monitor:macos:test` runs the same quality gates first, then executes:

```bash
mise run monitor:macos:xcodebuild -- \
  -workspace apps/harness-monitor-macos/HarnessMonitor.xcworkspace \
  -scheme HarnessMonitor \
  -destination "platform=macOS,arch=$(uname -m),name=My Mac" \
  -derivedDataPath xcode-derived \
  CODE_SIGNING_ALLOWED=NO \
  test-without-building
```

For routine work, prefer the smallest targeted command instead of the full `monitor:macos:test` lane. Stay on the `mise` path and pass the selector through `XCODE_ONLY_TESTING`, for example:

```bash
XCODE_ONLY_TESTING=HarnessMonitorKitTests/PolicyGapRuleTests mise run monitor:macos:test
```

`XCODE_ONLY_TESTING` also accepts a comma-separated list when you need more than one focused selector. `HarnessMonitorUITests` run against the isolated `Harness Monitor UI Testing` host (`io.harnessmonitor.app.ui-testing`) and launch with `-ApplePersistenceIgnoreState YES`, so targeted UI checks do not interfere with a manually running `Harness Monitor.app`.

Versioning for the monitor app is derived from the repo root `Cargo.toml`. Use `mise run version:set -- <version>` from the repo root when you bump a release. `mise run monitor:macos:generate` regenerates the Xcode project via Tuist, then `Scripts/post-generate.sh` resyncs the marker-anchored version literals in `Tuist/ProjectDescriptionHelpers/BuildSettings.swift` (the `// VERSION_MARKER_CURRENT` and `// VERSION_MARKER_MARKETING` lines), the repo-root and app-local `buildServer.json` SourceKit configs, and the bundled daemon helper Info.plist from that canonical version.

Do not pass `CODE_SIGNING_ALLOWED=NO` to `HarnessMonitorUITests`. macOS UI tests need Xcode to re-sign the generated `HarnessMonitorUITests-Runner.app`; otherwise Gatekeeper can reject the copied `com.apple.XCTRunner` runner before the test bundle bootstraps.

Example targeted UI regression:

```bash
XCODE_ONLY_TESTING=HarnessMonitorUITests/HarnessMonitorUITests/testToolbarOpensSettingsWindow mise run monitor:macos:test
```

The generated project intentionally keeps SwiftLint out of the Xcode build graph so SwiftUI previews and routine local builds stay responsive. Lint enforcement lives in the monitor quality-gate scripts and CI instead.

For SwiftUI canvas previews, open `HarnessMonitor.xcodeproj` and select the shared `HarnessMonitorUIPreviews` scheme. It uses the `Preview` configuration, builds only the UI framework graph, and avoids launching the full `Harness Monitor.app` as the preview host.

Regenerate the project after target or configuration changes:

```bash
mise run monitor:macos:generate
```
