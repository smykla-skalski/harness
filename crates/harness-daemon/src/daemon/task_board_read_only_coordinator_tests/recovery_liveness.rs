use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionPhase, TaskBoardExecutionState, TaskBoardWorkflowKind,
};

use super::fixture::{AttemptSeed, NOW, RETRY_AT, seed_additional_execution, seed_execution};
use super::runtime::{FakeReadOnlyRuntime, PlannedReport};
use crate::daemon::db::task_board::prelude::*;

#[tokio::test]
async fn recovery_cursor_advances_after_no_progress() {
    let first = Box::pin(seed_execution(
        "a-young-report",
        TaskBoardWorkflowKind::Review,
        TaskBoardExecutionState::Running,
        Some(AttemptSeed {
            state: TaskBoardAttemptState::Running,
            failure_class: None,
            available_at: Some(RETRY_AT),
            error: None,
            completed_at: None,
        }),
    ))
    .await;
    let (_, second_execution_id) = Box::pin(seed_additional_execution(
        &first.test.db,
        "b-start-report",
        TaskBoardWorkflowKind::Review,
        TaskBoardExecutionPhase::Review,
        TaskBoardExecutionState::Running,
        Some(starting_attempt()),
    ))
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
    let first = Box::pin(seed_execution(
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
    ))
    .await;
    Box::pin(seed_additional_execution(
        &first.test.db,
        "b-after-error",
        TaskBoardWorkflowKind::Review,
        TaskBoardExecutionPhase::Review,
        TaskBoardExecutionState::Running,
        Some(starting_attempt()),
    ))
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
