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

For routine work, prefer the smallest targeted command instead of the full `harness:macos:test` lane. `HarnessUITests` run against the isolated `AI Harness UI Testing` host (`io.aiharness.app.ui-testing`) and launch with `-ApplePersistenceIgnoreState YES`, so targeted UI checks do not interfere with a manually running `AI Harness.app`.

Do not pass `CODE_SIGNING_ALLOWED=NO` to `HarnessUITests`. macOS UI tests need Xcode to re-sign the generated `HarnessUITests-Runner.app`; otherwise Gatekeeper can reject the copied `com.apple.XCTRunner` runner before the test bundle bootstraps.

Example targeted UI regression:

```bash
xcodebuild -project 'apps/harness-macos/AI Harness.xcodeproj' -scheme "AI Harness" -configuration Debug -derivedDataPath tmp/xcode-derived -destination 'platform=macOS' test -only-testing:HarnessUITests/HarnessUITests/testToolbarOpensSettingsWindow
```

The generated project uses `SwiftLintBuildToolPlugin`, so the SwiftLint rules also run inside local Xcode builds and CI without restoring the older shell-wrapper lint path.
