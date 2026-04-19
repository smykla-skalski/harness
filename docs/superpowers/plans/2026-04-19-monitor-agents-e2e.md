# Monitor Agents E2E Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an explicit macOS monitor e2e lane that uses a real isolated daemon root, a real sandboxed-style daemon, a real unified bridge, and the live `Agents` UI to prove both the terminal-backed and structured Codex flows without joining the regular monitor UI suite.

**Architecture:** Create a separate UI-test bundle and shared scheme for `Agents` e2e, then extract the generic UI-test support files into a shared test-support directory so both UI-test bundles can reuse the same query and interaction helpers without duplicating them. Build the live lane vertically: first wire the new target and explicit invocation surface, then land the live-process harness and terminal smoke test, then land the real Codex steer-plus-approval test, and finish with docs, version sync, and focused validation.

**Tech Stack:** SwiftUI, XCTest UI tests, XcodeGen `project.yml`, lock-aware `xcodebuild`, Rust `harness` daemon and bridge binaries, root `mise` tasks, shared `tmp/xcode-derived`

---

## Worktree and execution notes

- Use a dedicated git worktree rooted from `main` before implementation.
- Keep every task self-contained and commit immediately after its green verification step with `git commit -sS`.
- Verify every commit with `git show --show-signature --format=fuller --stat -1 <sha>`.
- If the worktree still contains preexisting edits in:
  - `apps/harness-monitor-macos/Tests/HarnessMonitorUITests/AgentTuiWindowUITests+Support.swift`
  - `apps/harness-monitor-macos/Tests/HarnessMonitorUITests/AgentTuiWindowUITests.swift`
  - `apps/harness-monitor-macos/Tests/HarnessMonitorUITests/HarnessMonitorUITestAccessibility.swift`
  checkpoint them as a separate signed commit before Task 1 so the e2e feature starts from a clean tree.
- Prefer the smallest targeted lane that proves the task before running broader validation.

## File structure and responsibilities

- Create: `apps/harness-monitor-macos/Tests/HarnessMonitorUITestSupport/` — generic UI-test support shared by both UI-test bundles
- Move: `apps/harness-monitor-macos/Tests/HarnessMonitorUITests/HarnessMonitorUITestAccessibility.swift` → `apps/harness-monitor-macos/Tests/HarnessMonitorUITestSupport/HarnessMonitorUITestAccessibility.swift`
- Move: `apps/harness-monitor-macos/Tests/HarnessMonitorUITests/HarnessMonitorUITestAssertions.swift` → `apps/harness-monitor-macos/Tests/HarnessMonitorUITestSupport/HarnessMonitorUITestAssertions.swift`
- Move: `apps/harness-monitor-macos/Tests/HarnessMonitorUITests/HarnessMonitorUITestDiagnosticsSupport.swift` → `apps/harness-monitor-macos/Tests/HarnessMonitorUITestSupport/HarnessMonitorUITestDiagnosticsSupport.swift`
- Move: `apps/harness-monitor-macos/Tests/HarnessMonitorUITests/HarnessMonitorUITestInteractionSupport.swift` → `apps/harness-monitor-macos/Tests/HarnessMonitorUITestSupport/HarnessMonitorUITestInteractionSupport.swift`
- Move: `apps/harness-monitor-macos/Tests/HarnessMonitorUITests/HarnessMonitorUITestNativePresentationSupport.swift` → `apps/harness-monitor-macos/Tests/HarnessMonitorUITestSupport/HarnessMonitorUITestNativePresentationSupport.swift`
- Move: `apps/harness-monitor-macos/Tests/HarnessMonitorUITests/HarnessMonitorUITestQuerySupport.swift` → `apps/harness-monitor-macos/Tests/HarnessMonitorUITestSupport/HarnessMonitorUITestQuerySupport.swift`
- Move: `apps/harness-monitor-macos/Tests/HarnessMonitorUITests/HarnessMonitorUITestSupport.swift` → `apps/harness-monitor-macos/Tests/HarnessMonitorUITestSupport/HarnessMonitorUITestSupport.swift`
- Create: `apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ELiveHarness.swift` — process lifecycle, isolated roots, readiness polling, failure-log retention
- Create: `apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests.swift` — two explicit e2e tests only
- Create: `apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests+Support.swift` — `Agents`-window helpers that are live-mode specific and intentionally separate from preview-only Agent helpers
- Modify: `apps/harness-monitor-macos/Sources/HarnessMonitor/App/HarnessMonitorAppConfiguration.swift` — add an explicit live UI-test environment override so the new bundle never relies on incidental preview defaults
- Modify: `apps/harness-monitor-macos/project.yml` — add shared support folder, add the new UI-test target, and add the dedicated e2e scheme
- Modify: `apps/harness-monitor-macos/HarnessMonitor.xcodeproj/project.pbxproj` — generated tracked source for the target/scheme/support move
- Create: `apps/harness-monitor-macos/HarnessMonitor.xcodeproj/xcshareddata/xcschemes/HarnessMonitorAgentsE2E.xcscheme` — generated shared scheme for the new target
- Create: `apps/harness-monitor-macos/Scripts/test-agents-e2e.sh` — explicit e2e lane entrypoint
- Modify: `.mise.toml` — add `monitor:macos:test:agents-e2e`
- Modify: `apps/harness-monitor-macos/README.md` — document the explicit lane and its isolation guarantees
- Modify: `apps/harness-monitor-macos/CLAUDE.md` — document the dedicated e2e lane as opt-in and distinct from the regular UI suite
- Modify: `Cargo.toml`
- Modify: `Cargo.lock`
- Modify: `testkit/Cargo.toml`
- Modify: `apps/harness-monitor-macos/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist`
- Modify: `apps/harness-monitor-macos/HarnessMonitor.xcodeproj/project.pbxproj`

