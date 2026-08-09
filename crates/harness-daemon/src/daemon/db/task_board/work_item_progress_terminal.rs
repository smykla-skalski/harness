//! Atomic terminal projection from sessionless managed runtimes.

use sqlx::{Sqlite, Transaction, query_as};
use uuid::Uuid;

use super::admission_lifecycle::release_managed_worker_admission_in_tx;
use super::item_tx_ext::TaskBoardItemTxExt;
use super::work_item_progress::{insert_initial_progress_in_tx, persist_outcome_in_tx};
use super::work_item_progress_queries::TaskBoardRuntimeTerminalReport;
use super::work_item_progress_rows::{LoadedWorkItemProgress, load_progress_in_tx};
use crate::daemon::db::prelude::*;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::session::types::CONTROL_PLANE_ACTOR_ID;
use crate::task_board::{
    TaskBoardItem, TaskBoardWorkItemReport, TaskBoardWorkItemState, apply_work_item_report,
};
use harness_kernel::errors::CliErrorKind;

pub(super) async fn project_task_board_runtime_terminal(
    db: &AsyncDaemonDb,
    board_item_id: &str,
    work_item_id: &str,
    attempt_id: &str,
    report: &TaskBoardRuntimeTerminalReport,
) -> Result<bool, CliError> {
    validate_runtime_terminal_report(report)?;
    let mut transaction = db
        .begin_immediate_transaction("task board runtime terminal projection")
        .await?;
    let changed = project_exact_runtime_terminal_in_tx(
        &mut transaction,
        board_item_id,
        work_item_id,
        attempt_id,
        report,
    )
    .await?;
    transaction.commit().await.map_err(|error| {
        db_error(format!(
            "commit task board runtime terminal projection: {error}"
        ))
    })?;
    Ok(changed)
}

pub(super) async fn project_task_board_runtime_terminal_for_attempt(
    db: &AsyncDaemonDb,
    attempt_id: &str,
    report: &TaskBoardRuntimeTerminalReport,
) -> Result<bool, CliError> {
    validate_runtime_terminal_report(report)?;
    let mut transaction = db
        .begin_immediate_transaction("task board runtime terminal attempt projection")
        .await?;
    let identities = query_as::<_, (String, String)>(
        "SELECT item_id, work_item_id FROM task_board_work_item_progress
         WHERE attempt_id = ?1 AND state IN ('pending', 'running')
         ORDER BY item_id, work_item_id LIMIT 2",
    )
    .bind(attempt_id)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("resolve runtime terminal attempt: {error}")))?;
    let changed = match identities.as_slice() {
        [] => false,
        [(board_item_id, work_item_id)] => {
            project_exact_runtime_terminal_in_tx(
                &mut transaction,
                board_item_id,
                work_item_id,
                attempt_id,
                report,
            )
            .await?
        }
        _ => {
            return Err(db_error(format!(
                "runtime terminal attempt '{attempt_id}' matches multiple active work items"
            )));
        }
    };
    release_managed_worker_admission_in_tx(&mut transaction, attempt_id).await?;
    transaction.commit().await.map_err(|error| {
        db_error(format!(
            "commit task board runtime terminal attempt projection: {error}"
        ))
    })?;
    Ok(changed)
}

pub(in crate::daemon::db::task_board) async fn project_exact_runtime_terminal_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    board_item_id: &str,
    work_item_id: &str,
    attempt_id: &str,
    terminal: &TaskBoardRuntimeTerminalReport,
) -> Result<bool, CliError> {
    let Some((item, item_revision)) = transaction.load_item_in_tx(board_item_id).await? else {
        return Ok(false);
    };
    if item.work_item_id.as_deref() != Some(work_item_id) {
        return Ok(false);
    }
    let now = utc_now();
    let loaded =
        load_or_insert_progress_in_tx(transaction, &item, work_item_id, attempt_id, &now).await?;
    if loaded
        .progress
        .attempt_id
        .as_deref()
        .is_some_and(|recorded| recorded != attempt_id)
        || !matches!(
            loaded.progress.state,
            TaskBoardWorkItemState::Pending | TaskBoardWorkItemState::Running
        )
        || super::work_item_progress_settlement::task_board_work_item_is_workflow_owned_in_tx(
            transaction,
            board_item_id,
            work_item_id,
        )
        .await?
    {
        return Ok(false);
    }
    let report = TaskBoardWorkItemReport {
        actor: CONTROL_PLANE_ACTOR_ID.to_string(),
        state: Some(terminal.state),
        summary: terminal.summary.clone(),
        progress_percent: None,
        blocked_reason: terminal.blocked_reason.clone(),
        attempt_id: Some(attempt_id.to_string()),
        item_revision: item_revision.try_into().ok(),
        sequence: None,
        checkpoint_id: format!("work-item-checkpoint-{}", Uuid::new_v4().simple()),
        recorded_at: now,
    };
    let outcome = apply_work_item_report(&loaded.progress, &report);
    let applied = outcome.applied();
    persist_outcome_in_tx(transaction, item, item_revision, &outcome, &report).await?;
    Ok(applied)
}

async fn load_or_insert_progress_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &TaskBoardItem,
    work_item_id: &str,
    attempt_id: &str,
    now: &str,
) -> Result<LoadedWorkItemProgress, CliError> {
    if let Some(loaded) = load_progress_in_tx(transaction, &item.id, work_item_id).await? {
        return Ok(loaded);
    }
    Ok(LoadedWorkItemProgress {
        progress: insert_initial_progress_in_tx(
            transaction,
            item,
            work_item_id,
            Some(attempt_id),
            now,
        )
        .await?,
        worker_settled_at: None,
        agent_mode: item.agent_mode,
    })
}

fn validate_runtime_terminal_report(
    report: &TaskBoardRuntimeTerminalReport,
) -> Result<(), CliError> {
    if matches!(
        report.state,
        TaskBoardWorkItemState::AwaitingReview | TaskBoardWorkItemState::Blocked
    ) {
        return Ok(());
    }
    Err(CliErrorKind::invalid_transition(format!(
        "runtime terminal projection cannot report '{}'",
        report.state.as_str()
    ))
    .into())
}
