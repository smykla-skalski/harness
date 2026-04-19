# Monitor Agents E2E Design

## Problem statement

Harness now exposes terminal-backed agents and Codex threads as one unified `Agents` feature, but the current monitor validation stack does not prove that feature end to end in the real macOS UI against the real daemon, the real host bridge, and real on-disk databases.

The existing `HarnessMonitorUITests` bundle is optimized for fast preview-driven UI regressions.
That bundle is the wrong place for a live daemon-plus-bridge proof because:

- the shared UI-test bootstrap currently forces preview-safe behavior
- the regular monitor test lane intentionally skips UI tests by default
- the normal UI target should stay focused on narrow UI regressions, not runtime orchestration

The goal of this design is to add one explicit, fast, production-shaped UI e2e lane that proves the unified `Agents` feature through the real stack without polluting the regular monitor test suite.

## Desired outcome

Add an explicit opt-in monitor e2e lane that:

- launches the isolated `Harness Monitor UI Testing` host
- uses a real isolated daemon data root and real databases
- starts a real sandboxed-style daemon and a real unified bridge
- proves both unified `Agents` runtime families in the macOS UI:
  - terminal-backed agent flow
  - Codex flow with steer and approval resolution
- stays out of the normal `monitor:macos:test` lane and out of broad default UI runs
- remains fast enough to run as a focused confidence lane rather than a long smoke suite

## Scope

### In scope

- a new explicit-only monitor UI e2e target and scheme
- a new script and `mise` task for the explicit lane
- a live-mode UI test harness that starts and stops real daemon and bridge processes
- one isolated per-run `HARNESS_DAEMON_DATA_HOME`
- validation that the daemon SQLite database and monitor SwiftData cache are both real and isolated
- one terminal-agent e2e smoke test
- one Codex e2e smoke test that proves both steer and approval behavior
- failure diagnostics that preserve daemon and bridge logs under the isolated root

### Out of scope

- widening the default `HarnessMonitor` UI suite
- moving normal preview-based UI regressions into the new lane
- replacing the existing preview-driven UI tests
- broad monitor workflows outside the unified `Agents` feature
- new product behavior in the daemon, bridge, or monitor outside what is required to make the e2e lane possible and reliable

## Design constraints

- The lane must not run from `mise run monitor:macos:test`.
- The lane must require explicit invocation.
- The lane must use the isolated UI-testing host `io.harnessmonitor.app.ui-testing`.
- The lane must use the shared `tmp/xcode-derived` path and the lock-aware wrapper.
- The lane must not rely on fake preview bridge state.
- The lane must not touch the developer's normal daemon root, app-group data, or SwiftData store.
- The lane must avoid arbitrary sleeps as the primary readiness mechanism.
- The lane must stay small: two tests only.

## Chosen approach

### Summary

Create a separate UI-test target and scheme dedicated to live `Agents` e2e validation.
That target will share the same isolated UI-test host model as the current UI suite, but it will use a new live-mode test harness instead of the current preview-only harness rules.

This is the strongest long-term boundary because the e2e tests are excluded structurally, not merely skipped at runtime.
The normal UI suite remains stable and fast, while the explicit e2e lane gets the freedom to boot real subprocesses and wait on real daemon state.

### Why this approach

This approach is preferred over env-gated tests inside the existing `HarnessMonitorUITests` bundle because:

- it prevents accidental inclusion in regular UI runs
- it keeps the purpose of each target clear
- it matches the repo's current use of separate schemes for separate runtime modes
- it scales better if later `Agents` e2e coverage needs one or two more focused scenarios

This approach is preferred over a shell-heavy harness with only a thin XCTest wrapper because:

- the assertions still live where UI correctness belongs
- test failures stay attached to XCTest output and xcresult bundles
- UI lifecycle, accessibility lookup, and teardown remain inside one testing model

## Test topology

### New test target

Add a new UI-test target:

- `HarnessMonitorAgentsE2ETests`

Properties:

- uses the existing `HarnessMonitorUITestHost`
- runs with the isolated UI-testing bundle identifier
- compiles only the new e2e test files and shared support files required for live-mode orchestration

### New scheme

Add a new shared scheme:

- `HarnessMonitorAgentsE2E`

Properties:

- includes `HarnessMonitor`, `HarnessMonitorKit`, `HarnessMonitorUIPreviewable`, and the new `HarnessMonitorAgentsE2ETests` target
- does not include the existing `HarnessMonitorUITests` bundle
- supports focused `xcodebuild test-without-building` invocation for the e2e lane only

### New explicit run surfaces

Add:

- `apps/harness-monitor-macos/Scripts/test-agents-e2e.sh`
- `mise run monitor:macos:test:agents-e2e`

