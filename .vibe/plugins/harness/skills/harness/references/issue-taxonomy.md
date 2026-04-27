# Issue taxonomy

Categories, severity, fix safety, ownership, and routing guidance for `harness observe`.

## Contents

- [Categories](#categories)
- [Severity](#severity)
- [Fix routing](#fix-routing)
- [Common fix patterns](#common-fix-patterns)

## Categories

### hook_failure
- **Confidence**: high
- **Fix safety**: triage_required
- **Owner**: harness
- **Root cause**: guard or verify hook denied or errored unexpectedly
- **Fix target**: `src/hooks/`, skill files, or hook transport wiring
- **Validation**: `mise run check` and `TMPDIR=/tmp mise run test`

### skill_behavior
- **Confidence**: medium-high
- **Fix safety**: triage_required or auto_fix_guarded
- **Owner**: skill
- **Root cause**: skill drifted from contract or examples
- **Fix target**: SKILL.md, references, agent descriptors
- **Validation**: re-run affected skill path and repo gates

### cli_error
- **Confidence**: high
- **Fix safety**: auto_fix_safe
- **Owner**: harness
- **Root cause**: harness returned unexpected error or bad arg handling
- **Fix target**: `src/app/cli.rs` plus owning domain
- **Validation**: `mise run check` and `TMPDIR=/tmp mise run test`

### build_error
- **Confidence**: high
- **Fix safety**: auto_fix_safe
- **Owner**: harness
- **Root cause**: cargo check, clippy, or tests failed
- **Fix target**: Rust source files identified in failure
- **Validation**: `mise run check` and `TMPDIR=/tmp mise run test`

### workflow_error
- **Confidence**: high
- **Fix safety**: auto_fix_guarded
- **Owner**: harness
- **Root cause**: workflow or state machine in wrong state
- **Fix target**: owning workflow under `src/run/`, `src/create/`, `src/hooks/`
- **Validation**: `mise run check` and `TMPDIR=/tmp mise run test`

### naming_error
- **Confidence**: high
- **Fix safety**: auto_fix_safe
- **Owner**: skill
- **Root cause**: old or wrong command names, skill names, path roots
- **Fix target**: SKILL.md files, `src/app/cli.rs`
- **Validation**: grep for stale names and re-check current surface

### tool_error
- **Confidence**: high
- **Fix safety**: advisory_only
- **Owner**: model
- **Root cause**: tool used incorrectly
- **Fix target**: usually not a harness code fix
- **Validation**: n/a

### data_integrity
- **Confidence**: medium-high
- **Fix safety**: triage_required
- **Owner**: harness or product
- **Root cause**: stale state, corrupted payloads, missing artifacts
- **Fix target**: `src/run/`, `src/create/`, `src/workspace/`, `src/observe/`
- **Validation**: rerun affected flow plus repo gates

### subagent_issue
- **Confidence**: medium
- **Fix safety**: auto_fix_guarded
- **Owner**: skill
- **Root cause**: worker or analyst agent configured incorrectly
- **Fix target**: SKILL.md, agent descriptor, references
- **Validation**: rerun subagent path with corrected prompt

### unexpected_behavior
- **Confidence**: medium
- **Fix safety**: advisory_only or triage_required
- **Owner**: varies
- **Root cause**: suspicious behavior not fitting known buckets
- **Fix target**: manual triage
- **Validation**: case-by-case

### user_frustration
- **Confidence**: low
- **Fix safety**: advisory_only
- **Owner**: harness UX or skill UX
- **Root cause**: frustration signals in observed session
- **Fix target**: preceding UX or instruction path
- **Validation**: n/a

## Severity

| Level | Meaning | Default action |
|-------|---------|----------------|
| critical | Blocks workflow or produces clearly wrong behavior | Escalate first, then fix if approved |
| medium | Wrong output, friction, or wasted time | Fix if user asks, otherwise report |
| low | Cosmetic or minor inefficiency | Log and report |

## Fix routing

When preparing a fix proposal or worker handoff, include:

1. Issue summary and line references
2. Likely fix target
3. Expected correct behavior
4. Required validation
5. Whether safe to auto-fix or needs approval

For Rust changes in this repo:

```bash
mise run check
TMPDIR=/tmp mise run test
```

## Common fix patterns

**Hook not firing**: check hook registration, skill config, hook transport wiring under `src/hooks/`.

**Wrong question or wrong operator flow**: update owning SKILL.md or agent descriptor with missing precondition checks.

**CLI argument error**: fix `src/app/cli.rs` or owning transport layer.

**Build failure**: fix Rust code, then run repo gates.

**Stale state**: check owning state store under `src/run/`, `src/create/`, `src/workspace/`, `src/observe/`.

**Old names or old paths**: search for stale subcommands, skill names, or storage paths and align with current harness contract.
