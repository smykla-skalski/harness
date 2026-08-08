//! Durable worker progress for dispatched work items.
//!
//! One transaction per report: load the record, run the pure transition, and
//! persist the record, its checkpoint, and the board item's projected lane
//! together. Splitting those would let the board show a lane the record does
//! not back, which is exactly the drift owning the state was meant to end.

use sqlx::{Sqlite, Transaction, query, query_as};
use uuid::Uuid;

use super::ITEMS_CHANGE_SCOPE;
use super::item_tx_ext::TaskBoardItemTxExt;
use super::items::bump_change_in_tx;
use super::work_item_progress_rows::load_progress_in_tx;
use crate::daemon::db::prelude::*;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::task_board::{
    AgentMode, TaskBoardItem, TaskBoardWorkItemProgress, TaskBoardWorkItemReport,
    TaskBoardWorkItemReportOutcome, TaskBoardWorkItemReportRejection, TaskBoardWorkItemState,
    apply_work_item_report, codex_worker_id, terminal_worker_id,
};
use harness_kernel::errors::CliErrorKind;

/// One worker report as the caller states it, before the daemon stamps the
/// facts a worker must not be trusted to supply.
#[derive(Debug, Clone)]
pub(crate) struct TaskBoardWorkItemReportRequest {
    pub(crate) board_item_id: String,
    pub(crate) actor: String,
    pub(crate) state: Option<TaskBoardWorkItemState>,
    pub(crate) summary: Option<String>,
    pub(crate) progress_percent: Option<u8>,
    pub(crate) blocked_reason: Option<String>,
    pub(crate) sequence: Option<u64>,
}

/// What one report did, and what the caller still owes.
#[derive(Debug, Clone)]
pub(crate) struct TaskBoardWorkItemReportResult {
    pub(crate) progress: TaskBoardWorkItemProgress,
    pub(crate) item: TaskBoardItem,
    pub(crate) applied: bool,
    pub(crate) rejection: Option<TaskBoardWorkItemReportRejection>,
    /// The managed worker still owed a stop. Present only while the work item
    /// is settled and its worker has not been marked settled yet, so the stop
    /// runs exactly once across retries and daemon restarts.
    pub(crate) pending_worker_settlement: Option<String>,
}

pub(crate) async fn task_board_work_item_progress(
    db: &AsyncDaemonDb,
    board_item_id: &str,
) -> Result<Option<TaskBoardWorkItemProgress>, CliError> {
    let mut transaction = db
        .pool()
        .begin()
        .await
        .map_err(|error| db_error(format!("begin work item progress read: {error}")))?;
    let item = transaction
        .load_item_in_tx(board_item_id)
        .await?
        .map(|(item, _)| item);
    let progress = match item.as_ref().and_then(|item| item.work_item_id.as_deref()) {
        Some(work_item_id) => load_progress_in_tx(&mut transaction, work_item_id)
            .await?
            .map(|(progress, _)| progress),
        None => None,
    };
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit work item progress read: {error}")))?;
    Ok(progress)
}

pub(crate) async fn report_task_board_work_item_progress(
    db: &AsyncDaemonDb,
    request: &TaskBoardWorkItemReportRequest,
) -> Result<TaskBoardWorkItemReportResult, CliError> {
    let mut transaction = db
        .begin_immediate_transaction("task board work item report")
        .await?;
    let (item, item_revision) = transaction
        .load_item_in_tx(&request.board_item_id)
        .await?
        .ok_or_else(|| {
            db_error(format!(
                "task-board item '{}' not found",
                request.board_item_id
            ))
        })?;
    let work_item_id = item.work_item_id.clone().ok_or_else(|| {
        CliError::from(CliErrorKind::invalid_transition(format!(
            "task-board item '{}' has no dispatched work item to report progress for",
            request.board_item_id
        )))
    })?;
    let now = utc_now();
    let current = match load_progress_in_tx(&mut transaction, &work_item_id).await? {
        Some((progress, settled)) => (progress, settled),
        None => (
            insert_initial_progress_in_tx(&mut transaction, &item, &work_item_id, &now).await?,
            None,
        ),
    };
    let (current, worker_settled_at) = current;
    let attempt_id = resolve_attempt_id_in_tx(&mut transaction, &item, &work_item_id).await?;
    let report = stamped_report(request, attempt_id, item_revision, &now);
    let outcome = apply_work_item_report(&current, &report);
    let result =
        persist_outcome_in_tx(&mut transaction, item, item_revision, &outcome, &report).await?;
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit task board work item report: {error}")))?;
    Ok(finish_result(result, outcome, worker_settled_at))
}

