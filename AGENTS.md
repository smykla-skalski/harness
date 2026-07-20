# AGENTS.md

This is the repo-level contract for agents working in `harness`. Direct system, developer, and user instructions outrank this file. A deeper `AGENTS.md` overrides this file for its subtree.

## How to use this file

1. Start with the task-routing table and load the deepest relevant `AGENTS.md` before editing.
2. Treat the hard rules here as mandatory: `mise` workflows, an explicitly selected delivery mode, isolated session-scoped worktrees and lanes, path-limited signed commits, and scoped validation.
3. Select the delivery mode before creating the editing worktree, then read `docs/agent-guides/delivery-workflows.md` before integration or publication. Stop if the guide is unavailable.

## Task routing

| Work area | Start here |
| --- | --- |
| Delivery selection, replay, PR review, and closeout | `docs/agent-guides/delivery-workflows.md` |
| Rust CLI, hooks, orchestration, runtime bootstrap | This file, then `docs/agent-guides/root-reference.md` when details are needed |
| Harness Monitor macOS app | `apps/harness-monitor/AGENTS.md` |
| Monitor previewable SwiftUI layer | `apps/harness-monitor/Sources/HarnessMonitorUIPreviewable/AGENTS.md` |
| Runtime config layering | `docs/agents/runtime-config-layering.md` |

## Command execution

Discover repo workflows with `mise tasks ls`. Run repo logic through `mise run <task>` or `mise run <task> -- <args>` whenever a task exists. Do not wrap `mise` in `bash -lc`, `zsh -lc`, the `env` binary, or helper scripts. When an environment assignment is needed, put it before `mise`, for example `VAR=value mise run ...`. Do not run repo scripts, direct `cargo`, or direct `xcodebuild` when a `mise` task covers the workflow. Direct `cargo ...` is acceptable only for targeted Rust diagnosis that has no equivalent `mise` task granularity.

If several commands could apply, choose the smallest one that proves the change. Use broad gates only when the change affects shared behavior or before a final handoff that needs them.

## Delivery and worktrees

Use exactly one terminal delivery mode: `pr` or `replay`. `pr` is the default. Use `replay` only when the user explicitly requests it or explicitly confirms the agent's proposal for a small task such as a version bump, documentation change, or Git-history repair. Record the mode in substantial plans and handoffs.

Treat a feature expected to exceed about 5,000 Copilot-reviewable changed lines as an ordered PR series. Plan self-contained slices before implementation; each slice must remain independently valid and may be consumed or extended, but not knowingly repaired, replaced, or redesigned, by later slices. Complete Copilot review, user merge, and post-merge closeout for each dependent slice before implementing the next from current `upstream/main`, and stop for explicit user approval when no sound boundary fits the review budget.

Every user or agent session that edits files, generates projects, builds, tests, runs daemons, or drives XcodeBuildMCP must use its own full git worktree. Assign one custom worktree and one build/runtime lane to the whole session and reuse them so caches stay warm. Build/runtime lanes isolate side effects but never replace a separate checkout.

Commit and validate affected surfaces in the worktree. Unrelated dirty files may exist temporarily outside the task's explicit paths, but the worktree must be clean before rebase or delivery, and only committed state may be integrated or published. Keep the worktree and lane until session end or explicit cleanup.

Stay read-only outside the assigned worktree except for repository or remote state changes explicitly required by the selected delivery workflow; any other outside write needs explicit user approval. If another agent blocks progress for five minutes, ask the user.

A `replay` task ends only when clean local `main` and the session worktree point to the same commit, with any `upstream/main` difference reported. If completed local replay commits block the post-merge PR fast-forward, require a stable, signed, signed-off local range, rebase and re-sign only that range onto merged `upstream/main`, then wait for the user to push it; stop for the user when unpublished commits fail that precondition, and never cherry-pick the PR commit on top of the local range. Successful `pr` delivery ends only after the user merges, local `main`, `upstream/main`, and the clean reusable worktree match, and stale upstream tracking is removed; a closed-unmerged PR uses the guide's explicit undelivered terminal state. The agent never merges the PR.

## UI test failures

