//! Worker-stop debt and workflow-ownership queries for work-item progress.

use sqlx::{query, query_as};

use super::work_item_progress_queries::TaskBoardPendingWorkerSettlement;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::task_board::AgentMode;

pub(super) async fn settle_task_board_work_item_worker(
    db: &AsyncDaemonDb,
    board_item_id: &str,
    work_item_id: &str,
) -> Result<(), CliError> {
    query(
        "UPDATE task_board_work_item_progress
         SET worker_settled_at = ?3
         WHERE item_id = ?1 AND work_item_id = ?2
           AND completed_at IS NOT NULL AND worker_settled_at IS NULL",
    )
    .bind(board_item_id)
    .bind(work_item_id)
    .bind(utc_now())
    .execute(db.pool())
    .await
    .map_err(|error| db_error(format!("settle work item worker '{work_item_id}': {error}")))?;
    Ok(())
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
    query_as::<_, (bool,)>(
        "SELECT EXISTS(
             SELECT 1
             FROM task_board_work_item_progress AS progress
             JOIN task_board_workflow_executions AS execution
               ON execution.execution_id = progress.execution_id
             WHERE progress.item_id = ?1 AND progress.work_item_id = ?2
         )",
    )
    .bind(board_item_id)
    .bind(work_item_id)
    .fetch_one(db.pool())
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
