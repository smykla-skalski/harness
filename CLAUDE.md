# CLAUDE.md

Read `AGENTS.md` first - it is the canonical cross-runtime guide and covers build/test commands, agent asset architecture, harness CLI architecture, key modules, code conventions, commit signing, versioning, logging, clippy complexity, debugging discipline, Grafana dashboards, and gotchas. This file carries only the Claude Code deltas that AGENTS.md does not.

For the Harness Monitor macOS app (`apps/harness-monitor`), see that directory's own `CLAUDE.md` (Claude-specific deltas) and `AGENTS.md` (canonical Monitor guide).

## Task closeout

Finished tasks must end with the final work in the local `main` checkout, not only in the assigned session worktree or side branch. Use rebase or cherry-pick to replay the task onto local `main`; never create merge commits. Replay only committed worktree state, never dirty files. Before replaying, make sure the change builds or passes the smallest relevant validation in the worktree. Resolve conflicts by comparing current `main` behavior with the task intent, do not accept either side blindly, keep unrelated edits out of conflict resolution, rerun the smallest relevant validation from local `main`, and keep the session worktree/lane alive until the session ends or the user asks for cleanup.

For any goal or longer work split into chunks, do all work from one assigned custom worktree and reuse the same build/runtime lane for the whole Claude session, not per task. After every commit in that worktree, rebase the worktree branch onto current local `main` and resolve conflicts in the worktree first; then replay the finished task commit into `main`. Rebase and amend are allowed for your own unpublished commits in that assigned worktree. Do not rebase or amend local `main`, and do not force-push shared branches.

Parallel Claude sessions that edit, generate, build, test, run daemons, or use XcodeBuildMCP need separate full git worktrees. Lanes and env vars isolate build/runtime side effects inside a worktree; they do not make concurrent write/build work in one checkout acceptable.

## Path-limited commits

Commit with explicit paths passed straight to `git commit`: `git commit -sS -- <paths>`. Git stages exactly the listed paths for this commit and leaves the rest of the index and working tree untouched. For brand-new files, first run `git add -N -- <new-paths>` so Git can see them, then include those paths in the same path-limited commit. Do not pre-stage with plain `git add`, and never use `git add -A`, `git add .`, `git commit -a`, or `git commit -i`. Even with the worktree rule above, parallel agents and background tooling routinely drop unrelated edits into the working tree; path-limited commits keep them out of the signed history. Run `git diff -- <paths>` before committing to confirm the per-file scope.

## Hook system (Claude Code dispatch)

Claude Code uses these hook constants in `cli.rs` (Codex maps the same triggers to its unified `tool-guard` / `tool-result` / `tool-failure` constants - see `AGENTS.md`):

- **Pre-tool-use guards**: `guard-bash` (blocks direct cluster binary access), `guard-write` (blocks writes outside run surface), `guard-question`
- **Post-tool-use verifies**: `verify-bash`, `verify-write`, `verify-question`, `audit`
- **Blocking**: `guard-stop` (prevents session end if run incomplete, **off by default**)
- **Subagent gates**: `context-agent` (start), `validate-agent` (stop) — **off by default**
- **Failure enrichment**: `enrich-failure` / `tool-failure` (**off by default**)

The suite-lifecycle hooks (`guard-stop`, `context-agent`, `validate-agent`, `tool-failure`) are gated by `HARNESS_FEATURE_SUITE_HOOKS` (or `--enable-suite-hooks` on `harness setup bootstrap` and `harness setup agents generate`). Resolution lives in `src/feature_flags.rs::RuntimeHookFlags`. Bootstrap emits an `info!` line per regenerated config naming the omitted family.

## Versioning addenda

In addition to the canonical version surfaces listed in `AGENTS.md`, Claude-specific plugin paths:

- `.claude/plugins/suite/.claude-plugin/plugin.json` - bump only when plugin content changes (prompts, tools, SKILL.md, agent config); harness-only changes do not require a plugin version bump; `src/bootstrap.rs` reads this file for plugin-cache sync
- `.claude/plugins/harness/.claude-plugin/plugin.json` - bump only when harness plugin content changes (SKILL.md, agent config, references); harness-only changes do not require a plugin version bump

Never bump versions without explicit user approval. Changes to shipped `harness` or `aff` logic that mean the local binary must be reinstalled require a version bump once that approval exists. When working on `main`, make the approved bump in the same change. In a worktree or feature branch, defer the approved bump to `main` after merge to avoid conflicts.

## Logging addenda

Diagnostic output uses `tracing` macros. Default filter: `RUST_LOG=harness=info`.

## Async Monitor work

For Harness Monitor, do not perform real user-triggered work on the main thread after confirmation. Network mutations, policy actions, approvals, filesystem work, and other effectful jobs should be submitted as `HarnessMonitorAsyncWorkQueue.WorkItem`s to the global `HarnessMonitorAsyncWorkQueue.shared`. Do not create per-feature queues. The queue runs workers up to the active CPU count; update SwiftUI state and toasts by hopping back to the MainActor when the queued job finishes.

## UI test failures

When UI tests are failing, run one failing test at a time using `XCODE_ONLY_TESTING`. Never run a broad suite or multiple failing tests together — XCUITest runs block the whole machine and the run time compounds fast. Fix one, verify it passes, then move to the next.

## Working session efficiency

Token-burn lessons from real Claude Code sessions. Apply to every Harness Monitor crash or regression triage:

1. **Read `MEMORY.md` first.** Scan the index for the symptom family (e.g. `DisplayLink`, `deinit`, `MainActor`, `dispatch_assert`) before spawning an Explore subagent or running broad `grep` / `git log -G` sweeps. Past entries often name the exact file, fix pattern, and follow-ups.
2. **Match the crash artifact before reading it.** A `.ips` in `~/Library/Logs/DiagnosticReports/` is only relevant if its timestamp, signal, and faulting frame line up with the screenshot the user pasted. Reading an unrelated abort report wastes a full context window.
3. **Don't spawn an Explore subagent for "what's wrong" questions.** Use it only for "where is X defined" or "list call sites of Y". For diagnosis, pull the file the user pointed at and trace from there.
4. **Pick the deinit-isolation fix in this order on Swift 6.2 + macOS 26:** (a) `nonisolated(unsafe)` on the storage + thread-safe inline cleanup in deinit; (b) move the MainActor-only step into `dismantleNSView`. Do not try `isolated deinit` (SE-0371) first — the project does not enable that upcoming feature, and editor/format passes can revert the syntax silently.
5. **For slow Monitor Settings or toolbar interactions, inspect MCP accessibility tracking before rewriting SwiftUI layout.** Dense surfaces mount many `.harnessMCPButton` probes, and a probe that resolves `accessibilityFrame()` or republishes unthrottled on `NSWindow.didUpdateNotification` can make the whole window feel frozen. Prefer clip-aware AppKit geometry conversion plus throttled `didUpdate` refreshes.
