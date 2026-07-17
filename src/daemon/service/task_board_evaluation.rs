use tracing::warn;

use crate::agents::runtime::runtime_for_name;
use crate::daemon::db::AsyncDaemonDb;
#[cfg(test)]
use crate::daemon::db::DaemonDb;
use crate::daemon::index::ResolvedSession;
use crate::daemon::protocol::{
    SessionDetail, TaskBoardEvaluateRequest, TaskBoardEvaluationResponse,
};
use crate::errors::{CliError, CliErrorKind};
use crate::session::service as session_service;
#[cfg(test)]
use crate::session::storage as session_storage;
use crate::session::types::{SessionSignalRecord, TaskStatus, WorkItem};
#[cfg(test)]
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::{
    EvaluationSignalFailure, TaskBoardEvaluationOutcome, TaskBoardEvaluationRecord,
    TaskBoardEvaluationSummary, TaskBoardItem, TaskBoardStatus, evaluate_task_board_item,
    failed_workflow, missing_session_record, missing_task_record, record_from_decision,
    skipped_unlinked_record,
};
#[cfg(test)]
use crate::task_board::{TaskBoardStore, default_board_root};
use crate::workspace::utc_now;
use tokio::task::spawn_blocking;

#[cfg(test)]
use super::index;
use super::{build_log_entry, effective_project_dir, session_not_found};

/// Evaluate linked task-board items against their session work-item state.
///
/// # Errors
/// Returns `CliError` when board items cannot be loaded or updated.
#[cfg(test)]
pub fn evaluate_task_board(
    request: &TaskBoardEvaluateRequest,
    db: Option<&DaemonDb>,
) -> Result<TaskBoardEvaluationResponse, CliError> {
    let board = store();
    let items = selected_items(&board, request)?;
    evaluate_items_with_loader(
        &board,
        &items,
        request.dry_run,
        |session_id, work_item_id| {
            let detail = super::session_detail(session_id, db)?;
            Ok(task_from_detail(detail, work_item_id))
        },
        |item, task, record| materialize_reviewer_signal(item, task, record, db),
    )
}

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

/// Evaluate linked task-board items through the async daemon DB.
///
/// # Errors
/// Returns `CliError` when board items cannot be loaded, session state cannot be
/// read, or updated board items cannot be persisted.
#[expect(
    clippy::cognitive_complexity,
    reason = "evaluation loop keeps per-item failure branches explicit"
)]
pub(crate) async fn evaluate_task_board_async(
    request: &TaskBoardEvaluateRequest,
    async_db: &AsyncDaemonDb,
) -> Result<TaskBoardEvaluationResponse, CliError> {
    let items = selected_items_async(async_db, request).await?;
    let mut summary = TaskBoardEvaluationSummary::default();
    for item in &items {
        if matches!(
            item.workflow_kind,
            crate::task_board::TaskBoardWorkflowKind::Review
                | crate::task_board::TaskBoardWorkflowKind::PrReview
        ) {
            continue;
        }
        let Some((session_id, work_item_id)) = linked_task(item) else {
            summary.push(skipped_unlinked_record(item));
            continue;
        };
        let task = match super::session_detail_async(session_id, Some(async_db)).await {
            Ok(detail) => task_from_detail(detail, work_item_id),
            Err(error) => {
                let record = failure_record_async(
                    async_db,
                    item,
                    missing_session_record(item, error.to_string()),
                    "missing_session",
                    request.dry_run,
                )
                .await?;
                summary.push(record);
                continue;
            }
        };
        let Some(task) = task else {
            let record = failure_record_async(
                async_db,
                item,
                missing_task_record(item, format!("session task '{work_item_id}' was not found")),
                "missing_task",
                request.dry_run,
            )
            .await?;
            summary.push(record);
            continue;
        };
        let record = evaluate_linked_item_async(async_db, item, &task, request.dry_run).await?;
        // Record the decision before attempting reviewer materialization so a
        // downstream signal failure cannot drop the evaluation outcome.
        let signal_outcome = materialize_reviewer_signal_async(item, &task, &record, async_db)
            .await
            .err();
        summary.push(record);
        if let Some(error) = signal_outcome {
            record_signal_failure(&mut summary, item, &error);
        }
    }
    Ok(summary)
}

