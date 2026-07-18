use std::collections::BTreeSet;

use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};

use super::workflow_execution_candidates::load_candidates;
use super::workflow_execution_rows::WorkflowExecutionRow;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::TaskBoardWorkflowExecutionRecord;

const RECOVERY_QUEUE: &str = "read_only_recoverable";
const ELIGIBLE_COUNT: &str = "SELECT COUNT(*) FROM task_board_workflow_executions
    WHERE workflow_kind IN ('review', 'pr_review')
      AND completed_at IS NULL
      AND state IN ('preparing', 'starting', 'running')";
const SELECT_CANONICAL: &str = "SELECT * FROM task_board_workflow_executions
    WHERE workflow_kind IN ('review', 'pr_review')
      AND completed_at IS NULL
      AND state IN ('preparing', 'starting', 'running')
    ORDER BY updated_at, execution_id LIMIT ?1";
const SELECT_AFTER_CURSOR: &str = "SELECT * FROM task_board_workflow_executions
    WHERE workflow_kind IN ('review', 'pr_review')
      AND completed_at IS NULL
      AND state IN ('preparing', 'starting', 'running')
      AND (updated_at > ?1 OR (updated_at = ?1 AND execution_id > ?2))
    ORDER BY updated_at, execution_id LIMIT ?3";
const SELECT_THROUGH_CURSOR: &str = "SELECT * FROM task_board_workflow_executions
    WHERE workflow_kind IN ('review', 'pr_review')
      AND completed_at IS NULL
      AND state IN ('preparing', 'starting', 'running')
      AND (updated_at < ?1 OR (updated_at = ?1 AND execution_id <= ?2))
    ORDER BY updated_at, execution_id LIMIT ?3";

impl AsyncDaemonDb {
    pub(crate) async fn recoverable_task_board_workflow_executions(
        &self,
        limit: usize,
    ) -> Result<Vec<TaskBoardWorkflowExecutionRecord>, CliError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let effective_limit = limit.min(100);
        let sql_limit = i64::try_from(effective_limit)
            .map_err(|_| db_error("workflow execution recovery limit is out of range"))?;
        let mut transaction = self
            .begin_immediate_transaction("recoverable workflow execution selection")
            .await?;
        let eligible_count = recovery_eligible_count(&mut transaction).await?;
        let rows = if eligible_count <= effective_limit {
            load_canonical_page(&mut transaction, sql_limit).await?
        } else {
            load_truncated_page(&mut transaction, effective_limit, sql_limit).await?
        };
        let cursor = rows
            .last()
            .map(|row| (row.updated_at.clone(), row.execution_id.clone()));
        let executions = match load_candidates(&mut transaction, rows).await {
            Ok(executions) => executions,
            Err(error) => {
                transaction.rollback().await.map_err(|rollback_error| {
                    db_error(format!(
                        "rollback recoverable workflow selection after '{error}': {rollback_error}"
                    ))
                })?;
                return Err(error);
            }
        };
        if eligible_count > effective_limit {
            let (updated_at, execution_id) =
                cursor.ok_or_else(|| db_error("truncated workflow recovery page has no cursor"))?;
            store_recovery_cursor(&mut transaction, &updated_at, &execution_id).await?;
        }
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit recoverable workflow execution selection: {error}"
            ))
        })?;
        Ok(executions)
    }
}

async fn recovery_eligible_count(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<usize, CliError> {
    let count = query_scalar::<_, i64>(ELIGIBLE_COUNT)
        .fetch_one(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("count recoverable workflow executions: {error}")))?;
    usize::try_from(count)
        .map_err(|_| db_error("recoverable workflow execution count is out of range"))
}

async fn load_canonical_page(
    transaction: &mut Transaction<'_, Sqlite>,
    limit: i64,
) -> Result<Vec<WorkflowExecutionRow>, CliError> {
    query_as::<_, WorkflowExecutionRow>(SELECT_CANONICAL)
        .bind(limit)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load canonical workflow recovery page: {error}")))
}

async fn load_truncated_page(
    transaction: &mut Transaction<'_, Sqlite>,
    limit: usize,
    sql_limit: i64,
) -> Result<Vec<WorkflowExecutionRow>, CliError> {
    let cursor = load_recovery_cursor(transaction).await?;
    let mut rows = if let Some((updated_at, execution_id)) = cursor.as_ref() {
        query_as::<_, WorkflowExecutionRow>(SELECT_AFTER_CURSOR)
            .bind(updated_at)
            .bind(execution_id)
            .bind(sql_limit)
            .fetch_all(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("load workflow recovery page: {error}")))?
    } else {
        load_canonical_page(transaction, sql_limit).await?
    };
    if rows.len() < limit
        && let Some((updated_at, execution_id)) = cursor.as_ref()
    {
        let remaining = i64::try_from(limit - rows.len())
            .map_err(|_| db_error("workflow recovery wrap limit is out of range"))?;
        let mut wrapped = query_as::<_, WorkflowExecutionRow>(SELECT_THROUGH_CURSOR)
            .bind(updated_at)
            .bind(execution_id)
            .bind(remaining)
            .fetch_all(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("wrap workflow recovery page: {error}")))?;
        rows.append(&mut wrapped);
    }
    let unique = rows
        .iter()
        .map(|row| row.execution_id.as_str())
        .collect::<BTreeSet<_>>()
        .len();
    if rows.len() != limit || unique != limit {
        return Err(db_error(format!(
            "truncated workflow recovery page returned {} rows and {unique} unique executions, expected {limit}",
            rows.len()
        )));
    }
    Ok(rows)
}

async fn load_recovery_cursor(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<Option<(String, String)>, CliError> {
    query_as::<_, (String, String)>(
        "SELECT sort_updated_at, sort_execution_id
         FROM task_board_reconciliation_cursors WHERE queue = ?1",
    )
    .bind(RECOVERY_QUEUE)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load workflow recovery cursor: {error}")))
}

async fn store_recovery_cursor(
    transaction: &mut Transaction<'_, Sqlite>,
    updated_at: &str,
    execution_id: &str,
) -> Result<(), CliError> {
    query(
        "INSERT INTO task_board_reconciliation_cursors (
             queue, sort_updated_at, sort_execution_id
         ) VALUES (?1, ?2, ?3)
         ON CONFLICT(queue) DO UPDATE SET
             sort_updated_at = excluded.sort_updated_at,
             sort_execution_id = excluded.sort_execution_id",
    )
    .bind(RECOVERY_QUEUE)
    .bind(updated_at)
    .bind(execution_id)
    .execute(transaction.as_mut())
    .await
    .map(|_| ())
    .map_err(|error| db_error(format!("store workflow recovery cursor: {error}")))
}
