# Task-board Workflow

Use this reference when coordinating Harness session work through
`harness session task`.

## Contract

- Use Harness commands only. Do not read or write session state files directly.
- Use `harness session task list <session-id> --json` before assignment,
  review, or closeout decisions.
- Pass `--actor <agent-id>` on every mutating task command.
- Keep task titles short. Put scope, constraints, acceptance criteria, and
  verification in `--context`.

## Statuses

| Status | Meaning | Command path |
| --- | --- | --- |
| `open` | Available or queued work. | `create`, `assign`, `update` |
| `in_progress` | Worker is executing the task. | task-start signal or `update` |
| `awaiting_review` | Worker submitted finished work. | `submit-for-review` |
| `in_review` | Reviewer claimed the task. | `claim-review` |
| `blocked` | Cannot proceed without new input or arbitration. | `update`, `respond-review` |
| `done` | Closed work. | review approval, arbitration approval, or `update` |

Do not use generic `update` to enter `awaiting_review` or `in_review`.

## Leader Loop

```bash
harness session task create <session-id> \
  --title "Implement focused fix" \
  --context "Scope, files, acceptance criteria, verification." \
  --severity high \
  --actor <leader-agent-id>

harness session task list <session-id> --status open --json

harness session task assign <session-id> <task-id> <worker-agent-id> \
  --actor <leader-agent-id>
```

Keep tasks small, assigned to one owner, and backed by a concrete close
condition.

## Worker Loop

```bash
harness session task list <session-id> --json

harness session task checkpoint <session-id> <task-id> \
  --summary "Cause proven; patch underway" \
  --progress 50 \
  --actor <worker-agent-id>

harness session task submit-for-review <session-id> <task-id> \
  --summary "Implemented fix and ran focused verification" \
  --actor <worker-agent-id>
```

Use `blocked` with a note only when the next action depends on input outside the
current agent.

## Review Loop

```bash
harness session task list <session-id> --status awaiting_review --json

harness session task claim-review <session-id> <task-id> \
  --actor <reviewer-agent-id>

harness session task submit-review <session-id> <task-id> \
  --verdict approve \
  --summary "Verified focused behavior and tests" \
  --actor <reviewer-agent-id>
```

Verdicts are `approve`, `request_changes`, and `reject`.

For requested changes, include review points:

```bash
harness session task submit-review <session-id> <task-id> \
  --verdict request_changes \
  --summary "Needs one scoped correction" \
  --points '[{"point_id":"p1","text":"Update the focused test."}]' \
  --actor <reviewer-agent-id>

harness session task respond-review <session-id> <task-id> \
  --agreed p1 \
  --note "Test updated" \
  --actor <worker-agent-id>
```

If the task reaches arbitration, the leader resolves it:

```bash
harness session task arbitrate <session-id> <task-id> \
  --verdict request_changes \
  --summary "Return to worker for the listed fix" \
  --actor <leader-agent-id>
```
