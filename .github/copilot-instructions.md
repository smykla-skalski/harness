# Copilot instructions for `harness`

## Command execution

- Prefix shell commands with `rtk`.
- Prefer `rtk mise run <task>` over raw `cargo`, `xcodebuild`, or repo scripts. When there is no dedicated task, use `rtk mise run cargo:local -- <cargo args>`.
- Use `rtk mise tasks ls` to discover supported workflows.
- Use `rtk proxy` only when filtered `rtk` output hides information you genuinely need.

## Build, test, and lint commands

### Harness CLI and `aff`

```bash
rtk mise run check
rtk mise run harness:check
rtk mise run aff:check
rtk mise run test
rtk mise run test:unit
rtk mise run test:integration
rtk mise run test:slow
rtk mise run aff:test
rtk mise run lint:fix
rtk mise run install
rtk mise run check:agent-assets
rtk mise run setup:agents:generate
rtk mise run setup:bootstrap
```

Single-test patterns:

```bash
rtk mise run cargo:local -- test --quiet --lib cli::tests
rtk mise run cargo:local -- test --quiet --lib errors::tests::cli_err_basic_fields -- --exact
rtk mise run cargo:local -- test --quiet --test integration integration::hooks::guard_bash::guard_bash_payloads -- --exact --test-threads=1
```

- Unit tests live next to the code in `src/**`.
- Integration tests live under `tests/integration/`, but the target is `tests/integration.rs`.
- Integration tests intentionally run single-threaded because they use real filesystem and environment state.
- XDG-sensitive tests should isolate `XDG_DATA_HOME` and the active session env var via `temp_env::with_vars`.
- Slow tests are `#[ignore]` and run through `rtk mise run test:slow`.

### Harness Monitor macOS

```bash
rtk mise run monitor:generate
rtk mise run monitor:lint
rtk mise run monitor:quality-gate
rtk mise run monitor:build
rtk mise run monitor:test
rtk mise run monitor:test:scripts
rtk mise run monitor:audit -- --label baseline
```

Focused examples:

```bash
XCODE_ONLY_TESTING=HarnessMonitorKitTests/PolicyGapRuleTests \
  rtk mise run monitor:test

XCODE_ONLY_TESTING=HarnessMonitorUITests/HarnessMonitorUITests/testToolbarOpensSettingsWindow \
  rtk mise run monitor:test

COPILOT_SESSION_ID=<uuid> XCODE_ONLY_TESTING=HarnessMonitorKitTests/PolicyGapRuleTests \
  rtk mise run monitor:agent:test

COPILOT_SESSION_ID=<uuid> rtk mise run monitor:agent:build

rtk mise run monitor:xcodebuild -- \
  -workspace apps/harness-monitor-macos/HarnessMonitor.xcworkspace \
  -scheme HarnessMonitor \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m),name=My Mac" \
  build CODE_SIGNING_ALLOWED=NO
```

- `apps/harness-monitor-macos/HarnessMonitor.xcodeproj` and `.xcworkspace` are generated, ignored outputs from Tuist. Regenerate them with `rtk mise run monitor:generate`.
- Do not run the full `HarnessMonitorUITests` suite by default. Prefer `XCODE_ONLY_TESTING` with the smallest possible selector.
- In shared-checkout or agent-driven work, use `monitor:agent:*`. The isolated profile is derived from agent session env vars such as `COPILOT_SESSION_ID`.
- For custom macOS lanes, never use bare `-destination 'platform=macOS'`; use `platform=macOS,arch=$(uname -m),name=My Mac`.

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
- Evaluate semver whenever shipped behavior changes. `Cargo.toml` is the canonical version source; use `rtk mise run version:set -- <version>` and `rtk mise run version:sync` to update derived surfaces.
- Commit and PR titles should follow `type(scope): description`.
- For Harness Monitor SwiftUI work, prefer existing shared layout/control primitives and existing UI-test helpers instead of inventing one-off patterns.
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
- For performance regressions, use targeted perf tests through `XCODE_ONLY_TESTING=HarnessMonitorUITests/HarnessMonitorPerfTests/... rtk mise run monitor:test` and the deeper Instruments pipeline through `rtk mise run monitor:audit`.
