//! Worker-stop debt and workflow-ownership queries for work-item progress.

use sqlx::{Sqlite, Transaction, query, query_as};

use super::admission_lifecycle::release_managed_worker_admission_in_tx;
use super::work_item_progress_queries::{
    TaskBoardPendingWorkerSettlement, TaskBoardTerminalWorkerAttempt,
};
use crate::daemon::db::prelude::*;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::task_board::AgentMode;
use harness_daemon_managed_agents::AgentTuiStatus;

pub(super) async fn settle_task_board_work_item_worker(
    db: &AsyncDaemonDb,
    board_item_id: &str,
    work_item_id: &str,
) -> Result<(), CliError> {
    let mut transaction = db
        .begin_immediate_transaction("task board work item worker settlement")
        .await?;
    let attempt = query_as::<_, (String,)>(
        "SELECT attempt_id FROM task_board_work_item_progress
         WHERE item_id = ?1 AND work_item_id = ?2
           AND completed_at IS NOT NULL AND worker_settled_at IS NULL
           AND attempt_id IS NOT NULL",
    )
    .bind(board_item_id)
    .bind(work_item_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load work item worker settlement: {error}")))?;
    let Some((attempt_id,)) = attempt else {
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit empty work item worker settlement: {error}"))
        })?;
        return Ok(());
    };
    release_managed_worker_admission_in_tx(&mut transaction, &attempt_id).await?;
    query(
        "UPDATE task_board_work_item_progress
         SET worker_settled_at = ?3
         WHERE item_id = ?1 AND work_item_id = ?2
           AND attempt_id = ?4
           AND completed_at IS NOT NULL AND worker_settled_at IS NULL",
    )
    .bind(board_item_id)
    .bind(work_item_id)
    .bind(utc_now())
    .bind(&attempt_id)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("settle work item worker '{work_item_id}': {error}")))?;
    transaction.commit().await.map_err(|error| {
        db_error(format!(
            "commit work item worker settlement '{work_item_id}': {error}"
        ))
    })?;
    Ok(())
}

pub(super) async fn terminal_task_board_worker_attempts(
    db: &AsyncDaemonDb,
    limit: usize,
) -> Result<Vec<TaskBoardTerminalWorkerAttempt>, CliError> {
    let rows = query_as::<_, (String, String, Option<String>, Option<String>)>(
        "SELECT progress.attempt_id, tui.status, tui.error, tui.signal
         FROM task_board_work_item_progress AS progress
         JOIN agent_tuis AS tui ON tui.tui_id = progress.attempt_id
         JOIN task_board_items AS item
           ON item.item_id = progress.item_id
          AND item.work_item_id = progress.work_item_id
          AND item.deleted_at IS NULL
         WHERE progress.completed_at IS NULL
           AND progress.agent_mode = 'interactive'
           AND tui.workspace_id IS NOT NULL AND tui.agent_id = ''
           AND tui.status IN ('exited', 'failed', 'stopped')
           AND (
               progress.state IN ('pending', 'running')
               OR EXISTS (
                   SELECT 1 FROM task_board_dispatch_admission_ledger AS ledger
                   WHERE ledger.managed_worker_id = progress.attempt_id
                     AND ledger.kind = 'concurrency' AND ledger.state = 'committed'
               )
           )
         ORDER BY tui.updated_at, progress.item_id, progress.work_item_id
         LIMIT ?1",
    )
    .bind(i64::try_from(limit).unwrap_or(i64::MAX))
    .fetch_all(db.pool())
    .await
    .map_err(|error| db_error(format!("load terminal task board workers: {error}")))?;
    rows.into_iter()
        .map(|(attempt_id, status, error, signal)| {
            let status = AgentTuiStatus::parse(&status).map_err(db_error)?;
            let report = super::work_item_progress_queries::TaskBoardRuntimeTerminalReport::from_terminal_agent(
                status,
                error.as_deref(),
                signal.as_deref(),
            )
            .ok_or_else(|| db_error(format!("task board worker '{attempt_id}' is not terminal")))?;
            Ok(TaskBoardTerminalWorkerAttempt { attempt_id, report })
        })
        .collect()
}

pub(super) async fn pending_task_board_work_item_worker_settlements(
    db: &AsyncDaemonDb,
    limit: usize,
) -> Result<Vec<TaskBoardPendingWorkerSettlement>, CliError> {
    let rows = query_as::<_, (String, String, String, String)>(
        "SELECT item_id, work_item_id, attempt_id, agent_mode
         FROM task_board_work_item_progress
         WHERE completed_at IS NOT NULL AND worker_settled_at IS NULL
           AND attempt_id IS NOT NULL
         ORDER BY updated_at, item_id, work_item_id
         LIMIT ?1",
    )
    .bind(i64::try_from(limit).unwrap_or(i64::MAX))
    .fetch_all(db.pool())
    .await
    .map_err(|error| {
        db_error(format!(
            "load pending work item worker settlements: {error}"
        ))
    })?;
    rows.into_iter()
        .map(|(board_item_id, work_item_id, worker_id, agent_mode)| {
            Ok(TaskBoardPendingWorkerSettlement {
                board_item_id,
                work_item_id,
                worker_id,
                agent_mode: parse_agent_mode(&agent_mode)?,
            })
        })
        .collect()
}

pub(super) async fn task_board_work_item_is_workflow_owned(
    db: &AsyncDaemonDb,
    board_item_id: &str,
    work_item_id: &str,
) -> Result<bool, CliError> {
    let mut transaction = db
        .pool()
        .begin()
        .await
        .map_err(|error| db_error(format!("begin work item ownership read: {error}")))?;
    let owned =
        task_board_work_item_is_workflow_owned_in_tx(&mut transaction, board_item_id, work_item_id)
            .await?;
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit work item ownership read: {error}")))?;
    Ok(owned)
}

pub(super) async fn task_board_work_item_is_workflow_owned_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    board_item_id: &str,
    work_item_id: &str,
) -> Result<bool, CliError> {
    query_as::<_, (bool,)>(
        "SELECT EXISTS(
             SELECT 1
             FROM task_board_work_item_progress AS progress
             WHERE progress.item_id = ?1 AND progress.work_item_id = ?2
               AND (
                   EXISTS (
                       SELECT 1 FROM task_board_workflow_executions AS execution
                       WHERE execution.execution_id = progress.execution_id
                   )
                   OR EXISTS (
                       SELECT 1 FROM task_board_dispatch_intents AS intent
                       WHERE intent.item_id = progress.item_id
                         AND intent.work_item_id = progress.work_item_id
                         AND intent.workflow_execution_id = progress.execution_id
                         AND (
                             json_type(intent.payload_json, '$.read_only_workflow') IS NOT NULL
                             OR json_type(intent.payload_json, '$.write_workflow') IS NOT NULL
                         )
                   )
               )
         )",
    )
    .bind(board_item_id)
    .bind(work_item_id)
    .fetch_one(transaction.as_mut())
    .await
    .map(|(exists,)| exists)
    .map_err(|error| db_error(format!("inspect work item workflow ownership: {error}")))
}

fn parse_agent_mode(value: &str) -> Result<AgentMode, CliError> {
    match value {
        "headless" => Ok(AgentMode::Headless),
        "interactive" => Ok(AgentMode::Interactive),
        "planning" => Ok(AgentMode::Planning),
        "evaluate" => Ok(AgentMode::Evaluate),
        _ => Err(db_error(format!(
            "parse work item progress agent mode '{value}'"
        ))),
    }
}
