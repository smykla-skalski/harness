//! Every prompt an agent is started with, pinned to the bytes it rendered
//! before prompts became configurable, then exercised through a customized
//! catalog. The golden constants are captured from the shipped implementation,
//! so a builtin render that drifts by one character fails here.

use crate::task_board::AgentMode;
use crate::task_board::prompt_catalog::{
    PROMPT_CATALOG_TEST_LOCK, PromptCatalog, scoped_prompt_catalog,
};

use super::super::test_support::applied_task;
use super::super::{codex_worker_request, terminal_worker_request};
use super::{review_launch, write_launch};

const REVIEW_GOLDEN: &str = "Run a strictly read-only review for Task Board item 'board-1'.\n\nTitle: Board item\nContext: Investigate the issue\nExact head: head-frozen\nWorktree: /tmp/task-worktree\n\nDo not modify files, commits, branches, task state, pull requests, or external systems. Verify that every inspected change belongs to the exact frozen head above; return human_required when that revision cannot be inspected. Your final message must contain only one JSON value matching this exact identity and shape (use verdict pass, changes_required, or human_required):\n{\n  \"schema_version\": 1,\n  \"execution_id\": \"workflow-1\",\n  \"action_key\": \"review:default-code-reviewer\",\n  \"attempt\": 1,\n  \"idempotency_key\": \"codex-review-attempt\",\n  \"exact_head_revision\": \"head-frozen\",\n  \"artifact\": {\n    \"kind\": \"review\",\n    \"value\": {\n      \"profile_id\": \"default-code-reviewer\",\n      \"result\": {\n        \"verdict\": \"pass\",\n        \"head_revision\": \"head-frozen\",\n        \"summary\": \"concise review conclusion\",\n        \"findings\": [\n          \"actionable finding when changes are required\"\n        ]\n      }\n    }\n  }\n}";

const WRITE_GOLDEN: &str = "Implement the exact approved plan for Task Board item 'board-1'.\n\nTitle: Board item\nWorktree: /tmp/task-worktree\nBase head: head-base\n\nApproved plan:\n# Plan\n\nImplement the approved change.\n\nAcceptance criteria:\n- Focused tests pass\n\nWork only in the assigned worktree. Preserve unrelated changes, run focused validation through repository workflows, and create local commits as required by the repository; do not push, publish, or merge. Before responding, replace every REPLACE_WITH_CURRENT_HEAD token below with the exact resulting Git HEAD. Your final message must contain only one JSON value matching this exact identity and shape:\n{\n  \"schema_version\": 1,\n  \"execution_id\": \"workflow-1\",\n  \"action_key\": \"implementation:1\",\n  \"attempt\": 1,\n  \"idempotency_key\": \"codex-implementation-attempt\",\n  \"exact_head_revision\": \"REPLACE_WITH_CURRENT_HEAD\",\n  \"artifact\": {\n    \"kind\": \"implementation\",\n    \"value\": {\n      \"revision_cycle\": 1,\n      \"base_head_revision\": \"head-base\",\n      \"head_revision\": \"REPLACE_WITH_CURRENT_HEAD\",\n      \"summary\": \"concise implementation summary\",\n      \"evidence\": [\n        \"focused validation and owning gate results\"\n      ]\n    }\n  }\n}";

const WORKER_GOLDEN: &str = "Work on task-board item 'Ship managed worker launch'.\n\nBoard item: board-1\nSession task: task-1\nPriority: High\nStatus: InProgress\n\nWorktree:\n/tmp/task-worktree\n\nSession id:\nsession-1\n\nManaged run id:\ncodex-dispatch-intent-1\n\nTags:\nbackend\n\nExternal refs:\ngithub:123 (https://github.example/issues/123)\n\nTask body:\nStart a real worker.\n\nLifecycle:\nImplement the requested work, keep changes scoped, and run the smallest relevant validation.\n1. Run `harness session task list session-1 --json` and read `assigned_to` from task `task-1`; use that value as `<assigned-agent-id>`.\n2. Report progress with `harness session task checkpoint session-1 task-1 --actor <assigned-agent-id> --summary \"<summary>\" --progress <0-100>`.\n3. Submit with `harness session task submit-for-review session-1 task-1 --actor <assigned-agent-id> --summary \"<summary>\"`.\nThe controller also advances this task when the managed run completes and is the authoritative safety net.";

#[test]
fn the_read_only_review_prompt_renders_the_shipped_bytes() {
    let mut applied = applied_task(AgentMode::Evaluate);
    applied.read_only_workflow = Some(review_launch());

    let request =
        codex_worker_request(&applied, "codex-review-attempt").expect("render review request");

    assert_eq!(request.prompt, REVIEW_GOLDEN);
}

#[test]
fn the_write_implementation_prompt_renders_the_shipped_bytes() {
    let mut applied = applied_task(AgentMode::Headless);
    applied.write_workflow = Some(Box::new(write_launch()));

    let request = codex_worker_request(&applied, "codex-implementation-attempt")
        .expect("render write request");

    assert_eq!(request.prompt, WRITE_GOLDEN);
}

