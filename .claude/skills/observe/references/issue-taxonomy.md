# Issue taxonomy

Categories, severity, fix safety, ownership, and routing guidance for `harness observe`.

## Contents

- [Categories](#categories)
- [Severity](#severity)
- [Fix routing](#fix-routing)
- [Common fix patterns](#common-fix-patterns)

## Categories

### hook_failure
- Confidence: high
- Fix safety: triage_required
- Owner: harness
- Root cause: guard or verify hook denied or errored unexpectedly
- Fix target: `src/hooks/`, `.claude/plugins/suite/skills/`, or hook transport wiring
- Validation: `mise run check` and `TMPDIR=/tmp mise run test`

### skill_behavior
- Confidence: medium-high
- Fix safety: triage_required or auto_fix_guarded
- Owner: skill
- Root cause: the skill drifted from its contract or examples
- Fix target: `.claude/skills/*/SKILL.md`, `.claude/plugins/suite/skills/*/SKILL.md`, references, or agent descriptors
- Validation: re-run the affected skill path and the repo gates when code changed

### cli_error
- Confidence: high
- Fix safety: auto_fix_safe
- Owner: harness
- Root cause: `harness` returned an unexpected error or bad arg handling
- Fix target: `src/app/cli.rs` plus the owning domain under `src/run/`, `src/setup/`, `src/authoring/`, `src/observe/`, or `src/hooks/`
- Validation: `mise run check` and `TMPDIR=/tmp mise run test`

### build_error
- Confidence: high
- Fix safety: auto_fix_safe
- Owner: harness
- Root cause: `cargo check`, clippy, or tests failed
- Fix target: the Rust source files identified in the failure
- Validation: `mise run check` and `TMPDIR=/tmp mise run test`

### workflow_error
- Confidence: high
- Fix safety: auto_fix_guarded
- Owner: harness
- Root cause: a workflow or state machine is in the wrong state
- Fix target: the owning workflow under `src/run/`, `src/authoring/`, `src/hooks/`, or `src/workspace/`
- Validation: `mise run check` and `TMPDIR=/tmp mise run test`

### naming_error
- Confidence: high
- Fix safety: auto_fix_safe
- Owner: skill
- Root cause: old or wrong command names, skill names, or path roots are still used
- Fix target: SKILL.md files, `.claude/plugins/suite/skills/`, `src/kernel/skills.rs`, or `src/app/cli.rs`
- Validation: grep for stale names and re-check the current command surface in source

### tool_error
- Confidence: high
- Fix safety: advisory_only
- Owner: model
- Root cause: a tool was used incorrectly
- Fix target: usually not a harness code fix
- Validation: n/a

### data_integrity
- Confidence: medium-high
- Fix safety: triage_required
- Owner: harness or product
- Root cause: stale state, corrupted payloads, missing artifacts, or invalid persisted data
- Fix target: `src/run/`, `src/authoring/`, `src/workspace/`, or `src/observe/`
- Validation: rerun the affected flow plus the repo gates if code changed

### subagent_issue
- Confidence: medium
- Fix safety: auto_fix_guarded
- Owner: skill
- Root cause: a worker or analyst agent was configured incorrectly or returned unusable output
- Fix target: the owning SKILL.md, agent descriptor, or supporting reference docs
- Validation: rerun the subagent path with the corrected prompt or descriptor

### unexpected_behavior
- Confidence: medium
- Fix safety: advisory_only or triage_required
- Owner: varies
- Root cause: suspicious behavior that does not fit the known classifier buckets
- Fix target: manual triage
- Validation: case-by-case

### user_frustration
- Confidence: low
- Fix safety: advisory_only
- Owner: harness UX or skill UX
- Root cause: frustration signals in the observed session
- Fix target: the immediately preceding UX or instruction path
- Validation: n/a

## Severity

| Level | Meaning | Default action |
| --- | --- | --- |
| critical | blocks the workflow or produces clearly wrong behavior | escalate first, then fix if approved |
| medium | wrong output, friction, or wasted time | fix if user asks, otherwise report |
| low | cosmetic or minor inefficiency | log and report |

## Fix routing

When preparing a fix proposal or worker handoff, include:

1. the issue summary and line references
2. the likely fix target
3. the expected correct behavior
4. the required validation
5. whether the issue is safe to fix automatically or needs approval

For Rust changes in this repo, the required validation is:

```bash
mise run check
TMPDIR=/tmp mise run test
```

## Common fix patterns

**Hook not firing**: check hook registration, skill config, and hook transport wiring under `src/hooks/`.

**Wrong question or wrong operator flow**: update the owning SKILL.md or agent descriptor to add the missing precondition checks.

**CLI argument error**: fix `src/app/cli.rs` or the owning observe/run/setup transport layer.

**Build failure**: fix the Rust code, then run the repo gates.

**Stale state**: check the owning state store under `src/run/`, `src/authoring/`, `src/workspace/`, or `src/observe/`.

**Old names or old paths**: search for stale subcommands, stale skill names, or stale `kuma` storage paths and align them with the current `harness` contract.
