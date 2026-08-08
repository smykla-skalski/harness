//! Row shapes and reads for the durable work-item progress record.

use sqlx::{FromRow, Sqlite, Transaction, query_as};

use crate::daemon::db::{CliError, db_error};
use crate::task_board::{
    TaskBoardWorkItemCheckpoint, TaskBoardWorkItemProgress, TaskBoardWorkItemState,
};

#[derive(FromRow)]
pub(super) struct WorkItemProgressRow {
    pub(super) work_item_id: String,
    pub(super) item_id: String,
    pub(super) execution_id: Option<String>,
    pub(super) state: String,
    pub(super) progress_percent: Option<i64>,
    pub(super) summary: Option<String>,
    pub(super) blocked_reason: Option<String>,
    pub(super) attempt_id: Option<String>,
    pub(super) item_revision: Option<i64>,
    pub(super) report_sequence: i64,
    pub(super) created_at: String,
    pub(super) updated_at: String,
    pub(super) completed_at: Option<String>,
    pub(super) worker_settled_at: Option<String>,
}

#[derive(FromRow)]
struct WorkItemCheckpointRow {
    checkpoint_id: String,
    sequence: i64,
    actor: String,
    summary: String,
    progress_percent: Option<i64>,
    attempt_id: Option<String>,
    recorded_at: String,
}

const SELECT_PROGRESS_SQL: &str = "SELECT work_item_id, item_id, execution_id, state,
        progress_percent, summary, blocked_reason, attempt_id, item_revision,
        report_sequence, created_at, updated_at, completed_at, worker_settled_at
     FROM task_board_work_item_progress
     WHERE work_item_id = ?1";

const SELECT_CHECKPOINTS_SQL: &str = "SELECT checkpoint_id, sequence, actor, summary,
        progress_percent, attempt_id, recorded_at
     FROM task_board_work_item_checkpoints
     WHERE work_item_id = ?1
     ORDER BY sequence";

/// Loads one progress record and its checkpoint log inside a transaction.
pub(super) async fn load_progress_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    work_item_id: &str,
) -> Result<Option<(TaskBoardWorkItemProgress, Option<String>)>, CliError> {
    let Some(row) = query_as::<_, WorkItemProgressRow>(SELECT_PROGRESS_SQL)
        .bind(work_item_id)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load work item progress '{work_item_id}': {error}")))?
    else {
        return Ok(None);
    };
    let checkpoints = query_as::<_, WorkItemCheckpointRow>(SELECT_CHECKPOINTS_SQL)
        .bind(work_item_id)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| {
            db_error(format!(
                "load work item checkpoints '{work_item_id}': {error}"
            ))
        })?;
    let worker_settled_at = row.worker_settled_at.clone();
    Ok(Some((
        progress_from_rows(row, checkpoints),
        worker_settled_at,
    )))
}

fn progress_from_rows(
    row: WorkItemProgressRow,
    checkpoints: Vec<WorkItemCheckpointRow>,
) -> TaskBoardWorkItemProgress {
    TaskBoardWorkItemProgress {
        board_item_id: row.item_id,
        work_item_id: row.work_item_id,
        execution_id: row.execution_id,
        // A row whose spelling the current binary does not know is treated as
        // pending rather than refused: the record is advisory progress, and a
        // downgrade must not make the whole item unreadable.
        state: TaskBoardWorkItemState::from_str_opt(&row.state).unwrap_or_default(),
        progress_percent: row.progress_percent.and_then(clamped_percent),
        summary: row.summary,
        blocked_reason: row.blocked_reason,
        attempt_id: row.attempt_id,
        item_revision: row
            .item_revision
            .and_then(|revision| revision.try_into().ok()),
        report_sequence: row.report_sequence.try_into().unwrap_or_default(),
        checkpoints: checkpoints.into_iter().map(checkpoint_from_row).collect(),
        created_at: row.created_at,
        updated_at: row.updated_at,
        completed_at: row.completed_at,
    }
}

fn checkpoint_from_row(row: WorkItemCheckpointRow) -> TaskBoardWorkItemCheckpoint {
    TaskBoardWorkItemCheckpoint {
        checkpoint_id: row.checkpoint_id,
        sequence: row.sequence.try_into().unwrap_or_default(),
        actor: row.actor,
        summary: row.summary,
        progress_percent: row.progress_percent.and_then(clamped_percent),
        attempt_id: row.attempt_id,
        recorded_at: row.recorded_at,
    }
}

fn clamped_percent(value: i64) -> Option<u8> {
    u8::try_from(value.clamp(0, 100)).ok()
}
