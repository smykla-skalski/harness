# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Command execution

**Always use `rtk`** - it is the token-optimized proxy for shell commands and saves 60-90% on dev operations. Prefix every shell command with `rtk` (e.g. `rtk git status`, `rtk cargo test`). The Claude Code hook auto-rewrites commands transparently; do not fight it.

**`rtk proxy` is last resort only.** It bypasses all output filters and leaks raw command output (4000+ line dumps), burning the context window. Use it only when filtered output hides information you genuinely need to debug a specific issue, and switch back to plain `rtk` immediately after.

Discover supported workflows with `rtk mise tasks ls` and run repo logic only through `rtk mise run <task>` or `rtk mise run <task> -- <args>`. Do not wrap `mise` in `bash -lc`, `zsh -lc`, `env`, or other shells. Do not run repo scripts, raw `cargo`, or raw `xcodebuild` when a `mise` task already covers the workflow.

## Build and test commands

```bash
mise run check                 # type-check without building
mise run test                  # unit + integration (fast, single-threaded)
mise run test:unit             # unit tests only
mise run test:slow             # slow tests (#[ignore])
mise run lint:fix              # format + clippy fixes
mise run install               # build release binary, install to ~/.local/bin
cargo test --lib cli::tests    # all tests in a module
cargo test --lib errors::tests::cli_err_basic_fields -- --exact  # single test
cargo fmt --check              # check formatting
cargo clippy --lib             # lint check only
```

Unit tests are in-crate `#[test]` blocks. Integration tests live in `tests/integration/` and cover hooks, commands, and workflows end-to-end. Integration tests run single-threaded (`--test-threads=1`) for env safety. Tests that read XDG paths must isolate state with `temp_env::with_vars` setting both `XDG_DATA_HOME` and `CLAUDE_SESSION_ID`. No mocks - tests use real filesystem state. Slow tests are marked `#[ignore]` and run via `mise run test:slow`.

Pre-commit: `cargo fmt --check && cargo clippy --lib && mise run test`

Before any commit, run `/council` on the intended diff and address material findings before `git commit -sS`.

For the Harness Monitor macOS app (`apps/harness-monitor-macos`), see that directory's own `CLAUDE.md` - it covers the Tuist project layout, exact `xcodebuild` destination rules (`platform=macOS,arch=$(uname -m),name=My Mac` for local macOS lanes), SwiftUI/UX rules, performance measurement, and daemon modes.

## Agent asset architecture

`agents/skills/` and `agents/plugins/` are the only canonical cross-runtime skill and plugin sources in this repo.

`local-skills/claude/` holds Claude-only project-local skill sources. The generator symlinks each subdirectory into `.claude/skills/` so Claude Code picks them up. This works around the `.claude/rules/` auto-load bug - edits to the source files are live immediately.

Every directory under `.claude/`, `.agents/`, `.gemini/`, `.vibe/`, `.opencode/`, `.github/hooks/`, and `plugins/` that holds agent assets is a managed output root. The renderer owns these directories. Each contains an `AGENTS.md` marker it emits. Do not hand-edit files inside managed roots.

- `harness setup agents generate` - renders skill/plugin assets from canonical sources into all managed roots
- `harness setup bootstrap` - writes runtime config files (`.claude/settings.json`, `.codex/hooks.json`, `.codex/config.toml`, `.gemini/settings.json`, `.github/hooks/harness.json`, `.vibe/hooks.json`, `.opencode/hooks.json`) and syncs the Claude plugin cache

## Architecture

Harness is a test orchestration framework for Kubernetes/Kuma. It enforces tracked, user-story-first testing through state machines and hook-based guardrails.

### Two parallel workflow systems (`src/workflow/`)

**suite:run** (`workflow/runner.rs`): orchestrates test runs through phases `bootstrap` -> `ready` -> `approved` -> `running` -> `verdict`. State persisted as versioned JSON via `VersionedJsonRepository` (atomic tmp-file -> rename saves).

**suite:create** (`workflow/create.rs`): manages interactive suite creation with multi-step proposals and manifest validation.

### Hook system (`src/hooks/`, `src/cli.rs`)

Hooks intercept Claude Code tool usage. Classified in `cli.rs` as constants:

- **Pre-tool-use guards**: `guard-bash` (blocks direct cluster binary access), `guard-write` (blocks writes outside run surface), `guard-question`
- **Post-tool-use verifies**: `verify-bash`, `verify-write`, `verify-question`, `audit`
- **Blocking**: `guard-stop` (prevents session end if run incomplete, **off by default**)
- **Subagent gates**: `context-agent` (start), `validate-agent` (stop) — **off by default**
- **Failure enrichment**: `enrich-failure` / `tool-failure` (**off by default**)

