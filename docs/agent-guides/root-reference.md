# Root Agent Reference

Load this file only when the repo-root `AGENTS.md` routes the current task here.
The root `AGENTS.md` contains the mandatory contract; this file keeps the longer
reference material out of the default prompt path.

## Workflow systems

`suite:run` lives in `src/workflow/runner.rs`. It orchestrates test runs through
`bootstrap -> ready -> approved -> running -> verdict`. State is persisted as
versioned JSON through `VersionedJsonRepository`, using tmp-file then rename
saves.

`suite:create` lives in `src/workflow/create.rs`. It manages interactive suite
creation with multi-step proposals and manifest validation.

## Hook system

Hooks intercept Codex tool usage. The constants are classified in `src/cli.rs`:

- Unified tool lifecycle: `tool-guard`, `tool-result`, and `tool-failure`.
- Blocking: `guard-stop`.
- Subagent gates: `context-agent` and `validate-agent`.

The four suite-lifecycle hooks (`guard-stop`, `context-agent`,
`validate-agent`, `tool-failure`) are gated behind
`HARNESS_FEATURE_SUITE_HOOKS`. Re-enable them for a setup invocation with
`--enable-suite-hooks` on `harness setup bootstrap` or
`harness setup agents generate`, or globally with
`HARNESS_FEATURE_SUITE_HOOKS=1`. The CLI flag wins over the env var. Bootstrap
logs an `info!` line per regenerated config naming any omitted family.

Repo-policy/manual-task enforcement belongs to `aff`. Use harness setup tasks
for harness-owned outputs and the separate `aff:*` tasks for aff-owned runtime
hooks.

## Key modules

- `errors.rs` - unified error and hook-message system with placeholder
  substitution.
- `schema.rs` - custom frontmatter parser for suite/run YAML metadata.
- `context.rs` - run lifecycle types such as `RunLayout`, `RunMetadata`, and
  `CommandEnv`.
- `prepared_suite.rs` - suite artifact types.
- `compact.rs` - file fingerprinting with SHA256 and mtime.
- `core_defs.rs` - build info, timestamps, XDG paths, and session scope.
- `rules.rs` - declarative denied-binary lists and repo policy rules.
- `commands/` - CLI command handlers.
- `session/` - multi-agent orchestration types, roles, storage, service,
  transport, and observation.
- `task_board/` - cross-project board state, planning gates, dispatch/evaluate
  reconciliation, orchestrator state, external sync, and policy pipeline graph
  evaluation. See `docs/agent-guides/task-board-workflow.md` for operator
  behavior.
- `agents/runtime/` - runtime adapters, conversation events, signal protocol,
  and liveness detection.

## Data directories

- `$XDG_DATA_HOME/harness/suites/` - suite library.
- `$XDG_DATA_HOME/harness/runs/` - run directories with artifacts, commands,
  state, manifests, and reports.
- `$XDG_DATA_HOME/harness/contexts/{session-hash}/` - session context.
- `$XDG_DATA_HOME/harness/projects/project-{digest}/orchestration/` -
  multi-agent session state.
- `$XDG_DATA_HOME/harness/projects/project-{digest}/agents/signals/` -
  file-based agent signaling.
- Task-board state uses the board root resolved by the CLI/daemon, normally
  under the project Harness data area. Access it through `harness task-board`
  commands or daemon task-board routes instead of reading JSON files directly.

## Testing details

Integration tests live in `tests/integration/` and cover hooks, commands, and
workflows end to end. They run with `--test-threads=1` for environment safety.
Tests that read XDG paths must isolate state with `temp_env::with_vars`, setting
both `XDG_DATA_HOME` and `CLAUDE_SESSION_ID`. Avoid mocks; tests use real
filesystem state.

## Versioning details

Canonical harness version source:

- `Cargo.toml`.

Derived surfaces maintained by `rtk mise run version:*`:

- `testkit/Cargo.toml`.
- `Cargo.lock` package entries for `harness` and `harness-testkit`.
- `apps/harness-monitor-macos/Tuist/ProjectDescriptionHelpers/BuildSettings.swift`.
- `apps/harness-monitor-macos/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist`.

Additional version notes:

- `.Codex/plugins/suite/.Codex-plugin/plugin.json` changes only when plugin
  content changes.
- `src/observe/output.rs` reads SARIF `driver.version` from
  `env!("CARGO_PKG_VERSION")`.
- `src/bootstrap.rs` consumes plugin versions for plugin-cache sync and fixtures.
- `src/cli.rs` uses Clap's derived version.

## Logging

All diagnostics use `tracing` macros:

- `warn!` for non-fatal failures, fallbacks, and degraded operations.
- `info!` for progress, phase transitions, and completion.
- `debug!` for verbose dumps.
- `println!` remains for user-facing command output and hook JSON protocol.

Use structured fields such as `warn!(%error, "failed to load context")`. Do not
add `#[instrument]` unless explicitly requested. The subscriber is initialized
in `main.rs`; tests run without one. Default filter: `RUST_LOG=harness=info`.

## Clippy complexity and tracing

Tracing macros can inflate `clippy::cognitive_complexity`
(tokio-rs/tracing#553). When clippy flags complexity:

1. Simplify the function first.
2. Check whether tracing expansion is the only remaining driver.
3. Only then use `#[expect(clippy::cognitive_complexity)]` with this reason:

```rust
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
```

Never add that suppression as the first move.

## Grafana dashboards

Dashboards in `resources/observability/grafana/dashboards/` use Grafana 12+
responsive auto-grid layout:

- Root `layout`: `kind: "auto-grid"`, `maxColumns: 4`, `minColumnWidth: 300`.
- Stat panels: `gridPos.w: 6`.
- Time series and logs: `gridPos.w: 12`.
- Wide log viewers: `gridPos.w: 24` only when needed.
- Avoid `gridPos.w: 3` and `w: 4`.
- Panel order in JSON determines auto-grid placement.
