# Task Board Workflow

Harness task boards are cross-project work items managed through
`harness task-board`. Use this guide for backlog intake, planning review,
dispatch readiness, and overview reporting.

## Contract

- Treat the task board as Harness state. Read and mutate it only through
  `harness task-board ...` commands.
- Use `--json` for machine-readable reads. Do not parse board files directly.
- Keep titles short and imperative. Put scope, constraints, acceptance
  criteria, and verification notes in `--body`.
- Use `--project-id` when the work belongs to a known project. Use `--tag` for
  routing labels.
- Use `--board-root <path>` only for isolated tests or recovery work.

## Command Surface

| Command | Purpose |
| --- | --- |
| `create` | Create a new board task. |
| `list` | List active board tasks, optionally filtered by status. |
| `get` | Show one board task. |
| `update` | Change task fields, status, priority, project, tags, or planning state. |
| `delete` | Tombstone one board task. |
| `sync` | Print external synchronization readiness. |
| `dispatch` | Print session dispatch plans for board tasks. |
| `audit` | Print task-board totals, ready count, blocked count, and status counts. |
| `project` | Print project overview counts. |
| `machine` | Print worker-mode overview counts. |

Common read flags: `--json`, `--board-root <path>`.

## Work Item Shape

Each task carries:

- `id`, `title`, `body`
- `status`: `new`, `planning`, `plan_review`, `todo`, `in_progress`,
  `in_review`, `done`, `blocked`
- `priority`: `low`, `medium`, `high`, `critical`
- `agent_mode`: `headless`, `interactive`, `planning`, `evaluate`
- `tags`, optional `project_id`, external refs, planning metadata, and optional
  session/work-item links

Priority maps to dispatch severity when session plans are built:

| Priority | Use for |
| --- | --- |
| `critical` | Session-blocking correctness or safety issue. |
| `high` | Important work needed before closeout. |
| `medium` | Normal implementation, verification, or cleanup item. |
| `low` | Opportunistic polish or non-blocking follow-up. |

## Status Flow

```text
new -> planning -> plan_review -> todo -> in_progress -> in_review -> done
           |                         |          |
           v                         v          v
        blocked                   blocked    blocked
```

`blocked` means the task cannot proceed without new input, an external
dependency, or a planning/review decision.

Dispatch readiness requires:

- status is `todo`
- `planning.summary` is present
- `planning.approved_by` and `planning.approved_at` are present
- the item is not deleted and is not already linked to a session work item

The CLI sets `approved_at` when `--approved-by` is provided.

## Intake And Planning

1. Create the board item.

   ```bash
   harness task-board create \
     --title "Implement focused fix" \
     --body "Scope, files, acceptance criteria, and verification." \
     --priority high \
     --project-id <project-id> \
     --tag backend
   ```

2. Move it into planning.

   ```bash
   harness task-board update <task-id> --status planning
   ```

3. Submit the plan for review.

   ```bash
   harness task-board update <task-id> \
     --status plan_review \
     --planning-summary "Cause, fix shape, verification, and rollback notes."
   ```

4. Approve the plan and make it dispatchable.

   ```bash
   harness task-board update <task-id> \
     --status todo \
     --approved-by <reviewer-or-leader-id>
   ```

## Worker And Review Loop

1. Find ready work.

   ```bash
   harness task-board list --status todo --json
   harness task-board dispatch --json
   ```

2. Mark active work explicitly.

   ```bash
   harness task-board update <task-id> --status in_progress
   ```

3. Move finished work to review.

   ```bash
   harness task-board update <task-id> --status in_review
   ```

4. Close or block after review.

   ```bash
   harness task-board update <task-id> --status done
   harness task-board update <task-id> --status blocked
   ```

Use the task body, tags, and planning summary for review context. If the plan
changes materially, return to `planning` or `plan_review` before dispatching
again.

## Overview Integration

Use overview commands instead of reading task-board files:

```bash
harness task-board audit --json
harness task-board project --json
harness task-board machine --json
harness task-board sync --json
harness task-board dispatch --json
```

- `audit` gives total, ready, blocked, and by-status counts.
- `project` groups local items by `project_id` and ready count.
- `machine` groups local items by `agent_mode` and ready count.
- `sync` reports external-provider configuration, linked, pushable, and blocked
  counts.
- `dispatch` reports the session, worker, reviewer, and evaluator intent for
  each board item, including readiness block reasons.

## Operating Rules

- Prefer many small tasks over one broad task. Each task needs one clear close
  condition.
- Do not dispatch `new`, `planning`, `plan_review`, `in_progress`,
  `in_review`, `done`, or `blocked` items.
- Do not bypass the planning/review gate by setting `todo` without
  `--planning-summary` and `--approved-by`.
- Use `delete` for tombstones, not manual file removal.
- Keep `audit`, `project`, `machine`, and `dispatch` output in closeout notes
  when coordinating multiple projects or worker modes.