The suite-lifecycle hooks (`guard-stop`, `context-agent`, `validate-agent`, `tool-failure`) are gated by `HARNESS_FEATURE_SUITE_HOOKS` (or the matching `--enable-suite-hooks` CLI flag on `harness setup bootstrap` and `harness setup agents generate`). They default to off while the underlying features are unfinished. CLI flag wins over env var. Resolution lives in `src/feature_flags.rs::RuntimeHookFlags`. Bootstrap emits an `info!` line per regenerated config naming the omitted family.

Repo-policy/manual-task enforcement is owned by the standalone `aff` CLI. Keep the flows separate: use `mise run setup:bootstrap`, `mise run setup:agents:generate`, and `mise run check:agent-assets` for harness-owned outputs only. If you want aff-owned runtime hooks, run the separate manual `aff:*` mise tasks yourself.

**Hook landing rule**: a new hook lands with its handler doing observable work, *or* behind a dated feature flag in `src/feature_flags.rs` with a tracking issue. Triggers without working handlers slow every tool call without producing signal.

### Key modules

- `errors.rs` - unified error/hook message system with `{placeholder}` template substitution (fallback to `?`)
- `schema.rs` - custom frontmatter parser for suite/run YAML metadata
- `context.rs` - run lifecycle types: `RunLayout` (directory structure), `RunMetadata`, `CommandEnv`
- `prepared_suite.rs` - suite artifact types (manifests, groups, digests)
- `compact.rs` - file fingerprinting (SHA256 + mtime) for change tracking
- `core_defs.rs` - build info, timestamps, XDG paths, session scope (SHA256-hashed)
- `rules.rs` - declarative denied-binary lists, make targets, etc.
- `commands/` - 33 command handlers dispatched from CLI
- `session/` - multi-agent orchestration: `types.rs` (SessionState, AgentRegistration, WorkItem, SessionRole), `roles.rs` (permission matrix), `storage.rs` (VersionedJsonRepository + JSONL audit log), `service.rs` (12 orchestration functions), `transport.rs` (13 CLI commands), `observe.rs` (cross-agent observation with periodic sweep)
- `agents/runtime/` - AgentRuntime trait with 6 implementations (claude, codex, gemini, copilot, vibe, opencode), ConversationEvent types, signal protocol (write/read/acknowledge), liveness detection

### Data directories (XDG)

- `$XDG_DATA_HOME/harness/suites/` - suite library
- `$XDG_DATA_HOME/harness/runs/` - run directories (`{run_id}/{artifacts,commands,state,manifests,reports}`)
- `$XDG_DATA_HOME/harness/contexts/{session-hash}/` - session context
- `$XDG_DATA_HOME/harness/projects/project-{digest}/orchestration/` - multi-agent session state
- `$XDG_DATA_HOME/harness/projects/project-{digest}/agents/signals/` - file-based agent signaling

## Code conventions

- Rust 2024 edition, requires rustc 1.94+
- Clippy pedantic is set to `deny` - all new code must pass pedantic lints
- Errors use `CliErrorKind` enum variants with typed fields via thiserror
- Hook messages use `HookMessage` enum with `into_result()` conversion
- Commits: `{type}({scope}): {message}` — types: `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `perf`
- Never create merge commits. Keep history flat with rebase/cherry-pick workflows only; if a merge commit appears locally, rewrite it out before pushing or handing off.

## Commit signing (strict)

Every commit **must** be created with `git commit -sS` - both the `-s` sign-off and `-S` GPG signature are required, no exceptions. After each commit, verify:

- the commit signature is valid (`git log --show-signature -1`)
- the sign-off trailer is exactly `Signed-off-by: Bart Smykla <bartek@smykla.com>`

Never bypass signing with `--no-gpg-sign`, `-c commit.gpgsign=false`, `--no-verify`, or by using a different key. If 1Password (signing key source) is unavailable, hard stop and wait for the user - do not commit unsigned and do not substitute another key.

## Versioning

Every feature change must evaluate semver and bump the version. When working on `main` directly, bump in the same change. When working in a worktree or feature branch, never bump the version there - version bumps happen on `main` after the branch merges, because parallel worktrees would create conflicting version changes. The `/do` skill gates this behind user approval automatically.

- `major` - any breaking change to CLI commands or flags, hook payload contracts, persisted state/schema/artifact formats, machine-consumed output, or behavior that user scripts or suites can reasonably rely on
- `minor` - backward-compatible new functionality such as a new command, flag, output field, hook capability, report surface, or materially expanded behavior
- `patch` - backward-compatible bug fixes, internal refactors, diagnostics, performance work, or test/doc updates that do not add new capability and do not break an existing contract

Canonical version source for harness:

- `Cargo.toml` - canonical crate/package version

Automatic sync workflow:

- bump the canonical version with `mise run version:set -- <version>`; if you edit `Cargo.toml` directly, run `mise run version:sync` immediately afterward
- `mise run version:check` verifies every derived version surface and runs as part of `mise run check`
- `mise run monitor:macos:generate` regenerates the Tuist project, then `Scripts/post-generate.sh` resyncs the monitor version metadata from the root package version so the regenerated project always tracks the canonical Cargo version

Derived surfaces maintained by the `mise run version:*` sync workflow:

- `testkit/Cargo.toml`
- `Cargo.lock` package entries for `harness` and `harness-testkit`
- `apps/harness-monitor-macos/Tuist/ProjectDescriptionHelpers/BuildSettings.swift` (the `// VERSION_MARKER_CURRENT` and `// VERSION_MARKER_MARKETING` lines)
- `apps/harness-monitor-macos/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist`

