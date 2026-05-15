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
| `sync` | Preview or apply external synchronization. |
| `dispatch` | Print session dispatch plans for board tasks, or apply ready plans. |
| `evaluate` | Reconcile linked session work back into board workflow state. |
| `audit` | Print task-board totals, ready count, blocked count, and status counts. |
| `project` | Print project overview counts. |
| `machine` | Print worker-mode overview counts. |
| `orchestrator` | Manage autonomous task-board ticks and durable settings. |

Common read flags: `--json`, `--board-root <path>`.

## Work Item Shape

Each task carries:

- `id`, `title`, `body`
- `status`: `new`, `planning`, `plan_review`, `needs_you`, `todo`,
  `in_progress`, `in_review`, `done`, `blocked`
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

github inbox -> needs_you -> todo
                   |
                   v
                blocked
```

`blocked` means the task cannot proceed without new input, an external
dependency, or a planning/review decision.

Dispatch readiness requires:

- status is `todo`
- `planning.summary` is present
- `planning.approved_by` and `planning.approved_at` are present
- the item is not deleted and is not already linked to a session work item
- the policy decision for `spawn_agent` is `allow`

The CLI sets `approved_at` when `--approved-by` is provided.

Standard GitHub issue sync still imports repo-scoped `todo` items with a
synthesized planning summary. The separate GitHub inbox flow for selected repos
imports issues assigned to you and pull requests requesting your review as
repo-scoped `needs_you` items instead. Inbox items are not dispatch-ready until
a human moves them into the normal planning/ready flow. Review-request inbox
items that GitHub no longer reports for you are automatically resolved out of
the inbox state on the next pull sync.

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

## Dispatch, Worker, And Review Loop

1. Find ready work.

   ```bash
   harness task-board list --status todo --json
   harness task-board dispatch --dry-run --json
   ```

2. Apply ready dispatch plans when the leader is ready to create or reuse
   sessions and link board items to session work items.

   ```bash
   harness task-board dispatch --dry-run --json
   harness task-board dispatch --project-dir <project-dir> --actor <leader-id> --json
   ```

   Dry runs only report plans. Applied dispatch creates a session when the item
   has no `session_id`, creates a session work item from the board title/body,
   maps priority to task severity, stores `session_id` and `work_item_id`, marks
   the board item `in_progress`, and advances workflow state to `running` at
   the `dispatch` step.

3. Mark active work explicitly when work starts outside applied dispatch.

   ```bash
   harness task-board update <task-id> --status in_progress
   ```

4. Move finished work to review.

   ```bash
   harness task-board update <task-id> --status in_review
   ```

5. Reconcile linked session work back into the board.

   ```bash
   harness task-board evaluate --status in_progress --dry-run --json
   harness task-board evaluate --json
   ```

   `evaluate` skips unlinked board items. For linked items, it reads the
   session work item and maps session task state to board state:

   | Session task state | Board result |
   | --- | --- |
   | `open`, `in_progress` | `in_progress`, workflow `running` |
   | `awaiting_review`, `in_review` | `in_review`, workflow `running` |
   | `done` | `done`, workflow `completed` |
   | `blocked` | `blocked`, workflow `failed` |
   | missing session or task | `blocked`, workflow `failed` |

   A non-approving review consensus keeps the board item `in_review` and stores
   the review summary as the workflow error context.

6. Close or block after review when not using `evaluate`.

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
harness task-board project --json [--status <status>]
harness task-board machine --json [--status <status>]
harness task-board sync --json [--provider <provider>] [--direction <pull|push|both>] [--apply]
harness task-board dispatch --dry-run --json [--item-id <id>] [--status <status>]
harness task-board evaluate --json [--item-id <id>] [--status <status>]
harness task-board orchestrator status --json
harness task-board orchestrator settings --json
```

- `audit` gives total, ready, blocked, and by-status counts.
- `project` groups local items by `project_id` and ready count.
- `machine` groups local items by `agent_mode` and ready count.
- `sync` reports external-provider configuration, linked, pushable, and blocked
  counts plus previewed/applied operations. `--provider` narrows the provider,
  `--direction` narrows pull/push intent, and `--apply` persists external
  changes instead of previewing them. GitHub pull imports preserve `owner/repo`
  in `project_id` and synthesize dispatch-ready planning approval.
- `dispatch` reports the session, worker, reviewer, and evaluator intent for
  each selected board item, including readiness block reasons.
- `evaluate` reports evaluated, updated, skipped, completed, running,
  reviewing, blocked, and failed counts for the selected status or item.
- `orchestrator status` reports enabled/running intent, current tick, last run,
  workflow-state counts, settings, dispatch results, evaluation results, and
  policy trace IDs.

## Dispatch Intent

Each dispatch plan contains the control-plane intent needed to coordinate
agents:

