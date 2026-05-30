# AGENTS.md

This is the repo-level contract for agents working in `harness`. Direct system,
developer, and user instructions outrank this file. A deeper `AGENTS.md`
overrides this file for its subtree.

## How to use this file

1. Start with the task-routing table and load the deepest relevant
   `AGENTS.md` before editing.
2. Treat the hard rules here as mandatory: `mise` workflows, isolated
   worktrees for longer/editing work, path-limited signed commits, scoped
   validation, and final replay onto local `main`.
3. Load reference docs only when the task touches that area. Keep the prompt
   path short; this file is the contract, not the full design archive.

## Task routing

| Work area | Start here |
| --- | --- |
| Rust CLI, hooks, orchestration, agent assets | This file, then `docs/agent-guides/root-reference.md` when details are needed |
| Harness Monitor macOS app | `apps/harness-monitor/AGENTS.md` |
| Monitor previewable SwiftUI layer | `apps/harness-monitor/Sources/HarnessMonitorUIPreviewable/AGENTS.md` |
| Generated plugin/skill output roots | The local generated-root `AGENTS.md`; update canonical sources, not outputs |
| Runtime config layering | `docs/agents/runtime-config-layering.md` |

## Command execution

Discover repo workflows with `mise tasks ls`. Run repo logic through
`mise run <task>` or `mise run <task> -- <args>` whenever a task exists.
Do not wrap `mise` in `bash -lc`, `zsh -lc`, the `env` binary, or helper
scripts. When an environment assignment is needed, put it before `mise`, for
example `VAR=value mise run ...`. Do not run repo scripts, direct `cargo`,
or direct `xcodebuild` when a `mise` task covers the workflow. Direct
`cargo ...` is acceptable only for targeted Rust diagnosis that has no
equivalent `mise` task granularity.

If several commands could apply, choose the smallest one that proves the
change. Use broad gates only when the change affects shared behavior or before
a final handoff that needs them.

## Parallel worktrees

Every parallel user, agent, or long-running task that edits files, generates
projects, builds, tests, runs daemons, or drives XcodeBuildMCP must use its own
full git worktree. Build/runtime lanes isolate caches, daemon state, ports,
labels, and sockets inside a worktree; they do not replace a separate checkout.

For any goal or longer work split into smaller chunks, do all work from one
assigned custom worktree and reuse the same build/runtime lane for that
worktree. After every commit in that worktree, rebase the worktree branch onto
current local `main` and resolve any conflicts inside the worktree first. The
later replay onto `main` should then be mechanical. This is a hard rule.

Temporary worktrees are for isolation during the task, not for final landing.
Once the work is complete, replay it into the local `main` checkout. If the work
is fully present in local `main`, clean up the temporary worktree and its branch.

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
`tests/integration/` and run single-threaded for environment safety. Tests that
read XDG paths must isolate state with `temp_env::with_vars`, setting both
`XDG_DATA_HOME` and `CLAUDE_SESSION_ID`. Tests use real filesystem state.

Pre-commit gate: `mise run check`. Add `mise run aff:check` when the
task touches `aff` or aff-owned runtime hooks.

Validation should match risk:

- Docs-only or generated-guide edits: `mise run check:agent-assets`, plus
  `git diff --check`.
- Narrow Rust logic: the focused unit/integration test first, then the smallest
  relevant `mise` gate.
- Shared CLI, hook, runtime, or storage behavior: run the focused test and the
  owning package gate before `mise run check`.
- `aff` code or aff-owned runtime hooks: include `mise run aff:check`.

## Agent assets

Canonical source roots:

- `agents/skills/` and `agents/plugins/` for cross-runtime assets.
- `local-skills/claude/` for Claude-only project-local skills.

Managed output roots include `.claude/`, `.agents/`, `.gemini/`, `.vibe/`,
`.opencode/`, `.github/hooks/`, `.claude-plugin/`, and `plugins/`. Each managed
root has a generated `AGENTS.md` marker. Do not hand-edit generated outputs.
If a requested edit points at a managed root, update the canonical source or
the renderer, regenerate, and commit the regenerated output.

Use:

```bash
mise run setup:agents:generate
mise run setup:bootstrap
mise run check:agent-assets
```

## Architecture

Harness is a test orchestration framework for Kubernetes/Kuma. It enforces
tracked, user-story-first testing through state machines and hook-based
guardrails.

Core areas:

- `src/workflow/` owns `suite:run` and `suite:create`.
- `src/hooks/` and `src/cli.rs` own tool lifecycle hooks and hook dispatch.
- `src/session/` owns multi-agent orchestration state, roles, service logic,
  transport, storage, and observation.
- `src/agents/runtime/` owns runtime adapters for Claude, Codex, Gemini,
  Copilot, Vibe, and OpenCode.
- `src/commands/` owns CLI command handlers.
- Harness Monitor UI-triggered real work must leave the main thread through the
  global generic async work queue. Use `HarnessMonitorAsyncWorkQueue.shared`
  instead of route-local or action-specific queues; workers scale to the active
  CPU count, and UI state/toasts should hop back to the MainActor only for
  completion updates.

Detailed module and data-directory notes live in
`docs/agent-guides/root-reference.md`.

