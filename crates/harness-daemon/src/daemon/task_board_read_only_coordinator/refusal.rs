use crate::task_board::{
    TaskBoardDependencyRecoveryDecision, TaskBoardTerminalOutcomeKind,
    TaskBoardWorkflowExecutionRecord, classify_task_board_dependency_workflow_recovery,
};
use harness_kernel::errors::CliError;

use super::{attempts::require_human, requests};
use crate::daemon::db_handle::AsyncDaemonDbHandle;

/// Refuses an execution whose immutable inputs cannot be used at all.
///
/// `Ok(true)` means the execution was refused and needs no further reconciling.
pub(super) async fn refuse_unusable_execution(
    db: &AsyncDaemonDbHandle,
    execution: &TaskBoardWorkflowExecutionRecord,
    now: &str,
) -> Result<bool, CliError> {
    if let Err(error) = requests::run_context(execution) {
        require_human(
            db,
            &execution.execution_id,
            "read_only_run_context_missing",
            &error.to_string(),
            TaskBoardTerminalOutcomeKind::HumanRequired,
            now,
        )
        .await?;
        return Ok(true);
    }
    if execution.snapshot.workflow_kind.is_write()
        && let Err(error) = requests::write_task_id(execution)
    {
        require_human(
            db,
            &execution.execution_id,
            "write_task_id_missing",
            &error.to_string(),
            TaskBoardTerminalOutcomeKind::HumanRequired,
            now,
        )
        .await?;
        return Ok(true);
    }
    Ok(false)
}

pub(crate) async fn recovery_decision_or_refuse(
    db: &AsyncDaemonDbHandle,
    execution: &TaskBoardWorkflowExecutionRecord,
    now: &str,
) -> Result<Option<TaskBoardDependencyRecoveryDecision>, CliError> {
    let error = match classify_task_board_dependency_workflow_recovery(execution) {
        Ok(decision) => return Ok(Some(decision)),
        Err(error) => error,
    };
    require_human(
        db,
        &execution.execution_id,
        "dependency_recovery_invalid",
        &error.to_string(),
        TaskBoardTerminalOutcomeKind::HumanRequired,
        now,
    )
    .await?;
    Ok(None)
}
