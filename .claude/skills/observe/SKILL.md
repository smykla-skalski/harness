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

## Classifier script reference

The classifier at `scripts/classify-session.py` is the primary data source. Call it directly from Bash any time data is needed - not only through the observer agent loop. All output is structured for programmatic parsing.

### Invocation patterns

**Full scan** (initial triage):
```bash
"${CLAUDE_SKILL_DIR}/scripts/classify-session.py" \
  <session-id> --from-line <N> --json --summary
```

**Filtered scan** (targeted investigation):
```bash
"${CLAUDE_SKILL_DIR}/scripts/classify-session.py" \
  <session-id> --severity critical --json --summary

"${CLAUDE_SKILL_DIR}/scripts/classify-session.py" \
  <session-id> --category cli_error,naming_error --json

"${CLAUDE_SKILL_DIR}/scripts/classify-session.py" \
  <session-id> --fixable --exclude tool_error,subagent_issue --summary

"${CLAUDE_SKILL_DIR}/scripts/classify-session.py" \
  <session-id> --from-line 2000 --category build_error --json
```

**Watch mode** (continuous polling for new events):
```bash
"${CLAUDE_SKILL_DIR}/scripts/classify-session.py" \
  <session-id> --watch --from-line <N> --poll-interval 3 --timeout 90 --json --summary
```

**Raw event dump** (inspect session content without classification):
```bash
"${CLAUDE_SKILL_DIR}/scripts/classify-session.py" \
  <session-id> --dump --from-line 3800 --to-line 3900

"${CLAUDE_SKILL_DIR}/scripts/classify-session.py" \
  <session-id> --dump --filter "crashloop" --from-line 4000

"${CLAUDE_SKILL_DIR}/scripts/classify-session.py" \
  <session-id> --dump --role assistant --filter "deviation"

"${CLAUDE_SKILL_DIR}/scripts/classify-session.py" \
  <session-id> --dump --filter "otel-collector" --from-line 4100 --to-line 4250
```

**Context around a flagged line** (investigate what happened before/after an issue):
```bash
"${CLAUDE_SKILL_DIR}/scripts/classify-session.py" \
  <session-id> --context 4122

"${CLAUDE_SKILL_DIR}/scripts/classify-session.py" \
  <session-id> --context 4122 --window 20
```

**Human-readable** (quick glance, no --json):
```bash
"${CLAUDE_SKILL_DIR}/scripts/classify-session.py" \
  <session-id> --severity medium --summary
```

### All CLI options

| Flag | Type | Default | Purpose |
| --- | --- | --- | --- |
| `--from-line N` | int | 0 | Start from this JSONL line |
| `--to-line N` | int | none | Stop at this line (dump/context modes) |
| `--watch` | flag | off | Poll for new events instead of one-shot |
| `--poll-interval S` | float | 3.0 | Seconds between polls in watch mode |
| `--timeout S` | float | 90.0 | Exit watch after S seconds of no new events |
| `--json` | flag | off | Output issues as JSON lines (one object per line) |
| `--summary` | flag | off | Print a JSON summary object at the end |
| `--category X,Y` | str | all | Only include these categories (comma-separated) |
| `--severity LEVEL` | str | all | Minimum severity: `low`, `medium`, `critical` |
| `--fixable` | flag | off | Only show issues with `fixable: true` |
| `--exclude X,Y` | str | none | Exclude these categories (comma-separated) |
| `--project-hint DIR` | str | none | Narrow session search to project dir containing this string |
| `--dump` | flag | off | Raw event dump (no classification). Use with `--filter` and `--role` |
| `--context LINE` | int | none | Show events around LINE. Use `--window` to adjust range |
| `--window N` | int | 10 | Lines before/after for `--context` |
| `--filter TEXT` | str | none | Case-insensitive substring filter for `--dump` mode |
| `--role X,Y` | str | all | Role filter for `--dump` (comma-separated: `user`, `assistant`) |
| `--details-file PATH` | str | none | Write full untruncated issues here. Main output stays truncated |

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

Call `CronCreate` with:
- cron: `*/2 * * * *` (every 2 minutes)
- prompt: the observer cron prompt (see section below) with the actual session ID, classifier path, and state file path baked in

Store the returned task ID. Print to user:
```
Observer started (task <TASK_ID>). Checking every 2 minutes from line <CURSOR>.
```

Then stay available for ad-hoc queries and fix worker results. No manual relaunch needed.

**Ad-hoc queries** between cron cycles - call the classifier directly:

- "What build errors happened after line 2000?" → run with `--from-line 2000 --category build_error --json`
- "Show me only critical fixable issues" → run with `--severity critical --fixable --json`
- "Any new CLI errors?" → run with `--from-line <cursor> --category cli_error --json`

## Observer cron prompt

The cron prompt below is parameterized - bake in the actual `SESSION_ID`, classifier path (`${CLAUDE_SKILL_DIR}/scripts/classify-session.py`), and state file path (`/tmp/observe-SESSION_ID.state`) when calling `CronCreate`.

```
Read /tmp/observe-<SESSION_ID>.state and parse the cursor value.

Run:
  "<CLASSIFIER_PATH>" \
    <SESSION_ID> --from-line <CURSOR> --json --summary

Parse each JSON line. The last line with "status": "done" is the summary - extract
last_line as the new cursor.

Write the updated cursor back:
  echo '{"cursor": <NEW_CURSOR>, "session_id": "<SESSION_ID>"}' > /tmp/observe-<SESSION_ID>.state

If any issues were found:
- Report: "Cycle: lines OLD_CURSOR-NEW_CURSOR, N new issues (X critical)"
- For each fixable critical/medium issue, dispatch a fix worker (see Fix worker template)
If no issues: print nothing (silent cycles reduce noise).
```

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
1. Call `CronDelete(<TASK_ID>)` to cancel the loop
2. Remove `/tmp/observe-<SESSION_ID>.state`
3. Let any running fix workers complete
4. Print final summary: total issues found, fixes applied, issues remaining