### Task 1: Wire the Explicit E2E Target and Shared Test Support

**Files:**
- Create: `apps/harness-monitor-macos/Tests/HarnessMonitorUITestSupport/`
- Move: `apps/harness-monitor-macos/Tests/HarnessMonitorUITests/HarnessMonitorUITestAccessibility.swift`
- Move: `apps/harness-monitor-macos/Tests/HarnessMonitorUITests/HarnessMonitorUITestAssertions.swift`
- Move: `apps/harness-monitor-macos/Tests/HarnessMonitorUITests/HarnessMonitorUITestDiagnosticsSupport.swift`
- Move: `apps/harness-monitor-macos/Tests/HarnessMonitorUITests/HarnessMonitorUITestInteractionSupport.swift`
- Move: `apps/harness-monitor-macos/Tests/HarnessMonitorUITests/HarnessMonitorUITestNativePresentationSupport.swift`
- Move: `apps/harness-monitor-macos/Tests/HarnessMonitorUITests/HarnessMonitorUITestQuerySupport.swift`
- Move: `apps/harness-monitor-macos/Tests/HarnessMonitorUITests/HarnessMonitorUITestSupport.swift`
- Create: `apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests.swift`
- Modify: `apps/harness-monitor-macos/project.yml`
- Modify: `apps/harness-monitor-macos/HarnessMonitor.xcodeproj/project.pbxproj`
- Create: `apps/harness-monitor-macos/HarnessMonitor.xcodeproj/xcshareddata/xcschemes/HarnessMonitorAgentsE2E.xcscheme`
- Create: `apps/harness-monitor-macos/Scripts/test-agents-e2e.sh`
- Modify: `.mise.toml`

- [ ] **Step 1: Verify the explicit lane is missing before any code changes**

Run:

```bash
mise run monitor:macos:test:agents-e2e
apps/harness-monitor-macos/Scripts/xcodebuild-with-lock.sh \
  -project 'apps/harness-monitor-macos/HarnessMonitor.xcodeproj' \
  -scheme 'HarnessMonitorAgentsE2E' \
  -destination 'platform=macOS' \
  -derivedDataPath tmp/xcode-derived \
  build-for-testing
```

Expected:

- `mise` fails with `task not found`
- `xcodebuild` fails because `HarnessMonitorAgentsE2E` does not exist

- [ ] **Step 2: Add the new target, shared support directory, scheme, and explicit task**

