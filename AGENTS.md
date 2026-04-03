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

- `xcodebuild -project 'apps/harness-monitor-macos/HarnessMonitor.xcodeproj' -scheme "HarnessMonitor" -configuration Debug -derivedDataPath tmp/xcode-derived build CODE_SIGNING_ALLOWED=NO`
- `xcodebuild -project 'apps/harness-monitor-macos/HarnessMonitor.xcodeproj' -scheme "HarnessMonitor" -configuration Debug -derivedDataPath tmp/xcode-derived test CODE_SIGNING_ALLOWED=NO -destination 'platform=macOS' -skip-testing:HarnessMonitorUITests`
- All xcodebuild invocations must use `-derivedDataPath tmp/xcode-derived` so build artifacts land in a single, known location inside `tmp/`. Never create variant-named directories like `tmp/xcode-derived-foo` - one directory, reused across builds.
- Hard requirement: do not run the full macOS UI suite by default. Run only the smallest targeted build/test command needed for the current change, such as a single XCTest case, a single XCTest class, or a non-UI build lane.
- Only run the full macOS app validation lane or the full `HarnessMonitorUITests` suite after the user explicitly asks for the full suite.
- Targeted `HarnessMonitorUITests` runs must use the isolated `Harness Monitor UI Testing` host (`io.harnessmonitor.app.ui-testing`) instead of the shipping `Harness Monitor.app` bundle so local manual app usage is not interrupted.
- Keep the `-ApplePersistenceIgnoreState YES` UI-test launch argument in place for the isolated host so macOS window restoration does not make targeted UI runs flaky.
- The Harness Monitor targets run a strict Swift Quality Gate on every build with warnings-as-errors. Expect style/lint failures such as oversized view bodies and fix the source instead of bypassing the gate.
- Prefer shared layout and control primitives for Harness Monitor UI density/readability work so button sizing and glass treatment stay consistent across screens.

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

Manual bump surfaces for harness:

- `Cargo.toml` - canonical crate/package version
- `testkit/Cargo.toml` - keep the testkit crate aligned with the root package version
- `.Codex/plugins/suite/.Codex-plugin/plugin.json` - bump only when plugin content changes (prompts, tools, SKILL.md, agent config); harness-only changes do not require a plugin version bump; `src/bootstrap.rs` reads this file for plugin-cache sync
- `src/commands/observe/output.rs` - bump the SARIF `driver.version` only; do not change the SARIF schema version `2.1.0` unless the SARIF spec itself changes
- `Cargo.lock` - regenerate after the package-version changes
- `src/bootstrap.rs` - update only versioned plugin fixtures and cache-path expectations in tests when they intentionally track the released version; this file consumes the plugin version but is not a canonical version source

Related note: `src/cli.rs` uses Clap's derived `version`, so it follows the root `Cargo.toml` version automatically and should not get a manual version string.

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

## Gotchas

- `tool-guard` denies direct use of `kubectl`, `kumactl`, `helm`, `docker`, `k3d` and routes write/question policy through the same combined pre-tool hook (see `rules.rs:26`)
- `VersionedJsonRepository` saves atomically via tmp-file rename - don't read state files by path while a save is in progress, use the repository's `load()` method
- If using XcodeBuildMCP, use the installed XcodeBuildMCP skill before calling XcodeBuildMCP tools.
- `apps/harness-monitor-macos/HarnessMonitor.xcodeproj` is repo-owned metadata; keep `project.pbxproj`, shared workspace/scheme files, and Swift source membership in sync.