When UI tests are failing, run one failing test at a time using `XCODE_ONLY_TESTING`. Never run a broad suite or multiple failing tests together — XCUITest runs block the whole machine and the run time compounds fast. Fix one, verify it passes, then move to the next.

## Build and test

Run commands from the repo root:

```bash
mise run check
mise run harness:check
mise run aff:check
mise run test
mise run test:unit
mise run test:integration
mise run aff:test
mise run test:slow
mise run lint:fix
mise run install
```

Targeted Rust diagnosis examples, only when no `mise` task is precise enough:

```bash
cargo test --lib cli::tests
cargo test --lib errors::tests::cli_err_basic_fields -- --exact
cargo fmt --check
cargo clippy --lib
```

Unit tests are in-crate `#[test]` blocks. Integration tests live in
`tests/integration/`. Canonical Rust test tasks use nextest process isolation
and parallel scheduling. Tests must not require runner-wide serialization;
isolate their environment, filesystem paths, ports, and external resource
names instead. Tests that read XDG paths must isolate state with
`temp_env::with_vars`, setting both `XDG_DATA_HOME` and `CLAUDE_SESSION_ID`.
Tests use real filesystem state.

Pre-commit gate: `mise run check`. Add `mise run aff:check` when the task touches `aff` or aff-owned runtime hooks.

Validation should match risk:

- Docs-only edits: `git diff --check`.
- Narrow Rust logic: the focused unit/integration test first, then the smallest relevant `mise` gate.
- Shared CLI, hook, runtime, or storage behavior: run the focused test and the owning package gate before `mise run check`.
- `aff` code or aff-owned runtime hooks: include `mise run aff:check`.

## Runtime bootstrap

`mise run setup:bootstrap` installs the repo-aware wrapper and refreshes the project-local runtime configs that Harness owns. When a task changes hook registration or runtime config shape, rerun bootstrap in a temp project or focused test instead of looking for generated skill/plugin outputs.

Use:

```bash
mise run setup:bootstrap
```

## Architecture

Harness is a test orchestration framework for Kubernetes/Kuma. It enforces tracked, user-story-first testing through state machines and hook-based guardrails.

Core areas:

- `src/workflow/` owns `suite:run` and `suite:create`.
- `src/hooks/` and `src/cli.rs` own tool lifecycle hooks and hook dispatch.
- `src/session/` owns multi-agent orchestration state, roles, service logic, transport, storage, and observation.
- `src/agents/runtime/` owns runtime adapters for Claude, Codex, Gemini, Copilot, Vibe, and OpenCode.
- `src/commands/` owns CLI command handlers.
- Harness Monitor UI-triggered real work must leave the main thread through the global generic async work queue. Use `HarnessMonitorAsyncWorkQueue.shared` instead of route-local or action-specific queues; workers scale to the active CPU count, and UI state/toasts should hop back to the MainActor only for completion updates.

Detailed module and data-directory notes live in `docs/agent-guides/root-reference.md`.

## AGENTS.md maintenance

Keep agent guides short, scoped, and actionable. Put hard rules, routing, and copy-paste commands in `AGENTS.md`; move background, long rationale, and subsystem internals to `docs/agent-guides/`.

## Hooks

The active unified tool lifecycle is `tool-guard`, `tool-result`, and optional `tool-failure`. Suite-lifecycle hooks (`guard-stop`, `context-agent`, `validate-agent`, `tool-failure`) are off by default unless enabled with `HARNESS_FEATURE_SUITE_HOOKS=1` or the matching setup flag.

Repo-policy/manual-task enforcement is owned by the standalone `aff` CLI. Keep harness-owned setup (`setup:bootstrap`) separate from the manual `aff:*` tasks.

Hook landing rule: a new hook lands with observable handler behavior, or behind a dated feature flag in `src/feature_flags.rs` with a tracking issue.

## Code conventions

