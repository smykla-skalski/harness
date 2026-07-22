mod fixture;
mod lifecycle_recovery;
mod prepared_report_fixture;
mod publish_claim_races;
mod quorum;
mod recovery;
mod recovery_liveness;
mod report_claim_recovery;
mod runtime;
mod write_workflow;

use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionPhase, TaskBoardExecutionState, TaskBoardStatus,
    TaskBoardWorkflowKind, TaskBoardWorkflowStatus,
};

use super::task_board_read_only_coordinator::reconcile_task_board_read_only_workflows_with_runtime;
use fixture::{FROZEN_HEAD, Fixture, NOW, admission_state, seed_execution};
use runtime::{FakeReadOnlyRuntime, PlannedReport};

#[tokio::test]
async fn local_review_completes_evaluation_cleanup_and_atomic_projection() {
    let fixture = seed_execution(
        "local-lifecycle",
        TaskBoardWorkflowKind::Review,
        TaskBoardExecutionState::Pending,
        None,
    )
    .await;
    let runtime = FakeReadOnlyRuntime::new([
        PlannedReport::passing_review(),
        PlannedReport::passing_evaluation(),
    ]);

    drive_to_terminal_projection(&fixture, &runtime).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution.transition.phase,
        Some(TaskBoardExecutionPhase::Terminal)
    );
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::Completed
    );
    assert!(
        execution
            .artifacts
            .review_cycles
            .iter()
            .any(|cycle| { cycle.head_revision == FROZEN_HEAD && !cycle.outcomes.is_empty() })
    );
    assert_attempts_completed(
        &execution,
        &["cleanup", "evaluate", "review:reviewer-amber"],
    );
    assert_eq!(runtime.start_count(), 2);
    assert_eq!(runtime.publish_count(), 0);
    assert_terminal_projection(
        &fixture,
        TaskBoardStatus::Done,
        TaskBoardWorkflowStatus::Completed,
    )
    .await;
}

#[tokio::test]
async fn pr_review_completes_exact_head_publish_and_cleanup() {
    let fixture = seed_execution(
        "pr-lifecycle",
        TaskBoardWorkflowKind::PrReview,
        TaskBoardExecutionState::Pending,
        None,
    )
    .await;
    let runtime = FakeReadOnlyRuntime::new([PlannedReport::passing_review()]);

    drive_to_terminal_projection(&fixture, &runtime).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution.transition.phase,
        Some(TaskBoardExecutionPhase::Terminal)
    );
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::Completed
    );
    assert_attempts_completed(&execution, &["cleanup", "publish", "review:reviewer-amber"]);
    assert_eq!(runtime.start_count(), 1);
    assert_eq!(runtime.publish_count(), 1);
    assert_terminal_projection(
        &fixture,
        TaskBoardStatus::Done,
        TaskBoardWorkflowStatus::Completed,
    )
    .await;
}

#[tokio::test]
async fn stale_pr_head_before_publish_is_fenced_without_publish_claim() {
    let fixture = seed_execution(
        "pr-stale",
        TaskBoardWorkflowKind::PrReview,
        TaskBoardExecutionState::Pending,
        None,
    )
    .await;
    let runtime = FakeReadOnlyRuntime::new([PlannedReport::passing_review()]);
    drive_to_phase(&fixture, &runtime, TaskBoardExecutionPhase::Publish).await;
    runtime.set_head("head-replaced");

    tick(&fixture, &runtime, NOW).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(
        execution.transition.exact_head_revision.as_deref(),
        Some(FROZEN_HEAD)
    );
    assert_eq!(
        execution.blocked_reason.as_deref(),
        Some("exact_head_changed_before_publish")
    );
    assert!(
        execution
            .attempts
            .iter()
            .all(|attempt| attempt.action_key != "publish")
    );
    assert_eq!(runtime.publish_count(), 0);
    tick(&fixture, &runtime, NOW).await;
    assert_terminal_projection(
        &fixture,
        TaskBoardStatus::HumanRequired,
        TaskBoardWorkflowStatus::Paused,
    )
    .await;
}

async fn tick(fixture: &Fixture, runtime: &FakeReadOnlyRuntime, now: &str) {
    let report =
        reconcile_task_board_read_only_workflows_with_runtime(&fixture.test.db, runtime, now, 8)
            .await
            .expect("reconcile read-only workflow");
    assert!(report.failures.is_empty(), "{:?}", report.failures);
}

async fn drive_to_phase(
    fixture: &Fixture,
    runtime: &FakeReadOnlyRuntime,
    phase: TaskBoardExecutionPhase,
) {
    for _ in 0..12 {
        tick(fixture, runtime, NOW).await;
        if load_execution(fixture).await.transition.phase == Some(phase) {
            return;
        }
    }
    panic!("workflow did not reach {phase:?}");
}

async fn drive_to_terminal_projection(fixture: &Fixture, runtime: &FakeReadOnlyRuntime) {
    for _ in 0..20 {
        tick(fixture, runtime, NOW).await;
        let item = fixture
            .test
            .db
            .task_board_item_snapshot(&fixture.item_id)
            .await
            .expect("load item");
        if item.item.status == TaskBoardStatus::Done {
            return;
        }
    }
    panic!("workflow did not project terminal state");
}

async fn load_execution(fixture: &Fixture) -> crate::task_board::TaskBoardWorkflowExecutionRecord {
    fixture
        .test
        .db
        .task_board_workflow_execution(&fixture.execution_id)
        .await
        .expect("load execution")
        .expect("execution exists")
}

fn assert_attempts_completed(
    execution: &crate::task_board::TaskBoardWorkflowExecutionRecord,
    expected_actions: &[&str],
) {
    let actions = execution
        .attempts
        .iter()
        .map(|attempt| {
            assert_eq!(attempt.state, TaskBoardAttemptState::Completed);
            attempt.action_key.as_str()
        })
        .collect::<Vec<_>>();
    assert_eq!(actions, expected_actions);
}

async fn assert_terminal_projection(
    fixture: &Fixture,
    status: TaskBoardStatus,
    workflow_status: TaskBoardWorkflowStatus,
) {
    let item = fixture
        .test
        .db
        .task_board_item_snapshot(&fixture.item_id)
        .await
        .expect("load terminal item");
    assert_eq!(item.item.status, status);
    assert_eq!(item.item.workflow.status, workflow_status);
    assert!(item.item.workflow.current_step_id.is_none());
    assert_eq!(admission_state(fixture).await, "released");
}
