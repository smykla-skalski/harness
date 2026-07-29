use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionAttemptCas, TaskBoardExecutionPhase,
    TaskBoardExecutionState, TaskBoardWorkflowKind,
};

use super::fixture::{
    AttemptSeed, NOW, RETRY_AT, seed_additional_execution, seed_execution, seed_publish_attempt,
};
use super::runtime::{FakeReadOnlyRuntime, PlannedReport};

#[tokio::test]
async fn recovery_cursor_advances_after_no_progress() {
    let first = seed_publish_attempt(
        "a-young-publish",
        TaskBoardExecutionState::Running,
        TaskBoardAttemptState::Running,
    )
    .await;
    set_attempt_deadline(&first.test.db, &first.execution_id, RETRY_AT).await;
    let (_, second_execution_id) = seed_additional_execution(
        &first.test.db,
        "b-start-report",
        TaskBoardWorkflowKind::Review,
        TaskBoardExecutionPhase::Review,
        TaskBoardExecutionState::Running,
        Some(starting_attempt()),
    )
    .await;
    let runtime = FakeReadOnlyRuntime::new([PlannedReport::passing_review()]);
    let first_tick = super::super::task_board_read_only_coordinator::
        reconcile_task_board_read_only_workflows_with_runtime(&first.test.db, &runtime, NOW, 1)
        .await
        .expect("reconcile first recovery candidate");
    assert_eq!(first_tick.processed, 1);
    assert!(first_tick.failures.is_empty());
    assert_eq!(runtime.start_count(), 0);

    let second_tick = super::super::task_board_read_only_coordinator::
        reconcile_task_board_read_only_workflows_with_runtime(&first.test.db, &runtime, NOW, 1)
        .await
        .expect("reconcile next recovery candidate");
    assert_eq!(second_tick.processed, 1);
    assert!(second_tick.failures.is_empty());
    assert_eq!(runtime.start_count(), 1);
    let second = first
        .test
        .db
        .task_board_workflow_execution(&second_execution_id)
        .await
        .expect("load second execution")
        .expect("second execution");
    assert_ne!(second.attempts[0].state, TaskBoardAttemptState::Starting);
}

#[tokio::test]
async fn recovery_cursor_advances_after_candidate_error() {
    let first = seed_execution(
        "a-load-error",
        TaskBoardWorkflowKind::Review,
        TaskBoardExecutionState::Running,
        Some(AttemptSeed {
            state: TaskBoardAttemptState::Running,
            failure_class: None,
            available_at: None,
            error: None,
            completed_at: None,
        }),
    )
    .await;
    seed_additional_execution(
        &first.test.db,
        "b-after-error",
        TaskBoardWorkflowKind::Review,
        TaskBoardExecutionPhase::Review,
        TaskBoardExecutionState::Running,
        Some(starting_attempt()),
    )
    .await;
    let runtime = FakeReadOnlyRuntime::new([PlannedReport::passing_review()]);
    runtime.set_load_error("transient controller reconciliation failure");
    let first_tick = super::super::task_board_read_only_coordinator::
        reconcile_task_board_read_only_workflows_with_runtime(&first.test.db, &runtime, NOW, 1)
        .await
        .expect("record recoverable candidate error");
    assert_eq!(first_tick.processed, 1);
    assert_eq!(first_tick.failures.len(), 1);
    assert_eq!(runtime.start_count(), 0);

    let second_tick = super::super::task_board_read_only_coordinator::
        reconcile_task_board_read_only_workflows_with_runtime(&first.test.db, &runtime, NOW, 1)
        .await
        .expect("advance after recoverable candidate error");
    assert_eq!(second_tick.processed, 1);
    assert!(second_tick.failures.is_empty());
    assert_eq!(runtime.start_count(), 1);
}

const fn starting_attempt() -> AttemptSeed {
    AttemptSeed {
        state: TaskBoardAttemptState::Starting,
        failure_class: None,
        available_at: None,
        error: None,
        completed_at: None,
    }
}

async fn set_attempt_deadline(
    db: &crate::daemon::db::AsyncDaemonDb,
    execution_id: &str,
    available_at: &str,
) {
    let execution = db
        .task_board_workflow_execution(execution_id)
        .await
        .expect("load publish execution")
        .expect("publish execution");
    let current = execution.attempts[0].clone();
    let mut updated = current.clone();
    updated.available_at = Some(available_at.into());
    super::super::task_board_workflow_execution::record_workflow_execution_attempt(
        db,
        &TaskBoardExecutionAttemptCas::from(&current),
        &updated,
    )
    .await
    .expect("set publish verification deadline");
}
