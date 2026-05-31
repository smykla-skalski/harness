# Copilot instructions for `harness`

## Command execution

- `rtk` must not be used in Copilot sessions for this repository; run commands directly.
- Prefer `mise run <task>` over raw `cargo`, `xcodebuild`, or repo scripts. When there is no dedicated task, use `mise run cargo:local -- <cargo args>`.
- Use `mise tasks ls` to discover supported workflows.
- Parallel Copilot/user sessions that edit, generate, build, test, run daemons, or use XcodeBuildMCP must use separate full git worktrees. Lanes isolate build/runtime side effects inside a worktree; they are not a substitute for a separate checkout.
- Assign one custom worktree and one build/test/runtime lane to the whole Copilot session, not to each task. Reuse them across the session so caches stay warm and cleanup stays predictable.
- After every commit in that session worktree, rebase the worktree branch onto current local `main`, resolve conflicts inside the worktree first, make sure the change builds or passes the smallest relevant validation in the worktree only for affected surfaces, and replay only the finished task commit into `main`. Helper scripts, docs, and files outside an app/codebase do not require app builds or unrelated gates. Do not replay dirty files. Do not clean up the session worktree or lane after each task; keep them until the session ends or the user explicitly asks for cleanup. This is a hard rule.

## Build, test, and lint commands

### Harness CLI and `aff`

```bash
mise run check
mise run harness:check
mise run aff:check
mise run test
mise run test:unit
mise run test:integration
mise run test:slow
mise run aff:test
mise run lint:fix
mise run install
mise run check:agent-assets
mise run setup:agents:generate
mise run setup:bootstrap
```

Single-test patterns:

```bash
mise run cargo:local -- test --quiet --lib cli::tests
mise run cargo:local -- test --quiet --lib errors::tests::cli_err_basic_fields -- --exact
mise run cargo:local -- test --quiet --test integration integration::hooks::guard_bash::guard_bash_payloads -- --exact --test-threads=1
```

- Unit tests live next to the code in `src/**`.
- Integration tests live under `tests/integration/`, but the target is `tests/integration.rs`.
- Integration tests intentionally run single-threaded because they use real filesystem and environment state.
- XDG-sensitive tests should isolate `XDG_DATA_HOME` and the active session env var via `temp_env::with_vars`.
- Slow tests are `#[ignore]` and run through `mise run test:slow`.

### Harness Monitor macOS

```bash
mise run monitor:generate
mise run monitor:lint
mise run monitor:quality-gate
mise run monitor:build
mise run monitor:test
mise run monitor:test:scripts
mise run monitor:audit -- --label baseline
```

Focused examples:

```bash
XCODE_ONLY_TESTING=HarnessMonitorKitTests/PolicyGapRuleTests \
  mise run monitor:test

XCODE_ONLY_TESTING=HarnessMonitorUITests/HarnessMonitorUITests/testToolbarOpensSettingsWindow \
  mise run monitor:test

HARNESS_MONITOR_BUILD_LANE=copilot-<uuid> XCODE_ONLY_TESTING=HarnessMonitorKitTests/PolicyGapRuleTests \
  mise run monitor:test

# Batch many focused selectors into one call - chaining N calls forces N
# build-for-testing cold starts. Comma-separated selectors are supported.
HARNESS_MONITOR_BUILD_LANE=copilot-<uuid> XCODE_ONLY_TESTING='HarnessMonitorKitTests/A/test1(),HarnessMonitorKitTests/A/test2()' \
  mise run monitor:test

HARNESS_MONITOR_BUILD_LANE=copilot-<uuid> mise run monitor:build

HARNESS_MONITOR_RUNTIME_LANE=copilot-<uuid> \
  mise run monitor:xcodebuildmcp -- macos build --scheme HarnessMonitor

mise run monitor:xcodebuild -- \
  -workspace apps/harness-monitor/HarnessMonitor.xcworkspace \
  -scheme HarnessMonitor \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m),name=My Mac" \
  build CODE_SIGNING_ALLOWED=NO
```

