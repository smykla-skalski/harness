//! Terminal progress projection owned by the structured workflow engine.

use sqlx::{FromRow, Sqlite, Transaction, query, query_as};

use crate::daemon::db::{CliError, db_error};
use crate::task_board::TaskBoardWorkItemState;

#[derive(FromRow)]
struct WorkflowProgressState {
    state: String,
    summary: Option<String>,
    blocked_reason: Option<String>,
    report_sequence: i64,
}

pub(in crate::daemon::db::task_board) struct WorkflowTerminalProgressUpdate<'a> {
    pub board_item_id: &'a str,
    pub work_item_id: Option<&'a str>,
    pub execution_id: &'a str,
    pub state: TaskBoardWorkItemState,
    pub summary: Option<&'a str>,
    pub blocked_reason: Option<&'a str>,
    pub now: &'a str,
}

pub(in crate::daemon::db::task_board) async fn project_workflow_terminal_progress_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    update: &WorkflowTerminalProgressUpdate<'_>,
) -> Result<bool, CliError> {
    let Some(work_item_id) = update.work_item_id else {
        return Ok(false);
    };
    let Some(current) = query_as::<_, WorkflowProgressState>(
        "SELECT state, summary, blocked_reason, report_sequence
         FROM task_board_work_item_progress
         WHERE item_id = ?1 AND work_item_id = ?2 AND execution_id = ?3",
    )
    .bind(update.board_item_id)
    .bind(work_item_id)
    .bind(update.execution_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load workflow terminal progress: {error}")))?
    else {
        return Ok(false);
    };
    if current.state == update.state.as_str()
        && current.summary.as_deref() == update.summary
        && current.blocked_reason.as_deref() == update.blocked_reason
    {
        return Ok(false);
    }
    let sequence = current.report_sequence.checked_add(1).ok_or_else(|| {
        db_error(format!(
            "workflow work item '{work_item_id}' report sequence is exhausted"
        ))
    })?;
    query(
        "UPDATE task_board_work_item_progress
         SET state = ?4, summary = ?5, blocked_reason = ?6,
             report_sequence = ?7, updated_at = ?8, completed_at = ?8,
             worker_settled_at = ?8
         WHERE item_id = ?1 AND work_item_id = ?2 AND execution_id = ?3",
    )
    .bind(update.board_item_id)
    .bind(work_item_id)
    .bind(update.execution_id)
    .bind(update.state.as_str())
    .bind(update.summary)
    .bind(update.blocked_reason)
    .bind(sequence)
    .bind(update.now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("project workflow terminal progress: {error}")))?;
    Ok(true)
}
