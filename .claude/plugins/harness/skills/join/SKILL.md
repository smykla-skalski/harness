---
name: session:join
description: Join a multi-agent session. Default role is worker. Use --role observer to monitor and triage, or --role reviewer/improver for review work.
argument-hint: '[session-id] [--role worker|observer|reviewer|improver] [--runtime claude|codex|gemini|copilot|opencode] [--capabilities "x,y"]'
allowed-tools: Agent, AskUserQuestion, Bash, Edit, Glob, Grep, Read, Write
user-invocable: true
---

# Session join

Join an existing multi-agent session. Your behavior depends on the role you join with.

## Contract

All session state flows through `harness session` commands. Do not read or write orchestration state files directly.

## Arguments

Parse from `$ARGUMENTS`:

| Argument | Default | Purpose |
| --- | --- | --- |
| positional | interactive | Session ID to join. If omitted, list active sessions and ask the user to pick one. |
| `--role` | `worker` | Your role: worker, observer, reviewer, or improver |
| `--runtime` | auto-detect | Which runtime you are (claude, codex, gemini, copilot, opencode) |
| `--capabilities` | none | Comma-separated capability tags |

## Daemon-spawned TUI context

When `HARNESS_SESSION_ID` and `HARNESS_AGENT_TUI_ID` environment variables are set, this agent was spawned by the daemon as a managed TUI. In that case:

- Use the session ID from `HARNESS_SESSION_ID` instead of prompting for a session picker.
- Include `agent-tui` and `agent-tui:$HARNESS_AGENT_TUI_ID` in the `--capabilities` flag so the daemon can resolve the agent from session state.
- The auto-join prompt from the daemon already supplies these as arguments, so this section only applies when manually running the skill in a daemon-spawned terminal.

## Session picker

When no session ID is provided in arguments, run:

```bash
harness session list --json
```

Filter to active sessions only. If there are none, tell the user no active sessions exist and stop.

If there is exactly one active session, confirm with the user before joining.

If there are multiple, present them using AskUserQuestion with a numbered list showing:
- session ID (short form)
- context/goal
- agent count
- task counts (open/in-progress/done)

Put the most recently created session first. After the user picks one, proceed with joining.

## Step 1: Join the session

This step is the same for all roles.

```bash
harness session join <session-id> --role <role> --runtime <runtime>
```

Note your agent ID from the output. You need it for all `--actor` arguments.

After joining, follow the workflow for your role below.

---

## Worker workflow

Use this when `--role worker` (the default).

### Check assigned tasks

```bash
harness session task list <session-id> --json
```

Look for tasks assigned to your agent ID with status `open` or `in-progress`.

### Claim a task

```bash
harness session task update <session-id> <task-id> --status in-progress --actor <your-agent-id>
```

### Do the work

Execute the task according to its context and title. Follow project conventions:

- Read files before modifying them
- Run `mise run check` after code changes
- Run `mise run test` to verify
- Commit at logical checkpoints if the task involves code changes

### Report progress

For longer tasks, record checkpoints:

```bash
harness session task checkpoint <session-id> \
  --summary "what was done so far" \
  --progress 50 \
  --actor <your-agent-id>
```

### Complete the task

```bash
harness session task update <session-id> <task-id> \
  --status done \
  --note "summary of what was done" \
  --actor <your-agent-id>
```

### Check for more work

```bash
harness session task list <session-id> --status open --json
```

If there are unassigned tasks you can handle, inform the leader or pick them up if your role permits.

### Check for signals

The leader may send you signals. These are picked up automatically during hook callbacks, but you can also check:

```bash
harness session signal list --session-id <session-id> --json
```

Act on any pending signals - they may contain corrections, context, or instructions to pause/abort.

---

## Observer workflow

Use this when `--role observer`.

As an observer you do not execute tasks. You monitor the session through the `harness observe` pipeline, detect issues, and create session tasks from findings. You do not edit files or write code.

### Verify wiring

Before scanning, confirm that harness observe is wired correctly:

```bash
harness observe --observe-id <observe-id> doctor --json
```

Add `--agent <runtime>` if you know which agent's session you are observing. Default `--observe-id` is `project-default`.

### Run a baseline scan

```bash
harness observe --agent <agent> --observe-id <observe-id> scan <session-id> --json --summary
```

Add `--from-line N` or `--from <timestamp>` to start from a specific point. Add `--focus harness|skills|all` to filter categories.

### Triage findings

Summarize briefly:

- counts by severity and category
- critical issues first
- whether the observer state is established for this observe-id
- which fix target is most likely: skill, hook, suite, or harness code

Focus on:

- agents going off-track or violating contracts
- blocked tasks that need leader attention
- stalled agents with no recent activity
- file conflicts between agents

### Continuous monitoring

For ongoing observation use `watch`, not manual polling loops:

```bash
harness observe --agent <agent> --observe-id <observe-id> watch <session-id> --poll-interval 3 --timeout 90 --json
```

### Maintenance actions

Manage observer state through `scan --action`:

- `--action cycle` - advance the stored cursor and persist new findings
- `--action status` - inspect current observer state
- `--action resume` - continue scanning from the stored cursor
- `--action verify` - after a fix, check if the same fingerprint still reproduces
- `--action resolve-from` - resolve a line boundary from prose or timestamp
- `--action compare` - compare two windows
- `--action mute` / `--action unmute` - manage muted issue codes

### Use dump when the classifier may be wrong

Use `harness observe dump` when a finding looks suspicious, the issue is `unexpected_behavior`, or you need exact raw context around a line range.

### Create session tasks from findings

When you detect an issue that needs fixing:

```bash
harness session task create <session-id> \
  --title "issue summary" \
  --context "details from observe findings" \
  --severity <low|medium|high|critical> \
  --actor <your-agent-id>
```

### Initiate leader transfer if needed

If the leader appears unresponsive:

```bash
harness session transfer-leader <session-id> <new-leader-id> \
  --reason "leader unresponsive" \
  --actor <your-agent-id>
```

### Check session status

```bash
harness session status <session-id> --json
```

---

## Reviewer / Improver workflow

Use this when `--role reviewer` or `--role improver`.

### Check tasks needing review

```bash
harness session task list <session-id> --json
```

Look for tasks with status `done` or `in-review`.

### Review the work

Read the changed files, run checks, verify acceptance criteria from the task context.

### Assign tasks back if needed

If work needs corrections:

```bash
harness session task assign <session-id> <task-id> <agent-id> --actor <your-agent-id>
harness session task update <session-id> <task-id> --status open --note "needs fix: ..." --actor <your-agent-id>
```

### Mark reviewed tasks done

```bash
harness session task update <session-id> <task-id> \
  --status done \
  --note "reviewed, looks good" \
  --actor <your-agent-id>
```

---

## Role permissions

| Role | Can do |
| --- | --- |
| Worker | create tasks, update own task status, observe, view status |
| Observer | create tasks, transfer leader, observe, view status |
| Reviewer | create tasks, assign tasks, update task status, send signals, observe, view status |
| Improver | create tasks, assign tasks, update task status, send signals, observe, view status |

## Rules

- Always pass `--actor <your-agent-id>` for mutating operations
- Do not end the session - only the leader can do that
- Check `harness session status` if you lose track of session state
- Workers: update task status to `in-progress` before starting, `done` when finished
- Workers: do not modify files that another agent is actively working on
- Workers: if blocked, set status to `blocked` with a note explaining why
- Observers: do not edit files or execute tasks - observe and triage only
- Observers: create tasks from findings, do not fix issues directly
