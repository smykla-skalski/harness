# Observe

Use this skill when the user wants to inspect, monitor, or triage another agent session through `harness observe`, especially to improve a live skill, hook, or test suite while the session is still active.

`harness` is the source of truth. Do not read or mutate host-owned session/state paths directly unless you are debugging a legacy fallback. The shared runtime state lives under:

- `~harness/projects/project-<digest>/agents/ledger/events.jsonl`
- `~harness/projects/project-<digest>/agents/sessions/<agent>/<session-id>/raw.jsonl`
- `~harness/projects/project-<digest>/agents/observe/<observe-id>/events.jsonl`
- `~harness/projects/project-<digest>/agents/observe/<observe-id>/snapshot.json`

Do not tell the user to edit those files manually. All reads, listing, and mutation go through `harness observe` or other `harness` commands.

## Contract

Use only the current observe surface:

- `harness observe [--agent <claude|codex|gemini|copilot>] [--observe-id <id>] doctor`
- `harness observe [--agent <...>] [--observe-id <id>] scan <session-id> ...`
- `harness observe [--agent <...>] [--observe-id <id>] watch <session-id> ...`
- `harness observe [--agent <...>] [--observe-id <id>] dump <session-id> ...`

Rules:

- `--agent` narrows canonical session resolution when the host is known.
- `--observe-id` selects the shared observer state stream. Default: `project-default`.
- Stateful maintenance stays under `harness observe scan <session-id> --action ...`.
- `harness observe doctor` is the wiring and contract check. Do not use the removed `scan --action doctor` form.
- For continuous monitoring, use `watch`. Do not invent host-specific cron, `/loop`, or background job instructions.

## Arguments

Parse from `$ARGUMENTS`:

| Argument | Default | Purpose |
| --- | --- | --- |
| positional | required | Session ID to observe |
| `--agent` | none | Narrow lookup to a specific host runtime |
| `--observe-id` | `project-default` | Shared observer state identity |
| `--from-line` | `0` | Start at a specific JSONL line |
| `--from` | none | Resolve the start from a line number, ISO timestamp, or prose substring |
| `--focus` | `all` | Preset category filter: `harness`, `skills`, or `all` |

Resolution rules for `--from`:

- omitted: start from the beginning unless the user explicitly asked to resume from current state
- numeric value: use directly as the starting line
- ISO timestamp: start at the first event at or after that timestamp
- prose: find the earliest matching substring in the session log

If prose resolution is ambiguous, ask the user which point they mean.

## Project hint

Do not pass `--project-hint` by default. Harness resolves canonical agent sessions globally.

Only add `--project-hint` if the scan returns `KSRCLI085` for an ambiguous session. Use the matching project names from the error or ask the user which project they mean.

## Workflow

### 1. Establish scope

Resolve:

- session ID
- optional `--agent`
- `--observe-id`
- optional `--project-hint`
- optional start from `--from` or `--from-line`
- optional `--focus` preset

If the user asked whether harness itself is wired correctly, or you suspect stale wrapper, pointer, or compact-handoff state, start with:

```bash
harness observe --agent <agent> --observe-id <observe-id> doctor --json
```

Omit `--agent` if it is unknown.

### 2. Run the baseline scan

Run a one-shot scan first:

```bash
harness observe --agent <agent> --observe-id <observe-id> scan <session-id> --json --summary
```

Add `--from-line`, `--from`, `--focus`, or `--project-hint` only when they are actually needed.

### 3. Summarize

Summarize briefly:

- counts by severity and category
- critical issues first
- whether the observer state is now established for this `observe-id`
- which fix target is most likely: skill, hook, suite, or harness code

Do not apply fixes automatically. Observe and triage first.

### 4. Continue monitoring when requested

For continuous monitoring, use `watch`:

```bash
harness observe --agent <agent> --observe-id <observe-id> watch <session-id> --poll-interval 3 --timeout 90 --json
```

Use `watch` only when the user wants ongoing observation. Do not start autonomous loops on your own.

### 5. Use maintenance actions through `scan --action`

The shared observer state is managed by harness. Use:

- `--action cycle` to advance the stored cursor and persist new findings
- `--action status` to inspect the current observer state
- `--action resume` to continue scanning from the stored cursor
- `--action verify` after a fix to see if the same fingerprint still reproduces
- `--action resolve-from` to resolve a line boundary from prose or timestamp
- `--action compare` to compare two windows
- `--action mute` / `--action unmute` to manage muted issue codes for the current `observe-id`

### 6. Use dump when the classifier may be wrong

Use `dump` when:

- a classifier finding looks suspicious
- the issue is `unexpected_behavior`
- you need exact raw session context around a line range

## Fix routing

Read [references/issue-taxonomy.md](references/issue-taxonomy.md) for category ownership, likely fix targets, and validation expectations.

Read [references/overrides.md](references/overrides.md) for mutes, focus presets, and overrides-file behavior.

When spawning a deeper analyst or fix worker:

- keep the session ID, `--agent`, and `--observe-id` in the prompt
- use `harness observe dump` or `harness observe scan --action compare` to gather context
- keep all state transitions in `harness`, not in ad hoc temp files

For Rust changes in this repo, validate with:

```bash
mise run check
TMPDIR=/tmp mise run test
```

## Output handling

For JSON scans:

- each issue is one JSON line
- each issue uses nested sections: `location`, `classification`, `source`, `message`, and `remediation`
- with `--summary`, the final line includes `cursor.last_line` and issue aggregates

For watch mode:

- issues stream as they arrive
- the final summary arrives when the timeout ends

For dump mode:

- use it to inspect raw context before deciding whether a classifier finding is real

## Scope

This skill is for observing and improving harness-managed agent session recordings through the `harness observe` pipeline. It is the live feedback loop for fixing skills, hooks, and suites, not a general-purpose log viewer or a replacement for the harness workflow state machines.

## Common failures

- **Missing session**: the session ID does not match any canonical ledger or legacy transcript. Verify the session ID first.
- **Ambiguous session**: add `--project-hint` or `--agent`.
- **Broken harness wiring**: run `harness observe doctor`.
- **Stale observer state**: use `scan --action status` and `scan --action cycle` for the same `--observe-id`.

## Example invocations

```bash
harness observe --agent codex --observe-id project-default doctor --json
```

```bash
harness observe --agent claude --observe-id incident-1 scan abc123 --json --summary
```

```bash
harness observe --agent gemini --observe-id incident-1 scan abc123 --action status
```

```bash
harness observe --agent copilot --observe-id incident-1 watch abc123 --json
```
