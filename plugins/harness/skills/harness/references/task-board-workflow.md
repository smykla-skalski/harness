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

`create`, `list`, `get`, `update`, `delete`, `sync`, `dispatch`, `evaluate`,
`audit`, `project`, `machine`, and `orchestrator`.

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
an approval timestamp, no tombstone, no existing session work-item link, and an
`allow` policy decision for `spawn_agent`.
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
harness task-board dispatch --dry-run --json
harness task-board dispatch --project-dir <project-dir> --actor <leader-id> --json
harness task-board update <task-id> --status in_progress
harness task-board update <task-id> --status in_review
harness task-board evaluate --status in_progress --dry-run --json
harness task-board evaluate --json
harness task-board update <task-id> --status done
```

Applied dispatch creates or reuses a session, creates a session work item,
links `session_id` and `work_item_id`, marks the board item `in_progress`, and
sets workflow state to `running` at step `dispatch`.

`evaluate` reconciles linked session work back to board state: open/running
tasks stay `in_progress`; review tasks become `in_review`; done tasks become
`done`; blocked, missing-session, or missing-task cases become `blocked` with
failed workflow state. Unlinked items are skipped.

Use `blocked` only when the next action depends on input outside the current
agent. If the plan changes materially, return to `planning` or `plan_review`
before making the task `todo` again.

## Overview Integration

Use these commands for board overviews:

```bash
harness task-board audit --json
harness task-board project --json [--status <status>]
harness task-board machine --json [--status <status>]
harness task-board sync --json [--provider <provider>] [--direction <pull|push|both>] [--apply]
harness task-board dispatch --dry-run --json [--item-id <id>] [--status <status>]
harness task-board evaluate --json [--item-id <id>] [--status <status>]
harness task-board orchestrator status --json
```

- `audit` reports total, ready, blocked, and by-status counts.
- `project` groups by `project_id`; `--status` narrows the set.
- `machine` groups by `agent_mode`; `--status` narrows the set.
- `sync` reports external-provider readiness; `--provider`, `--direction`, and
  `--apply` control provider scope and whether changes are persisted.
- `dispatch` reports session, worker, reviewer, evaluator, and block reasons
  for the selected status or item.
- `evaluate` reports reconciled, updated, skipped, completed, reviewing,
  running, blocked, and failed counts for the selected status or item.
- `orchestrator status` reports enabled/running intent, current tick, last run,
  workflow counts, settings, and policy trace IDs.

## Dispatch Intent

Each dispatch plan includes:

- `session`: existing session if `session_id` is set, otherwise create one.
- `task`: title/body, priority-derived severity, planning summary, tags, and
  external refs.
- `worker`: board `agent_mode` (`headless`, `interactive`, `planning`,
  `evaluate`).
- `reviewer`: `code-reviewer` after worker review with consensus count `2`.
- `evaluator`: `evaluate` follow-up after worker review.
- `policy`: decision that allowed or blocked dispatch.

`dispatch` does not directly start managed agents. Use session agent commands
to launch capacity from the plan:

```bash
harness session agents start terminal <session-id> --runtime <runtime> \
  --role worker --capability <tag> --prompt "..."
harness session agents start codex <session-id> --mode <mode> --prompt "..."
harness session agents start acp --session-id <session-id> --agent <descriptor> \
  --role worker --prompt "..."
```

Managed controls include `list`, `show`, terminal `input`/`resize`/`stop`,
Codex `steer`/`interrupt`/`approve`, and ACP `inspect`. Start commands can set
role, fallback role, capabilities, name, persona, model, effort, and project
directory when supported.

## Orchestrator

```bash
harness task-board orchestrator status --json
harness task-board orchestrator start --json
harness task-board orchestrator stop --json
harness task-board orchestrator run-once --dry-run --json
harness task-board orchestrator run-once --apply --status todo --json
harness task-board orchestrator settings --json
harness task-board orchestrator settings --dry-run-default false --json
harness task-board orchestrator settings --dispatch-status-filter todo --json
harness task-board orchestrator settings --project-dir <project-dir> --json
```

Defaults are `dry_run_default=true` and `dispatch_status_filter=todo`.
`run-once` records dispatch, runs dispatch through the daemon service, records
evaluation, evaluates linked work, and persists the last run. `--apply`
overrides the dry-run default for one tick.

## Policy Pipeline

Dispatch readiness uses policy. Draft policy graphs are stored but ignored by
dispatch; dry-run or enforced graphs replace the built-in gate. The built-in
gate allows normal planning/sync/triage/spawn-agent/branch/PR/review/stop-agent
actions, forces repo mutation to dry-run-only, requires a human for worktree
deletion, secret access, and destructive filesystem actions, and gates PR merge
with evidence.

Daemon routes load, save draft, simulate, promote, and audit policy pipelines:

- HTTP: `/v1/task-board/policy/pipeline`, `/v1/task-board/policy/simulate`,
  `/v1/task-board/policy/promote`, `/v1/task-board/policy/audit`
- WebSocket: `task_board.policy_pipeline_get`,
  `task_board.policy_pipeline_save_draft`,
  `task_board.policy_pipeline_simulate`,
  `task_board.policy_pipeline_promote`, `task_board.policy_pipeline_audit`

Promotion requires successful exact-revision simulation.

Merge evidence predicates:

| Field | Pass | Failure |
| --- | --- | --- |
| `checks_green` | true | deny `checks_not_green` |
| `branch_protection_allows_merge` | true | deny `branch_protection_blocked` |
| `reviewer_verdict_approved` | true | deny `reviewer_not_approved` |
| `unresolved_requested_changes` | zero | deny `unresolved_requested_changes` |
| `protected_path_touched` | false | require consensus `protected_path_touched` |
| `risk_score` | <= `40` | dry-run-only `risk_above_threshold` |

Missing merge evidence or invalid graphs require a human.
