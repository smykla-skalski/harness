use super::tests::{NOW, seeded_terminal_execution};
use super::*;
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::db::task_board::work_item_progress_queries::WorkItemProgressQueries;
use crate::daemon::db::task_board::workflow_execution_queries::WorkflowExecutionQueries;
use crate::task_board::{
    TaskBoardExecutionState, TaskBoardTerminalOutcome, TaskBoardTerminalOutcomeKind,
    TaskBoardWorkItemState, TaskBoardWorkflowExecutionCas,
};

#[tokio::test]
async fn every_workflow_terminal_state_settles_its_monitor_progress() {
    for (state, progress_state) in [
        (
            TaskBoardExecutionState::Completed,
            TaskBoardWorkItemState::Done,
        ),
        (
            TaskBoardExecutionState::Failed,
            TaskBoardWorkItemState::Blocked,
        ),
        (
            TaskBoardExecutionState::Cancelled,
            TaskBoardWorkItemState::Blocked,
        ),
        (
            TaskBoardExecutionState::HumanRequired,
            TaskBoardWorkItemState::Blocked,
        ),
    ] {
        let (db, execution_id) = Box::pin(seeded_terminal_execution(true)).await;
        set_terminal_execution_state(&db, &execution_id, state).await;

        project_task_board_read_only_workflow_terminal(&db, &execution_id)
            .await
            .expect("project terminal execution");

        let progress = db
            .task_board_work_item_progress("terminal-item")
            .await
            .expect("read workflow progress")
            .expect("progress exists");
        assert_eq!(progress.state, progress_state, "{state:?}");
        assert!(progress.completed_at.is_some(), "{state:?}");
        let worker_settled_at: Option<String> = sqlx::query_scalar(
            "SELECT worker_settled_at FROM task_board_work_item_progress
             WHERE item_id = 'terminal-item' AND work_item_id = 'work-terminal'",
        )
        .fetch_one(db.pool())
        .await
        .expect("read workflow worker settlement");
        assert!(worker_settled_at.is_some(), "{state:?}");
    }
}

async fn set_terminal_execution_state(
    db: &AsyncDaemonDb,
    execution_id: &str,
    state: TaskBoardExecutionState,
) {
    let current = db
        .task_board_workflow_execution(execution_id)
        .await
        .expect("load execution")
        .expect("execution exists");
    let mut updated = current.clone();
    updated.transition.execution_state = state;
    updated.artifacts.terminal_outcome = Some(TaskBoardTerminalOutcome {
        kind: match state {
            TaskBoardExecutionState::Completed => TaskBoardTerminalOutcomeKind::Succeeded,
            TaskBoardExecutionState::Failed => TaskBoardTerminalOutcomeKind::Failed,
            TaskBoardExecutionState::Cancelled => TaskBoardTerminalOutcomeKind::Cancelled,
            TaskBoardExecutionState::HumanRequired => TaskBoardTerminalOutcomeKind::HumanRequired,
            _ => unreachable!("test uses terminal states only"),
        },
        summary: format!("terminal {state:?}"),
        recorded_at: NOW.into(),
    });
    updated.blocked_reason =
        (state != TaskBoardExecutionState::Completed).then(|| format!("terminal {state:?}"));
    db.compare_and_set_task_board_workflow_execution(
        &TaskBoardWorkflowExecutionCas::from(&current),
        &updated,
    )
    .await
    .expect("update terminal execution");
}
