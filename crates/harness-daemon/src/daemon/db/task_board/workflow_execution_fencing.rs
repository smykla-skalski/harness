//! Workflow-execution's side of the fencing/settlement interface with the
//! remote-execution cluster (`remote_assignment_*`). Every method here is an
//! existing `pub(super)`/`pub(in ..)` helper that already lives in one of
//! workflow-execution's own files; this trait gives remote-execution one
//! named, documented surface to call through instead of reaching into each
//! helper's home file directly, so a later crate split only has to move this
//! file and its call sites, not renegotiate which functions cross the
//! boundary.
//!
//! Two kinds of capability live here:
//! - fencing: `cas_mismatch`, `live_execution_revision_mismatch_in_tx`,
//!   `attempt_cas_matches`, `validate_attempt_phase` -- what remote checks
//!   before accepting an offer or adopting a result.
//! - settlement: `settle_prepared_dispatch_in_tx`,
//!   `project_terminal_execution_in_tx` -- what remote calls to finish
//!   projecting a workflow's terminal state from inside its own settlement
//!   code.
//!
//! `revalidate_first_start_admission_in_tx` is neither: it is the admission
//! bridge, workflow re-running its own first-start admission decision on
//! remote's behalf at the one call site where fencing, workflow's admission
//! bookkeeping, and the separate dispatch-admission cluster all meet. It sits
//! on this trait because remote is the caller, not because it behaves like a
//! fencing check.
//!
//! No method takes `&self`: every real call site already holds an open
//! transaction and nothing else from `AsyncDaemonDb`, so `Self` here is a
//! namespace rather than an instance, called through
//! `AsyncDaemonDb::method(..)`.

use sqlx::{Sqlite, Transaction};

use super::{
    workflow_execution_attempts, workflow_execution_revisions, workflow_executions,
    workflow_first_start_admission, workflow_terminal,
};
use crate::daemon::db::{AsyncDaemonDb, CliError};
use crate::task_board::{
    TaskBoardExecutionAttemptCas, TaskBoardExecutionAttemptRecord, TaskBoardWorkflowCasMismatch,
    TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord,
};
use workflow_first_start_admission::TaskBoardFirstStartAdmission;
use workflow_terminal::{PreparedDispatchSettlement, TaskBoardWorkflowTerminalProjection};

pub(in crate::daemon::db::task_board) trait WorkflowExecutionFencing:
    Send + Sync
{
    fn cas_mismatch(
        expected: &TaskBoardWorkflowExecutionCas,
        current: &TaskBoardWorkflowExecutionRecord,
    ) -> Option<TaskBoardWorkflowCasMismatch>;

    async fn live_execution_revision_mismatch_in_tx(
        transaction: &mut Transaction<'_, Sqlite>,
        execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<Option<TaskBoardWorkflowCasMismatch>, CliError>;

    fn attempt_cas_matches(
        expected: &TaskBoardExecutionAttemptCas,
        current: &TaskBoardExecutionAttemptRecord,
    ) -> bool;

    fn validate_attempt_phase(
        parent: &TaskBoardWorkflowExecutionRecord,
        attempt: &TaskBoardExecutionAttemptRecord,
    ) -> Result<(), CliError>;

    async fn settle_prepared_dispatch_in_tx(
        transaction: &mut Transaction<'_, Sqlite>,
        execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<PreparedDispatchSettlement, CliError>;

    async fn project_terminal_execution_in_tx(
        transaction: &mut Transaction<'_, Sqlite>,
        execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<TaskBoardWorkflowTerminalProjection, CliError>;

    /// The admission bridge -- see the module docs above.
    async fn revalidate_first_start_admission_in_tx(
        transaction: &mut Transaction<'_, Sqlite>,
        parent: &TaskBoardWorkflowExecutionRecord,
        current_attempt: &TaskBoardExecutionAttemptRecord,
        now: &str,
    ) -> Result<TaskBoardFirstStartAdmission, CliError>;
}

impl WorkflowExecutionFencing for AsyncDaemonDb {
    fn cas_mismatch(
        expected: &TaskBoardWorkflowExecutionCas,
        current: &TaskBoardWorkflowExecutionRecord,
    ) -> Option<TaskBoardWorkflowCasMismatch> {
        workflow_executions::cas_mismatch(expected, current)
    }

    async fn live_execution_revision_mismatch_in_tx(
        transaction: &mut Transaction<'_, Sqlite>,
        execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<Option<TaskBoardWorkflowCasMismatch>, CliError> {
        workflow_execution_revisions::live_execution_revision_mismatch_in_tx(transaction, execution)
            .await
    }

    fn attempt_cas_matches(
        expected: &TaskBoardExecutionAttemptCas,
        current: &TaskBoardExecutionAttemptRecord,
    ) -> bool {
        workflow_execution_attempts::attempt_cas_matches(expected, current)
    }

    fn validate_attempt_phase(
        parent: &TaskBoardWorkflowExecutionRecord,
        attempt: &TaskBoardExecutionAttemptRecord,
    ) -> Result<(), CliError> {
        workflow_execution_attempts::validate_attempt_phase(parent, attempt)
    }

    async fn settle_prepared_dispatch_in_tx(
        transaction: &mut Transaction<'_, Sqlite>,
        execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<PreparedDispatchSettlement, CliError> {
        workflow_terminal::settle_prepared_dispatch_in_tx(transaction, execution).await
    }

    async fn project_terminal_execution_in_tx(
        transaction: &mut Transaction<'_, Sqlite>,
        execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<TaskBoardWorkflowTerminalProjection, CliError> {
        workflow_terminal::project_terminal_execution_in_tx(transaction, execution).await
    }

    async fn revalidate_first_start_admission_in_tx(
        transaction: &mut Transaction<'_, Sqlite>,
        parent: &TaskBoardWorkflowExecutionRecord,
        current_attempt: &TaskBoardExecutionAttemptRecord,
        now: &str,
    ) -> Result<TaskBoardFirstStartAdmission, CliError> {
        workflow_first_start_admission::revalidate_first_start_admission_in_tx(
            transaction,
            parent,
            current_attempt,
            now,
        )
        .await
    }
}
