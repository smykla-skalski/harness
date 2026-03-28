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
apps/harness-monitor-macos/Scripts/lint-swift.sh all
apps/harness-monitor-macos/Scripts/test-swift.sh
```

`monitor:test` regenerates the project, runs the mandatory strict Swift format and SwiftLint gates, and executes:

```bash
xcodebuild -project apps/harness-monitor-macos/HarnessMonitor.xcodeproj -scheme HarnessMonitor -destination platform=macOS test
```

The pre-build quality gates in `project.yml` make the strict lint step non-optional inside Xcode builds as well.