## AGENTS.md maintenance

Keep agent guides short, scoped, and actionable. Put hard rules, routing, and
copy-paste commands in `AGENTS.md`; move background, long rationale, and
subsystem internals to `docs/agent-guides/`. Generated-root guide text lives in
`src/agents/assets/render_guides.rs`; regenerate outputs after changing it.

## Hooks

The active unified tool lifecycle is `tool-guard`, `tool-result`, and optional
`tool-failure`. Suite-lifecycle hooks (`guard-stop`, `context-agent`,
`validate-agent`, `tool-failure`) are off by default unless enabled with
`HARNESS_FEATURE_SUITE_HOOKS=1` or the matching setup flag.

Repo-policy/manual-task enforcement is owned by the standalone `aff` CLI. Keep
harness-owned setup (`setup:bootstrap`, `setup:agents:generate`,
`check:agent-assets`) separate from the manual `aff:*` tasks.

Hook landing rule: a new hook lands with observable handler behavior, or behind
a dated feature flag in `src/feature_flags.rs` with a tracking issue.

## Code conventions

- Rust 2024 edition, rustc 1.94+.
- Clippy pedantic is `deny`; new Rust must pass it.
- Errors use `CliErrorKind` variants with typed fields via `thiserror`.
- Hook messages use `HookMessage` with `into_result()`.
- Diagnostic output uses `tracing` macros. Default filter: `RUST_LOG=harness=info`. Do not add `eprintln!` diagnostics.
- Commit messages: `{type}({scope}): {message}` with `feat`, `fix`,
  `refactor`, `chore`, `docs`, `test`, or `perf`.
- Never create merge commits. Keep history flat with rebase or cherry-pick. The no-rebase/no-amend/no-force-push restriction applies when working directly in local `main`. In an assigned worktree, rebase onto local `main` and amend only your own unpublished commits when needed to keep the branch easy to replay; never rewrite local `main` history or force-push shared branches.

## Commit signing

Every commit must use path-limited `git commit -sS -- <paths>`. Pass the file
list directly to `git commit`; git stages exactly those paths for this commit
and leaves the rest of the index and working tree alone. For brand-new files,
first run `git add -N -- <new-paths>` so Git can see them, then include those
paths in the same path-limited commit. Do not pre-stage with plain `git add`,
and do not use `git add -A`, `git add .`, `git commit -a`, or `git commit -i`.
Parallel agents on the same worktree routinely have unrelated edits in flight,
and path-limited commits keep them out of the signed history. Verify after
committing:

```bash
git log --show-signature -1
```

The sign-off trailer must be exactly:

```text
Signed-off-by: Bart Smykla <bartek@smykla.com>
```

Never bypass signing with `--no-gpg-sign`, `-c commit.gpgsign=false`,
`--no-verify`, or another key. If 1Password signing is unavailable, stop and
wait for the user.

## Closeout and versioning

Every finished task must end with the final work present in the local `main`
checkout with clean, flat history. Use a temporary worktree or branch for
isolated development when needed, but before handoff update local `main`,
replay the task changes there, and rerun the smallest relevant validation from
local `main`. Resolve conflicts in the assigned worktree during the post-commit
rebase onto current local `main`, not during the final replay when you can
avoid it. If the work is fully landed in local `main`, remove the temporary
worktree and branch afterward.

Every change must evaluate semver. Do not bump versions without explicit user approval. Docs-only changes normally require no version bump. If shipped `harness` or `aff` behavior changes enough that the local binary must be reinstalled, a version bump is required after approval.

Use `mise run version:set -- <version>` for approved bumps, or
`mise run version:sync` after any direct canonical-version edit. See
`docs/agent-guides/root-reference.md` for derived version surfaces.

## Debugging discipline

Start with real data. Reproduce with the smallest targeted command and collect
preserved traces, logs, screenshots, or failure artifacts before changing
behavior. If the signal is weak, improve observability first. Correlate across
layers, patch the proven cause only, keep each iteration single-cause, and keep
task state honest.

## Build lane and fsmonitor cleanup

Harness Monitor xcodebuild lane internals and fsmonitor cleanup details live in
`docs/agent-guides/root-reference.md`. Use the `clean:*` mise tasks documented
there; do not raise the host-wide Monitor xcodebuild concurrency cap.

## Gotchas

- `tool-guard` denies direct use of `kubectl`, `kumactl`, `helm`, `docker`, and
  `k3d`; see `rules.rs`.
- `VersionedJsonRepository` saves atomically with tmp-file rename. Use the
  repository `load()` path instead of reading state files during saves.
- Use the installed XcodeBuildMCP skill before XcodeBuildMCP tools. Monitor app
  work needs a full worktree plus explicit `HARNESS_MONITOR_BUILD_LANE` and
  `HARNESS_MONITOR_RUNTIME_LANE`.
- Harness Monitor enables MCP accessibility tracking on normal app paths. In
  tracked-element hot paths, do not call `accessibilityFrame()` or republish on
  every `NSWindow.didUpdateNotification`; dense windows such as Settings can
  become visibly sluggish. Prefer clip-aware AppKit geometry conversion plus a
  throttled `didUpdate` refresh path.
