//! Remote-execution's narrow cut of the fencing/settlement interface with
//! workflow-execution. This is deliberately not #1076's `RemoteExecutionQueries`,
//! which covers `service`/`task_board_remote_transport` callers and excludes
//! all five methods here: none of them cleared that trait's caller-count bar,
//! since the only production-facing wrapper around the fencing check is
//! `#[cfg(test)]`-gated and stop handling has no `service`-facing entry point
//! at all. Workflow-execution reaches these directly, so they get their own
//! interface here instead of sharing #1076's.
//!
//! Two kinds of capability live here:
//! - fencing: `active_remote_assignment_exists_in_tx`, `has_remote_io_authority`
//!   -- whether an active remote assignment currently holds authority over an
//!   execution, checked before workflow starts a local attempt or claims a
//!   side effect.
//! - stop handling: `remote_target_stop_plan_in_tx`,
//!   `remote_stop_requires_cancellation` -- one-directional, remote owns this
//!   end to end and workflow only ever calls in.
//!
//! `load_assignment_in_tx` is settlement's other half: workflow's own
//! settlement code reads the assignment record directly to decide what it is
//! settling, the mirror image of remote calling into workflow's
//! `settle_prepared_dispatch_in_tx`/`project_terminal_execution_in_tx` (see
//! `workflow_execution_fencing`).
//!
//! No method takes `&self`, for the same reason as the workflow-execution
//! side of this interface: every real call site already holds an open
//! transaction and nothing else from `AsyncDaemonDb`.

use async_trait::async_trait;
use sqlx::{Sqlite, Transaction};

use super::remote_assignment_stop_fence::RemoteTargetStopPlan;
use super::{remote_assignment_active_fence, remote_assignment_io_authority};
use super::{remote_assignment_model, remote_assignment_stop_fence};
use crate::daemon::db::{AsyncDaemonDb, CliError};
use crate::task_board::TaskBoardWorkflowExecutionRecord;
use remote_assignment_model::TaskBoardRemoteAssignmentRecord;

#[async_trait]
pub(in crate::daemon::db::task_board) trait RemoteAssignmentFencing:
    Send + Sync
{
    async fn active_remote_assignment_exists_in_tx(
        transaction: &mut Transaction<'_, Sqlite>,
        execution_id: &str,
    ) -> Result<bool, CliError>;

    fn has_remote_io_authority(execution: &TaskBoardWorkflowExecutionRecord) -> bool;

    async fn remote_target_stop_plan_in_tx(
        transaction: &mut Transaction<'_, Sqlite>,
        current: &TaskBoardWorkflowExecutionRecord,
        updated: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<RemoteTargetStopPlan, CliError>;

    fn remote_stop_requires_cancellation(
        current: &TaskBoardWorkflowExecutionRecord,
        updated: &TaskBoardWorkflowExecutionRecord,
    ) -> bool;

    async fn load_assignment_in_tx(
        transaction: &mut Transaction<'_, Sqlite>,
        assignment_id: &str,
    ) -> Result<Option<TaskBoardRemoteAssignmentRecord>, CliError>;
}

#[async_trait]
impl RemoteAssignmentFencing for AsyncDaemonDb {
    async fn active_remote_assignment_exists_in_tx(
        transaction: &mut Transaction<'_, Sqlite>,
        execution_id: &str,
    ) -> Result<bool, CliError> {
        remote_assignment_active_fence::active_remote_assignment_exists_in_tx(
            transaction,
            execution_id,
        )
        .await
    }

    fn has_remote_io_authority(execution: &TaskBoardWorkflowExecutionRecord) -> bool {
        remote_assignment_io_authority::has_remote_io_authority(execution)
    }

    async fn remote_target_stop_plan_in_tx(
        transaction: &mut Transaction<'_, Sqlite>,
        current: &TaskBoardWorkflowExecutionRecord,
        updated: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<RemoteTargetStopPlan, CliError> {
        remote_assignment_stop_fence::remote_target_stop_plan_in_tx(transaction, current, updated)
            .await
    }

    fn remote_stop_requires_cancellation(
        current: &TaskBoardWorkflowExecutionRecord,
        updated: &TaskBoardWorkflowExecutionRecord,
    ) -> bool {
        remote_assignment_stop_fence::remote_stop_requires_cancellation(current, updated)
    }

    async fn load_assignment_in_tx(
        transaction: &mut Transaction<'_, Sqlite>,
        assignment_id: &str,
    ) -> Result<Option<TaskBoardRemoteAssignmentRecord>, CliError> {
        remote_assignment_model::load_assignment_in_tx(transaction, assignment_id).await
    }
}