Update `apps/harness-monitor-macos/project.yml` to extract the generic UI-test support files and add the dedicated e2e bundle:

```yaml
  HarnessMonitorUITests:
    type: bundle.ui-testing
    platform: macOS
    deploymentTarget: "26.0"
    sources:
      - Tests/HarnessMonitorUITestSupport
      - Tests/HarnessMonitorUITests
    dependencies:
      - target: HarnessMonitorUITestHost

  HarnessMonitorAgentsE2ETests:
    type: bundle.ui-testing
    platform: macOS
    deploymentTarget: "26.0"
    sources:
      - Tests/HarnessMonitorUITestSupport
      - Tests/HarnessMonitorAgentsE2ETests
    dependencies:
      - target: HarnessMonitorUITestHost
    postBuildScripts:
      - name: Clear Gatekeeper Metadata
        basedOnDependencyAnalysis: false
        script: |
          if [ "${XCODE_RUNNING_FOR_PREVIEWS:-}" = "1" ] || [[ "${BUILD_DIR:-}" == *"/Previews/"* ]]; then
            exit 0
          fi

          strip_attrs() {
            local target_path="$1"
            if [ -e "$target_path" ]; then
              /usr/bin/xattr -dr com.apple.provenance "$target_path" 2>/dev/null || true
              /usr/bin/xattr -dr com.apple.quarantine "$target_path" 2>/dev/null || true
            fi
          }

          strip_attrs "$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"

          for runner in "$BUILT_PRODUCTS_DIR"/*-Runner.app; do
            if [ -e "$runner" ]; then
              strip_attrs "$runner"
            fi
          done
    settings:
      base:
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: Q498EB36N4
        PRODUCT_BUNDLE_IDENTIFIER: io.harnessmonitor.agents-e2e-tests
        TEST_TARGET_NAME: HarnessMonitorUITestHost
```

Add the scheme and task surfaces:

```yaml
  HarnessMonitorAgentsE2E:
    build:
      targets:
        HarnessMonitor: all
        HarnessMonitorKit: all
        HarnessMonitorUIPreviewable: all
    test:
      targets:
        - name: HarnessMonitorAgentsE2ETests
```

```toml
[tasks."monitor:macos:test:agents-e2e"]
description = "Run the explicit Harness Monitor Agents end-to-end UI lane"
run = "apps/harness-monitor-macos/Scripts/test-agents-e2e.sh"
```

Create the explicit script:

```bash
#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- \"$(dirname -- \"$0\")/..\" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- \"$ROOT/../..\" && pwd)"
DESTINATION="${XCODEBUILD_DESTINATION:-platform=macOS}"
DERIVED_DATA_PATH="${XCODEBUILD_DERIVED_DATA_PATH:-$REPO_ROOT/tmp/xcode-derived}"
XCODEBUILD_RUNNER="${XCODEBUILD_RUNNER:-$ROOT/Scripts/xcodebuild-with-lock.sh}"

\"$ROOT/Scripts/generate-project.sh\"
cargo build --bin harness

\"$XCODEBUILD_RUNNER\" \
  -project \"$ROOT/HarnessMonitor.xcodeproj\" \
  -scheme \"HarnessMonitorAgentsE2E\" \
  -destination \"$DESTINATION\" \
  -derivedDataPath \"$DERIVED_DATA_PATH\" \
  build-for-testing

\"$XCODEBUILD_RUNNER\" \
  -project \"$ROOT/HarnessMonitor.xcodeproj\" \
  -scheme \"HarnessMonitorAgentsE2E\" \
  -destination \"$DESTINATION\" \
  -derivedDataPath \"$DERIVED_DATA_PATH\" \
  test-without-building \
  -only-testing:HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests
```

Create the initial empty test shell:

```swift
import XCTest

@MainActor
final class HarnessMonitorAgentsE2ETests: HarnessMonitorUITestCase {}
```

- [ ] **Step 3: Regenerate the Xcode project and make the script executable**

Run:

```bash
apps/harness-monitor-macos/Scripts/generate-project.sh
chmod +x apps/harness-monitor-macos/Scripts/test-agents-e2e.sh
```

