---
name: observe
description: >-
  Session observer for harness and skill testing. Use it to scan, watch, or dump
  another Claude Code session with the current `harness observe` contract.
argument-hint: "<session-id> [--from-line N] [--from <line|timestamp|prose>] [--focus harness|skills|all]"
allowed-tools: Agent, AskUserQuestion, Bash, CronDelete, CronList, Edit, Glob, Grep, Read, Skill
disable-model-invocation: true
user-invocable: true
hooks:
  Stop:
    - hooks:
        - type: command
          command: "harness hook --skill observe guard-stop"
---

# Observe

Use this skill when the user wants to inspect or monitor another Claude Code session and `harness observe` is the source of truth.

This skill must follow the current observe contract to prevent drift between the skill instructions and the CLI binary:
- top-level subcommands are `doctor`, `scan`, `watch`, and `dump`
- `harness observe doctor` is the direct project-health command
- stateful observer maintenance stays under `harness observe scan <session-id> --action ...`
- observer state is stored automatically at `$XDG_DATA_HOME/harness/observe/<SESSION_ID>.state`

Do not use the removed `scan --action doctor` form. Use `harness observe doctor` directly. Do not use removed top-level observe maintenance commands.

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
- `now` or omitted: resolve the current session length first (`wc -l` or `scan --action status`), then start from that line. This is the default - the user wants to observe from the moment they invoked /observe, not replay history.
- numeric value: use directly as the starting line
- ISO timestamp: start at the first event at or after that timestamp
- prose: find the earliest matching substring in the session log

If prose resolution is ambiguous, ask the user which point they mean before proceeding.

## Project hint

Do not pass `--project-hint` by default. The harness binary searches all project directories under `~/.claude/projects/` automatically and resolves the session ID globally.

Only add `--project-hint` if the scan returns `KSRCLI085` (session ambiguous across multiple projects). In that case, derive the hint from the error output which lists the matching project names, or ask the user which project they mean.

## Workflow

### 1. Establish scope

Resolve:
- session ID
- `--project-hint`
- optional start from `--from` or `--from-line`
- optional `--focus` preset

If the user asked whether harness itself is wired correctly, or you suspect stale wrapper, pointer, or compact-handoff state, start with `harness observe doctor`.

Read [references/command-surface.md](references/command-surface.md) for the full list of supported invocation shapes and maintenance actions.

### 2. Run the initial scan

Run a one-shot scan to establish baseline:

```bash
harness observe scan <session-id> --from-line <start> --json --summary
```

Only add `--project-hint` if you get an ambiguity error. If the user requested a narrower slice, add the filters up front.

Project-health baseline when the issue may be environment or state drift:

```bash
harness observe doctor --project-dir "$CLAUDE_PROJECT_DIR" --json
```

### 3. Summarize and proceed

Summarize the initial scan briefly:
- counts by severity and category
- critical issues first

Do not ask the user what to do next. Proceed directly to continuous monitoring (step 4). The user invoked /observe to watch a session - do that.

### 4. Start monitoring loops

After the initial scan summary, immediately start two concurrent `/loop` instances. Both are mandatory - do not skip either one, do not ask the user whether to start them. This is what /observe exists to do.

**Loop A - automated heuristic scan (every 1 minute):**

Start with `/loop 1m` running an incremental `harness observe scan` from the last known cursor. Each iteration:
1. Run `harness observe scan <session-id> --from-line <cursor> --json --summary`
2. Parse the summary for `cursor.last_line` and update the cursor for the next cycle
3. If new issues are found, report them inline with severity and category
4. If no new issues, stay silent - do not report empty cycles

The prompt for the loop should be:
```
Run harness observe scan <session-id> --from-line <cursor> --json --summary, report any new issues, and update the cursor from cursor.last_line in the summary.
```

**Loop B - deep analyst agent (every 5 minutes):**

Start with `/loop 5m` spawning a subagent using [agents/deep-analyst.md](agents/deep-analyst.md). Each iteration:
1. Determine the line range: from the cursor 5 minutes ago to the current cursor
2. Spawn the deep-analyst agent with the session ID and line range
3. Report the agent's findings if any issues are flagged
4. If the agent returns "Deep analysis: clean", stay silent

