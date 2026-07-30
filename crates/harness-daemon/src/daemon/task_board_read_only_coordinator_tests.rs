mod driver;
mod fixture;
mod openrouter;
mod prepared_report_fixture;
mod quorum;
mod recovery;
mod recovery_liveness;
mod report_claim_recovery;
mod report_prompt_recovery;
mod runtime;
mod write_workflow;

use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionPhase, TaskBoardExecutionState, TaskBoardStatus,
    TaskBoardWorkflowKind, TaskBoardWorkflowStatus,
};

use driver::HeadlessWorkflowDriver;
use fixture::{FROZEN_HEAD, Fixture, NOW, admission_state, seed_execution};
use runtime::{FakeReadOnlyRuntime, PlannedReport};

#[tokio::test]
async fn local_review_completes_evaluation_cleanup_and_atomic_projection() {
    let fixture = Box::pin(seed_execution(
        "local-lifecycle",
        TaskBoardWorkflowKind::Review,
        TaskBoardExecutionState::Pending,
        None,
    ))
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
async fn pr_review_completes_exact_head_report_and_cleanup_without_publication() {
    let fixture = Box::pin(seed_execution(
        "pr-lifecycle",
        TaskBoardWorkflowKind::PR_REVIEW,
        TaskBoardExecutionState::Pending,
        None,
    ))
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
    assert_attempts_completed(&execution, &["cleanup", "review:reviewer-amber"]);
    assert_eq!(runtime.start_count(), 1);
    assert_eq!(runtime.publish_count(), 0);
    assert_terminal_projection(
        &fixture,
        TaskBoardStatus::Done,
        TaskBoardWorkflowStatus::Completed,
    )
    .await;
}

async fn tick(fixture: &Fixture, runtime: &FakeReadOnlyRuntime, now: &str) {
    HeadlessWorkflowDriver::new(fixture, runtime)
        .tick(now)
        .await;
}

async fn drive_to_terminal_projection(fixture: &Fixture, runtime: &FakeReadOnlyRuntime) {
    HeadlessWorkflowDriver::new(fixture, runtime)
        .drive_to_terminal_projection(NOW, 20)
        .await;
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