Expected:

- `project.pbxproj` is updated
- `HarnessMonitorAgentsE2E.xcscheme` exists under `xcshareddata/xcschemes/`

- [ ] **Step 4: Run the new explicit build lane and verify it is wired correctly**

Run:

```bash
mise run monitor:macos:test:agents-e2e
```

Expected:

- the task exists
- `cargo build --bin harness` succeeds
- Xcode builds the new target
- the test run executes the empty `HarnessMonitorAgentsE2ETests` class and finishes without touching the regular `HarnessMonitorUITests` bundle

- [ ] **Step 5: Commit the wiring phase**

Run:

```bash
git add .mise.toml \
  apps/harness-monitor-macos/project.yml \
  apps/harness-monitor-macos/HarnessMonitor.xcodeproj/project.pbxproj \
  apps/harness-monitor-macos/HarnessMonitor.xcodeproj/xcshareddata/xcschemes/HarnessMonitorAgentsE2E.xcscheme \
  apps/harness-monitor-macos/Scripts/test-agents-e2e.sh \
  apps/harness-monitor-macos/Tests/HarnessMonitorUITestSupport \
  apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests.swift
git commit -sS -m "test(monitor): add agents e2e target"
git show --show-signature --format=fuller --stat -1 HEAD
```

### Task 2: Add Explicit Live UI-Test Mode and the Live Process Harness

**Files:**
- Modify: `apps/harness-monitor-macos/Sources/HarnessMonitor/App/HarnessMonitorAppConfiguration.swift`
- Create: `apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ELiveHarness.swift`
- Create: `apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests+Support.swift`
- Modify: `apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests.swift`

- [ ] **Step 1: Write the failing terminal smoke test first**

Replace the empty test shell with:

```swift
import XCTest

@MainActor
final class HarnessMonitorAgentsE2ETests: HarnessMonitorUITestCase {
  func testTerminalAgentStartsShowsViewportAndStops() throws {
    let harness = try LiveAgentsHarness(label: "terminal-smoke")
    try harness.start()

    let app = launchAgentsLive(using: harness)
    openAgentsWindow(in: app)
    startTerminalAgent(in: app, runtimeTitle: "Codex", prompt: "Reply with exactly TERMINAL_E2E_OK")

    let viewport = element(in: app, identifier: HarnessMonitorUITestAccessibility.agentTuiViewport)
    let stopButton = element(in: app, identifier: HarnessMonitorUITestAccessibility.agentTuiStopButton)
    let state = element(in: app, identifier: HarnessMonitorUITestAccessibility.agentTuiState)

    XCTAssertTrue(waitForElement(viewport, timeout: 10))
    XCTAssertTrue(waitForElement(stopButton, timeout: 10))
    XCTAssertTrue(
      waitUntil(timeout: 10) {
        state.label.contains("status=running")
      }
    )

    tapButton(in: app, identifier: HarnessMonitorUITestAccessibility.agentTuiStopButton)

    XCTAssertTrue(
      waitUntil(timeout: 10) {
        state.label.contains("status=stopped")
          || state.label.contains("status=exited")
      }
    )
  }
}
```

- [ ] **Step 2: Run only the terminal smoke test and verify it fails**

Run:

```bash
apps/harness-monitor-macos/Scripts/xcodebuild-with-lock.sh \
  -project 'apps/harness-monitor-macos/HarnessMonitor.xcodeproj' \
  -scheme 'HarnessMonitorAgentsE2E' \
  -destination 'platform=macOS' \
  -derivedDataPath tmp/xcode-derived \
  test-without-building \
  -only-testing:HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests/testTerminalAgentStartsShowsViewportAndStops
```

Expected: FAIL because `LiveAgentsHarness`, `launchAgentsLive`, `openAgentsWindow`, and `startTerminalAgent` do not exist yet.

- [ ] **Step 3: Add an explicit live UI-test environment key and implement the live harness**

In `HarnessMonitorAppConfiguration.swift`, add an explicit environment flag so the new bundle does not rely on incidental launch-mode behavior:

