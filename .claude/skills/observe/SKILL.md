---
name: observe
description: >-
  Session observer for harness and skill testing. Use it to scan, watch, or dump
  another Claude Code session with the current `harness observe` contract.
argument-hint: "<session-id> [--from-line N] [--from <line|timestamp|prose>] [--focus harness|skills|all]"
allowed-tools: AskUserQuestion, Bash, Edit, Read
disable-model-invocation: true
user-invocable: true
---

# Observe

Use this skill when the user wants to inspect or monitor another Claude Code session and `harness observe` is the source of truth.

This skill must follow the current observe contract to prevent drift between the skill instructions and the CLI binary:
- top-level subcommands are `scan`, `watch`, and `dump`
- maintenance operations are routed through `harness observe scan <session-id> --action ...`
- observer state is stored automatically at `$XDG_DATA_HOME/harness/observe/<SESSION_ID>.state`

Do not use the removed top-level observe maintenance commands because they were consolidated under `scan --action ...` and the old entry points no longer resolve.

Do not assume autonomous fixing because misidentified classifier findings can cause regressions if applied without triage. Observe first, summarize clearly, and ask the user before applying fixes or spawning deeper analysis.

## Arguments

Parse from `$ARGUMENTS`:

| Argument | Default | Purpose |
| --- | --- | --- |
| positional | required | Session ID to observe |
| `--from-line` | `0` | Start at a specific JSONL line |
| `--from` | none | Resolve the start from a line number, ISO timestamp, or prose substring |
| `--focus` | `all` | Preset category filter: `harness`, `skills`, or `all` |

Resolution rules for `--from`:
- numeric value: use directly as the starting line
- ISO timestamp: start at the first event at or after that timestamp
- prose: find the earliest matching substring in the session log

If prose resolution is ambiguous, ask the user which point they mean before proceeding.

## Project hint

When `CLAUDE_PROJECT_DIR` is available, derive `--project-hint` from it:

```bash
PROJECT_HINT=$(basename "$CLAUDE_PROJECT_DIR")
```

If `CLAUDE_PROJECT_DIR` is unset, omit `--project-hint`.

## Workflow

### 1. Establish scope

Resolve:
- session ID
- `--project-hint`
- optional start from `--from` or `--from-line`
- optional `--focus` preset

If the user did not request continuous monitoring, start with a one-shot scan.

Read [references/command-surface.md](references/command-surface.md) for the full list of supported invocation shapes and maintenance actions.

### 2. Run the initial scan

Preferred baseline:

```bash
harness observe scan <session-id> --project-hint <hint> --json --summary
```

If the user requested a narrower slice, add the filters up front instead of scanning wide and triaging noise later.

### 3. Triage before fixing

Summarize:
- counts by severity
- counts by category
- critical issues first
- whether the issues look fixable, advisory, or likely environment noise

Default follow-up question:
"Found N issues, including X critical. Do you want me to fix anything now, or just keep observing?"

### 4. Use dump or verify when needed

Use `dump` when:
- a classifier finding looks suspicious
- the issue is `unexpected_behavior`
- you need the exact session context around a line

Use `scan --action verify` after a fix to check whether the same fingerprint still reproduces.

### 5. Continuous monitoring

Use `watch` only when the user explicitly wants live monitoring in the current session.

Use `scan --action cycle` only when you want persisted observer cursor/state behavior. It is stateful maintenance, not the default scan path.

## Deep analysis

If the user explicitly asks for a deeper pass, read [agents/deep-analyst.md](agents/deep-analyst.md) and review a recent dump window holistically.

Do not spawn deep analysts or fix workers by default. Ask first.

## Fix routing

Read [references/issue-taxonomy.md](references/issue-taxonomy.md) for category ownership, likely fix targets, and validation expectations.

Read [references/overrides.md](references/overrides.md) for mutes, focus presets, and overrides-file behavior.

When a fix is approved, use Edit to apply the change to the identified fix target. For Rust changes in this repo, validate with:

```bash
mise run check
TMPDIR=/tmp mise run test
```

For skill or docs changes, re-check the referenced observe command surface against source before claiming the skill is fresh.

## Output handling

For JSON scans:
- each issue is one JSON line
- with `--summary`, the final line is the summary object
- `last_line` from the summary is the next cursor for incremental follow-up

For watch mode:
- issues stream as they arrive
- the summary arrives when the timeout ends

For dump mode:
- use it to inspect raw context before deciding whether a classifier finding is real

## Example invocations

<example>
Scan a session with default settings:

```bash
harness observe scan abc123 --project-hint harness --json --summary
```
</example>

<example>
Resume from a specific line with harness-only focus:

```bash
harness observe scan abc123 --project-hint harness --from-line 500 --focus harness --json --summary
```
</example>

<example>
Start from a prose match and filter to skills issues:

```bash
harness observe scan abc123 --project-hint harness --from "suite:run started" --focus skills --json --summary
```
</example>