#[cfg(test)]
fn selected_items(
    board: &TaskBoardStore,
    request: &TaskBoardEvaluateRequest,
) -> Result<Vec<TaskBoardItem>, CliError> {
    request.item_id.as_deref().map_or_else(
        || board.list(request.status),
        |item_id| board.get(item_id).map(|item| vec![item]),
    )
}

async fn selected_items_async(
    db: &AsyncDaemonDb,
    request: &TaskBoardEvaluateRequest,
) -> Result<Vec<TaskBoardItem>, CliError> {
    if let Some(item_id) = request.item_id.as_deref() {
        return db.task_board_item(item_id).await.map(|item| vec![item]);
    }
    db.list_task_board_items(request.status).await
}

#[cfg(test)]
fn evaluate_items_with_loader<F>(
    board: &TaskBoardStore,
    items: &[TaskBoardItem],
    dry_run: bool,
    mut load_task: F,
    mut schedule_reviewer: impl FnMut(
        &TaskBoardItem,
        &WorkItem,
        &TaskBoardEvaluationRecord,
    ) -> Result<(), CliError>,
) -> Result<TaskBoardEvaluationSummary, CliError>
where
    F: FnMut(&str, &str) -> Result<Option<WorkItem>, CliError>,
{
    let mut summary = TaskBoardEvaluationSummary::default();
    for item in items {
        let Some((session_id, work_item_id)) = linked_task(item) else {
            summary.push(skipped_unlinked_record(item));
            continue;
        };
        let task = match load_task(session_id, work_item_id) {
            Ok(task) => task,
            Err(error) => {
                summary.push(failure_record(
                    board,
                    item,
                    missing_session_record(item, error.to_string()),
                    "missing_session",
                    dry_run,
                )?);
                continue;
            }
        };
        let Some(task) = task else {
            summary.push(failure_record(
                board,
                item,
                missing_task_record(item, format!("session task '{work_item_id}' was not found")),
                "missing_task",
                dry_run,
            )?);
            continue;
        };
        let record = evaluate_linked_item(board, item, &task, dry_run)?;
        // Record the decision before scheduling the reviewer signal so a
        // downstream failure cannot drop the evaluation outcome from the summary.
        let signal_outcome = schedule_reviewer(item, &task, &record).err();
        summary.push(record);
        if let Some(error) = signal_outcome {
            record_signal_failure(&mut summary, item, &error);
        }
    }
    Ok(summary)
}

fn linked_task(item: &TaskBoardItem) -> Option<(&str, &str)> {
    Some((item.session_id.as_deref()?, item.work_item_id.as_deref()?))
}

fn task_from_detail(detail: SessionDetail, work_item_id: &str) -> Option<WorkItem> {
    detail
        .tasks
        .into_iter()
        .find(|task| task.task_id == work_item_id && !task.is_deleted())
}

#[cfg(test)]
fn evaluate_linked_item(
    board: &TaskBoardStore,
    item: &TaskBoardItem,
    task: &WorkItem,
    dry_run: bool,
) -> Result<TaskBoardEvaluationRecord, CliError> {
    let decision = evaluate_task_board_item(item, task);
    let changed = item.status != decision.status || item.workflow != decision.workflow;
    if dry_run || !changed {
        return Ok(record_from_decision(item, &decision, false, None));
    }
    let updated_item = board.update(
        &item.id,
        TaskBoardItemPatch {
            status: Some(decision.status),
            workflow: Some(decision.workflow.clone()),
            ..TaskBoardItemPatch::default()
        },
    )?;
    Ok(record_from_decision(
        item,
        &decision,
        true,
        Some(updated_item),
    ))
}