/// Marks a settled work item's worker as stopped so no later report tries to
/// stop it again.
pub(crate) async fn settle_task_board_work_item_worker(
    db: &AsyncDaemonDb,
    work_item_id: &str,
) -> Result<(), CliError> {
    query(
        "UPDATE task_board_work_item_progress
         SET worker_settled_at = ?2
         WHERE work_item_id = ?1 AND completed_at IS NOT NULL AND worker_settled_at IS NULL",
    )
    .bind(work_item_id)
    .bind(utc_now())
    .execute(db.pool())
    .await
    .map_err(|error| db_error(format!("settle work item worker '{work_item_id}': {error}")))?;
    Ok(())
}

/// The attempt identity is read from the item's own dispatch rather than taken
/// from the report: a worker can only name its own run, and a review handoff
/// has to carry the attempt the board actually started.
async fn resolve_attempt_id_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &TaskBoardItem,
    work_item_id: &str,
) -> Result<Option<String>, CliError> {
    let intent_id = query_as::<_, (String,)>(
        "SELECT intent_id FROM task_board_dispatch_intents
         WHERE item_id = ?1 AND work_item_id = ?2
         ORDER BY created_at DESC, intent_id DESC LIMIT 1",
    )
    .bind(&item.id)
    .bind(work_item_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load work item dispatch intent: {error}")))?;
    Ok(intent_id.map(|(intent_id,)| worker_id_for(item.agent_mode, &intent_id)))
}

fn worker_id_for(agent_mode: AgentMode, intent_id: &str) -> String {
    if agent_mode == AgentMode::Interactive {
        terminal_worker_id(intent_id)
    } else {
        codex_worker_id(intent_id)
    }
}

fn stamped_report(
    request: &TaskBoardWorkItemReportRequest,
    attempt_id: Option<String>,
    item_revision: i64,
    now: &str,
) -> TaskBoardWorkItemReport {
    TaskBoardWorkItemReport {
        actor: request.actor.clone(),
        state: request.state,
        summary: request.summary.clone(),
        progress_percent: request.progress_percent,
        blocked_reason: request.blocked_reason.clone(),
        attempt_id,
        item_revision: item_revision.try_into().ok(),
        sequence: request.sequence,
        checkpoint_id: format!("work-item-checkpoint-{}", Uuid::new_v4().simple()),
        recorded_at: now.to_string(),
    }
}

async fn insert_initial_progress_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &TaskBoardItem,
    work_item_id: &str,
    now: &str,
) -> Result<TaskBoardWorkItemProgress, CliError> {
    let progress = TaskBoardWorkItemProgress::new(
        item.id.clone(),
        work_item_id.to_string(),
        item.workflow.execution_id.clone(),
        now.to_string(),
    );
    query(
        "INSERT INTO task_board_work_item_progress (
             work_item_id, item_id, execution_id, state, report_sequence, created_at, updated_at
         ) VALUES (?1, ?2, ?3, ?4, 0, ?5, ?5)",
    )
    .bind(work_item_id)
    .bind(&item.id)
    .bind(item.workflow.execution_id.as_deref())
    .bind(progress.state.as_str())
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "create work item progress '{work_item_id}': {error}"
        ))
    })?;
    Ok(progress)
}

