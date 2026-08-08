//! Evaluate dispatched task-board items against their durable worker progress.
//!
//! Every dispatched item now reads its progress from the record the board owns.
//! A sessionless item is already authoritative there, so evaluation only reports
//! it. A legacy Session-linked item still learns its progress from its Session
//! task, but that reading is translated into one ordinary worker report rather
//! than projected onto the item behind the record's back - one write path, one
//! set of monotonic guards, and no new Session task is ever created.

use tracing::warn;

use crate::agents::runtime::runtime_for_name;
use crate::daemon::index::ResolvedSession;
use crate::daemon::protocol::{
    SessionDetail, TaskBoardEvaluateRequest, TaskBoardEvaluationResponse,
};
use crate::session::service as session_service;
use crate::session::types::{CONTROL_PLANE_ACTOR_ID, SessionSignalRecord, TaskStatus, WorkItem};
use crate::task_board::TaskBoardWorkflowKind;
use crate::task_board::{
    EvaluationSignalFailure, TaskBoardEvaluationOutcome, TaskBoardEvaluationRecord,
    TaskBoardEvaluationSummary, TaskBoardItem, TaskBoardStatus, TaskBoardWorkItemProgress,
    failed_workflow, missing_session_record, missing_task_record, outcome_for_work_item_state,
    record_from_work_item_progress, skipped_unlinked_record, work_item_reason_from_session_task,
    work_item_state_from_session_task,
};
use crate::workspace::utc_now;
use harness_kernel::errors::{CliError, CliErrorKind};
use tokio::task::spawn_blocking;

use super::{build_log_entry, effective_project_dir, session_not_found};
use crate::daemon::db::prelude::*;
use crate::daemon::db::task_board::prelude::*;
use crate::daemon::db::task_board::work_item_progress::TaskBoardWorkItemReportRequest;
use crate::daemon::db_handle::AsyncDaemonDbHandle;

fn record_signal_failure(
    summary: &mut TaskBoardEvaluationSummary,
    item: &TaskBoardItem,
    error: &CliError,
) {
    let failure = signal_failure(item, error);
    log_signal_failure(&failure);
    summary.signal_failures.push(failure);
}