```swift
private static let uiTestsLiveEnvironmentKey = "HARNESS_MONITOR_UI_TEST_LIVE"

private static func uiTestSafeEnvironment() -> HarnessMonitorEnvironment {
  let environment = HarnessMonitorEnvironment.current
  let isUITestHost = Bundle.main.bundleIdentifier == uiTestingBundleIdentifier
  let isUITesting = environment.values[uiTestsEnvironmentKey] == "1" || isUITestHost
  guard isUITesting else {
    return environment
  }

  var values = environment.values
  values[uiTestsEnvironmentKey] = "1"
  values[DaemonOwnership.environmentKey] = "0"

  let forceLiveUITesting = values[uiTestsLiveEnvironmentKey] == "1"
  if forceLiveUITesting {
    values[HarnessMonitorLaunchMode.environmentKey] = HarnessMonitorLaunchMode.live.rawValue
  } else if isUITestHost, isBlank(values[HarnessMonitorLaunchMode.environmentKey]) {
    values[HarnessMonitorLaunchMode.environmentKey] = HarnessMonitorLaunchMode.preview.rawValue
  }

  if isBlank(values[HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey]) {
    values[HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey] = defaultUITestDataHomePath(
      bundleIdentifier: Bundle.main.bundleIdentifier
    )
  }

  return HarnessMonitorEnvironment(values: values, homeDirectory: environment.homeDirectory)
}
```

Create the live harness with real daemon and bridge lifecycle:

```swift
import Foundation
import HarnessMonitorKit
import XCTest

struct LiveAgentsHarness {
  let root: URL
  let workspaceRoot: URL
  let daemonLog: URL
  let bridgeLog: URL
  let codexPort: Int
  private(set) var daemon: Process?
  private(set) var bridge: Process?

  init(label: String) throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("HarnessMonitorAgentsE2ETests", isDirectory: true)
      .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    self.root = base
    self.workspaceRoot = base.appendingPathComponent("workspace", isDirectory: true)
    self.daemonLog = base.appendingPathComponent("daemon.log")
    self.bridgeLog = base.appendingPathComponent("bridge.log")
    self.codexPort = try Self.reservePort()
  }

  mutating func start() throws {
    try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
    daemon = try Self.startProcess(
      arguments: ["./target/debug/harness", "daemon", "serve", "--sandboxed", "--host", "127.0.0.1", "--port", "0"],
      root: root,
      logURL: daemonLog
    )
    try Self.waitForDaemon(root: root)

    bridge = try Self.startProcess(
      arguments: ["./target/debug/harness", "bridge", "start", "--capability", "codex", "--capability", "agent-tui", "--codex-port", String(codexPort)],
      root: root,
      logURL: bridgeLog
    )
    try Self.waitForBridge(root: root)
  }
}
```

Create the live-mode UI helpers:

```swift
import XCTest

@MainActor
extension HarnessMonitorAgentsE2ETests {
  func launchAgentsLive(using harness: LiveAgentsHarness) -> XCUIApplication {
    launch(
      mode: "live",
      additionalEnvironment: [
        "HARNESS_MONITOR_UI_TEST_LIVE": "1",
        "HARNESS_DAEMON_DATA_HOME": harness.root.path,
      ]
    )
  }

  func openAgentsWindow(in app: XCUIApplication) {
    tapDockButton(in: app, identifier: HarnessMonitorUITestAccessibility.agentsButton, label: "agents")
    XCTAssertTrue(
      waitUntil(timeout: 10) {
        self.element(in: app, identifier: HarnessMonitorUITestAccessibility.agentTuiLaunchPane).exists
          || self.element(in: app, identifier: HarnessMonitorUITestAccessibility.agentTuiSessionPane).exists
      }
    )
  }

  func startTerminalAgent(in app: XCUIApplication, runtimeTitle: String, prompt: String) {
    tapButton(in: app, title: runtimeTitle)
    let promptField = editableField(in: app, identifier: HarnessMonitorUITestAccessibility.agentTuiPromptField)
    XCTAssertTrue(waitForElement(promptField, timeout: 5))
    promptField.tap()
    promptField.typeText(prompt)
    tapButton(in: app, identifier: HarnessMonitorUITestAccessibility.agentTuiStartButton)
  }
}
```

