---
name: lead
description: Start and lead a multi-agent session. Create tasks, assign agents, coordinate work, and end the session when all work is done.
argument-hint: '[--context "goal"] [--session-id ID] [--agents codex,gemini]'
allowed-tools: Agent, AskUserQuestion, Bash, Glob, Grep, Read, Skill
user-invocable: true
---

# Session lead

Use this skill when the user wants to start a multi-agent orchestration session and lead it. You become the session leader - responsible for creating tasks, assigning agents, monitoring progress, and ending the session.

## Contract

All session state flows through `harness session` commands. Do not read or write orchestration state files directly.

### Commands

```
harness session start --context "<goal>"
harness session join <session-id> --role <role> --runtime <runtime> [--capabilities "x,y"]
harness session end <session-id> --actor <your-agent-id>
harness session assign <session-id> <agent-id> --role <role> --actor <your-agent-id>
harness session remove <session-id> <agent-id> --actor <your-agent-id>
harness session transfer-leader <session-id> <new-leader-id> --actor <your-agent-id>
harness session task create <session-id> --title "..." --context "..." --severity <low|medium|high|critical> --actor <your-agent-id>
harness session task assign <session-id> <task-id> <agent-id> --actor <your-agent-id>
harness session task list <session-id> [--status <status>] --json
harness session task update <session-id> <task-id> --status <status> [--note "..."] --actor <your-agent-id>
harness session signal send <agent-id> --command <cmd> --message "..." --session-id <id> --actor <your-agent-id>
harness session signal list --session-id <id> --json
harness session observe <session-id> [--poll-interval 3] --actor <your-agent-id> --json
harness session status <session-id> --json
harness session list --json
```

## Arguments

Parse from `$ARGUMENTS`:

| Argument | Default | Purpose |
| --- | --- | --- |
| `--context` | required | Human-readable goal for the session |
| `--session-id` | auto-generated | Explicit session ID |
| `--agents` | none | Comma-separated list of runtimes to expect |

## Workflow

### 1. Start the session

```bash
harness session start --context "<goal from arguments>"
```

Note the session ID and your agent ID from the output. You are now the leader.

### 2. Plan the work

Break the goal into discrete tasks. Each task should be:

- independent enough for one agent to complete
- specific about what file(s) or module(s) to touch
- clear about acceptance criteria

### 3. Create tasks

For each work item:

```bash
harness session task create <session-id> \
  --title "short description" \
  --context "detailed instructions including files, acceptance criteria" \
  --severity <low|medium|high|critical> \
  --actor <your-agent-id>
```

### 4. Wait for agents to join

Other agents join via `harness session join`. Check who has joined:

```bash
harness session status <session-id> --json
```

Tell the user which agents are expected and how to start them. Each agent needs:

- The session ID
- Their assigned role
- The harness binary on PATH (`~/.local/bin/harness`)
- Bootstrap hooks installed (`harness setup bootstrap --agent <runtime>`)

### 5. Assign tasks

Once agents have joined, assign tasks to them:

```bash
harness session task assign <session-id> <task-id> <agent-id> --actor <your-agent-id>
```

Match tasks to agent capabilities. Prefer assigning file-isolated work to different agents to avoid cross-agent file conflicts.

### 6. Monitor progress

Check task status periodically:

```bash
harness session task list <session-id> --json
```

For live observation of all agent activity:

```bash
harness session observe <session-id> --poll-interval 5 --actor <your-agent-id> --json
```

### 7. Send signals when needed

If an agent is stuck, stalled, or needs redirection:

```bash
harness session signal send <agent-id> \
  --command inject_context \
  --message "guidance or correction" \
  --session-id <session-id> \
  --actor <your-agent-id>
```

Available signal commands: `inject_context`, `request_action`, `pause`, `resume`, `abort`.

### 8. End the session

When all tasks are done:

```bash
harness session end <session-id> --actor <your-agent-id>
```

This will fail if any tasks are still in progress. Either wait for completion or update stuck tasks manually.

## Role permissions

As leader you can: end session, join/remove agents, assign roles, transfer leadership, create/assign/update tasks, observe, view status.

## Signals

Signals are file-based and picked up by agents during their hook callbacks. Delivery is best-effort with configurable retries. Do not expect instant response - allow at least one tool-use cycle for the target agent to pick up the signal.

## Rules

- Always pass `--actor <your-agent-id>` for mutating operations
- Do not assign the same file to multiple agents simultaneously
- Create tasks before assigning them
- Check task status before ending - the session rejects end with in-progress work
- Use `--json` for machine-readable output when parsing results
- Do not read orchestration state files directly, use harness commands
