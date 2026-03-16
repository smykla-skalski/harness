# Issue taxonomy

Categories, severity levels, confidence, fix safety, and fix routing for the session observer.

## Categories

### hook_failure
- Confidence: high
- Fix safety: triage_required (hooks are safety-critical)
- Owner: harness
- Root cause: guard/verify hook denied or errored unexpectedly
- Fix target: `src/hooks/`, SKILL.md hook config
- Validation: `cargo test --lib hooks`
- False positives: intentional denials (hook working correctly)
- Retry: max 2 attempts, escalate on 3rd
- Escalation: ask user if the denial is expected behavior

### skill_behavior
- Confidence: medium-high
- Fix safety: triage_required or auto_fix_guarded
- Owner: skill
- Root cause: skill deviated from SKILL.md instructions
- Fix target: `skills/*/SKILL.md`
- Validation: re-run the skill step that failed
- False positives: model creativity that happens to match a pattern
- Retry: max 2 attempts, escalate on 3rd
- Escalation: show both attempts to user

### cli_error
- Confidence: high
- Fix safety: auto_fix_safe
- Owner: harness
- Root cause: harness CLI returned unexpected error or bad args
- Fix target: `src/cli.rs`, `src/commands/`
- Validation: `cargo clippy --lib && cargo test --lib`
- False positives: rare - CLI errors are unambiguous
- Retry: max 2 attempts
- Escalation: include the full error message

### build_error
- Confidence: high
- Fix safety: auto_fix_safe
- Owner: harness
- Root cause: cargo check/clippy/test failure
- Fix target: Rust source files indicated in error
- Validation: `cargo clippy --lib && cargo test --lib`
- False positives: none - compiler errors are definitive
- Retry: max 2 attempts
- Escalation: include compiler output

### workflow_error
- Confidence: high
- Fix safety: auto_fix_guarded
- Owner: harness
- Root cause: state machine or approval flow in wrong state
- Fix target: `src/workflow/`
- Validation: `cargo test --lib workflow`
- False positives: transient state during transitions
- Retry: max 2 attempts
- Escalation: include current state and expected state

### naming_error
- Confidence: high
- Fix safety: auto_fix_safe
- Owner: skill
- Root cause: old or wrong skill/path names used
- Fix target: SKILL.md, `src/rules.rs`
- Validation: grep for old names
- False positives: none
- Retry: 1 attempt (mechanical fix)

### tool_error
- Confidence: high
- Fix safety: advisory_only
- Owner: model
- Root cause: Claude tool usage error (edit before read, etc.)
- Fix target: not fixable in harness - model behavior
- Validation: n/a
- False positives: none
- Retry: 0 (model must self-correct)

### data_integrity
- Confidence: medium-high
- Fix safety: triage_required
- Owner: harness or product
- Root cause: stale state, corrupted payloads, missing artifacts
- Fix target: `src/authoring.rs`, `src/workflow/`
- Validation: re-run the failing operation
- False positives: transient filesystem state
- Retry: max 2 attempts
- Escalation: include file contents and expected shape

### subagent_issue
- Confidence: medium
- Fix safety: auto_fix_guarded
- Owner: skill
- Root cause: worker agent permissions, wrong format, or failed save
- Fix target: agent descriptors, SKILL.md agent config
- Validation: re-spawn the agent
- False positives: permission prompts that the user handled
- Retry: max 2 attempts
- Escalation: include agent output

### unexpected_behavior
- Confidence: medium
- Fix safety: advisory_only or triage_required
- Owner: varies (harness/skill/model)
- Root cause: anything that doesn't fit above but looks wrong
- Fix target: triage manually
- Validation: case-by-case
- False positives: shell aliases, env differences
- Retry: 0 (needs human judgment)

### user_frustration
- Confidence: low
- Fix safety: advisory_only
- Owner: harness (UX)
- Root cause: user frustration signals (!!!, explicit complaints)
- Fix target: review UX of the preceding interaction
- Validation: n/a
- False positives: enthusiastic punctuation, quoted text
- Retry: 0 (observational only)

## Severity levels

| Level | Meaning | Action |
| --- | --- | --- |
| critical | Breaks functionality, blocks the skill workflow | Dispatch fix worker immediately |
| medium | Causes user friction, wrong output, wasted time | Dispatch fix worker or report to user |
| low | Cosmetic, self-correcting, or minor inefficiency | Log and report in summary |

## Fix routing

When dispatching a fix worker, provide:

1. The issue summary, issue_id, and affected lines
2. The specific file(s) to fix (from fix_target)
3. What the correct behavior should be (from fix_hint)
4. A requirement to run `cargo clippy --lib && cargo test --lib` for Rust changes
5. A requirement to verify the fix doesn't break anything else
6. The fix_safety level - auto_fix_safe can proceed without confirmation, auto_fix_guarded needs a test pass, triage_required needs user approval

### Common fix patterns

**Hook not firing**: Check bootstrap wrapper path, SKILL.md hook commands, harness CLI skill name validation.

**Wrong question asked**: Update SKILL.md step instructions to add precondition checks.

**CLI argument error**: Fix `src/cli.rs` value_parser or add the missing subcommand/kind.

**Build failure**: Fix the Rust code, ensure clippy pedantic passes.

**Stale state**: Check `src/authoring.rs` or `src/workflow/` for state cleanup logic.

**Old names**: Search for `suite-author`/`suite-runner` in all files and replace with `suite:new`/`suite:run`.

### Retry and escalation policy

- Max 2 fix attempts per issue before escalating to user
- After escalation, include both attempts' output and the original issue details
- Never retry advisory_only issues - report and move on
- Batch issues with the same code + fix_target into a single worker
