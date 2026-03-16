---
name: observe
description: >-
  Live session observer for harness and skill testing. Monitors another Claude Code
  session's JSONL log for bugs, hook failures, skill misbehavior, CLI errors, and
  unexpected outcomes. Use whenever testing harness skills in a separate session and
  you want continuous automated monitoring with parallel fix dispatching. Also use
  when the user says "watch this session", "observe session", "monitor for issues",
  or gives you a session ID to analyze.
argument-hint: "<session-id> [--from-line N] [--from <line|timestamp|prose>] [--focus harness|skills|all]"
allowed-tools: Agent, AskUserQuestion, Bash, CronCreate, CronDelete, Edit, Read
disable-model-invocation: true
user-invocable: true
---

# Session observer

Monitor a live Claude Code session for issues in harness behavior, skill correctness, hook failures, and unexpected outcomes. Runs as a manager that dispatches parallel fix workers.

This is not a one-shot scan. Run continuously until explicitly stopped. Between observation cycles, advance the cursor from where the last cycle ended so no events are missed even across session compactions or skill switches.

## Arguments

Parse from `$ARGUMENTS`:

| Argument | Default | Purpose |
| --- | --- | --- |
| (positional) | required | Session ID to observe |
| `--from-line` | 0 | Start observation from this JSONL line number |
| `--from` | - | When to start observing. Accepts a line number, ISO timestamp, or prose description |
| `--focus` | all | Filter scope: `harness` (Rust code only), `skills` (SKILL.md/agents only), `all` |

The `--from` argument is flexible. It can be:
- A line number: `--from 2500`
- An ISO timestamp: `--from 2026-03-15T17:00:00`
- A prose description: `--from "when suite:new started running"`, `--from "about 2 hours ago"`, `--from "after the compaction"`, `--from "when the MOTB feature was scoped"`

When the value is prose, resolve it to a line number by scanning the session JSONL for matching context. Look at timestamps on events and text content that matches the description. Use the earliest matching line as the starting point. If multiple candidates match, use AskUserQuestion to let the user pick which event they meant before proceeding.

## Preprocessed context

- Classifier script: `${CLAUDE_SKILL_DIR}/scripts/classify-session.py`
- Project dir: !`echo "$CLAUDE_PROJECT_DIR"`
- Session search path: !`echo "$HOME/.claude/projects/"`

## Harness observe command reference

The `harness observe` command is the primary data source. All subcommands use `--project-hint` to narrow session search.

### Invocation patterns

**Full scan**: `harness observe scan <session-id> --project-hint <hint> --json --summary`
**Filtered**: `harness observe scan <session-id> --project-hint <hint> --from-line 2000 --json --summary`
**One-shot cycle**: `harness observe cycle <session-id> --project-hint <hint>` (reads/updates cursor from state file)
**Raw dump**: `harness observe dump <session-id> --project-hint <hint> --from-line 3800 --to-line 3900`
**Filtered dump**: `harness observe dump <session-id> --project-hint <hint> --filter "crashloop" --from-line 4000`
**Context**: `harness observe context <session-id> --project-hint <hint> --line 4122 --window 20`
**Watch mode**: `harness observe watch <session-id> --project-hint <hint> --from-line <N>`

### Subcommands

| Subcommand | Purpose |
| --- | --- |
| `scan` | One-shot scan with `--json --summary`, `--from-line`, `--severity`, `--category` filters |
| `cycle` | Read cursor from state file, scan new events, update cursor, report. Used by the automated cron. |
| `dump` | Raw event dump with `--from-line`, `--to-line`, `--filter`, `--role` |
| `context` | Show events around a specific `--line` with `--window` |
| `watch` | Continuous polling with `--poll-interval` and `--timeout` |

### Output format

**With `--json`**, each issue is one JSON line:
```json
{"line": 1215, "category": "build_error", "severity": "critical", "summary": "Build or lint failure", "details": "error[E0308]: mismatched types...", "source_role": "user", "fixable": true, "fix_target": null, "fix_hint": "Fix the Rust code causing the failure"}
```

**With `--summary`**, the last line is always a summary object:
```json
{"status": "done", "last_line": 2928, "total_issues": 19, "by_severity": {"critical": 3, "medium": 11, "low": 5}, "by_category": {"build_error": 1, "cli_error": 4, ...}}
```

The `last_line` field is the cursor - pass it as `--from-line` on the next invocation to pick up where you left off.

**With `--watch`**, issues are flushed to stdout as they arrive (one JSON line per issue). The summary prints at the end when the timeout triggers.

**Without `--json`** (human-readable), each issue prints as:
```
[CRITICAL] L1215 (build_error): Build or lint failure
  hint: Fix the Rust code causing the failure
```

### Issue categories

