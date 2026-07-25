//! The durable workflow coordinator renders the same three prompts the
//! dispatch path does, for executions it reconstructs from the database. The
//! goldens pin them to the bytes they produced before prompts became
//! configurable.

use std::collections::BTreeMap;

use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionAttemptRecord, TaskBoardExecutionOwnership,
    TaskBoardExecutionPhase, TaskBoardExecutionState, TaskBoardReadOnlyRunContext,
    TaskBoardResolvedReviewer, TaskBoardReviewerProfile, TaskBoardWorkflowExecutionArtifacts,
    TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind, TaskBoardWorkflowSnapshot,
    TaskBoardWorkflowTransitionState, TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
};

use crate::task_board::prompt_catalog::{
    PROMPT_CATALOG_TEST_LOCK, PromptCatalog, scoped_prompt_catalog,
};

use super::{codex_attempt_request, remote_codex_attempt_request};

const NOW: &str = "2026-07-25T10:00:00Z";

fn attempt(action_key: &str) -> TaskBoardExecutionAttemptRecord {
    TaskBoardExecutionAttemptRecord {
        execution_id: "execution-1".into(),
        action_key: action_key.into(),
        attempt: 1,
        idempotency_key: "attempt-1".into(),
        state: TaskBoardAttemptState::Running,
        failure_class: None,
        available_at: None,
        error: None,
        artifact: None,
        started_at: NOW.into(),
        updated_at: NOW.into(),
        completed_at: None,
    }
}

fn execution(phase: TaskBoardExecutionPhase) -> TaskBoardWorkflowExecutionRecord {
    let reviewer = TaskBoardResolvedReviewer {
        reviewer_count: 1,
        required_approvals: 1,
        max_revision_cycles: 3,
        profiles: vec![TaskBoardReviewerProfile::default()],
    };
    let context = TaskBoardReadOnlyRunContext {
        schema_version: TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
        session_id: "session-1".into(),
        title: "Board item".into(),
        body: "Investigate the issue".into(),
        tags: vec!["backend".into()],
        worktree: "/tmp/task-worktree".into(),
    };
    TaskBoardWorkflowExecutionRecord {
        execution_id: "execution-1".into(),
        item_id: "item-1".into(),
        snapshot: TaskBoardWorkflowSnapshot {
            workflow_kind: TaskBoardWorkflowKind::Review,
            execution_repository: None,
            item_revision: 3,
            configuration_revision: 1,
            policy_version: "policy-v1".into(),
            reviewer: reviewer.clone(),
            read_only_run_context: Some(context),
            provider_revision: None,
        },
        resolved_reviewers: reviewer,
        transition: TaskBoardWorkflowTransitionState {
            workflow_kind: TaskBoardWorkflowKind::Review,
            phase: Some(phase),
            execution_state: TaskBoardExecutionState::Running,
            pull_request: None,
            exact_head_revision: Some("head-frozen".into()),
        },
        artifacts: TaskBoardWorkflowExecutionArtifacts::default(),
        ownership: TaskBoardExecutionOwnership {
            host_id: None,
            fencing_epoch: 0,
            resources: BTreeMap::from([("task_id".into(), "task-1".to_string())]),
        },
        available_at: None,
        blocked_reason: None,
        created_at: NOW.into(),
        updated_at: NOW.into(),
        completed_at: None,
        attempts: Vec::new(),
    }
}

const REVIEW_GOLDEN: &str = "Run a strictly read-only review for Task Board item 'item-1'.\n\nTitle: Board item\nContext: Investigate the issue\nExact head: head-frozen\nWorktree: /tmp/task-worktree\n\nDo not modify files, commits, branches, task state, pull requests, or external systems. Verify that every inspected change belongs to the exact frozen head above; return human_required when that revision cannot be inspected. Your final message must contain only one JSON value matching this exact identity and shape (use verdict pass, changes_required, or human_required):\n{\n  \"schema_version\": 1,\n  \"execution_id\": \"execution-1\",\n  \"action_key\": \"review:default-code-reviewer\",\n  \"attempt\": 1,\n  \"idempotency_key\": \"attempt-1\",\n  \"exact_head_revision\": \"head-frozen\",\n  \"artifact\": {\n    \"kind\": \"review\",\n    \"value\": {\n      \"profile_id\": \"default-code-reviewer\",\n      \"result\": {\n        \"verdict\": \"pass\",\n        \"head_revision\": \"head-frozen\",\n        \"summary\": \"concise review conclusion\",\n        \"findings\": [\n          \"actionable finding when changes are required\"\n        ]\n      }\n    }\n  }\n}";

