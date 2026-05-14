# Task-board Workflow

Use this reference when coordinating cross-project work through
`harness task-board`.

## Contract

- Use Harness commands only. Do not read or write board files directly.
- Use `harness task-board list --json` before dispatch, review, or closeout
  decisions.
- Put scope, constraints, acceptance criteria, and verification in `--body`.
- Use `--project-id`, `--tag`, and `--agent-mode` for routing hints.

## Command Surface

`harness task-board` exposes:

`create`, `list`, `get`, `update`, `delete`, `sync`, `dispatch`, `audit`,
`project`, and `machine`.

Common read flags: `--json`, `--board-root <path>`.

## Statuses

| Status | Meaning | Normal command |
| --- | --- | --- |
| `new` | Captured but not planned. | `create` |
| `planning` | Plan is being written. | `update --status planning` |
| `plan_review` | Plan is waiting for approval. | `update --status plan_review --planning-summary "..."` |
| `todo` | Approved and ready for dispatch. | `update --status todo --approved-by <id>` |
| `in_progress` | Worker is executing the task. | `update --status in_progress` |
| `in_review` | Finished work is being reviewed. | `update --status in_review` |
| `done` | Closed work. | `update --status done` |
| `blocked` | Cannot proceed without new input or decision. | `update --status blocked` |

Priorities are `low`, `medium`, `high`, and `critical`.

## Planning Gate

Dispatch readiness requires `todo`, a non-empty planning summary, an approver,
an approval timestamp, no tombstone, and no existing session work-item link.
The CLI writes the approval timestamp when `--approved-by` is set.

```bash
harness task-board create \
  --title "Implement focused fix" \
  --body "Scope, files, acceptance criteria, verification." \
  --priority high \
  --project-id <project-id> \
  --tag backend

harness task-board update <task-id> --status planning

harness task-board update <task-id> \
  --status plan_review \
  --planning-summary "Cause, fix shape, verification, and rollback notes."

harness task-board update <task-id> \
  --status todo \
  --approved-by <reviewer-or-leader-id>
```

## Dispatch And Review Loop

```bash
harness task-board list --status todo --json
harness task-board dispatch --json
harness task-board update <task-id> --status in_progress
harness task-board update <task-id> --status in_review
harness task-board update <task-id> --status done
```

Use `blocked` only when the next action depends on input outside the current
agent. If the plan changes materially, return to `planning` or `plan_review`
before making the task `todo` again.

## Overview Integration

Use these commands for board overviews:

```bash
harness task-board audit --json
harness task-board project --json
harness task-board machine --json
harness task-board sync --json
harness task-board dispatch --json
```

- `audit` reports total, ready, blocked, and by-status counts.
- `project` groups by `project_id`.
- `machine` groups by `agent_mode`.
- `sync` reports external-provider readiness.
- `dispatch` reports session, worker, reviewer, evaluator, and block reasons.
