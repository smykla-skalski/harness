# Task Board Workflow

Harness task boards are session work items managed through
`harness session task`. Use this guide when a session needs visible ownership,
review handoffs, or progress checkpoints across multiple agents.

## Contract

- Treat the task board as Harness state. Read and mutate it only through
  `harness session ...` commands.
- Use `--json` for machine-readable reads. Do not parse state files directly.
- Pass `--actor <agent-id>` on every mutating task command.
- Keep task titles short and imperative. Put constraints, acceptance criteria,
  file paths, and known risks in `--context`.
- Use `--suggested-fix` only for a concrete implementation hint. Do not use it
  as a second task description.

## Roles

| Role | Board responsibility |
| --- | --- |
| Leader | Starts the session, creates the initial task set, assigns work, resolves arbitration. |
| Observer | Creates tasks from confirmed observations and keeps findings triaged. |
| Worker | Executes assigned work, records checkpoints, submits finished work for review. |
| Reviewer | Claims review work, records verdicts, and routes fixes back through the board. |
| Improver | Handles improvement follow-ups and can move tasks through the same review flow. |

## Work Item Shape

Each task carries:

- `task_id`, `title`, `context`, `severity`
- `status`: `open`, `in_progress`, `awaiting_review`, `in_review`, `blocked`, `done`
- `assigned_to`, `queue_policy`, `source`, optional `suggested_fix`
- latest `checkpoint_summary` plus append-only checkpoint history
- review metadata once the task enters the review path

Use severity to order attention:

| Severity | Use for |
| --- | --- |
| `critical` | Session-blocking correctness or safety issue. |
| `high` | Important work needed before the session can close. |
| `medium` | Normal implementation, verification, or cleanup item. |
| `low` | Opportunistic polish or non-blocking follow-up. |

## Status Flow

```text
open -> in_progress -> awaiting_review -> in_review -> done
                            ^                |
                            |                v
                        in_progress <- request_changes
```

`blocked` means the task cannot proceed without new input, a dependency, or
leader arbitration.

Generic status updates handle `open`, `in_progress`, `blocked`, and `done`.
Review-only states use the review commands:

- `awaiting_review`: worker runs `submit-for-review`.
- `in_review`: reviewer runs `claim-review`.

## Leader Flow

1. Start or identify the session.

   ```bash
   harness session start --context "<goal>" --title "<short title>"
   harness session join <session-id> --role leader --runtime <runtime>
   harness session status <session-id> --json
   ```

2. Create the initial board from the goal.

   ```bash
   harness session task create <session-id> \
     --title "Implement focused fix" \
     --context "Scope, files, acceptance criteria, and verification." \
     --severity high \
     --actor <leader-agent-id>
   ```

3. List available work before assigning.

   ```bash
   harness session task list <session-id> --status open --json
   ```

4. Assign one task per available worker.

   ```bash
   harness session task assign <session-id> <task-id> <worker-agent-id> \
     --actor <leader-agent-id>
   ```

5. Monitor by status and checkpoint.

   ```bash
   harness session task list <session-id> --json
   harness session status <session-id> --json
   ```

6. Keep the board small enough to act on. Split vague tasks before assignment;
   close or block stale tasks with a note.

## Worker Flow

1. Join or confirm registration, then inspect assigned work.

   ```bash
   harness session task list <session-id> --json
   ```

2. Start only the assigned task. A delivered task-start signal moves the task to
   `in_progress`; if needed, update explicitly.

   ```bash
   harness session task update <session-id> <task-id> \
     --status in_progress \
     --actor <worker-agent-id>
   ```

3. Record checkpoints at useful boundaries.

   ```bash
   harness session task checkpoint <session-id> <task-id> \
     --summary "Cause proven; patch underway" \
     --progress 50 \
     --actor <worker-agent-id>
   ```

4. When ready for review, submit through the review flow instead of marking the
   task done directly.

   ```bash
   harness session task submit-for-review <session-id> <task-id> \
     --summary "Implemented fix and ran focused verification" \
     --actor <worker-agent-id>
   ```

5. If blocked, use a status update with a note that names the missing input or
   dependency.

   ```bash
   harness session task update <session-id> <task-id> \
     --status blocked \
     --note "Waiting for <specific input>" \
     --actor <worker-agent-id>
   ```

## Review Flow

1. Find work ready for review.

   ```bash
   harness session task list <session-id> --status awaiting_review --json
   ```

2. Claim a review slot.

   ```bash
   harness session task claim-review <session-id> <task-id> \
     --actor <reviewer-agent-id>
   ```

3. Submit a verdict.

   ```bash
   harness session task submit-review <session-id> <task-id> \
     --verdict approve \
     --summary "Verified focused behavior and tests" \
     --actor <reviewer-agent-id>
   ```

   Verdicts are `approve`, `request_changes`, or `reject`.

4. For requested changes, include review points as JSON so the worker can
   answer each point.

   ```bash
   harness session task submit-review <session-id> <task-id> \
     --verdict request_changes \
     --summary "Needs one scoped correction" \
     --points '[{"point_id":"p1","text":"Update the focused test."}]' \
     --actor <reviewer-agent-id>
   ```

5. Worker response must cover every consensus point.

   ```bash
   harness session task respond-review <session-id> <task-id> \
     --agreed p1 \
     --note "Test updated" \
     --actor <worker-agent-id>
   ```

6. If the review cycle reaches arbitration, the leader resolves it.

   ```bash
   harness session task arbitrate <session-id> <task-id> \
     --verdict request_changes \
     --summary "Return to worker for the listed fix" \
     --actor <leader-agent-id>
   ```

## Operating Rules

- Prefer many small tasks over one broad task. Each task should have a clear
  owner and close condition.
- Do not assign new execution work to a worker whose task is in
  `awaiting_review`; that worker may need to answer review points.
- Do not use generic `update` to enter review-only states. Use
  `submit-for-review` and `claim-review`.
- Mark work `done` only after required review completes or the leader closes an
  explicitly low-risk task.
- Use `blocked` only when the next action is outside the current agent's
  control; otherwise keep the task moving with checkpoints.