- [ ] **Step 4: Re-run the terminal smoke test and verify it passes**

Run the same `xcodebuild ... -only-testing:...testTerminalAgentStartsShowsViewportAndStops` command from Step 2.

Expected: PASS.

- [ ] **Step 5: Commit the live terminal harness phase**

Run:

```bash
git add \
  apps/harness-monitor-macos/Sources/HarnessMonitor/App/HarnessMonitorAppConfiguration.swift \
  apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ELiveHarness.swift \
  apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests+Support.swift \
  apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests.swift
git commit -sS -m "test(monitor): add live agents harness"
git show --show-signature --format=fuller --stat -1 HEAD
```

### Task 3: Add the Real Codex Steer E2E Proof

**Files:**
- Modify: `apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests.swift`
- Modify: `apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests+Support.swift`
- Modify: `apps/harness-monitor-macos/Tests/HarnessMonitorUITestSupport/HarnessMonitorUITestAccessibility.swift`

- [ ] **Step 1: Write the failing steer test first**

Add the second test:

```swift
func testCodexRunCanBeSteeredAndApprovalCanBeResolved() throws {
  let harness = try LiveAgentsHarness(label: "codex-smoke")
  try harness.start()

  let app = launchAgentsLive(using: harness)
  openAgentsWindow(in: app)

  startCodexRun(
    in: app,
    prompt: """
    First inspect the current directory contents in detail and keep working until you receive another instruction.
    Do not stop early.
    """,
    mode: "Report"
  )

  let contextField = editableField(in: app, identifier: HarnessMonitorUITestAccessibility.agentsCodexContextField)
  XCTAssertTrue(waitForElement(contextField, timeout: 15))
  contextField.tap()
  contextField.typeText("Reply with exactly AGENTS_E2E_STEER_OK and stop.")
  tapButton(in: app, identifier: HarnessMonitorUITestAccessibility.agentsCodexSteerButton)

  let state = element(in: app, identifier: HarnessMonitorUITestAccessibility.agentTuiState)
  XCTAssertTrue(
    waitUntil(timeout: 60) {
      state.label.contains("AGENTS_E2E_STEER_OK")
    }
  )
}
```

- [ ] **Step 2: Run only the Codex test and verify it fails**

Run:

```bash
apps/harness-monitor-macos/Scripts/xcodebuild-with-lock.sh \
  -project 'apps/harness-monitor-macos/HarnessMonitor.xcodeproj' \
  -scheme 'HarnessMonitorAgentsE2E' \
  -destination 'platform=macOS' \
  -derivedDataPath tmp/xcode-derived \
  test-without-building \
  -only-testing:HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests/testCodexRunCanBeSteeredAndApprovalCanBeResolved
```

Expected: FAIL because the live helpers do not yet drive the structured Codex controls end to end.

- [ ] **Step 3: Implement the structured Codex UI helpers**

Add the missing helpers:

```swift
@MainActor
extension HarnessMonitorAgentsE2ETests {
  func startCodexRun(in app: XCUIApplication, prompt: String, mode: String) {
    tapButton(in: app, title: "Codex")
    let promptField = editableField(in: app, identifier: HarnessMonitorUITestAccessibility.agentsCodexPromptField)
    XCTAssertTrue(waitForElement(promptField, timeout: 5))
    promptField.tap()
    promptField.typeText(prompt)
    selectSegmentedControlValue(
      in: app,
      controlIdentifier: HarnessMonitorUITestAccessibility.agentsCodexModePicker,
      value: mode
    )
    tapButton(in: app, identifier: HarnessMonitorUITestAccessibility.agentsCodexSubmitButton)
  }
}
```

Update `HarnessMonitorUITestAccessibility.swift` so the shared support includes the unified `Agents` entry identifier used by live and preview tests:

```swift
static let agentsButton = "harness.session.agents"
```

- [ ] **Step 4: Re-run the Codex steer test and verify it passes**

