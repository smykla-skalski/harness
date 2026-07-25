//! Recovering a worker that was launched before its prompt was customized.
//!
//! The launch prompt used to be the whole identity check, compared byte for
//! byte, so any prompt change stranded a running worker. Identity now rests on
//! the frozen structural fields, and the prompt is confirmation rather than
//! the proof.

use crate::daemon::protocol::{CodexRunStatus, ManagedAgentSnapshot};
use crate::task_board::AgentMode;
use crate::task_board::prompt_catalog::{
    PROMPT_CATALOG_TEST_LOCK, PromptCatalog, scoped_prompt_catalog,
};

use super::super::test_support::{applied_task, codex_snapshot};
use super::super::{codex_worker_request, recover_same_applied_worker};
use super::review_launch;

fn running_review_worker() -> (crate::task_board::DispatchAppliedTask, ManagedAgentSnapshot) {
    let mut applied = applied_task(AgentMode::Evaluate);
    applied.read_only_workflow = Some(review_launch());
    let run_id = "codex-review-attempt";
    let request = codex_worker_request(&applied, run_id).expect("render review request");
    let mut run = codex_snapshot(CodexRunStatus::Running, &applied.session_id);
    run.run_id = run_id.into();
    run.board_item_id = request.board_item_id;
    run.workflow_execution_id = request.workflow_execution_id;
    run.task_id = request.task_id;
    run.mode = request.mode;
    run.prompt = request.prompt;
    run.model = request.model;
    run.effort = request.effort;
    run.project_dir = applied
        .read_only_workflow
        .as_ref()
        .expect("read-only launch")
        .run_context
        .worktree
        .clone();
    (applied, ManagedAgentSnapshot::Codex(run))
}

#[test]
fn a_worker_launched_before_the_prompt_changed_still_recovers() {
    let _lock = PROMPT_CATALOG_TEST_LOCK.lock().expect("catalog test lock");
    let (applied, snapshot) = running_review_worker();

    let _installed = scoped_prompt_catalog(
        PromptCatalog::from_json(br#"{"read_only_review": "Review {{ board_item_id }} now"}"#)
            .expect("parse overrides"),
    );

    recover_same_applied_worker(snapshot, &applied)
        .expect("a prompt change must not strand a running worker");
}

#[test]
fn a_prompt_change_does_not_excuse_a_different_worktree() {
    let _lock = PROMPT_CATALOG_TEST_LOCK.lock().expect("catalog test lock");
    let (applied, snapshot) = running_review_worker();
    let ManagedAgentSnapshot::Codex(mut run) = snapshot else {
        panic!("codex snapshot");
    };
    run.project_dir = "/tmp/other-worktree".into();

    let _installed = scoped_prompt_catalog(
        PromptCatalog::from_json(br#"{"read_only_review": "Review {{ board_item_id }} now"}"#)
            .expect("parse overrides"),
    );

    let error = recover_same_applied_worker(ManagedAgentSnapshot::Codex(run), &applied)
        .expect_err("a conflicting worktree still fails");

    assert_eq!(error.code(), "KSRCLI092");
}

/// Identity is structural, so recovery must not need the prompt to render at
/// all. It used to: an unrenderable template turned a healthy running worker
/// into a conflict, and because the claim is fenced before rollback that
/// looped until the daemon restarted — not the one-line configuration edit it
/// looked like.
#[test]
fn a_worker_recovers_even_when_the_configured_prompt_cannot_render() {
    let _lock = PROMPT_CATALOG_TEST_LOCK.lock().expect("catalog test lock");
    let (applied, snapshot) = running_review_worker();

    let _installed = scoped_prompt_catalog(
        PromptCatalog::from_json(br#"{"read_only_review": "Review {{ titel }}"}"#)
            .expect("parse overrides"),
    );

    recover_same_applied_worker(snapshot, &applied)
        .expect("a broken template must not strand a healthy worker");
}