| Category | What it catches | Auto-fixable? |
| --- | --- | --- |
| `hook_failure` | Guard/verify hooks denied or errored, KSA codes | yes |
| `skill_behavior` | Wrong SKILL.md name field, wrong question prompts | yes |
| `cli_error` | Invalid harness arguments, wrong subcommands | yes |
| `build_error` | Cargo check/clippy/test failures | yes |
| `workflow_error` | State machine errors from harness Bash output | yes |
| `naming_error` | Old skill names in `--skill` flag | yes |
| `tool_error` | Edit before Read, file modified since read | no (model behavior) |
| `data_integrity` | Stale state, corrupted payloads | sometimes |
| `subagent_issue` | Non-zero exit codes from subagent commands | sometimes |
| `unexpected_behavior` | Destructive commands, file churn, alias interference | no (needs triage) |
| `user_frustration` | User frustration signals (!!!, "don't guess", etc.) | no (UX review) |

## Workflow

### Phase 1: Locate session and initial scan

If `--focus` is set to `harness` or `skills`, filter the classifier output accordingly - use `--category` to include only the relevant subset (e.g., `build_error,cli_error,workflow_error` for harness focus, `skill_behavior,hook_failure,naming_error` for skills focus).

If `--from` was provided, resolve it to a `--from-line` value before running the classifier. For numeric or timestamp values, map directly. For prose, scan the JSONL to find the matching line (see Arguments section).

Run the classifier for a full scan with `--json --summary`. Parse every JSON line. The last line with `"status": "done"` is the summary - extract `last_line` as the cursor.

Present a brief triage summary to the user:
- Count by severity (critical / medium / low)
- Count by category
- List critical issues first with their line numbers and summaries

Ask the user: "Found N issues (X critical). Start fixing critical issues now, or adjust the observation scope first?"

### Phase 2: Fix dispatch

For each fixable issue with severity critical or medium:

1. Read [references/issue-taxonomy.md](references/issue-taxonomy.md) for fix routing guidance
2. Spawn a background fix worker agent with:
   - The issue description and line reference
   - The target file to fix
   - The fix hint from the classifier
   - Instructions to run `cargo clippy --lib && cargo test --lib` after Rust changes
   - Instructions to verify the fix doesn't break other things
3. Spawn all fix workers in parallel because sequential dispatch blocks observation while waiting for builds. Waiting per-issue adds minutes of idle time when issues are independent.

When fix workers complete:
- Re-run the classifier with `--from-line` targeting the original issue's line range to confirm the fix resolved it
- If the issue still appears: read the fix worker's output, identify what went wrong, and spawn a second fix attempt with the failure context added
- If the second attempt also fails: escalate to the user with both attempts' output
- Log successful fixes and note which issues remain unfixed

For issues marked `fixable: false` (like model behavior issues), just log them in the summary.

For uncertain issues (`category: unexpected_behavior`), report them to the user with the raw event details and ask for a triage decision.

### Phase 3: Start loop

Write initial cursor state to a temp file:
```bash
echo '{"cursor": <CURSOR>, "session_id": "<SESSION_ID>"}' > /tmp/observe-<SESSION_ID>.state
```

Create two cron jobs:

1. **Automated cron** (`*/2 * * * *`) - runs `harness observe cycle` for fast heuristic scanning. See "Automated cron" section below.
2. **Deep analysis cron** (`*/5 * * * *`) - spawns a subagent that reads recent activity holistically and flags subtle issues automated heuristics miss. See "Deep analysis cron" section below.

Store both cron IDs. Print to user:
```
Observer started. Automated scan every 2min (task <ID1>), deep analysis every 5min (task <ID2>). From line <CURSOR>.
```

Then stay available for ad-hoc queries and fix worker results.

**Ad-hoc queries** between cron cycles - call the classifier directly:

- "What build errors happened after line 2000?" → run with `--from-line 2000 --category build_error --json`
- "Show me only critical fixable issues" → run with `--severity critical --fixable --json`
- "Any new CLI errors?" → run with `--from-line <cursor> --category cli_error --json`

## Automated cron (every 2 minutes)

Bake in the actual `SESSION_ID` and state file path when calling `CronCreate`.

```
Run: harness observe cycle <SESSION_ID> --project-hint <PROJECT_HINT>

If the output is empty (no issues), do nothing.

If issues were found, parse each JSON line and apply this policy:

**Critical or medium severity + fixable**: Immediately spawn a background fix worker agent
with mode: "auto" and run_in_background: true. Include the issue summary, details,
fix_target, and fix_hint. Instruct the worker to run cargo clippy --lib && cargo test --lib
after Rust changes.

**Low severity or not fixable**: Use AskUserQuestion to ask the user:
"Observer found: [summary] at L[line] ([category]). Fix now?" with options
"Fix it", "Skip", "Investigate first". Only dispatch a fix worker if the user selects "Fix it".
```

## Deep analysis cron (every 5 minutes)

Create a second cron that spawns a subagent for holistic analysis of recent session activity. This catches subtle issues that automated heuristics miss - wrong assumptions, questionable decisions, suboptimal approaches, schema misunderstandings, missing validations, and anything that smells off.

Call `CronCreate` with `*/5 * * * *` and this prompt (bake in session ID and project hint):

