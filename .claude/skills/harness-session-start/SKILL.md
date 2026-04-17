---
name: harness-session-start
description: Start a new multi-agent orchestration session. Use when coordinating work across multiple agents - planning, delegating tasks, and monitoring progress without executing work directly.
argument-hint: '--title "name" --context "goal"'
allowed-tools: Agent, AskUserQuestion, Bash, Read
user-invocable: true
---

# Session start

Start a new multi-agent orchestration session as the leader.

## Bundled resources

Read these references when deeper context is needed:

- [references/command-surface.md](references/command-surface.md) - Full CLI command reference for session orchestration
- [references/roles-and-permissions.md](references/roles-and-permissions.md) - Role definitions and permission matrix
- [references/signals.md](references/signals.md) - Signal types and delivery mechanics

## Constraints

Act as a coordinator, not an executor.

- Do not execute tasks directly (no editing files, writing code, or running tests) because the leader role is coordination only - workers handle execution.
- Do not start working on the goal directly. Break it into tasks and delegate to workers so work can be parallelized.
- Wait for agents to join before assigning tasks because assignments to non-existent agents fail silently.
- If no agents join, tell the user and wait. Do not fall back to doing the work.
- Do not spawn subagents without asking the user first via AskUserQuestion because spawning consumes resources and the user controls the agent budget.

## Contract

All session state flows through `harness session` commands. Do not read or write orchestration state files directly because the daemon manages concurrency and persistence.

## Arguments

Parse from `$ARGUMENTS`:

| Argument | Default | Purpose |
| --- | --- | --- |
| `--title` | required | Short human-readable session name |
| `--context` | required | Human-readable goal for the session |

## Workflow

### 1. Start the session

```bash
harness session start --title "<title from arguments>" --context "<goal from arguments>" --runtime <your-runtime>
```

Replace `<your-runtime>` with the agent type: `claude`, `copilot`, `codex`, `gemini`, `vibe`, or `opencode`.

Note the session ID and agent ID from the output.

### 2. Plan the work

Break the goal into discrete tasks. Each task should be:

- independent enough for one agent to complete
- specific about what file(s) or module(s) to touch
- clear about acceptance criteria

Planning means writing task descriptions, not code.

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

Tell the user which agents are needed and provide the join command:

<example>
To start workers, open new terminals and run:

  /harness:session:join <session-id> --role worker
</example>

If the user specified agents via context, include the runtime flag in the instructions.

### 5. Wait for agents to join

Poll session status until agents show up:

```bash
harness session status <session-id> --json
```

Do not proceed until at least one worker has joined. Do not start doing work while waiting.

### 6. Assign tasks

Read [references/roles-and-permissions.md](references/roles-and-permissions.md) to understand role capabilities before assigning.

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

If an agent is stuck or needs redirection, read [references/signals.md](references/signals.md) for signal types, then:

```bash
harness session signal send <agent-id> \
  --command inject_context \
  --message "guidance or correction" \
  --session-id <session-id> \
  --actor <your-agent-id>
```

### 9. End the session

When all tasks are done:

```bash
harness session end <session-id> --actor <your-agent-id>
```

This fails if any tasks are still in progress. Wait for completion or update stuck tasks manually.

## Rules

For the full command reference, read [references/command-surface.md](references/command-surface.md).

- Always pass `--actor <your-agent-id>` for mutating operations so the audit log tracks who made changes.
- Do not assign the same file to multiple agents simultaneously to prevent merge conflicts.
- Create tasks before assigning them because assignment validates task existence.
- Check task status before ending - the session rejects end with in-progress work.
- Use `--json` for machine-readable output when parsing results.
- Do not read orchestration state files directly - use harness commands because the daemon handles locking.
- If about to edit a file or run code to implement something: stop and create a task for it instead.
- Ask the user via AskUserQuestion before spawning subagents because the user controls the agent budget.

## Example invocations

```bash
# Start a session for a feature implementation
/harness:session:start --title "Add user auth" --context "Implement OAuth2 login flow with Google provider"

# Start a session for a bug investigation
/harness:session:start --title "Fix memory leak" --context "Investigate and fix the memory leak in the worker pool reported in issue #123"
```

<example>
Input: User says "coordinate adding dark mode support"

Output:
1. Start session with --title "Dark mode" --context "Add dark mode support across the application"
2. Create tasks: "Add theme provider", "Update color tokens", "Add toggle UI", "Update tests"
3. Tell user to spawn 2-3 workers
4. Wait for workers, assign tasks, monitor until complete
</example>