The script is the canonical entrypoint for the lane.
It will:

- build the repo-local debug `harness` binary before invoking Xcode so the live e2e harness never uses a stale installed binary
- regenerate the project
- build for testing through the lock-aware wrapper
- execute only the new e2e scheme
- keep artifacts in `tmp/xcode-derived`

## Runtime model

### Isolated storage

Each test run gets one isolated root under `FileManager.default.temporaryDirectory`.
That root is the only storage root for:

- daemon manifest
- daemon auth token
- daemon SQLite database
- bridge state
- monitor SwiftData store
- runtime logs
- test-created workspace content

The harness sets:

- `HARNESS_DAEMON_DATA_HOME=<isolated root>`

The lane must later assert that at least these files exist and are non-empty:

- `<root>/harness/daemon/harness.db`
- `<root>/harness/harness-cache.store`

### Real daemon

The live e2e harness starts:

```text
./target/debug/harness daemon serve --sandboxed --host 127.0.0.1 --port 0
```

The daemon inherits the isolated `HARNESS_DAEMON_DATA_HOME`.

Using `daemon serve --sandboxed` instead of preview or external-dev mode is intentional.
The monitor e2e lane must exercise the same sandboxed-style host-bridge path that the shipping monitor depends on for unified `Agents`.

### Real bridge

The live e2e harness starts:

```text
./target/debug/harness bridge start --capability codex --capability agent-tui --codex-port <allocated-free-port>
```

The bridge inherits the same isolated `HARNESS_DAEMON_DATA_HOME`.
The `allocated-free-port` value is reserved by the test harness immediately before bridge startup through a dedicated free-port helper.

This guarantees:

- the bridge publishes state into the same isolated daemon root
- the sandboxed daemon sees the real bridge capability manifest
- the monitor UI reflects the actual host-bridge readiness state instead of preview overrides

### Monitor app mode

The new e2e harness launches the UI host in live mode, not preview mode.
That requires a dedicated live UI-test bootstrap path because the current UI-test bootstrap intentionally normalizes UI runs to preview-safe behavior.

The live e2e bootstrap must:

- preserve `HARNESS_MONITOR_UI_TESTS=1`
- preserve `-ApplePersistenceIgnoreState YES`
- preserve isolated `HARNESS_DAEMON_DATA_HOME`
- set `HARNESS_MONITOR_LAUNCH_MODE=live`
- avoid the current forced external-daemon suppression path for this lane
- connect through the real manifest and live daemon bootstrap path

The live e2e lane does not use `HARNESS_MONITOR_EXTERNAL_DAEMON=1`.
That mode is for unsandboxed developer flows and bypasses the bridge path that this e2e lane is supposed to prove.

## Readiness model

Readiness must be event-driven and state-driven.
The lane must not depend on large fixed sleeps.

### Daemon readiness

The harness waits until:

- the isolated manifest file exists
- the manifest contains a live endpoint
- authenticated daemon health succeeds

### Bridge readiness

The harness waits until bridge status under the isolated root reports:

- running = true
- `codex` capability healthy
- `agent-tui` capability healthy

### UI readiness

The app is considered ready only after:

- the UI-test host is foregrounded
- the main window exists with non-zero frame
- the monitor has connected to the live daemon
- the `Agents` dock or entry affordance is visible

## Test cases

The lane contains exactly two end-to-end tests.

### 1. Terminal agent smoke

Name:

- `testTerminalAgentStartsShowsViewportAndStops`

Flow:

1. launch the monitor in live UI-test mode against the isolated root
2. open the unified `Agents` window
3. start one terminal-backed agent
4. wait for a real session row, live viewport, and terminal controls
5. verify the agent can be stopped cleanly
6. verify the final state reflects termination

Assertions:

- no bridge recovery banner is shown for terminal agents
- a real agent session appears in the sidebar
- the viewport is present and sized
- stop transitions the session out of active state

This is the minimum proof that the unified bridge-backed terminal flow works through the real UI.

### 2. Codex smoke with steer and approval

Name:

- `testCodexRunCanBeSteeredAndApprovalCanBeResolved`

This test proves two critical Codex behaviors in one focused flow while keeping runtime small.

#### Phase A: steer

1. launch the monitor in live UI-test mode against the isolated root
2. open the unified `Agents` window
3. start a real Codex run in report mode with a prompt designed to stay active long enough for same-turn steering
4. wait until the run is active and the session pane exposes Codex controls
5. send steer text through the UI
6. wait for completion and assert the deterministic steer marker appears in the final run summary

The steer prompt must be intentionally deterministic and same-turn safe.
The lane should not use a tiny one-shot prompt that can finish before steering reaches the daemon.

