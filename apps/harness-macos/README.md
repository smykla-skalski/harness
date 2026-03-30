# AI Harness macOS App

Native SwiftUI control deck for live harness daemon sessions. `project.yml` is the generator input, and the generated `AI Harness.xcodeproj` is checked in as tracked source.

## Prerequisites

- Xcode with `xcodebuild`
- `xcodegen`
- `swiftlint`

## Workflows

From the repo root:

```bash
mise run harness:macos:generate
mise run harness:macos:lint
mise run harness:macos:test
```

Direct scripts:

```bash
apps/harness-macos/Scripts/generate-project.sh
apps/harness-macos/Scripts/run-quality-gates.sh
apps/harness-macos/Scripts/test-swift.sh
```

`harness:macos:lint` regenerates the project, runs strict `swift format` over Sources and Tests, then runs `xcodebuild build-for-testing` against `tmp/xcode-derived` so the sandboxed `SwiftLintBuildToolPlugin` enforces the in-build lint rules without reusing stale local app caches.

`harness:macos:test` runs the same quality gates first, then executes:

```bash
xcodebuild -project 'apps/harness-macos/AI Harness.xcodeproj' -scheme "AI Harness" -destination platform=macOS -derivedDataPath tmp/xcode-derived test-without-building
```

The generated project uses `SwiftLintBuildToolPlugin`, so the SwiftLint rules also run inside local Xcode builds and CI without restoring the older shell-wrapper lint path.
