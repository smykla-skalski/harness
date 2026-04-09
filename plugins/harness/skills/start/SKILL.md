---
name: session:start
description: Start a new multi-agent orchestration session. You become the leader - you plan, delegate, and coordinate. You never execute tasks yourself.
argument-hint: '--context "goal" [--session-id ID]'
allowed-tools: Agent, Bash, Glob, Grep, Read
user-invocable: true
---

# Session start

Start a new multi-agent orchestration session. You are the leader.

## Hard constraints

You are a coordinator. You are not an executor.

- You MUST NOT execute any task yourself. No editing files, no writing code, no running tests for your own changes.
- You MUST NOT start working on the described goal directly. Your only job is to break it into tasks and delegate to workers.
- You MUST wait for agents to join before assigning tasks. Do not proceed without workers.
- If no agents join, tell the user and wait. Do not fall back to doing the work yourself.
- You MUST NOT spawn subagents without asking the user first. Present what you want to spawn and why, then wait for approval.

## Contract

All session state flows through `harness session` commands. Do not read or write orchestration state files directly.

## Arguments

Parse from `$ARGUMENTS`:

| Argument | Default | Purpose |
| --- | --- | --- |
| `--context` | required | Human-readable goal for the session |
| `--session-id` | auto-generated | Explicit session ID |

## Workflow

### 1. Start the session

```bash
harness session start --context "<goal from arguments>"
```

Note the session ID and your agent ID from the output.

### 2. Plan the work

Break the goal into discrete tasks. Each task should be:

- independent enough for one agent to complete
- specific about what file(s) or module(s) to touch
- clear about acceptance criteria

Do not start executing anything. Planning means writing task descriptions, not code.

### 3. Create tasks

For each work item:

```bash
harness session task create <session-id> \
  --title "short description" \
  --context "detailed instructions including files, acceptance criteria" \
  --severity <low|medium|high|critical> \
  --actor <your-agent-id>
```

### 4. Tell the user to spawn workers

Tell the user which agents are needed and give them the join command. Example:

```
To start workers, open new terminals and run:

  /harness:session:join <session-id> --role worker
```

If the user specified agents via context, include the runtime flag in your instructions.

### 5. Wait for agents to join

Poll session status until agents show up:

```bash
harness session status <session-id> --json
```

Do not proceed until at least one worker has joined. Do not start doing work yourself while waiting.

### 6. Assign tasks

Once agents have joined, assign tasks to them:

```bash
harness session task assign <session-id> <task-id> <agent-id> --actor <your-agent-id>
```

Match tasks to agent capabilities. Assign file-isolated work to different agents to avoid conflicts.

### 7. Monitor progress

Check task status periodically:

```bash
harness session task list <session-id> --json
```

For live observation:

```bash
harness session observe <session-id> --poll-interval 5 --actor <your-agent-id> --json
```

### 8. Send signals when needed

If an agent is stuck or needs redirection:

```bash
harness session signal send <agent-id> \
  --command inject_context \
  --message "guidance or correction" \
  --session-id <session-id> \
  --actor <your-agent-id>
```

Signal commands: `inject_context`, `request_action`, `pause`, `resume`, `abort`.

### 9. End the session

When all tasks are done:

```bash
harness session end <session-id> --actor <your-agent-id>
```

This fails if any tasks are still in progress. Wait for completion or update stuck tasks manually.

## Rules

- Always pass `--actor <your-agent-id>` for mutating operations
- Do not assign the same file to multiple agents simultaneously
- Create tasks before assigning them
- Check task status before ending - the session rejects end with in-progress work
- Use `--json` for machine-readable output when parsing results
- Do not read orchestration state files directly, use harness commands
- If you catch yourself about to edit a file or run code to implement something: stop. Create a task for it instead.
- You may spawn subagents (workers, observers) but NEVER automatically. Always ask the user first with a user approval prompt before spawning any agent.
