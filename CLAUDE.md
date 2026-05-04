# CLAUDE.md

Read `AGENTS.md` first - it is the canonical cross-runtime guide and covers build/test commands, agent asset architecture, harness CLI architecture, key modules, code conventions, commit signing, versioning, logging, clippy complexity, debugging discipline, Grafana dashboards, and gotchas. This file carries only the Claude Code deltas that AGENTS.md does not.

For the Harness Monitor macOS app (`apps/harness-monitor-macos`), see that directory's own `CLAUDE.md` (Claude-specific deltas) and `AGENTS.md` (canonical Monitor guide).

## Command execution

**Always use `rtk`** - it is the token-optimized proxy for shell commands and saves 60-90% on dev operations. Prefix every shell command with `rtk` (e.g. `rtk git status`, `rtk cargo test`). The Claude Code hook auto-rewrites commands transparently; do not fight it.

**`rtk proxy` is last resort only.** It bypasses all output filters and leaks raw command output (4000+ line dumps), burning the context window. Use it only when filtered output hides information you genuinely need to debug a specific issue, and switch back to plain `rtk` immediately after.

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

When working on `main`, make the approved bump in the same change. In a worktree or feature branch, defer the approved bump to `main` after merge to avoid conflicts.

## Working session efficiency

Token-burn lessons from real Claude Code sessions. Apply to every Harness Monitor crash or regression triage:

1. **Read `MEMORY.md` first.** Scan the index for the symptom family (e.g. `DisplayLink`, `deinit`, `MainActor`, `dispatch_assert`) before spawning an Explore subagent or running broad `grep` / `git log -G` sweeps. Past entries often name the exact file, fix pattern, and follow-ups.
2. **Match the crash artifact before reading it.** A `.ips` in `~/Library/Logs/DiagnosticReports/` is only relevant if its timestamp, signal, and faulting frame line up with the screenshot the user pasted. Reading an unrelated abort report wastes a full context window.
3. **Don't spawn an Explore subagent for "what's wrong" questions.** Use it only for "where is X defined" or "list call sites of Y". For diagnosis, pull the file the user pointed at and trace from there.
4. **Pick the deinit-isolation fix in this order on Swift 6.2 + macOS 26:** (a) `nonisolated(unsafe)` on the storage + thread-safe inline cleanup in deinit; (b) move the MainActor-only step into `dismantleNSView`. Do not try `isolated deinit` (SE-0371) first — the project does not enable that upcoming feature, and editor/format passes can revert the syntax silently.
