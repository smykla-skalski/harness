use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionAttemptRecord, TaskBoardExecutionPhase,
    TaskBoardWorkflowExecutionRecord,
};
use harness_kernel::errors::CliError;

use super::super::task_board_read_only_runtime::TaskBoardReadOnlyRuntime;
use super::{dependency_triage, lifecycle, reports};
use crate::daemon::db_handle::AsyncDaemonDbHandle;

/// Drives an attempt that is already under way. `Ok(true)` means this pass is
/// finished with the execution; `Ok(false)` means no in-progress attempt
/// claimed it and the caller continues down its own reconciliation path.
pub(super) async fn reconcile_active_attempt_in_progress<R>(
    db: &AsyncDaemonDbHandle,
    runtime: &R,
    execution: &TaskBoardWorkflowExecutionRecord,
    active_attempt: Option<&TaskBoardExecutionAttemptRecord>,
    now: &str,
) -> Result<bool, CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    if let Some(attempt) = active_attempt.filter(|attempt| {
        attempt.action_key == dependency_triage::DEPENDENCY_TRIAGE_ACTION
            && matches!(
                attempt.state,
                TaskBoardAttemptState::Starting | TaskBoardAttemptState::Running
            )
    }) {
        let allow_start = attempt.state == TaskBoardAttemptState::Starting;
        dependency_triage::reconcile(db, runtime, execution, attempt, allow_start, now).await?;
        return Ok(true);
    }
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
