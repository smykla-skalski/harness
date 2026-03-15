# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and test commands

```bash
cargo check                    # type-check without building
cargo build                    # full build
cargo test --lib               # run all unit tests
cargo test --lib errors::tests::cli_err_basic_fields -- --exact  # single test
cargo test --lib cli::tests    # all tests in a module
cargo clippy --lib             # lint (pedantic = deny)
cargo fmt --check              # check formatting
cargo fmt                      # auto-format
```

Unit tests are in-crate `#[test]` blocks. Integration tests live in `tests/integration/` and cover hooks, commands, and workflows end-to-end. No Makefile or CI pipeline.

Pre-commit checklist: `cargo fmt --check && cargo clippy --lib && cargo test`

## Architecture

Harness is a test orchestration framework for Kubernetes/Kuma. It enforces tracked, user-story-first testing through state machines and hook-based guardrails.

### Two parallel workflow systems (`src/workflow/`)

**Suite-runner** (`workflow/runner.rs`): orchestrates test runs through phases `bootstrap` -> `ready` -> `approved` -> `running` -> `verdict`. State persisted as versioned JSON via `VersionedJsonRepository` (atomic tmp-file -> rename saves).

**Suite-author** (`workflow/author.rs`): manages interactive suite creation with multi-step proposals and manifest validation.

### Hook system (`src/hooks/`, `src/cli.rs`)

Hooks intercept Claude Code tool usage. Classified in `cli.rs` as constants:

- **Pre-tool-use guards**: `guard-bash` (blocks direct cluster binary access), `guard-write` (blocks writes outside run surface), `guard-question`
- **Post-tool-use verifies**: `verify-bash`, `verify-write`, `verify-question`, `audit`
- **Blocking**: `guard-stop` (prevents session end if run incomplete)
- **Subagent gates**: `context-agent` (start), `validate-agent` (stop)
- **Failure enrichment**: `enrich-failure`

### Key modules

- `errors.rs` - unified error/hook message system with `{placeholder}` template substitution (fallback to `?`)
- `schema.rs` - custom frontmatter parser for suite/run YAML metadata
- `context.rs` - run lifecycle types: `RunLayout` (directory structure), `RunMetadata`, `CommandEnv`
- `prepared_suite.rs` - suite artifact types (manifests, groups, digests)
- `compact.rs` - file fingerprinting (SHA256 + mtime) for change tracking
- `core_defs.rs` - build info, timestamps, XDG paths, session scope (SHA256-hashed)
- `rules.rs` - declarative denied-binary lists, make targets, etc.
- `commands/` - 24 command handlers dispatched from CLI

### Data directories (XDG)

- `$XDG_DATA_HOME/kuma/suites/` - suite library
- `$XDG_DATA_HOME/kuma/runs/` - run directories (`{run_id}/{artifacts,commands,state,manifests,reports}`)
- `$XDG_DATA_HOME/kuma/contexts/{session-hash}/` - session context

## Code conventions

- Rust 2024 edition, requires rustc 1.94+
- Clippy pedantic is set to `deny` - all new code must pass pedantic lints
- Errors use `CliErrorKind` enum variants with typed fields via thiserror
- Hook messages use `HookMessage` enum with `into_result()` conversion

## Gotchas

- `guard-bash` denies direct use of `kubectl`, `kumactl`, `helm`, `docker`, `k3d` - all cluster access must go through harness commands (see `rules.rs:26`)
- `VersionedJsonRepository` saves atomically via tmp-file rename - don't read state files by path while a save is in progress, use the repository's `load()` method
