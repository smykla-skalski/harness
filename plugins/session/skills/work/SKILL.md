---
name: work
description: Join a multi-agent session as a worker. Pick up assigned tasks, execute them, report progress, and signal completion.
argument-hint: '<session-id> [--role worker|reviewer|improver] [--runtime claude|codex|gemini|copilot|opencode] [--capabilities "x,y"]'
allowed-tools: Agent, AskUserQuestion, Bash, Edit, Glob, Grep, Read, Write
user-invocable: true
---

# Session work

Use this skill when the user wants this agent to join an existing multi-agent session and work on assigned tasks. You become a session participant - responsible for joining, picking up tasks, doing the work, and reporting progress.

## Contract

All session state flows through `harness session` commands. Do not read or write orchestration state files directly.

### Commands you will use

```
harness session join <session-id> --role <role> --runtime <runtime> [--capabilities "x,y"]
harness session task list <session-id> [--status open] --json
harness session task update <session-id> <task-id> --status <status> [--note "..."] --actor <your-agent-id>
harness session task checkpoint <session-id> --summary "..." --progress <0-100> --actor <your-agent-id>
harness session signal list --session-id <session-id> --json
harness session status <session-id> --json
```

## Arguments

Parse from `$ARGUMENTS`:

| Argument | Default | Purpose |
| --- | --- | --- |
| positional | required | Session ID to join |
| `--role` | `worker` | Your role in the session |
| `--runtime` | auto-detect | Which runtime you are (claude, codex, gemini, copilot, opencode) |
| `--capabilities` | none | Comma-separated capability tags |

## Workflow

### 1. Join the session

```bash
harness session join <session-id> --role <role> --runtime <runtime>
```

Note your agent ID from the output. You need it for all `--actor` arguments.

### 2. Check assigned tasks

```bash
harness session task list <session-id> --json
```

Look for tasks assigned to your agent ID with status `open` or `in-progress`.

### 3. Claim a task

When you start working on a task, update its status:

```bash
harness session task update <session-id> <task-id> --status in-progress --actor <your-agent-id>
```

### 4. Do the work

Execute the task according to its context and title. Follow the project conventions:

- Read files before modifying them
- Run `mise run check` after code changes
- Run `mise run test` to verify
- Commit at logical checkpoints if the task involves code changes

### 5. Report progress

For longer tasks, record checkpoints:

```bash
harness session task checkpoint <session-id> \
  --summary "what was done so far" \
  --progress 50 \
  --actor <your-agent-id>
```

### 6. Complete the task

When done:

```bash
harness session task update <session-id> <task-id> \
  --status done \
  --note "summary of what was done" \
  --actor <your-agent-id>
```

### 7. Check for more work

After completing a task, check for more:

```bash
harness session task list <session-id> --status open --json
```

If there are unassigned tasks you can handle, inform the leader or pick them up if your role permits.

### 8. Check for signals

The leader or observer may send you signals. These are picked up automatically during hook callbacks, but you can also check manually:

```bash
harness session signal list --session-id <session-id> --json
```

Act on any pending signals - they may contain corrections, new context, or instructions to pause/abort.

## Role permissions

| Role | Can do |
| --- | --- |
| Worker | create tasks, update own task status, observe, view status |
| Reviewer | create tasks, assign tasks, update task status, observe, view status |
| Improver | create tasks, assign tasks, update task status, observe, view status |

## Rules

- Always pass `--actor <your-agent-id>` for mutating operations
- Update task status to `in-progress` before starting work
- Update task status to `done` when finished, with a note
- Do not modify files that another agent is actively working on
- If blocked, update task status to `blocked` with a note explaining why
- Check `harness session status` if you lose track of session state
- Do not end the session - only the leader can do that
- Report progress via checkpoints for tasks that take more than a few minutes