- `apps/harness-monitor/HarnessMonitor.xcodeproj` and `.xcworkspace` are generated, ignored outputs from Tuist. Regenerate them with `mise run monitor:generate`.
- Do not run the full `HarnessMonitorUITests` suite by default. Prefer `XCODE_ONLY_TESTING` with the smallest possible selector.
- When UI tests are failing, run one failing test at a time. Never run multiple failing tests together — XCUITest runs block the whole machine and the run time compounds fast. Fix one, verify it passes, then move to the next.
- In each parallel worktree, set explicit lanes for agent-driven work. Use `HARNESS_MONITOR_BUILD_LANE=copilot-<uuid>` for DerivedData isolation and `HARNESS_MONITOR_RUNTIME_LANE=copilot-<uuid>` for daemon, bridge, launchd label, port, and XcodeBuildMCP socket isolation. Do not rely on removed per-agent task aliases or profile env vars.
- For custom macOS lanes, never use bare `-destination 'platform=macOS'`; use `platform=macOS,arch=$(uname -m),name=My Mac`.
- `monitor:test` defaults to skipping `build-for-testing` when the existing `.xctestrun` is fresher than every Swift source, project descriptor, SPM lockfile, and the cross-project `mcp-servers/` tree. Break-glass: set `HARNESS_MONITOR_FORCE_BUILD_FOR_TESTING=1` to always rebuild (use after .xcconfig edits, environment switches, or external package updates outside the scoped freshness roots).
- Named build lanes write to `xcode-derived-lanes/<lane>`; runtime lanes write to the app-group `runtime-lanes/<lane>` tree. Delete stale lane directories only after confirming no process is using that lane. Use `mise run clean:stale` for safe orphan cleanup and `mise run monitor:reset` only when resetting the active runtime lane is intended.
- Legacy profile env vars such as `HARNESS_MONITOR_RUNTIME_PROFILE`, `HARNESS_MONITOR_USER_RUNTIME_PROFILE`, and the old agent-profile overrides are intentionally rejected.

## High-level architecture

- `src/main.rs` is intentionally thin: it initializes tracing and delegates to `crate::app::cli`.
- `src/app/` is the transport/router layer. Clap commands dispatch into domain roots for `run`, `create`, `setup`, `agents`, `observe`, `session`, `daemon`, `bridge`, `mcp`, and hook entrypoints.
- The main domain roots are:
  - `src/run/` - tracked suite execution: run context/layout, prepared suite specs, workflow state, diagnostics, repair, and reporting
  - `src/create/` - suite authoring and approval workflow
  - `src/setup/` - bootstrap, capabilities, cluster setup, and session lifecycle helpers
  - `src/hooks/` - tool-guard / tool-result lifecycle, policy, and hook protocol normalization
  - `src/agents/` - shared agent lifecycle, runtime adapters, signal delivery, transcript parsing, and asset rendering from `agents/`
  - `src/session/` - multi-agent orchestration: roles, permissions, work items, and observer-driven issue creation
  - `src/observe/` - session-log scanning, classification, and fix routing
  - `src/daemon/` and `src/mcp/` - Harness Monitor daemon, bridge flows, and the MCP control surface
- Shared support roots:
  - `src/workspace/` resolves XDG state, project/session context, and current-run pointers
  - `src/kernel/` holds pure shared concepts
  - `src/infra/` holds generic side effects such as execution, persistence, env, and HTTP
  - `src/errors/` holds typed error families and rendering
  - `src/platform/` is internal adapter code, not a stable public API
- `agents/` is the canonical source for shared skills and plugins. `.claude/`, `.agents/`, `.gemini/`, `.opencode/`, `.github/hooks/`, and `plugins/` are generated outputs, not source.
- The Rust MCP server lives under `src/mcp/`; the app-side registry host it talks to lives under `mcp-servers/harness-monitor-registry/`.
- The usual product flow is `setup` -> `create` -> `run` -> `observe` -> `session`.
- Important state lives under the harness data root (`$XDG_DATA_HOME/harness` on XDG systems, with a macOS app-group/Application Support fallback): suites under `suites/`, session context under `contexts/`, and project-scoped orchestration under `projects/project-<digest>/`.