async fn persist_outcome_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: TaskBoardItem,
    item_revision: i64,
    outcome: &TaskBoardWorkItemReportOutcome,
    report: &TaskBoardWorkItemReport,
) -> Result<TaskBoardItem, CliError> {
    let TaskBoardWorkItemReportOutcome::Applied(progress) = outcome else {
        return Ok(item);
    };
    write_progress_in_tx(transaction, progress).await?;
    if let Some(checkpoint) = progress.latest_checkpoint()
        && checkpoint.checkpoint_id == report.checkpoint_id
    {
        query(
            "INSERT INTO task_board_work_item_checkpoints (
                 work_item_id, sequence, checkpoint_id, actor, summary,
                 progress_percent, attempt_id, recorded_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        )
        .bind(&progress.work_item_id)
        .bind(i64::try_from(checkpoint.sequence).unwrap_or(i64::MAX))
        .bind(&checkpoint.checkpoint_id)
        .bind(&checkpoint.actor)
        .bind(&checkpoint.summary)
        .bind(checkpoint.progress_percent.map(i64::from))
        .bind(checkpoint.attempt_id.as_deref())
        .bind(&checkpoint.recorded_at)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("record work item checkpoint: {error}")))?;
    }
    project_item_in_tx(transaction, item, item_revision, progress).await
}

async fn write_progress_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    progress: &TaskBoardWorkItemProgress,
) -> Result<(), CliError> {
    query(
        "UPDATE task_board_work_item_progress
         SET execution_id = ?2, state = ?3, progress_percent = ?4, summary = ?5,
             blocked_reason = ?6, attempt_id = ?7, item_revision = ?8,
             report_sequence = ?9, updated_at = ?10, completed_at = ?11
         WHERE work_item_id = ?1",
    )
    .bind(&progress.work_item_id)
    .bind(progress.execution_id.as_deref())
    .bind(progress.state.as_str())
    .bind(progress.progress_percent.map(i64::from))
    .bind(progress.summary.as_deref())
    .bind(progress.blocked_reason.as_deref())
    .bind(progress.attempt_id.as_deref())
    .bind(
        progress
            .item_revision
            .and_then(|value| i64::try_from(value).ok()),
    )
    .bind(i64::try_from(progress.report_sequence).unwrap_or(i64::MAX))
    .bind(&progress.updated_at)
    .bind(progress.completed_at.as_deref())
    .execute(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "record work item progress '{}': {error}",
            progress.work_item_id
        ))
    })?;
    Ok(())
}

/// Writes the lane the record now implies onto the board item, in the same
/// transaction. A projection that changes nothing skips the write so a pure
/// checkpoint does not churn the item's revision or its change feed.
async fn project_item_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: TaskBoardItem,
    item_revision: i64,
    progress: &TaskBoardWorkItemProgress,
) -> Result<TaskBoardItem, CliError> {
    let mut projected = item.clone();
    projected.status = progress.state.board_status();
    projected.workflow = progress.project_workflow(&item.workflow);
    if projected.status == item.status && projected.workflow == item.workflow {
        return Ok(item);
    }
    projected.updated_at = progress.updated_at.clone();
    transaction
        .apply_task_board_item_status_transition_in_tx(&projected)
        .await?;
    transaction
        .replace_item_in_tx(&projected, item_revision)
        .await?;
    bump_change_in_tx(transaction, ITEMS_CHANGE_SCOPE).await?;
    Ok(projected)
}

fn finish_result(
    item: TaskBoardItem,
    outcome: TaskBoardWorkItemReportOutcome,
    worker_settled_at: Option<String>,
) -> TaskBoardWorkItemReportResult {
    let applied = outcome.applied();
    let rejection = outcome.rejection();
    let progress = match outcome {
        TaskBoardWorkItemReportOutcome::Applied(progress)
        | TaskBoardWorkItemReportOutcome::Ignored {
            current: progress, ..
        } => progress,
    };
    let pending_worker_settlement = (progress.state.is_terminal() && worker_settled_at.is_none())
        .then(|| progress.attempt_id.clone())
        .flatten();
    TaskBoardWorkItemReportResult {
        progress,
        item,
        applied,
        rejection,
        pending_worker_settlement,
    }
}
