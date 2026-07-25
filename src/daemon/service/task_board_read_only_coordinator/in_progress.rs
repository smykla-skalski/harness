use crate::daemon::db::AsyncDaemonDb;
use harness_kernel::errors::CliError;
use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionAttemptRecord, TaskBoardExecutionPhase,
    TaskBoardWorkflowExecutionRecord,
};

use super::super::task_board_read_only_runtime::TaskBoardReadOnlyRuntime;
use super::{lifecycle, reports};

/// Drives an attempt that is already under way. `Ok(true)` means this pass is
/// finished with the execution; `Ok(false)` means no in-progress attempt
/// claimed it and the caller continues down its own reconciliation path.
pub(super) async fn reconcile_active_attempt_in_progress<R>(
    db: &AsyncDaemonDb,
    runtime: &R,
    execution: &TaskBoardWorkflowExecutionRecord,
    active_attempt: Option<&TaskBoardExecutionAttemptRecord>,
    now: &str,
) -> Result<bool, CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    if let Some(attempt) = active_attempt.filter(|attempt| {
        matches!(
            execution.transition.phase,
            Some(
                TaskBoardExecutionPhase::Implementation
                    | TaskBoardExecutionPhase::Review
                    | TaskBoardExecutionPhase::Evaluate
            )
        ) && matches!(
            attempt.state,
            TaskBoardAttemptState::Starting | TaskBoardAttemptState::Running
        )
    }) && Box::pin(reports::reconcile_report_attempt(
        db, runtime, execution, attempt, false, now,
    ))
    .await?
    {
        return Ok(true);
    }
    if let Some(attempt) = active_attempt.filter(|attempt| {
        execution.transition.phase == Some(TaskBoardExecutionPhase::Publish)
            && attempt.state == TaskBoardAttemptState::Running
    }) {
        Box::pin(lifecycle::reconcile_lifecycle_attempt(
            db, runtime, execution, attempt, now,
        ))
        .await?;
        return Ok(true);
    }
    Ok(false)
}