## Key conventions

- Treat harness as workflow-first, not shell-first. Direct `kubectl`, `kubectl-validate`, `kumactl`, `helm`, `docker`, and `k3d` use is intentionally blocked; use `harness` commands that persist state and audit trail.
- Do not hand-edit generated roots or harness-managed control files. That includes `.claude/`, `.agents/`, `.github/hooks/`, `plugins/`, and workflow state/report artifacts such as run state JSON and command logs.
- `VersionedJsonRepository` is the expected persistence layer for workflow and session state. Schema versions are enforced and writes are atomic.
- Suite specs are strict Markdown + YAML contracts:
  - `suite.md` frontmatter must include `suite_id`, `feature`, `scope`, and `keep_clusters`
  - group files must include YAML frontmatter plus `## Configure`, `## Consume`, and `## Debug` sections
- In `create`, writes are allowed only under `suite.md`, `groups/**`, and `baseline/**`, and only during the `writing` phase unless bypass mode is active.
- Use `tracing` macros for diagnostics. Keep `println!` for user-facing CLI output and hook JSON protocol; do not add new diagnostic `eprintln!`.
- Clippy is strict (`pedantic` plus extra denies), and `build.rs` makes `cargo clippy --lib` fail when tracked Rust files under `src/`, `tests/`, or `testkit/` exceed 520 lines.
- Evaluate semver whenever shipped behavior changes. `Cargo.toml` is the canonical version source; use `mise run version:set -- <version>` and `mise run version:sync` to update derived surfaces.
- Commit and PR titles should follow `type(scope): description`.
- Every commit must be signed and signed-off: `git commit -sS` with the trailer `Signed-off-by: Bart Smykla <bartek@smykla.com>`. Never bypass signing (`--no-gpg-sign`, `--no-verify`).
- Commit with explicit paths passed directly to `git commit`: `git commit -sS -- <paths>`. Git stages exactly the listed paths for this commit and leaves the rest of the index and working tree alone. For brand-new files, first run `git add -N -- <new-paths>` so Git can see them, then include those paths in the same path-limited commit. Do not pre-stage with plain `git add`, and never use `git add -A`, `git add .`, `git commit -a`, or `git commit -i`. Parallel Copilot/agent sessions routinely leave unrelated edits in the working tree; path-limited commits keep them out of the signed history. Run `git diff -- <paths>` before committing to confirm the per-file scope.
- Finished tasks must be integrated through `main` with clean, flat history. Rebase or cherry-pick; never create merge commits. The no-rebase/no-amend/no-force-push restriction applies when working directly in local `main`. In an assigned session worktree, rebase onto local `main` and amend only your own unpublished commits when needed to keep the branch easy to replay; never rewrite local `main` history or force-push shared branches. Resolve conflicts in the assigned worktree after each commit, keep unrelated edits out of conflict resolution, make sure the change builds or passes the smallest relevant validation in the worktree before replay only for affected surfaces, replay only committed worktree state, and keep the session worktree/lane until the session ends or the user asks for cleanup. After replay onto `main`, do not rerun builds or checks there just because of the replay; continue unless the user asks for more validation or a new affected surface appears. Helper scripts, docs, and files outside an app/codebase do not require app builds or unrelated gates.
- For Harness Monitor SwiftUI work, prefer existing shared layout/control primitives and existing UI-test helpers instead of inventing one-off patterns.
- For Harness Monitor, real user-triggered work must be offloaded from the main thread through the global generic `HarnessMonitorAsyncWorkQueue.shared`. Submit `WorkItem`s instead of awaiting network mutations, policy actions, approvals, filesystem work, or daemon calls directly in SwiftUI handlers. Do not add per-action or per-feature queues; the shared queue scales workers to the active CPU count and UI state/toasts should update only after hopping back to the MainActor.
- If a macOS UI test cannot find or tap a control that looks correct, fix the test query/interaction path before changing product UI.
- Do not put `.accessibilityIdentifier(...)` on container views that wrap interactive children with their own identifiers or frame markers. Keep identifiers on the controls and use container probes instead.
- Do not allocate formatters or encoders in SwiftUI view bodies; cache them instead.
- Liquid Glass belongs on navigation/control surfaces, not content, and should not be stacked on top of other glass.

