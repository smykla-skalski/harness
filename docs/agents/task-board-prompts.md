# Task Board agent prompts

Every prompt a Task Board agent runs with is compiled in as a default and can be replaced from a file, without rebuilding. With nothing configured the daemon renders exactly the shipped prompts, byte for byte.

## Turning it on

```bash
HARNESS_FEATURE_TASK_BOARD_PROMPT_OVERRIDES=1 \
HARNESS_TASK_BOARD_PROMPTS_FILE=/path/to/prompts.json \
  harness-daemon serve
```

The file is read once, at daemon startup. Editing it takes effect on the next restart. With the flag off the file is ignored entirely, and with the flag on but no file configured the shipped prompts are used.

A file that cannot be read, is not JSON, or names a prompt that does not exist leaves the daemon on the shipped prompts and logs the reason. The daemon still starts: a broken prompt file must not take the control plane down.

## The file

An object keyed by prompt name. A value is either the prompt text or an array of its lines, joined with newlines.

```json
{
  "triage_escalation": "Decide whether {{ title }} is ready to work on.",
  "read_only_review": [
    "Review {{ board_item_id }} at {{ exact_head_revision }}.",
    "{{ workspace_directive }}",
    "Reply with only this JSON:",
    "{{ response_json }}"
  ]
}
```

Prompts you leave out keep their shipped text.

## Prompts

| Name | The agent it starts |
| --- | --- |
| `triage_escalation` | Judges whether an item a deterministic check could not decide is ready to work on |
| `worker` | An ordinary board worker, on both the Codex and terminal transports |
| `write_implementation` | Implements an approved plan |
| `read_only_review` | Reviews a frozen revision |
| `evaluation` | Judges the durable review evidence |

## Variables

`{{ name }}` is replaced with the named fact. Single braces pass through untouched, so embedded JSON needs no escaping, and a substituted value is never re-scanned — an item whose body contains `{{ title }}` is inert text.

Some variables are always available; others exist only for an item that has them. Naming one an item lacks is refused before the agent starts, and naming one that does not exist at all is refused for that prompt the first time it is used. Both surface as a failed spawn with the variable named, so the item stays unstarted.

The `*_section` variables are the shipped prompt's optional blocks, already wrapped in their heading and empty when the fact is missing. Use them to reorder or drop sections; use the raw fact next to them when you want your own wording and are willing to have the spawn refused for an item without it.

`triage_escalation` — `title`, `priority`, `kind`, `tags`, `body`, `escalation_id`, `verdict_token`, `evidence_fingerprint`; `project_id` when the item has one. `tags` and `body` substitute `(none)`/`(empty)` rather than disappearing.

`worker` — `title`, `board_item_id`, `work_item_id`, `priority`, `status`, `lifecycle_section`, and the section/fact pairs `project_id`, `worktree`, `session_id`, `managed_run_id`, `tags`, `external_refs`, `planning_summary`, `task_body`.

`write_implementation` — `board_item_id`, `title`, `workspace_directive`, `base_head_revision`, `plan_markdown`, `acceptance_criteria`, `response_json`, `execution_id`, `managed_run_id`; `worktree` for a local run.

`read_only_review` — `board_item_id`, `title`, `context`, `exact_head_revision`, `pull_request_line`, `workspace_directive`, `response_json`, `execution_id`, `managed_run_id`, `profile_id`; `worktree` for a local run and `pull_request` when the item has one.

`evaluation` — `board_item_id`, `title`, `exact_head_revision`, `review_evidence`, `response_json`, `execution_id`, `managed_run_id`.

`workspace_directive` is the whole workspace line: it names a worktree for a local run and the executor checkout for a remote one, which is why a template that hardcodes `Worktree: {{ worktree }}` refuses remote runs.

## What a customized prompt must still do

The workflow prompts embed a result contract in `response_json` and the escalation prompt embeds the exact command the agent reports its verdict with. Dropping either leaves the agent with no way to return a result the daemon accepts, and the run fails at its report step rather than at spawn. Keep `{{ response_json }}` in the workflow prompts and the report command in the escalation prompt.

## Recovery

An interrupted worker used to be identified by comparing its launch prompt byte for byte, which meant no prompt could ever change without stranding running work. Identity now rests on the frozen structural fields — session, worktree, board item, workflow execution, task, mode, model, effort — and a recovered worker whose prompt no longer matches is logged and accepted. A worker whose structural fields disagree is still refused.

The prompt an agent actually ran with stays recoverable: a Codex-backed run keeps it on its run row next to its result, and a terminal agent's prompt is written to `prompt.txt` beside its transcript.
