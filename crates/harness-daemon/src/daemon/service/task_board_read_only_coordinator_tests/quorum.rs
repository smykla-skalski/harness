use std::collections::BTreeSet;

use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionPhase, TaskBoardExecutionState,
    TaskBoardReviewRoundDecision, TaskBoardStatus, TaskBoardWorkflowKind, TaskBoardWorkflowStatus,
};

use super::fixture::{NOW, seed_execution_with_reviewers};
use super::runtime::{FakeReadOnlyRuntime, PlannedReport};

#[tokio::test]
async fn pull_request_review_runs_review_cleanup_and_terminal_without_publication() {
    let fixture = Box::pin(seed_execution_with_reviewers(
        "report-only-pull-request-review",
        TaskBoardWorkflowKind::PR_REVIEW,
        1,
        1,
    ))
    .await;
    let runtime = FakeReadOnlyRuntime::new([PlannedReport::passing_review()]);

    super::drive_to_terminal_projection(&fixture, &runtime).await;

    let completed = super::load_execution(&fixture).await;
    assert_eq!(
        completed.transition.phase,
        Some(TaskBoardExecutionPhase::Terminal)
    );
    assert_eq!(
        completed.transition.execution_state,
        TaskBoardExecutionState::Completed
    );
    let actions = completed
        .attempts
        .iter()
        .map(|attempt| attempt.action_key.as_str())
        .collect::<BTreeSet<_>>();
    assert_eq!(actions, ["cleanup", "review:reviewer-amber"].into());
    assert_eq!(runtime.start_count(), 1);
    assert_eq!(runtime.publish_count(), 0);
    let reports = fixture
        .test
        .db
        .task_board_ai_review_reports(&fixture.item_id)
        .await
        .expect("load retained review report");
    assert_eq!(reports.len(), 1);
    assert_eq!(reports[0].head_revision, super::fixture::FROZEN_HEAD);
    assert_eq!(reports[0].runtime, "runtime-shared");
    assert_eq!(reports[0].requested_model, "model-reviewer-amber");
    assert_eq!(
        reports[0].effective_model.as_deref(),
        Some("model-reviewer-amber")
    );
    assert_eq!(
        reports[0].summary.as_deref(),
        Some("exact-head review passed")
    );
    super::assert_terminal_projection(
        &fixture,
        TaskBoardStatus::Done,
        TaskBoardWorkflowStatus::Completed,
    )
    .await;
}

#[tokio::test]
async fn local_review_waits_for_two_reviewer_quorum_before_evaluation() {
    let fixture = Box::pin(seed_execution_with_reviewers(
        "local-two-reviewer-quorum",
        TaskBoardWorkflowKind::Review,
        2,
        2,
    ))
    .await;
    let runtime = FakeReadOnlyRuntime::new([
        PlannedReport::passing_review_for("reviewer-amber"),
        PlannedReport::passing_review_for("reviewer-indigo"),
        PlannedReport::passing_evaluation(),
    ]);

    for _ in 0..8 {
        super::tick(&fixture, &runtime, NOW).await;
        let execution = super::load_execution(&fixture).await;
        if execution
            .artifacts
            .review_cycles
            .last()
            .is_some_and(|cycle| cycle.outcomes.len() == 1)
        {
            break;
        }
    }

    let awaiting = super::load_execution(&fixture).await;
    assert_eq!(
        awaiting.transition.phase,
        Some(TaskBoardExecutionPhase::Review)
    );
    assert_eq!(
        awaiting.transition.execution_state,
        TaskBoardExecutionState::Pending
    );
    let first_cycle = awaiting
        .artifacts
        .review_cycles
        .last()
        .expect("first review outcome cycle");
    assert_eq!(first_cycle.outcomes.len(), 1);
    assert_eq!(first_cycle.outcomes[0].profile_id, "reviewer-amber");
    assert_eq!(
        first_cycle.decision,
        Some(TaskBoardReviewRoundDecision::AwaitingReviewers)
    );
    assert!(
        awaiting
            .attempts
            .iter()
            .all(|attempt| attempt.action_key != "evaluate")
    );

    super::drive_to_terminal_projection(&fixture, &runtime).await;

    let completed = super::load_execution(&fixture).await;
    assert_eq!(
        completed.transition.phase,
        Some(TaskBoardExecutionPhase::Terminal)
    );
    assert_eq!(
        completed.transition.execution_state,
        TaskBoardExecutionState::Completed
    );
    let cycle = completed
        .artifacts
        .review_cycles
        .last()
        .expect("completed review cycle");
    assert_eq!(cycle.outcomes.len(), 2);
    assert_eq!(cycle.outcomes[0].profile_id, "reviewer-amber");
    assert_eq!(cycle.outcomes[1].profile_id, "reviewer-indigo");
    assert_eq!(cycle.decision, Some(TaskBoardReviewRoundDecision::Approved));
    for action in [
        "review:reviewer-amber",
        "review:reviewer-indigo",
        "evaluate",
    ] {
        let attempt = completed
            .attempts
            .iter()
            .find(|attempt| attempt.action_key == action)
            .unwrap_or_else(|| panic!("missing completed attempt for {action}"));
        assert_eq!(attempt.state, TaskBoardAttemptState::Completed);
    }
    assert!(
        completed
            .attempts
            .iter()
            .all(|attempt| attempt.action_key != "publish")
    );
    assert_eq!(runtime.start_count(), 3);
    assert_eq!(runtime.publish_count(), 0);
    super::assert_terminal_projection(
        &fixture,
        TaskBoardStatus::Done,
        TaskBoardWorkflowStatus::Completed,
    )
    .await;
}