## Debugging discipline

- Start with real data. Reproduce with the smallest targeted command and preserve logs, traces, screenshots, or failure artifacts before changing code.
- If the signal path is weak (for example bare `XCTAssertTrue`, missing preserved traces, or ambiguous failures), improve observability or the failing test first.
- Correlate failures across layers before patching: UI-test host trace, app/daemon trace, and the emitting source path.
- Reuse known-good fixtures, preview scenarios, and launch helpers instead of inventing new harnesses.
- Do not trust scenario names or assumed mounted UI; confirm the actual rendered surface (`dashboard` vs `cockpit`) and patch the proven cause only.
- Avoid infer -> patch -> rerun loops. Prefer one hypothesis, one instrumentation or code change, and one narrow rerun.
- For day-to-day Harness Monitor development, the external daemon path (`harness daemon dev`) is the normal debug lane. Use the managed `HarnessMonitor` scheme when you need to validate the shipping sandboxed path.
- For performance regressions, use targeted perf tests through `XCODE_ONLY_TESTING=HarnessMonitorUITests/HarnessMonitorPerfTests/... mise run monitor:test` and the deeper Instruments pipeline through `mise run monitor:audit`.
- For Swift-only verification when the working tree carries dirty Rust changes from parallel agents, build with the `HarnessMonitor (External Daemon)` scheme; the default `HarnessMonitor` scheme runs a `Build harness daemon (parallel)` script phase that fails on broken Rust.
- When preview and live app disagree, first prove whether they share the same rendering and measurement path. If preview is synchronous or fixture-driven while live is incremental/AppKit-backed, debug the live path first instead of spending cycles polishing preview parity.
- Before changing spacing, padding, or borders, verify that live row measurement receives the real environment inputs (`fontScale`, current width, cache state) and add a coordinator-level regression for that wiring. A passing leaf measurement helper test is not enough if callers can still pass stale/default values.
- Separate viewport/container bugs from row-content sizing bugs early. A clipped first row at `Latest` can be a top-edge inset/scroll issue even when lower-row gaps come from bad height measurement; do not mix those hypotheses into one patch loop.
- When `monitor:test` fails, read the generated `swift-diagnostics`/xcodebuild failure report first and only fall back to raw tee logs if the report is insufficient.

## Harness Monitor crash patterns to avoid

- **Never wrap `deinit` cleanup in `MainActor.assumeIsolated { ... }`** on a `@MainActor` class (or `NSView` / `NSObject` subclass that's MainActor in the SDK overlay) under Swift 6 strict concurrency on macOS 26. ARC routinely drops the last reference on `com.apple.SwiftUI.DisplayLink` (notably during dashboard ↔ cockpit transitions or any SwiftUI view-tree rebuild), and `assumeIsolated` traps with `BUG IN CLIENT OF LIBDISPATCH: Block was expected to execute on queue [com.apple.main-thread]`. Confirmed crashes in `KeyWindowObserver.deinit`, `WindowCommandScopeTrackingNSView.deinit`, and an earlier `HarnessMonitorStore.deinit`. Required pattern: mark the storage `nonisolated(unsafe) var` so the nonisolated deinit can read it without the non-Sendable error, inline only thread-safe cleanup (`NotificationCenter.removeObserver(_:)` and `IOPMAssertionRelease` are documented thread-safe; treat `NSEvent.removeMonitor` as MainActor-only), and move any MainActor-only step (e.g. clearing routing state on a `@MainActor @Observable`) into the NSViewRepresentable's static `dismantleNSView(_:coordinator:)`, which SwiftUI guarantees runs on the MainActor when the representable is removed. Do not reach for `isolated deinit` (SE-0371) — the upcoming feature is not enabled in this project.