fn signal_failure(item: &TaskBoardItem, error: &CliError) -> EvaluationSignalFailure {
    EvaluationSignalFailure {
        board_item_id: item.id.clone(),
        message: error.to_string(),
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_signal_failure(failure: &EvaluationSignalFailure) {
    warn!(
        board_item_id = %failure.board_item_id,
        error = %failure.message,
        "task-board evaluation: reviewer signal materialization failed",
    );
}

/// Evaluate dispatched task-board items through the async daemon DB.
///
/// # Errors
/// Returns `CliError` when board items cannot be loaded, session state cannot be
/// read, or updated board items cannot be persisted.
pub(crate) async fn evaluate_task_board_async(
    request: &TaskBoardEvaluateRequest,
    async_db: &AsyncDaemonDbHandle,
) -> Result<TaskBoardEvaluationResponse, CliError> {
    let items = selected_items_async(async_db, request).await?;
    let mut summary = TaskBoardEvaluationSummary::default();
    for item in &items {
        if matches!(item.workflow_kind, TaskBoardWorkflowKind::Review)
            || item.workflow_kind.is_read_only_review()
        {
            continue;
        }
        if item.work_item_id.is_none() {
            summary.push(skipped_unlinked_record(item));
            continue;
        }
        // Boxed to keep the per-item frame out of this loop's future; the
        // session read and the report path each nest several database frames.
        Box::pin(evaluate_one_item(
            async_db,
            item,
            request.dry_run,
            &mut summary,
        ))
        .await?;
    }
    Ok(summary)
}

async fn evaluate_one_item(
    db: &AsyncDaemonDbHandle,
    item: &TaskBoardItem,
    dry_run: bool,
    summary: &mut TaskBoardEvaluationSummary,
) -> Result<(), CliError> {
    let Some(session_id) = item.session_id.as_deref() else {
        summary.push(sessionless_record(db, item).await?);
        return Ok(());
    };
    let work_item_id = item.work_item_id.as_deref().unwrap_or_default();
    let task = match super::session_detail_async(session_id, Some(db)).await {
        Ok(detail) => task_from_detail(detail, work_item_id),
        Err(error) => {
            summary.push(
                failure_record_async(
                    db,
                    item,
                    missing_session_record(item, error.to_string()),
                    "missing_session",
                    dry_run,
                )
                .await?,
            );
            return Ok(());
        }
    };
    let Some(task) = task else {
        summary.push(
            failure_record_async(
                db,
                item,
                missing_task_record(item, format!("session task '{work_item_id}' was not found")),
                "missing_task",
                dry_run,
            )
            .await?,
        );
        return Ok(());
    };
    let record = translate_session_task(db, item, &task, dry_run).await?;
    // Record the decision before attempting reviewer materialization so a
    // downstream signal failure cannot drop the evaluation outcome.
    let signal_outcome = materialize_reviewer_signal_async(item, &task, &record, db)
        .await
        .err();
    summary.push(record);
    if let Some(error) = signal_outcome {
        record_signal_failure(summary, item, &error);
    }
    Ok(())
}

/// A sessionless item has nothing to translate: its record is already the
/// authority and the write path already projected the lane, so evaluation only
/// reports what the record says.
async fn sessionless_record(
    db: &AsyncDaemonDbHandle,
    item: &TaskBoardItem,
) -> Result<TaskBoardEvaluationRecord, CliError> {
    let Some(progress) = db.task_board_work_item_progress(&item.id).await? else {
        return Ok(skipped_unlinked_record(item));
    };
    Ok(record_from_work_item_progress(item, &progress))
}

/// Feeds one legacy Session task through the ordinary report path.
///
/// The report carries no sequence, so it takes the next one and the record's
/// own guards decide: a settled work item stays settled however many times
/// evaluation reruns, and a Session task that moved gets followed exactly once.
async fn translate_session_task(
    db: &AsyncDaemonDbHandle,
    item: &TaskBoardItem,
    task: &WorkItem,
    dry_run: bool,
) -> Result<TaskBoardEvaluationRecord, CliError> {
    let state = work_item_state_from_session_task(task);
    if dry_run {
        return Ok(dry_run_record(item, task, state));
    }
    let result = db
        .report_task_board_work_item_progress(&TaskBoardWorkItemReportRequest {
            board_item_id: item.id.clone(),
            actor: CONTROL_PLANE_ACTOR_ID.to_string(),
            state: Some(state),
            summary: None,
            progress_percent: None,
            blocked_reason: work_item_reason_from_session_task(task),
            sequence: None,
        })
        .await?;
    // `updated` counts board items this evaluation moved, not records it wrote:
    // the first report for an item creates its record without necessarily
    // changing the lane the item already shows.
    Ok(translated_record(
        item,
        task,
        &result.progress,
        result.item_changed,
    ))
}

fn dry_run_record(
    item: &TaskBoardItem,
    task: &WorkItem,
    state: crate::task_board::TaskBoardWorkItemState,
) -> TaskBoardEvaluationRecord {
    TaskBoardEvaluationRecord {
        board_item_id: item.id.clone(),
        session_id: item.session_id.clone(),
        work_item_id: item.work_item_id.clone(),
        outcome: outcome_for_work_item_state(state),
        task_status: Some(task.status),
        board_status: Some(state.board_status()),
        workflow_status: Some(state.workflow_status()),
        work_item_state: Some(state),
        updated: false,
        reason: work_item_reason_from_session_task(task),
        item: None,
    }
}

fn translated_record(
    item: &TaskBoardItem,
    task: &WorkItem,
    progress: &TaskBoardWorkItemProgress,
    item_changed: bool,
) -> TaskBoardEvaluationRecord {
    let mut record = record_from_work_item_progress(item, progress);
    record.task_status = Some(task.status);
    record.updated = item_changed;
    record
}

async fn selected_items_async(
    db: &AsyncDaemonDbHandle,
    request: &TaskBoardEvaluateRequest,
) -> Result<Vec<TaskBoardItem>, CliError> {
    if let Some(item_id) = request.item_id.as_deref() {
        return super::task_board_repository_scope::scoped_task_board_item_db(db, item_id)
            .await
            .map(|item| vec![item]);
    }
    super::task_board_repository_scope::scoped_task_board_items_db(db, request.status).await
}

fn task_from_detail(detail: SessionDetail, work_item_id: &str) -> Option<WorkItem> {
    detail
        .tasks
        .into_iter()
        .find(|task| task.task_id == work_item_id && !task.is_deleted())
}

async fn materialize_reviewer_signal_async(
    item: &TaskBoardItem,
    task: &WorkItem,
    record: &TaskBoardEvaluationRecord,
    async_db: &AsyncDaemonDbHandle,
) -> Result<(), CliError> {
    if !should_materialize_reviewer_signal(task, record) {
        return Ok(());
    }
    let Some(session_id) = item.session_id.as_deref() else {
        return Ok(());
    };
    let Some(resolved) = async_db.resolve_session(session_id).await? else {
        return Err(session_not_found(session_id));
    };
    write_reviewer_signal_async(&resolved, task, async_db).await
}

fn should_materialize_reviewer_signal(task: &WorkItem, record: &TaskBoardEvaluationRecord) -> bool {
    record.updated
        && record.outcome == TaskBoardEvaluationOutcome::ReviewPending
        && task.status == TaskStatus::AwaitingReview
}

async fn write_reviewer_signal_async(
    resolved: &ResolvedSession,
    task: &WorkItem,
    async_db: &AsyncDaemonDbHandle,
) -> Result<(), CliError> {
    let now = utc_now();
    let Some(record) =
        session_service::maybe_emit_spawn_reviewer(&resolved.state, &task.task_id, &now)
    else {
        return Ok(());
    };
    let Some(runtime) = runtime_for_name(&record.runtime) else {
        return Ok(());
    };
    let project_dir = effective_project_dir(resolved).to_path_buf();
    let target_session_id = signal_target_session_id(resolved, &record);
    let signal = record.signal.clone();
    spawn_blocking(move || runtime.write_signal(&project_dir, &target_session_id, &signal))
        .await
        .unwrap_or_else(|error| {
            Err(CliErrorKind::workflow_io(format!(
                "task-board evaluation reviewer signal worker failed: {error}"
            ))
            .into())
        })?;
    async_db
        .append_log_entry(&build_log_entry(
            &resolved.state.session_id,
            session_service::log_signal_sent(
                &record.signal.signal_id,
                &record.agent_id,
                &record.signal.command,
            ),
            None,
            None,
        ))
        .await
}

fn signal_target_session_id(resolved: &ResolvedSession, record: &SessionSignalRecord) -> String {
    resolved
        .state
        .agents
        .get(&record.agent_id)
        .and_then(|agent| agent.agent_session_id.clone())
        .unwrap_or_else(|| record.session_id.clone())
}

async fn failure_record_async(
    db: &AsyncDaemonDbHandle,
    item: &TaskBoardItem,
    mut record: TaskBoardEvaluationRecord,
    step: &'static str,
    dry_run: bool,
) -> Result<TaskBoardEvaluationRecord, CliError> {
    if dry_run {
        return Ok(record);
    }
    let reason = record.reason.clone().unwrap_or_else(|| step.to_string());
    let workflow = failed_workflow(item, step, reason);
    if item.status == TaskBoardStatus::Failed && item.workflow == workflow {
        return Ok(record);
    }
    let Some(updated_item) = db
        .update_task_board_item_for_evaluation(&item.id, |current| {
            current.status = TaskBoardStatus::Failed;
            current.workflow.clone_from(&workflow);
            Ok(true)
        })
        .await?
        .map(|mutation| mutation.item)
    else {
        return Ok(record);
    };
    record.updated = true;
    record.item = Some(updated_item);
    Ok(record)
}

#[cfg(test)]
#[path = "task_board_evaluation_tests.rs"]
mod tests;
