use sqlx::{Sqlite, Transaction};

use super::{
    cas_mismatch, ensure_terminal_transition_has_no_active_side_effect, load_execution_in_tx,
    validate_phase_change,
};
use crate::daemon::db::task_board::remote_assignment_stop_fence::{
    RemoteTargetStopPlan, remote_target_stop_plan_in_tx,
};
use crate::daemon::db::task_board::workflow_execution_revisions::live_execution_revision_mismatch_in_tx;
use crate::daemon::db::{CliError, db_error};
use crate::task_board::{
    TaskBoardWorkflowCasMismatch, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionCasOutcome, TaskBoardWorkflowExecutionRecord,
    validate_task_board_execution_update,
};

/// What a screened CAS leaves for its caller to do: an outcome that is already
/// final, or the exact record the write should persist.
pub(super) enum WorkflowExecutionCasScreen {
    Settled(TaskBoardWorkflowExecutionCasOutcome),
    Persist(TaskBoardWorkflowExecutionRecord),
}

/// Decide a workflow execution CAS without writing anything.
///
/// Every refusal returns rather than committing, so the caller owns the single
/// commit for both the refusals and the write.
pub(super) async fn screen_workflow_execution_cas_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected: &TaskBoardWorkflowExecutionCas,
    updated: &TaskBoardWorkflowExecutionRecord,
) -> Result<WorkflowExecutionCasScreen, CliError> {
    let Some(current) = load_execution_in_tx(transaction, &expected.execution_id).await? else {
        return Ok(stale(TaskBoardWorkflowCasMismatch::ExecutionId, None));
    };
    ensure_terminal_transition_has_no_active_side_effect(&current, updated)?;
    if let Some(mismatch) =
        cas_generation_mismatch_in_tx(transaction, expected, updated, &current).await?
    {
        return Ok(stale(mismatch, Some(current)));
    }
    resolve_cas_write_in_tx(transaction, current, updated).await
}

/// The reason this CAS lost its generation, if it lost it: the compared columns
/// first, then the live item revision a phase change is fenced against.
async fn cas_generation_mismatch_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected: &TaskBoardWorkflowExecutionCas,
    updated: &TaskBoardWorkflowExecutionRecord,
    current: &TaskBoardWorkflowExecutionRecord,
) -> Result<Option<TaskBoardWorkflowCasMismatch>, CliError> {
    if let Some(mismatch) = cas_mismatch(expected, current) {
        return Ok(Some(mismatch));
    }
    if current.transition.phase != updated.transition.phase {
        return live_execution_revision_mismatch_in_tx(transaction, current).await;
    }
    Ok(None)
}

/// Validate the accepted update and resolve what it actually writes: an
/// unchanged record settles here, and a remote stop plan may substitute the
/// cancel-intent parent for the caller's record.
async fn resolve_cas_write_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    current: TaskBoardWorkflowExecutionRecord,
    updated: &TaskBoardWorkflowExecutionRecord,
) -> Result<WorkflowExecutionCasScreen, CliError> {
    validate_task_board_execution_update(&current, updated)
        .map_err(|error| db_error(format!("validate workflow execution CAS: {error}")))?;
    validate_phase_change(&current, updated)?;
    if current == *updated {
        return Ok(WorkflowExecutionCasScreen::Settled(
            TaskBoardWorkflowExecutionCasOutcome::Unchanged(current),
        ));
    }
    match remote_target_stop_plan_in_tx(transaction, &current, updated).await? {
        RemoteTargetStopPlan::ApplyRequested => {
            Ok(WorkflowExecutionCasScreen::Persist(updated.clone()))
        }
        RemoteTargetStopPlan::PersistCancelIntent(parent) => {
            Ok(WorkflowExecutionCasScreen::Persist(parent))
        }
        RemoteTargetStopPlan::ReplayedCancelIntent(parent) => {
            Ok(WorkflowExecutionCasScreen::Settled(
                TaskBoardWorkflowExecutionCasOutcome::Unchanged(parent),
            ))
        }
    }
}

fn stale(
    mismatch: TaskBoardWorkflowCasMismatch,
    current: Option<TaskBoardWorkflowExecutionRecord>,
) -> WorkflowExecutionCasScreen {
    WorkflowExecutionCasScreen::Settled(TaskBoardWorkflowExecutionCasOutcome::Stale {
        mismatch,
        current,
    })
}
