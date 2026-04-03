# Harness Monitor macOS App

Native SwiftUI control deck for live harness daemon sessions. `project.yml` is the generator input, and the generated `HarnessMonitor.xcodeproj` is checked in as tracked source.

## Prerequisites

- Xcode with `xcodebuild`
- `xcodegen`
- `swiftlint`

## Workflows

From the repo root:

```bash
mise run harness-monitor:macos:generate
mise run harness-monitor:macos:lint
mise run harness-monitor:macos:test
```

Direct scripts:

```bash
apps/harness-monitor-macos/Scripts/generate-project.sh
apps/harness-monitor-macos/Scripts/run-quality-gates.sh
apps/harness-monitor-macos/Scripts/test-swift.sh
```

`harness-monitor:macos:lint` regenerates the project, runs strict `swift format` over Sources and Tests, then runs `xcodebuild build-for-testing` against `tmp/xcode-derived` so the sandboxed `SwiftLintBuildToolPlugin` enforces the in-build lint rules without reusing stale local app caches.

`harness-monitor:macos:test` runs the same quality gates first, then executes:

```bash
xcodebuild -project 'apps/harness-monitor-macos/HarnessMonitor.xcodeproj' -scheme "HarnessMonitor" -destination platform=macOS -derivedDataPath tmp/xcode-derived test-without-building
```

For routine work, prefer the smallest targeted command instead of the full `harness-monitor:macos:test` lane. `HarnessMonitorUITests` run against the isolated `Harness Monitor UI Testing` host (`io.harnessmonitor.app.ui-testing`) and launch with `-ApplePersistenceIgnoreState YES`, so targeted UI checks do not interfere with a manually running `Harness Monitor.app`.

Do not pass `CODE_SIGNING_ALLOWED=NO` to `HarnessMonitorUITests`. macOS UI tests need Xcode to re-sign the generated `HarnessMonitorUITests-Runner.app`; otherwise Gatekeeper can reject the copied `com.apple.XCTRunner` runner before the test bundle bootstraps.

Example targeted UI regression:

```bash
xcodebuild -project 'apps/harness-monitor-macos/HarnessMonitor.xcodeproj' -scheme "HarnessMonitor" -configuration Debug -derivedDataPath tmp/xcode-derived -destination 'platform=macOS' test -only-testing:HarnessMonitorUITests/HarnessMonitorUITests/testToolbarOpensSettingsWindow
```

The generated project uses `SwiftLintBuildToolPlugin`, so the SwiftLint rules also run inside local Xcode builds and CI without restoring the older shell-wrapper lint path.
