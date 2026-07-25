//! Sealing a remote offer renders the prompt, so a configured prompt can fail
//! for one execution and not its neighbours. That has to stay one candidate's
//! problem.

use crate::daemon::db::add_remote_review_candidate;
use crate::task_board::prompt_catalog::{
    PromptCatalog, prompt_catalog_test_lock, scoped_prompt_catalog,
};
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TaskBoardAttemptState, TaskBoardPullRequestIdentity,
};

use super::super::{TaskBoardRemoteControllerReport, offer_remote_candidates};
use super::{assignment_count, refresh_fixture_observation};

/// The failure this pins: the render error propagated out of the loop, and the
/// controller pass is a precondition of every dispatch route. One execution
/// naming a fact it does not have therefore stopped every unrelated item from
/// dispatching, on every tick, until the daemon restarted.
///
/// The fixture execution has no pull request and sorts first; the second
/// candidate has one and must still reach its host.
#[tokio::test]
async fn one_unrenderable_candidate_does_not_block_the_others() {
    let _lock = prompt_catalog_test_lock();
    let fixture = crate::daemon::db::remote_controller_fixture(1).await;
    let renderable = add_remote_review_candidate(
        &fixture.db,
        "remote-with-pr",
        Some(TaskBoardPullRequestIdentity {
            repository: "example/harness".into(),
            number: 42,
            head: None,
        }),
    )
    .await;
    refresh_fixture_observation(&fixture, 2, 0).await;
    let _installed = scoped_prompt_catalog(
        PromptCatalog::from_json(br#"{"read_only_review": "Review {{ pull_request }}"}"#)
            .expect("parse overrides"),
    );
    let mut report = TaskBoardRemoteControllerReport::default();

    offer_remote_candidates(&fixture.db, &mut report)
        .await
        .expect("one unrenderable prompt must not abort the pass");

    assert_eq!(report.offered_attempts, 1);
    assert_eq!(assignment_count(&fixture).await, 0);
    assert_eq!(
        execution_target(&fixture.db, &fixture.execution.execution_id).await,
        Some("local".into())
    );
    let offered = fixture
        .db
        .task_board_workflow_execution(&renderable.execution_id)
        .await
        .expect("load the renderable candidate")
        .expect("renderable candidate exists");
    assert_eq!(offered.attempts[0].state, TaskBoardAttemptState::Starting);
    assert!(
        offered
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            .is_some_and(|target| target.starts_with("remote:")),
        "{:?}",
        offered.ownership.resources
    );
}

async fn execution_target(
    db: &crate::daemon::db::AsyncDaemonDb,
    execution_id: &str,
) -> Option<String> {
    db.task_board_workflow_execution(execution_id)
        .await
        .expect("load execution target")
        .expect("execution exists")
        .ownership
        .resources
        .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
        .cloned()
}