#### Phase B: approval

1. start a second real Codex run in approval mode against a test-owned workspace under the isolated root
2. use a deterministic command that requires approval and creates a known file
3. wait for a visible approval control in the UI
4. accept the approval in the UI
5. wait for completion
6. assert that the expected file exists on disk in the isolated workspace

Assertions:

- no Codex recovery banner is shown when the bridge is healthy
- steer succeeds through the UI and changes the final outcome
- approval is surfaced in the UI rather than bypassed
- accepting the approval produces the expected file-system effect

## Determinism strategy

### Terminal path

The terminal-agent test should use the smallest command or runtime path that still yields a stable viewport quickly.
It should not depend on long-running random shell behavior.

### Codex path

The Codex prompts must use deterministic markers and isolated paths under the test root.
The test must assert specific expected markers, not approximate prose.

The approval prompt should create a file such as:

- `<root>/workspace/approved-e2e.txt`

with exact content:

- `APPROVED_E2E_OK`

The steer prompt should converge to a deterministic terminal marker such as:

- `AGENTS_E2E_STEER_OK`

These markers are normative for the lane and must remain machine-verifiable.

## Support code boundaries

### New live e2e support layer

Add a dedicated support file or small support cluster for:

- isolated root creation
- child-process lifecycle management
- daemon readiness polling
- bridge readiness polling
- live app launch helpers
- failure-log capture

This support must be separate from the preview-specific helpers so the preview UI suite does not inherit live-process complexity.

### Shared UI query reuse

The new e2e target should reuse existing accessibility identifiers and narrow UI interaction helpers whenever possible.
Do not duplicate query logic that already exists and is generic.

### Minimal app changes

Any product code changes required for this lane must be infrastructure-grade, not test-only hacks.
Expected acceptable changes include:

- allowing a live UI-test bootstrap path in addition to the preview-safe bootstrap
- exposing stable accessibility hooks for already-visible `Agents` controls
- tightening reconnect or state markers if current signals are not precise enough

Unacceptable changes include:

- preview-only bypasses in the live path
- disabling real daemon or bridge behavior for the e2e lane
- hidden product shortcuts that exist only to satisfy the test

## Failure diagnostics

On failure, the lane must preserve enough evidence to debug without rerunning blindly.

The isolated root should retain:

- daemon stdout/stderr log files
- bridge stdout/stderr log files
- created workspace files
- manifest and bridge state files

The XCTest failure messages should include:

- the isolated root path
- the last known daemon endpoint
- the last known bridge capability state
- any expected file paths or markers that were missing

## Validation contract

### Default monitor lane

The existing default monitor lanes remain:

- `mise run monitor:macos:lint`
- `mise run monitor:macos:test`

They must not start running the new e2e target.

### Explicit e2e lane

The new lane is invoked separately, for example:

```bash
mise run monitor:macos:test:agents-e2e
```

That task should internally use the lock-aware wrapper and a focused Xcode invocation against the dedicated e2e scheme.

## Versioning assessment

This change is a patch-level version bump.

Reasoning:

- it adds validation infrastructure
- it does not add a new shipped user-facing command contract
- it does not change the daemon or monitor external behavior promised to users

The implementation phase must therefore bump the repo version as a patch in the same change that lands the feature.

## Risks and mitigations

### Risk: live UI-test flakiness

Mitigation:

- drive readiness from real manifest and bridge state
- boot daemon and bridge once per test bundle where possible
- keep the lane to two tests only

### Risk: Codex steer races short runs

Mitigation:

- use a prompt that guarantees an active turn window before steering
- assert same-turn steering through explicit status and final marker changes

### Risk: contamination of developer data

Mitigation:

- require one isolated `HARNESS_DAEMON_DATA_HOME`
- create all workspace files under the isolated root
- never fall back to the developer app-group or home-directory paths

### Risk: accidental inclusion in routine test runs

Mitigation:

- separate target
- separate scheme
- separate script
- separate `mise` task

## Acceptance criteria

The design is complete when the implementation can satisfy all of the following:

1. `mise run monitor:macos:test` does not execute the new e2e lane.
2. `mise run monitor:macos:test:agents-e2e` runs only the dedicated `Agents` e2e target.
3. The lane uses a real isolated daemon root and leaves the developer's normal data untouched.
4. The lane starts a real sandboxed-style daemon and a real unified bridge.
5. The terminal-agent smoke test passes through the real UI.
6. The Codex smoke test proves steer and approval through the real UI.
7. The lane asserts the existence of the real isolated daemon and monitor databases.
8. Failures preserve enough logs and paths to diagnose the issue directly.
