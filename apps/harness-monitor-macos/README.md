# Harness Monitor macOS App

Native SwiftUI control deck for live harness daemon sessions. The checked-in source of truth is `project.yml`; the Xcode project is generated and ignored.

## Prerequisites

- Xcode with `xcodebuild`
- `xcodegen`
- `swiftlint`

## Workflows

From the repo root:

```bash
mise run monitor:generate
mise run monitor:lint
mise run monitor:test
```

Direct scripts:

```bash
apps/harness-monitor-macos/Scripts/generate-project.sh
apps/harness-monitor-macos/Scripts/run-quality-gates.sh
apps/harness-monitor-macos/Scripts/test-swift.sh
```

`monitor:lint` regenerates the project, runs strict `swift format` over Sources and Tests, then runs `xcodebuild build-for-testing` so the sandboxed `SwiftLintBuildToolPlugin` enforces the in-build lint rules.

`monitor:test` runs the same quality gates first, then executes:

```bash
xcodebuild -project apps/harness-monitor-macos/HarnessMonitor.xcodeproj -scheme HarnessMonitor -destination platform=macOS test-without-building
```

The generated project uses `SwiftLintBuildToolPlugin`, so the SwiftLint rules also run inside local Xcode builds and CI without restoring the older shell-wrapper lint path.