The prompt for the loop should be:
```
Read .claude/skills/observe/agents/deep-analyst.md and spawn a deep-analyst subagent for session <session-id> covering lines <range_start> to <range_end>.
```

Both loops run until the user tells you to stop. Do not terminate them early. Do not ask whether to continue.

### 5. Cleanup

When observation ends - whether the user asks to stop, the session is closing, or the skill is being interrupted - all cron jobs created in step 4 must be deleted before the skill exits. This is mandatory.

Cleanup procedure:
1. Run `CronList` to find all active observe loop jobs
2. Run `CronDelete` for each job ID
3. Confirm deletion

The `Stop` hook (`harness hook --skill observe guard-stop`) will block session termination if observe loops are still running. The agent must clean up crons before the session can end. Do not rely on session-scoped auto-cleanup - always delete explicitly so the user sees a clean state.

If the user says "stop observing" or similar, interpret that as: delete both loops, print a final summary of all issues found during the observation window, and return control to the user.

### 6. Use dump or verify when needed

Use `dump` when:
- a classifier finding looks suspicious
- the issue is `unexpected_behavior`
- you need the exact session context around a line

Use `scan --action verify` after a fix to check whether the same fingerprint still reproduces.

## Fix routing

Read [references/issue-taxonomy.md](references/issue-taxonomy.md) for category ownership, likely fix targets, and validation expectations.

Read [references/overrides.md](references/overrides.md) for mutes, focus presets, and overrides-file behavior.

When spawning fix worker subagents:
- Use `isolation: "worktree"` to give the subagent an isolated copy of the repo with full filesystem access
- Use `mode: "bypassPermissions"` so the agent can run Bash, Write, and Edit without prompts
- For files outside the project directory (suite files under `~/.local/share/harness/suites/`, session files under `~/.claude/projects/`), read the contents from the main context first and pass them in the subagent prompt, or make those edits directly from the main context

When a fix is approved, use Grep and Glob to locate the fix target in the codebase, then use Edit to apply the change. For Rust changes in this repo, validate with:

```bash
mise run check
TMPDIR=/tmp mise run test
```

For skill or docs changes, re-check the referenced observe command surface against source before claiming the skill is fresh.

## Output handling

For JSON scans:
- each issue is one JSON line
- each issue uses nested sections: `location`, `classification`, `source`, `message`, and `remediation`
- with `--summary`, the final line is a summary envelope with `cursor.last_line` and `issues.{total,by_severity,by_category}`
- use `remediation.available` instead of looking for a flat `fixable` field
- use `source.tool` instead of looking for a flat `source_tool` field
- use `cursor.last_line` as the next cursor for incremental follow-up

For watch mode:
- issues stream as they arrive
- the summary arrives when the timeout ends

For dump mode:
- use it to inspect raw context before deciding whether a classifier finding is real

## Scope

This skill is for observing and triaging Claude Code session recordings through the `harness observe` pipeline. It is not a general-purpose log viewer, live debugger, or log aggregation tool.

## Common failures

- **Missing session**: the session ID does not match any JSONL file. The binary searches all projects under `~/.claude/projects/` automatically. If still not found, verify with `find ~/.claude/projects/ -name "<session-id>*"`.
- **Empty scan**: scan returns zero issues. Check whether `--focus` or `--severity` filters are too narrow, or the session has no tool-use events yet.
- **Broken harness wiring**: run `harness observe doctor` first. It checks the local install, active project plugin wiring, lifecycle command drift, current-run pointer readability, and compact handoff readability.
- **Stale observer state**: `scan --action status` shows a cursor far behind the session length. Run `scan --action cycle` to advance the cursor.

## Example invocations

<example>
Check harness wiring for the current project:

```bash
harness observe doctor --project-dir "$CLAUDE_PROJECT_DIR" --json
```
</example>

<example>
Scan a session with default settings:

```bash
harness observe scan abc123 --json --summary
```
</example>

<example>
Resume from a specific line with harness-only focus:

```bash
harness observe scan abc123 --from-line 500 --focus harness --json --summary
```
</example>

<example>
Start from a prose match and filter to skills issues:

```bash
harness observe scan abc123 --from "suite:run started" --focus skills --json --summary
```
</example>