const EVALUATION_GOLDEN: &str = "Evaluate the durable review evidence for Task Board item 'item-1'.\n\nTitle: Board item\nExact head: head-frozen\nReview evidence:\n[]\n\nDo not modify files, commits, branches, task state, pull requests, or external systems. Confirm the evidence is internally consistent and bound to the exact frozen head. Your final message must contain only one JSON value matching this exact identity and shape (use verdict pass, changes_required, or human_required):\n{\n  \"schema_version\": 1,\n  \"execution_id\": \"execution-1\",\n  \"action_key\": \"evaluate\",\n  \"attempt\": 1,\n  \"idempotency_key\": \"attempt-1\",\n  \"exact_head_revision\": \"head-frozen\",\n  \"artifact\": {\n    \"kind\": \"evaluation\",\n    \"value\": {\n      \"verdict\": \"pass\",\n      \"summary\": \"concise evaluation conclusion\",\n      \"evidence\": [\n        \"exact-head review evidence supporting the verdict\"\n      ]\n    }\n  }\n}";

#[test]
fn the_durable_review_prompt_renders_the_shipped_bytes() {
    let request = codex_attempt_request(
        &execution(TaskBoardExecutionPhase::Review),
        &attempt("review:default-code-reviewer"),
    )
    .expect("review request");

    assert_eq!(request.prompt, REVIEW_GOLDEN);
}

#[test]
fn the_durable_evaluation_prompt_renders_the_shipped_bytes() {
    let request = codex_attempt_request(
        &execution(TaskBoardExecutionPhase::Evaluate),
        &attempt("evaluate"),
    )
    .expect("evaluation request");

    assert_eq!(request.prompt, EVALUATION_GOLDEN);
}

#[test]
fn a_remote_attempt_names_its_executor_checkout_instead_of_a_worktree() {
    let request = remote_codex_attempt_request(
        &execution(TaskBoardExecutionPhase::Review),
        &attempt("review:default-code-reviewer"),
    )
    .expect("remote review request");

    assert!(
        request
            .prompt
            .contains("\nWorkspace: use the isolated executor checkout assigned to this run\n"),
        "{}",
        request.prompt
    );
    assert!(!request.prompt.contains("/tmp/task-worktree"));
}

#[test]
fn a_configured_evaluation_prompt_replaces_the_shipped_one() {
    let _lock = PROMPT_CATALOG_TEST_LOCK.lock().expect("catalog test lock");
    let _installed = scoped_prompt_catalog(
        PromptCatalog::from_json(
            br#"{"evaluation": "Judge {{ board_item_id }} at {{ exact_head_revision }}"}"#,
        )
        .expect("parse overrides"),
    );

    let request = codex_attempt_request(
        &execution(TaskBoardExecutionPhase::Evaluate),
        &attempt("evaluate"),
    )
    .expect("evaluation request");

    assert_eq!(request.prompt, "Judge item-1 at head-frozen");
}

#[test]
fn a_remote_attempt_refuses_a_prompt_naming_a_worktree_it_does_not_have() {
    let _lock = PROMPT_CATALOG_TEST_LOCK.lock().expect("catalog test lock");
    let _installed = scoped_prompt_catalog(
        PromptCatalog::from_json(br#"{"read_only_review": "Review in {{ worktree }}"}"#)
            .expect("parse overrides"),
    );

    let local = codex_attempt_request(
        &execution(TaskBoardExecutionPhase::Review),
        &attempt("review:default-code-reviewer"),
    )
    .expect("local review request");
    assert_eq!(local.prompt, "Review in /tmp/task-worktree");

    let error = remote_codex_attempt_request(
        &execution(TaskBoardExecutionPhase::Review),
        &attempt("review:default-code-reviewer"),
    )
    .expect_err("a remote run has no worktree to name");
    assert!(error.message().contains("worktree"), "{}", error.message());
}