Run the same `xcodebuild ... -only-testing:...testCodexRunCanBeSteeredAndApprovalCanBeResolved` command from Step 2.

Expected: PASS with the deterministic `AGENTS_E2E_STEER_OK` marker visible in the live run state.

- [ ] **Step 5: Commit the steer phase**

Run:

```bash
git add \
  apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests.swift \
  apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests+Support.swift \
  apps/harness-monitor-macos/Tests/HarnessMonitorUITestSupport/HarnessMonitorUITestAccessibility.swift
git commit -sS -m "test(monitor): cover codex steer e2e"
git show --show-signature --format=fuller --stat -1 HEAD
```

### Task 4: Add Approval Resolution and Real Database Assertions

**Files:**
- Modify: `apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests.swift`
- Modify: `apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ELiveHarness.swift`
- Modify: `apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests+Support.swift`

- [ ] **Step 1: Extend the Codex test with failing approval and database assertions**

Extend `testCodexRunCanBeSteeredAndApprovalCanBeResolved` with:

```swift
  startCodexRun(
    in: app,
    prompt: """
    Run exactly this command and stop after approvals are resolved:
    printf 'APPROVED_E2E_OK' > \(harness.workspaceRoot.path)/approved-e2e.txt
    """,
    mode: "Approval"
  )

  let approvalButton = element(
    in: app,
    identifier: HarnessMonitorUITestAccessibility.codexApprovalButton("accept")
  )
  XCTAssertTrue(waitForElement(approvalButton, timeout: 30))
  tapElement(in: app, identifier: HarnessMonitorUITestAccessibility.codexApprovalButton("accept"))

  XCTAssertTrue(
    waitUntil(timeout: 60) {
      FileManager.default.fileExists(atPath: harness.workspaceRoot.appendingPathComponent("approved-e2e.txt").path)
    }
  )

  let daemonDatabase = harness.root.appendingPathComponent("harness/daemon/harness.db")
  let appDatabase = harness.root.appendingPathComponent("harness/harness-cache.store")
  XCTAssertTrue(FileManager.default.fileExists(atPath: daemonDatabase.path))
  XCTAssertTrue(FileManager.default.fileExists(atPath: appDatabase.path))
  XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: daemonDatabase.path)[.size] as? NSNumber ?? 0, 0)
  XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: appDatabase.path)[.size] as? NSNumber ?? 0, 0)
```

- [ ] **Step 2: Run the Codex test again and verify it fails on the new assertions**

Run the same `xcodebuild ... -only-testing:...testCodexRunCanBeSteeredAndApprovalCanBeResolved` command.

Expected: FAIL because approval handling, file verification, or DB-path assertions are not complete yet.

- [ ] **Step 3: Implement approval helpers and preserve failure logs**

Add explicit helpers and diagnostics:

```swift
extension LiveAgentsHarness {
  func approvalFileURL() -> URL {
    workspaceRoot.appendingPathComponent("approved-e2e.txt")
  }

  func diagnosticsSummary() -> String {
    [
      "root=\(root.path)",
      "workspace=\(workspaceRoot.path)",
      "daemonLog=\(daemonLog.path)",
      "bridgeLog=\(bridgeLog.path)",
    ].joined(separator: "\n")
  }
}

@MainActor
extension HarnessMonitorAgentsE2ETests {
  func acceptFirstApproval(in app: XCUIApplication) {
    tapElement(in: app, identifier: HarnessMonitorUITestAccessibility.codexApprovalButton("accept"))
  }
}
```

Make teardown preserve the isolated root on failure and include `diagnosticsSummary()` in assertion messages instead of deleting the evidence unconditionally.

- [ ] **Step 4: Re-run the Codex test and verify it passes end to end**

Run the same `xcodebuild ... -only-testing:...testCodexRunCanBeSteeredAndApprovalCanBeResolved` command.

Expected: PASS with:

- steer marker observed
- approval surfaced and accepted in the UI
- `approved-e2e.txt` created with `APPROVED_E2E_OK`
- both isolated databases present and non-empty

- [ ] **Step 5: Commit the approval and database phase**

Run:

