# Signal protocol

## How signals work

Signals are file-based messages between agents. They are written to:

```
$XDG_DATA_HOME/harness/projects/project-{digest}/agents/signals/{agent}/{session-id}/pending/
```

Agents pick up pending signals during `PreToolUse` hook callbacks. The hook handler reads pending signals, injects their content into the agent's context, writes an acknowledgment, and moves the signal to `acknowledged/`.

## Signal commands

| Command | Purpose | When to use |
|---------|---------|-------------|
| `inject_context` | Add information to context | Agent missing context or making wrong assumptions |
| `request_action` | Ask agent to do something specific | Redirect to different task or approach |
| `transfer_leadership` | Request leader role transfer | Current leader needs to hand off |
| `pause` | Ask agent to pause work | Coordination issue, need to regroup |
| `resume` | Ask agent to resume work | After a pause |
| `abort` | Ask agent to stop current task | Task no longer needed or agent going wrong direction |

## Sending a signal

```bash
harness session signal send <session-id> <target-agent-id> \
  --command inject_context \
  --message "The API endpoint changed to /v2/sessions" \
  --action-hint "update the base URL in client.rs" \
  --actor <your-agent-id>
```

## Delivery characteristics

| Property | Value |
|----------|-------|
| Delivery | Best effort, picked up during hook callbacks |
| Latency | 1-10 seconds when agent actively using tools |
| Failure mode | Signals queue until activity resumes |
| TTL | Default 5 minutes |
| Deduplication | Atomic rename prevents double-processing |
| Retries | Configurable, default 3 |

## Checking signal status

```bash
harness session signal list <session-id> --json
harness session signal list <session-id> --agent <agent-id> --json
```
