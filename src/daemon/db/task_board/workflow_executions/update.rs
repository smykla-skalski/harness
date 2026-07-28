use sqlx::{Sqlite, Transaction, query};

use super::super::workflow_execution_rows::{execution_json, label, phase_label};
use crate::daemon::db::{CliError, db_error};
use crate::task_board::{TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord};

/// The bound values that need a fallible conversion or lookup, computed once
/// so the query builder itself binds plain values.
struct ExecutionUpdateBindings {
    phase: String,
    state: String,
    fencing_epoch: i64,
    expected_phase: String,
    expected_state: String,
    expected_configuration_revision: i64,
}

fn execution_update_bindings(
    expected: &TaskBoardWorkflowExecutionCas,
    record: &TaskBoardWorkflowExecutionRecord,
) -> Result<ExecutionUpdateBindings, CliError> {
    Ok(ExecutionUpdateBindings {
        phase: phase_label(record.transition.phase)?,
        state: label(record.transition.execution_state, "execution state")?,
        fencing_epoch: i64::try_from(record.ownership.fencing_epoch)
            .map_err(|_| db_error("workflow fencing epoch is out of range"))?,
        expected_phase: phase_label(expected.phase)?,
        expected_state: label(expected.state, "execution state")?,
        expected_configuration_revision: i64::try_from(expected.revisions.configuration_revision)
            .map_err(|_| {
            db_error("workflow configuration revision is out of range")
        })?,
    })
}

pub(in super::super) async fn update_execution_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected: &TaskBoardWorkflowExecutionCas,
    record: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), CliError> {
    let (_, _, artifacts, ownership) = execution_json(record)?;
    let bindings = execution_update_bindings(expected, record)?;
    let rows = query(
        "UPDATE task_board_workflow_executions SET phase = ?1, state = ?2, host_id = ?3,
         fencing_epoch = ?4, available_at = ?5, blocked_reason = ?6, diagnostics_json = ?7,
         resource_ownership_json = ?8, updated_at = ?9, completed_at = ?10
         WHERE execution_id = ?11 AND phase = ?12 AND state = ?13 AND item_revision = ?14
           AND configuration_revision = ?15 AND provider_revision IS ?16",
    )
    .bind(bindings.phase)
    .bind(bindings.state)
    .bind(&record.ownership.host_id)
    .bind(bindings.fencing_epoch)
    .bind(&record.available_at)
    .bind(&record.blocked_reason)
    .bind(artifacts)
    .bind(ownership)
    .bind(&record.updated_at)
    .bind(&record.completed_at)
    .bind(&expected.execution_id)
    .bind(bindings.expected_phase)
    .bind(bindings.expected_state)
    .bind(expected.revisions.item_revision)
    .bind(bindings.expected_configuration_revision)
    .bind(&expected.revisions.provider_revision)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("update workflow execution CAS: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(())
    } else {
        Err(db_error("workflow execution CAS lost atomic update"))
    }
}
