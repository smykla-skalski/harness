# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

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

For `apps/harness-monitor-macos`, treat `HarnessMonitor.xcodeproj` as tracked source. If you add, remove, or rename Swift files under the Harness Monitor app, update the Xcode project in the same change instead of relying on local-only project state.

Harness Monitor app validation expectations:

- `xcodebuild -project 'apps/harness-monitor-macos/HarnessMonitor.xcodeproj' -scheme "HarnessMonitor" -configuration Debug -derivedDataPath xcode-derived -destination "platform=macOS,arch=$(uname -m),name=My Mac" build CODE_SIGNING_ALLOWED=NO`
- `xcodebuild -project 'apps/harness-monitor-macos/HarnessMonitor.xcodeproj' -scheme "HarnessMonitor" -configuration Debug -derivedDataPath xcode-derived test CODE_SIGNING_ALLOWED=NO -destination "platform=macOS,arch=$(uname -m),name=My Mac" -skip-testing:HarnessMonitorUITests`
- All xcodebuild invocations must use `-derivedDataPath xcode-derived` so build artifacts land in a single, known location at the repo root (gitignored). Never create variant-named directories like `xcode-derived-foo` - one directory, reused across builds.
- For macOS Harness Monitor lanes, never use bare `-destination 'platform=macOS'` because it matches both `My Mac` and `Any Mac` and triggers the multiple-matching-destinations warning. On Apple Silicon, even `name=My Mac` is still ambiguous because Xcode exposes both `arm64` and `x86_64`. Use `-destination "platform=macOS,arch=$(uname -m),name=My Mac"` unless a more specific `id=...` selector is required.
- Hard requirement: do not run the full macOS UI suite by default. Run only the smallest targeted build/test command needed for the current change, such as a single XCTest case, a single XCTest class, or a non-UI build lane.
- Only run the full macOS app validation lane or the full `HarnessMonitorUITests` suite after the user explicitly asks for the full suite.
- Targeted `HarnessMonitorUITests` runs must use the isolated `Harness Monitor UI Testing` host (`io.harnessmonitor.app.ui-testing`) instead of the shipping `Harness Monitor.app` bundle so local manual app usage is not interrupted.
- Keep the `-ApplePersistenceIgnoreState YES` UI-test launch argument in place for the isolated host so macOS window restoration does not make targeted UI runs flaky.
- The Harness Monitor targets run a strict Swift Quality Gate on every build with warnings-as-errors. Expect style/lint failures such as oversized view bodies and fix the source instead of bypassing the gate.
- Prefer shared layout and control primitives for Harness Monitor UI density/readability work so button sizing and glass treatment stay consistent across screens.

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

Hooks intercept Codex tool usage. Classified in `cli.rs` as constants:

- **Unified tool lifecycle**: `tool-guard` (pre-tool policy dispatch), `tool-result` (post-tool verification and audit), `tool-failure` (failure enrichment and audit)
- **Blocking**: `guard-stop` (prevents session end if run incomplete)
- **Subagent gates**: `context-agent` (start), `validate-agent` (stop)

### Key modules

- `errors.rs` - unified error/hook message system with `{placeholder}` template substitution (fallback to `?`)
- `schema.rs` - custom frontmatter parser for suite/run YAML metadata
- `context.rs` - run lifecycle types: `RunLayout` (directory structure), `RunMetadata`, `CommandEnv`
- `prepared_suite.rs` - suite artifact types (manifests, groups, digests)
- `compact.rs` - file fingerprinting (SHA256 + mtime) for change tracking
- `core_defs.rs` - build info, timestamps, XDG paths, session scope (SHA256-hashed)
- `rules.rs` - declarative denied-binary lists, make targets, etc.
- `commands/` - 33 command handlers dispatched from CLI

### Data directories (XDG)

- `$XDG_DATA_HOME/kuma/suites/` - suite library
- `$XDG_DATA_HOME/kuma/runs/` - run directories (`{run_id}/{artifacts,commands,state,manifests,reports}`)
- `$XDG_DATA_HOME/kuma/contexts/{session-hash}/` - session context

## Code conventions

- Rust 2024 edition, requires rustc 1.94+
- Clippy pedantic is set to `deny` - all new code must pass pedantic lints
- Errors use `CliErrorKind` enum variants with typed fields via thiserror
- Hook messages use `HookMessage` enum with `into_result()` conversion
- Commits: `{type}({scope}): {message}` — types: `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `perf`

## Versioning

Every feature change must evaluate semver and bump the version in the same change. Do not ship feature work without updating the version surfaces that track the release.

- `major` - any breaking change to CLI commands or flags, hook payload contracts, persisted state/schema/artifact formats, machine-consumed output, or behavior that user scripts or suites can reasonably rely on
- `minor` - backward-compatible new functionality such as a new command, flag, output field, hook capability, report surface, or materially expanded behavior
- `patch` - backward-compatible bug fixes, internal refactors, diagnostics, performance work, or test/doc updates that do not add new capability and do not break an existing contract

Canonical version source for harness:

- `Cargo.toml` - canonical crate/package version

Automatic sync workflow:

- bump the canonical version with `mise run version:set -- <version>`; if you edit `Cargo.toml` directly, run `mise run version:sync` immediately afterward
- `mise run version:check` verifies every derived version surface and runs as part of `mise run check`
- `mise run monitor:macos:generate` regenerates the project, then resyncs the monitor version metadata from the root package version so XcodeGen cannot reintroduce stale build numbers

Derived surfaces maintained by the `mise run version:*` sync workflow:

- `testkit/Cargo.toml`
- `Cargo.lock` package entries for `harness` and `harness-testkit`
- `apps/harness-monitor-macos/project.yml`
- `apps/harness-monitor-macos/HarnessMonitor.xcodeproj/project.pbxproj`
- `apps/harness-monitor-macos/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist`

Additional version notes:

- `.Codex/plugins/suite/.Codex-plugin/plugin.json` - bump only when plugin content changes (prompts, tools, SKILL.md, agent config); harness-only changes do not require a plugin version bump; `src/bootstrap.rs` reads this file for plugin-cache sync
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

- `tool-guard` denies direct use of `kubectl`, `kumactl`, `helm`, `docker`, `k3d` and routes write/question policy through the same combined pre-tool hook (see `rules.rs:26`)
- `VersionedJsonRepository` saves atomically via tmp-file rename - don't read state files by path while a save is in progress, use the repository's `load()` method
- If using XcodeBuildMCP, use the installed XcodeBuildMCP skill before calling XcodeBuildMCP tools.
- `apps/harness-monitor-macos/HarnessMonitor.xcodeproj` is repo-owned metadata; keep `project.pbxproj`, shared workspace/scheme files, and Swift source membership in sync.