async fn evaluate_linked_item_async(
    db: &AsyncDaemonDb,
    item: &TaskBoardItem,
    task: &WorkItem,
    dry_run: bool,
) -> Result<TaskBoardEvaluationRecord, CliError> {
    let decision = evaluate_task_board_item(item, task);
    let changed = item.status != decision.status || item.workflow != decision.workflow;
    if dry_run || !changed {
        return Ok(record_from_decision(item, &decision, false, None));
    }
    let updated_item = db
        .update_task_board_item(&item.id, |current| {
            current.status = decision.status;
            current.workflow.clone_from(&decision.workflow);
            Ok(true)
        })
        .await?
        .expect("task-board evaluation always mutates")
        .item;
    Ok(record_from_decision(
        item,
        &decision,
        true,
        Some(updated_item),
    ))
}

#[cfg(test)]
fn materialize_reviewer_signal(
    item: &TaskBoardItem,
    task: &WorkItem,
    record: &TaskBoardEvaluationRecord,
    db: Option<&DaemonDb>,
) -> Result<(), CliError> {
    if !should_materialize_reviewer_signal(task, record) {
        return Ok(());
    }
    let Some(session_id) = item.session_id.as_deref() else {
        return Ok(());
    };
    let resolved = resolve_session(session_id, db)?;
    write_reviewer_signal(&resolved, task, db)
}

async fn materialize_reviewer_signal_async(
    item: &TaskBoardItem,
    task: &WorkItem,
    record: &TaskBoardEvaluationRecord,
    async_db: &AsyncDaemonDb,
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

#[cfg(test)]
fn resolve_session(session_id: &str, db: Option<&DaemonDb>) -> Result<ResolvedSession, CliError> {
    if let Some(db) = db
        && let Some(resolved) = db.resolve_session(session_id)?
    {
        return Ok(resolved);
    }
    index::resolve_session(session_id)
}

#[cfg(test)]
fn write_reviewer_signal(
    resolved: &ResolvedSession,
    task: &WorkItem,
    db: Option<&DaemonDb>,
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
    runtime.write_signal(&project_dir, &target_session_id, &record.signal)?;
    let transition = session_service::log_signal_sent(
        &record.signal.signal_id,
        &record.agent_id,
        &record.signal.command,
    );
    if let Some(db) = db {
        return db.append_log_entry(&build_log_entry(
            &resolved.state.session_id,
            transition,
            None,
            None,
        ));
    }
    let layout =
        session_storage::layout_from_project_dir(&project_dir, &resolved.state.session_id)?;
    session_storage::append_log_entry(&layout, transition, None, None)
}

async fn write_reviewer_signal_async(
    resolved: &ResolvedSession,
    task: &WorkItem,
    async_db: &AsyncDaemonDb,
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

#[cfg(test)]
fn failure_record(
    board: &TaskBoardStore,
    item: &TaskBoardItem,
    mut record: TaskBoardEvaluationRecord,
    step: &str,
    dry_run: bool,
) -> Result<TaskBoardEvaluationRecord, CliError> {
    if dry_run {
        return Ok(record);
    }
    let reason = record.reason.clone().unwrap_or_else(|| step.to_string());
    let workflow = failed_workflow(item, step, reason);
    let changed = item.status != TaskBoardStatus::Failed || item.workflow != workflow;
    if !changed {
        return Ok(record);
    }
    let updated_item = board.update(
        &item.id,
        TaskBoardItemPatch {
            status: Some(TaskBoardStatus::Failed),
            workflow: Some(workflow),
            ..TaskBoardItemPatch::default()
        },
    )?;
    record.updated = true;
    record.item = Some(updated_item);
    Ok(record)
}

async fn failure_record_async(
    db: &AsyncDaemonDb,
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
    let updated_item = db
        .update_task_board_item(&item.id, |current| {
            current.status = TaskBoardStatus::Failed;
            current.workflow.clone_from(&workflow);
            Ok(true)
        })
        .await?
        .expect("task-board evaluation failure always mutates")
        .item;
    record.updated = true;
    record.item = Some(updated_item);
    Ok(record)
}

#[cfg(test)]
fn store() -> TaskBoardStore {
    TaskBoardStore::new(default_board_root())
}

#[cfg(test)]
#[path = "task_board_evaluation_tests.rs"]
mod tests;