- Rust 2024 edition, rustc 1.94+.
- Clippy pedantic is `deny`; new Rust must pass it.
- Errors use `CliErrorKind` variants with typed fields via `thiserror`.
- Hook messages use `HookMessage` with `into_result()`.
- Diagnostic output uses `tracing` macros. Default filter: `RUST_LOG=harness=info`. Do not add `eprintln!` diagnostics.
- Keep Rust files under 520 lines and functions under 100 lines.
- Commit messages: `{type}({scope}): {message}` with `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, or `perf`. PRs squash-merge, so the PR title uses the same format and becomes the commit title on `main`.
- Never create merge commits or rewrite local `main`. In `replay`, perform the final rebase onto local `main` in the worktree and integrate only by fast-forward. In `pr`, base the branch on `upstream/main`; after publication, prefer additive commits and use `--force-with-lease` only for an unavoidable rewrite of the dedicated session branch. Never plain-force or rewrite a shared branch.

## Commit signing

Every commit must use path-limited `git commit -sS -- <paths>`. Pass the file list directly to `git commit`; git stages exactly those paths for this commit and leaves the rest of the index and working tree alone. For brand-new files, first run `git add -N -- <new-paths>` so Git can see them, then include those paths in the same path-limited commit. Do not pre-stage with plain `git add`, and do not use `git add -A`, `git add .`, `git commit -a`, or `git commit -i`. Parallel agents on the same worktree routinely have unrelated edits in flight, and path-limited commits keep them out of the signed history. Verify after committing:

```bash
git log --show-signature -1
```

The sign-off trailer must be exactly:

```text
Signed-off-by: Bart Smykla <bartek@smykla.com>
```

Never bypass signing with `--no-gpg-sign`, `-c commit.gpgsign=false`, `--no-verify`, or another key. On macOS, use the configured 1Password SSH signer and stop if it is unavailable. On Smycracker Linux, run `/usr/local/bin/smycracker-git-signing-doctor` before the first commit and use only the managed public key and Git signing wrapper. On other Linux hosts, stop unless the user explicitly approved another GitHub-registered signer. See the delivery guide for the full platform contract.

## Closeout and versioning

Finish through the selected mode in `docs/agent-guides/delivery-workflows.md`. Before integration or publication, commit the task and run only the smallest validation for affected surfaces in the worktree; helper scripts, docs, and files outside an app or codebase need no unrelated app gate. Do not rerun builds or checks on `main` merely because replay or merge closeout succeeded.

Every change must evaluate semver. Do not bump versions without explicit user approval. Docs-only changes normally require no version bump. Include any approved required bump in the same delivery rather than adding unreviewed work afterward. If shipped `harness` or `aff` behavior changes enough that the local binary must be reinstalled, a version bump is required after approval.

Use `mise run version:set -- <version>` for approved bumps, or `mise run version:sync` after any direct canonical-version edit. See `docs/agent-guides/root-reference.md` for derived version surfaces.

## Debugging discipline

Start with real data. Reproduce with the smallest targeted command and collect preserved traces, logs, screenshots, or failure artifacts before changing behavior. If the signal is weak, improve observability first. Correlate across layers, patch the proven cause only, keep each iteration single-cause, and keep task state honest.

## Build lane and fsmonitor cleanup

Harness Monitor xcodebuild lane internals and fsmonitor cleanup details live in `docs/agent-guides/root-reference.md`. Use the `clean:*` mise tasks documented there; do not raise the host-wide Monitor xcodebuild concurrency cap.

## Gotchas

- `tool-guard` denies direct use of `kubectl`, `kumactl`, `helm`, `docker`, and `k3d`; see `rules.rs`.
- `VersionedJsonRepository` saves atomically with tmp-file rename. Use the repository `load()` path instead of reading state files during saves.
- Use the installed XcodeBuildMCP skill before XcodeBuildMCP tools. Monitor app work needs a full worktree plus explicit `HARNESS_MONITOR_BUILD_LANE` and `HARNESS_MONITOR_RUNTIME_LANE`.
- Harness Monitor enables MCP accessibility tracking on normal app paths. In tracked-element hot paths, do not call `accessibilityFrame()` or republish on every `NSWindow.didUpdateNotification`; dense windows such as Settings can become visibly sluggish. Prefer clip-aware AppKit geometry conversion plus a throttled `didUpdate` refresh path.