```bash
git add \
  apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests.swift \
  apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ELiveHarness.swift \
  apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/HarnessMonitorAgentsE2ETests+Support.swift
git commit -sS -m "test(monitor): cover codex approvals e2e"
git show --show-signature --format=fuller --stat -1 HEAD
```

### Task 5: Document the Lane, Bump the Version, and Run Final Validation

**Files:**
- Modify: `apps/harness-monitor-macos/README.md`
- Modify: `apps/harness-monitor-macos/CLAUDE.md`
- Modify via script: `Cargo.toml`
- Modify via script: `Cargo.lock`
- Modify via script: `testkit/Cargo.toml`
- Modify via script: `apps/harness-monitor-macos/project.yml`
- Modify via script: `apps/harness-monitor-macos/HarnessMonitor.xcodeproj/project.pbxproj`
- Modify via script: `apps/harness-monitor-macos/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist`

- [ ] **Step 1: Write the docs updates first**

Update the monitor docs with an explicit-only lane section:

```md
### Agents end-to-end lane

Run this lane only when you want the real live `Agents` UI flow against a real isolated daemon root:

```bash
mise run monitor:macos:test:agents-e2e
```

This lane is separate from `monitor:macos:test`.
It uses the `Harness Monitor UI Testing` host, a real isolated `HARNESS_DAEMON_DATA_HOME`, a real sandboxed-style daemon, and the real unified bridge.
```

- [ ] **Step 2: Bump the version as a patch**

Run:

```bash
./scripts/version.sh set 26.0.1
```

Expected: versioned surfaces are updated in place, including the generated monitor metadata.

- [ ] **Step 3: Run the focused validation stack**

Run:

```bash
mise run check
cargo test --lib app::cli::tests::snapshot_cli_help_text -- --exact
apps/harness-monitor-macos/Scripts/xcodebuild-with-lock.sh \
  -project 'apps/harness-monitor-macos/HarnessMonitor.xcodeproj' \
  -scheme 'HarnessMonitor' \
  -configuration Debug \
  -derivedDataPath tmp/xcode-derived \
  test \
  -destination 'platform=macOS' \
  -skip-testing:HarnessMonitorUITests \
  -skip-testing:HarnessMonitorAgentsE2ETests
mise run monitor:macos:test:agents-e2e
```

Expected:

- repo checks pass
- non-UI monitor lane stays green without running either UI bundle
- the explicit e2e lane passes independently

- [ ] **Step 4: Commit docs, version bump, and final validation**

Run:

```bash
git add \
  Cargo.toml \
  Cargo.lock \
  testkit/Cargo.toml \
  apps/harness-monitor-macos/project.yml \
  apps/harness-monitor-macos/HarnessMonitor.xcodeproj/project.pbxproj \
  apps/harness-monitor-macos/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist \
  apps/harness-monitor-macos/README.md \
  apps/harness-monitor-macos/CLAUDE.md
git commit -sS -m "test(monitor): add agents e2e lane"
git show --show-signature --format=fuller --stat -1 HEAD
```

## Self-review checklist

- Spec coverage:
  - separate explicit target and scheme: Task 1
  - real isolated daemon root and databases: Tasks 2 and 4
  - real sandboxed-style daemon plus real bridge: Task 2
  - terminal-backed `Agents` smoke: Task 2
  - Codex steer and approval smoke: Tasks 3 and 4
  - explicit script and `mise` gating: Task 1
  - docs and version bump: Task 5
- Placeholder scan:
  - no `TODO`, `TBD`, or deferred “handle later” language remains in the task steps
  - each task has explicit files, code snippets, commands, and commit steps
- Type consistency:
  - the explicit env key is consistently `HARNESS_MONITOR_UI_TEST_LIVE`
  - the explicit target name is consistently `HarnessMonitorAgentsE2ETests`
  - the explicit scheme name is consistently `HarnessMonitorAgentsE2E`

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-19-monitor-agents-e2e.md`.

Per your earlier instruction, the recommended execution mode is already decided: subagent-driven execution with parallel mini-model explorers/workers where the write sets stay disjoint, while the main rollout remains responsible for validation and every signed commit.