Additional version notes:

- `.claude/plugins/suite/.claude-plugin/plugin.json` - bump only when plugin content changes (prompts, tools, SKILL.md, agent config); harness-only changes do not require a plugin version bump; `src/bootstrap.rs` reads this file for plugin-cache sync
- `.claude/plugins/harness/.claude-plugin/plugin.json` - bump only when harness plugin content changes (SKILL.md, agent config, references); harness-only changes do not require a plugin version bump
- `src/observe/output.rs` sources the SARIF `driver.version` from `env!("CARGO_PKG_VERSION")`; do not replace that with a manual version string
- `src/bootstrap.rs` - update only versioned plugin fixtures and cache-path expectations in tests when they intentionally track the released version; this file consumes the plugin version but is not a canonical version source
- `src/cli.rs` uses Clap's derived `version`, so it follows the root `Cargo.toml` version automatically and should not get a manual version string

## Logging

All diagnostic output uses `tracing` macros. Never use `eprintln!` for new diagnostic messages.

- `warn!` - non-fatal failures, fallbacks, degraded operations
- `info!` - progress updates, phase transitions, completion
- `debug!` - verbose dumps (full JSON specs, etc.)
- `println!` stays for user-facing command output and hook JSON protocol
- Use structured fields: `warn!(%error, "failed to load context")`, `info!(name = %value, "message")`
- No `#[instrument]` unless explicitly requested
- Subscriber is initialized in `main.rs` only - tests run without one (silent no-op)
- Default filter: `RUST_LOG=harness=info`

## Clippy complexity and tracing

Tracing macros inflate `clippy::cognitive_complexity` scores artificially (tokio-rs/tracing#553). When clippy flags a function for complexity, triage before suppressing:

1. Read the function critically - if it is genuinely complex, simplify it first. Be strict: even slightly too complex means refactor.
2. Only after the function is as simple as it can be, check whether tracing macro expansion is the sole remaining driver of the warning.
3. If and only if tracing is the only reason the score is over threshold, suppress with `#[expect]` and cite the known issue:

```rust
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
```

Never add `#[expect(clippy::cognitive_complexity)]` as a first move. Always simplify first.

## Grafana dashboards

All dashboards in `resources/observability/grafana/dashboards/` use Grafana 12+ responsive auto-grid layout. When creating or modifying dashboards:

- Include the `layout` block at the dashboard root with `kind: "auto-grid"`, `maxColumns: 4`, `minColumnWidth: 300`
- Use `gridPos.w: 6` (quarter width) for stat panels - 4 across on large screens, stacks on narrow
- Use `gridPos.w: 12` (half width) for time series and logs - 2 across on large screens, stacks on narrow
- Use `gridPos.w: 24` (full width) sparingly for wide panels like log viewers
- Avoid `gridPos.w: 3` or `w: 4` - too dense for mobile/tablet viewports
- Panel order in the JSON determines auto-grid placement when widths allow reflow

## Gotchas

- `guard-bash` denies direct use of `kubectl`, `kumactl`, `helm`, `docker`, `k3d` - all cluster access must go through harness commands (see `rules.rs:26`)
- `VersionedJsonRepository` saves atomically via tmp-file rename - don't read state files by path while a save is in progress, use the repository's `load()` method