- `session`: reuse `session_id` when present; otherwise create a session with
  the board title, body context, and project id.
- `task`: create a session work item from the title/body, planning summary,
  priority-derived severity, tags, and external refs.
- `worker`: use the board item's `agent_mode` (`headless`, `interactive`,
  `planning`, or `evaluate`) as the requested worker mode.
- `reviewer`: request the `code-reviewer` persona after worker review with
  consensus count `2`.
- `evaluator`: request an `evaluate` follow-up after worker review.
- `policy`: include the policy decision that allowed or blocked dispatch.

`dispatch` does not directly start managed agents. Leaders use the dispatch
plan plus session agent commands to launch capacity:

```bash
harness session agents start terminal <session-id> --runtime <runtime> \
  --role worker --capability <tag> --prompt "..."
harness session agents start codex <session-id> --mode <mode> --prompt "..."
harness session agents start acp --session-id <session-id> --agent <descriptor> \
  --role worker --prompt "..."
```

Managed agent controls include `list`, `show`, terminal `input`/`resize`/`stop`,
Codex `steer`/`interrupt`/`approve`, and ACP `inspect`. Start commands can carry
role, fallback role, capability tags, display name, persona, model, effort, and
project directory where the runtime supports them.

## Orchestrator

`harness task-board orchestrator` persists autonomous intent and one-tick run
state under the task-board root. Its command surface is:

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

Defaults are conservative: workflows enabled for default tasks, PR fixes, PR
reviews, and dependency updates; `dry_run_default=true`; and
`dispatch_status_filter=todo`. `run-once` records a `dispatch` phase, executes
task-board dispatch through the daemon service, records an `evaluation` phase,
then evaluates linked work. When `github_project.enabled_automations` includes
`sync_task_board`, `run-once` first performs a GitHub pull preview/apply with
the current dry-run mode. The persisted `github_project.owner`/`repo` settings
act as the repository fallback when `HARNESS_GITHUB_REPOSITORY` or
`GITHUB_REPOSITORY` is unset. `--apply` overrides the dry-run default for that
tick. Failures persist a failed last-run summary instead of silently dropping
tick state.

When GitHub automations are enabled, the same tick also reuses the dispatched
session worktree to manage the PR lifecycle for repo-scoped items. Harness
publishes the managed branch, creates or reuses the configured draft PR, marks
it ready for review when requested, syncs managed labels, reads checks and
review evidence through GitHub, and auto-merges only when the merge policy
allows it. Review-changes-requested items do not open fresh PRs until the
underlying task becomes reviewable again.

## Policy Pipeline

Dispatch policy is part of readiness. The built-in gate allows normal planning,
sync, triage, spawn-agent, branch, PR, review, and stop-agent actions; forces
repository mutation into dry-run-only; requires a human for worktree deletion,
secret access, and destructive filesystem actions; and gates PR merge by
evidence.

When the durable policy graph exists in `dry_run` or `enforced` mode, dispatch
uses the graph policy gate instead of the built-in gate. Draft graphs are stored
but do not affect dispatch readiness. The daemon exposes policy-pipeline
routes to load the graph, save drafts, simulate, promote, and audit:

- HTTP: `/v1/task-board/policy/pipeline`, `/v1/task-board/policy/simulate`,
  `/v1/task-board/policy/promote`, `/v1/task-board/policy/audit`
- WebSocket: `task_board.policy_pipeline_get`,
  `task_board.policy_pipeline_save_draft`,
  `task_board.policy_pipeline_simulate`,
  `task_board.policy_pipeline_promote`, and
  `task_board.policy_pipeline_audit`

Policy promotion requires a successful exact-revision simulation. Simulation
records decisions for all policy actions and writes policy trace IDs for audit.

Merge evidence predicates are:

| Field | Passing predicate | Failing result |
| --- | --- | --- |
| `checks_green` | true | deny `checks_not_green` |
| `branch_protection_allows_merge` | true | deny `branch_protection_blocked` |
| `reviewer_verdict_approved` | true | deny `reviewer_not_approved` |
| `unresolved_requested_changes` | zero | deny `unresolved_requested_changes` |
| `protected_path_touched` | false | require consensus `protected_path_touched` |
| `risk_score` | less than or equal to threshold `40` | dry-run-only `risk_above_threshold` |

Missing merge evidence requires a human. Invalid graphs also require a human.

## Operating Rules

- Prefer many small tasks over one broad task. Each task needs one clear close
  condition.
- Do not dispatch `new`, `planning`, `plan_review`, `needs_you`,
  `in_progress`, `in_review`, `done`, or `blocked` items.
- Do not bypass the planning/review gate by setting `todo` without
  `--planning-summary` and `--approved-by`.
- Use `delete` for tombstones, not manual file removal.
- Keep `audit`, `project`, `machine`, and `dispatch` output in closeout notes
  when coordinating multiple projects or worker modes.