#[test]
fn the_worker_prompt_renders_the_shipped_bytes_on_both_transports() {
    let codex = codex_worker_request(&applied_task(AgentMode::Headless), "codex-dispatch-intent-1")
        .expect("render codex worker request");
    assert_eq!(codex.prompt, WORKER_GOLDEN);

    let terminal = terminal_worker_request(
        &applied_task(AgentMode::Interactive),
        "agent-tui-dispatch-intent-1",
    )
    .expect("render terminal worker request");
    assert_eq!(
        terminal.prompt.as_deref(),
        Some(WORKER_GOLDEN.replace("codex-dispatch-intent-1", "agent-tui-dispatch-intent-1"))
            .as_deref()
    );
}

#[test]
fn a_configured_review_prompt_replaces_the_shipped_one() {
    let _lock = PROMPT_CATALOG_TEST_LOCK.lock().expect("catalog test lock");
    let _installed = scoped_prompt_catalog(
        PromptCatalog::from_json(
            br#"{"read_only_review": "Review {{ board_item_id }} at {{ exact_head_revision }} as {{ profile_id }}"}"#,
        )
        .expect("parse overrides"),
    );
    let mut applied = applied_task(AgentMode::Evaluate);
    applied.read_only_workflow = Some(review_launch());

    let request =
        codex_worker_request(&applied, "codex-review-attempt").expect("render review request");

    assert_eq!(
        request.prompt,
        "Review board-1 at head-frozen as default-code-reviewer"
    );
}

#[test]
fn a_configured_write_prompt_replaces_the_shipped_one() {
    let _lock = PROMPT_CATALOG_TEST_LOCK.lock().expect("catalog test lock");
    let _installed = scoped_prompt_catalog(
        PromptCatalog::from_json(
            br#"{"write_implementation": "Implement {{ board_item_id }} from {{ base_head_revision }}"}"#,
        )
        .expect("parse overrides"),
    );
    let mut applied = applied_task(AgentMode::Headless);
    applied.write_workflow = Some(Box::new(write_launch()));

    let request = codex_worker_request(&applied, "codex-implementation-attempt")
        .expect("render write request");

    assert_eq!(request.prompt, "Implement board-1 from head-base");
}

#[test]
fn a_configured_worker_prompt_replaces_the_shipped_one_on_both_transports() {
    let _lock = PROMPT_CATALOG_TEST_LOCK.lock().expect("catalog test lock");
    let _installed = scoped_prompt_catalog(
        PromptCatalog::from_json(br#"{"worker": "Do {{ board_item_id }} in {{ worktree }}"}"#)
            .expect("parse overrides"),
    );

    let codex = codex_worker_request(&applied_task(AgentMode::Headless), "codex-dispatch-intent-1")
        .expect("render codex worker request");
    assert_eq!(codex.prompt, "Do board-1 in /tmp/task-worktree");

    let terminal = terminal_worker_request(
        &applied_task(AgentMode::Interactive),
        "agent-tui-dispatch-intent-1",
    )
    .expect("render terminal worker request");
    assert_eq!(
        terminal.prompt.as_deref(),
        Some("Do board-1 in /tmp/task-worktree")
    );
}

#[test]
fn a_review_prompt_naming_an_absent_pull_request_refuses_the_spawn() {
    let _lock = PROMPT_CATALOG_TEST_LOCK.lock().expect("catalog test lock");
    let _installed = scoped_prompt_catalog(
        PromptCatalog::from_json(br#"{"read_only_review": "Review {{ pull_request }}"}"#)
            .expect("parse overrides"),
    );
    let mut applied = applied_task(AgentMode::Evaluate);
    applied.read_only_workflow = Some(review_launch());

    let error = codex_worker_request(&applied, "codex-review-attempt")
        .expect_err("absent pull request refuses the spawn");

    assert!(
        error.message().contains("pull_request"),
        "{}",
        error.message()
    );
}

#[test]
fn a_worker_prompt_naming_an_absent_fact_refuses_the_spawn() {
    let _lock = PROMPT_CATALOG_TEST_LOCK.lock().expect("catalog test lock");
    let _installed = scoped_prompt_catalog(
        PromptCatalog::from_json(br#"{"worker": "Do {{ board_item_id }} for {{ project_id }}"}"#)
            .expect("parse overrides"),
    );

    let error = codex_worker_request(&applied_task(AgentMode::Headless), "codex-dispatch-intent-1")
        .expect_err("absent project refuses the spawn");
    assert!(error.message().contains("project_id"), "{}", error.message());

    let error = terminal_worker_request(
        &applied_task(AgentMode::Interactive),
        "agent-tui-dispatch-intent-1",
    )
    .expect_err("absent project refuses the terminal spawn");
    assert!(error.message().contains("project_id"), "{}", error.message());
}
