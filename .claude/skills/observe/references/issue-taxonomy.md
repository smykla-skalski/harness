# Issue taxonomy

Categories, severity levels, and fix routing for the session observer.

## Categories

| Category | Description | Typical fix target |
| --- | --- | --- |
| hook_failure | Guard or verify hook blocked/errored unexpectedly | `src/hooks/`, SKILL.md hook config |
| skill_behavior | Skill deviated from its SKILL.md instructions | `skills/*/SKILL.md` |
| cli_error | Harness CLI returned unexpected error or bad args | `src/cli.rs`, `src/commands/` |
| build_error | Cargo check/clippy/test failure | Rust source files |
| workflow_error | State machine or approval flow in wrong state | `src/workflow/` |
| naming_error | Old or wrong skill/path names used | SKILL.md, `src/rules.rs`, `src/bootstrap.rs` |
| tool_error | Claude tool usage error (edit before read, etc.) | Not fixable in harness - model behavior |
| data_integrity | Stale state, corrupted payloads, missing artifacts | `src/authoring.rs`, `src/workflow/` |
| subagent_issue | Worker agent returned wrong format or failed | Agent descriptors in `agents/` |
| unexpected_behavior | Anything that doesn't fit above but looks wrong | Triage manually |

## Severity levels

| Level | Meaning | Action |
| --- | --- | --- |
| critical | Breaks functionality, blocks the skill workflow | Dispatch fix worker immediately |
| medium | Causes user friction, wrong output, wasted time | Dispatch fix worker or report to user |
| low | Cosmetic, self-correcting, or minor inefficiency | Log and report in summary |

## Fix routing

When dispatching a fix worker, provide:

1. The issue summary and affected lines
2. The specific file(s) to fix
3. What the correct behavior should be
4. A requirement to run `cargo clippy --lib && cargo test --lib` for Rust changes
5. A requirement to verify the fix doesn't break anything else

### Common fix patterns

**Hook not firing**: Check bootstrap wrapper path, SKILL.md hook commands, harness CLI skill name validation.

**Wrong question asked**: Update SKILL.md step instructions to add precondition checks.

**CLI argument error**: Fix `src/cli.rs` value_parser or add the missing subcommand/kind.

**Build failure**: Fix the Rust code, ensure clippy pedantic passes.

**Stale state**: Check `src/authoring.rs` or `src/workflow/` for state cleanup logic.

**Old names**: Search for `suite-author`/`suite-runner` in all files and replace with `suite:new`/`suite:run`.
