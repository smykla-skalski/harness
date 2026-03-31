# Signal protocol

## How signals work

Signals are file-based messages between agents. They are written to:

```
$XDG_DATA_HOME/harness/projects/project-{digest}/agents/signals/{agent}/{session-id}/pending/
```

Agents pick up pending signals during `PreToolUse` hook callbacks. The hook handler reads pending signals, injects their content into the agent's context, writes an acknowledgment, and moves the signal to `acknowledged/`.

## Signal commands

| Command | Purpose | When to use |
| --- | --- | --- |
| `inject_context` | Add information to the agent's context | Agent is missing context or making wrong assumptions |
| `request_action` | Ask the agent to do something specific | Redirect agent to a different task or approach |
| `transfer_leadership` | Request leader role transfer | Current leader needs to hand off |
| `pause` | Ask the agent to pause work | Coordination issue, need to regroup |
| `resume` | Ask the agent to resume work | After a pause |
| `abort` | Ask the agent to stop its current task | Task is no longer needed or agent is going in wrong direction |

## Sending a signal

```bash
harness session signal send <target-agent-id> \
  --command inject_context \
  --message "The API endpoint changed to /v2/sessions" \
  --action-hint "update the base URL in client.rs" \
  --session-id <session-id> \
  --actor <your-agent-id>
```

## Delivery characteristics

- **Best effort**: signals are picked up during hook callbacks, not push-delivered
- **Latency**: 1-10 seconds when the agent is actively using tools
- **Failure mode**: if no tool calls happen, signals queue until activity resumes
- **Expiry**: signals have a TTL (default 5 minutes)
- **Deduplication**: atomic rename prevents double-processing
- **Retries**: configurable, default 3

## Checking signal status

```bash
harness session signal list --session-id <session-id> --json
harness session signal list --agent <agent-id> --session-id <session-id> --json
```