```
Spawn a general-purpose Agent with mode: "auto" and this prompt:

"You are a deep session analyst. Dump the last 5 minutes of session activity:

harness observe dump <SESSION_ID> --project-hint <PROJECT_HINT> --from-line <CURSOR_FROM_STATE_FILE>

Read the full dump carefully. You are looking for ANYTHING wrong, questionable, or suboptimal
that automated heuristics would miss. Think holistically about what the runner is doing.

Flag issues in these categories:

1. **Wrong assumptions** - runner assumes something about the API, CRD schema, or behavior
   that isn't verified. Example: assuming ContainerPatch value is a YAML object when it's
   actually a JSON string field.

2. **Skipped verification** - runner applies a manifest and moves on without checking it
   actually took effect. Example: applying a policy without verifying xDS config changed.

3. **Questionable decisions** - runner makes a choice that seems wrong for the context.
   Example: skipping a group without asking, continuing after a failure without triage.

4. **Schema/API misuse** - using wrong field names, wrong resource versions, deprecated
   fields, or fields that don't exist in the CRD.

5. **Missing cleanup** - resources created but never deleted, leftover state from previous
   groups that could contaminate later tests.

6. **Inefficiency** - doing the same thing multiple times, using sleep when --delay exists,
   absolute paths when relative would work, manual commands when harness wraps them.

7. **Anything else that smells wrong** - trust your instincts. If something looks off,
   flag it.

For each finding, report:
- Line number(s)
- What you found
- Why it's wrong
- Suggested fix

If you find nothing: say 'Deep analysis: clean' and stop.
If you find issues: present them via AskUserQuestion with the header 'Deep analysis'
and options 'Fix all', 'Review individually', 'Skip'."
```

Store both cron IDs. When stopping the observer, delete both.

### Handling session compaction

The observed session may compact. The JSONL file gets new entries with compaction metadata. The observer picks these up naturally since it reads incrementally. When you see compaction events (text containing "this session is being continued"), note them in the status update.

### Handling skill switches

The user may test one skill, compact, then test another in the same session. The observer handles this naturally - it classifies events regardless of which skill produced them.

## Fix worker template

When spawning a fix worker agent, use this prompt structure:

```
Fix this issue in the harness project:

Issue: <summary>
Category: <category>
Session line: <line>
Details: <details>

Target file: <fix_target>
Hint: <fix_hint>

Requirements:
- Read the target file before editing
- Make the minimal fix needed
- Run: cargo clippy --lib && cargo test --lib
- Verify the fix passes
- Do not change unrelated code
```

Set `mode: "auto"` and `run_in_background: true` on fix workers. `mode: "auto"` grants tool permissions so the agent can edit and build without prompts. Background execution prevents fix workers from blocking the observation loop.

## Example invocations

```bash
# Observe a session from the beginning
/observe abc123def

# Start from a specific line (skip already-reviewed events)
/observe abc123def --from-line 2500

# Start from a timestamp
/observe abc123def --from "2026-03-15T17:00:00"

# Start from a prose description
/observe abc123def --from "when suite:new started running"

# Focus on harness Rust code issues only
/observe abc123def --focus harness

# Focus on skill behavior only, starting from a specific point
/observe abc123def --focus skills --from-line 1000
```

<example>
Input: /observe abc123def --from-line 500 --focus harness

Classifier output (3 issues):
{"line": 612, "category": "build_error", "severity": "critical", "summary": "Build or lint failure", "fixable": true, "fix_hint": "Fix the Rust code causing the failure"}
{"line": 789, "category": "cli_error", "severity": "medium", "summary": "Harness CLI error: harness: error:", "fixable": true, "fix_target": "src/cli.rs"}
{"line": 1102, "category": "tool_error", "severity": "low", "summary": "Tool usage error: file has not been read yet", "fixable": false}
{"status": "done", "last_line": 1200, "total_issues": 3, "by_severity": {"critical": 1, "medium": 1, "low": 1}, "by_category": {"build_error": 1, "cli_error": 1, "tool_error": 1}}

Observer response: "Found 3 issues (1 critical). 1 build failure at L612, 1 CLI error at L789, 1 tool error at L1102 (not fixable). Start fixing critical issues now, or adjust the observation scope first?"
</example>

<example>
Input: /observe abc123def --from "about 2 hours ago"

The observer scans timestamps in the JSONL, finds the line closest to 2 hours before the latest event, and uses that as --from-line. If the session started 90 minutes ago, it reports: "Session is only 90 minutes old - starting from line 0."
</example>

<example>
Input: Fix verification after a fix worker completes

The observer re-runs: "${CLAUDE_SKILL_DIR}/scripts/classify-session.py" abc123def --from-line 610 --category build_error --json
If the build_error at L612 no longer appears in new output, the fix is confirmed. If it still appears, a second fix worker is spawned with the first worker's failure context.
</example>

## Stopping

When the user says to stop:
1. Call `CronDelete` on both cron IDs (automated + deep analysis)
2. Remove `/tmp/observe-<SESSION_ID>.state`
3. Let any running fix workers or deep analysis agents complete
4. Print final summary: total issues found, fixes applied, deep analysis findings, issues remaining
