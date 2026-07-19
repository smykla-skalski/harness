use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardAttemptState, TaskBoardExecutionAttemptCas,
    TaskBoardExecutionAttemptRecord, TaskBoardExecutionPhase, TaskBoardExecutionState,
    TaskBoardLifecycleOutcome, TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord,
    TaskBoardWorkflowRevisionGuard,
};

use super::fixture::{Fixture, NOW, RETRY_AT, seed_publish_attempt};
use super::runtime::FakeReadOnlyRuntime;

#[tokio::test]
async fn stale_starting_snapshot_does_not_republish_settled_attempt() {
    let fixture = seed_publish_attempt(
        "publish-stale-starting-snapshot",
        TaskBoardExecutionState::Running,
        TaskBoardAttemptState::Starting,
    )
    .await;
    let runtime = FakeReadOnlyRuntime::new([]);
    let stale = super::load_execution(&fixture).await;

    super::super::task_board_read_only_coordinator::reconcile_preloaded_read_only_execution(
        &fixture.test.db,
        &runtime,
        stale.clone(),
        NOW,
    )
    .await
    .expect("settle first publish claim");
    assert_eq!(runtime.publish_count(), 1);

    super::super::task_board_read_only_coordinator::reconcile_preloaded_read_only_execution(
        &fixture.test.db,
        &runtime,
        stale,
        NOW,
    )
    .await
    .expect("ignore stale publish claimant after settlement");

    let completed = super::load_execution(&fixture).await;
    assert_eq!(
        completed.attempts[0].state,
        TaskBoardAttemptState::Completed
    );
    assert_eq!(runtime.publish_count(), 1);
    assert_eq!(runtime.verification_count(), 1);
}

#[tokio::test]
async fn completed_publish_phase_advance_supersedes_parent_state_repair() {
    let fixture = seed_publish_attempt(
        "publish-phase-advance-wins",
        TaskBoardExecutionState::Running,
        TaskBoardAttemptState::Starting,
    )
    .await;
    let initial = super::load_execution(&fixture).await;
    let starting = initial.attempts[0].clone();
    let mut claimed = starting.clone();
    claimed.state = TaskBoardAttemptState::Running;
    claimed.available_at = Some(RETRY_AT.into());
    fixture
        .test
        .db
        .claim_task_board_workflow_side_effect(
            &TaskBoardWorkflowExecutionCas::from(&initial),
            &TaskBoardExecutionAttemptCas::from(&starting),
            &claimed,
            NOW,
        )
        .await
        .expect("claim publish side effect")
        .expect("publish claim winner");

    let mut completed = claimed.clone();
    completed.state = TaskBoardAttemptState::Completed;
    completed.available_at = None;
    completed.artifact = Some(TaskBoardAttemptResultArtifact::Lifecycle(
        TaskBoardLifecycleOutcome {
            mutated: true,
            terminal: false,
            provider_revision: None,
            external_url: Some("https://github.com/example/compass/pull/17".into()),
        },
    ));
    completed.completed_at = Some(NOW.into());
    super::super::task_board_workflow_execution::record_workflow_execution_attempt(
        &fixture.test.db,
        &TaskBoardExecutionAttemptCas::from(&claimed),
        &completed,
    )
    .await
    .expect("persist completed publish evidence");

    let settled = super::load_execution(&fixture).await;
    assert_stale_claim_is_superseded(&fixture, &initial, &starting, &claimed).await;
    super::super::task_board_workflow_execution::advance_workflow_execution(
        &fixture.test.db,
        &TaskBoardWorkflowExecutionCas::from(&settled),
        &TaskBoardWorkflowRevisionGuard::from(&settled.snapshot),
        settled.transition.pull_request.as_ref(),
        settled.transition.exact_head_revision.as_deref(),
        NOW,
    )
    .await
    .expect("advance completed publish evidence");
    let advanced = super::load_execution(&fixture).await;
    assert_eq!(
        advanced.transition.phase,
        Some(TaskBoardExecutionPhase::Cleanup)
    );
    assert_eq!(
        advanced.transition.execution_state,
        TaskBoardExecutionState::Pending
    );
    assert_stale_claim_is_superseded(&fixture, &initial, &starting, &claimed).await;

    super::super::task_board_read_only_coordinator::settle_execution_running_in_phase_for_test(
        &fixture.test.db,
        &fixture.execution_id,
        TaskBoardExecutionPhase::Publish,
        NOW,
    )
    .await
    .expect("phase advance supersedes stale parent repair");

    assert_eq!(super::load_execution(&fixture).await, advanced);
}

async fn assert_stale_claim_is_superseded(
    fixture: &Fixture,
    stale_execution: &TaskBoardWorkflowExecutionRecord,
    stale_attempt: &TaskBoardExecutionAttemptRecord,
    claimed: &TaskBoardExecutionAttemptRecord,
) {
    let before = super::load_execution(fixture).await;
    assert!(
        fixture
            .test
            .db
            .claim_task_board_workflow_side_effect(
                &TaskBoardWorkflowExecutionCas::from(stale_execution),
                &TaskBoardExecutionAttemptCas::from(stale_attempt),
                claimed,
                NOW,
            )
            .await
            .expect("settled publish supersedes a stale claimant")
            .is_none()
    );
    assert_eq!(super::load_execution(fixture).await, before);
}
