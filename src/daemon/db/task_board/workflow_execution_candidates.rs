use sqlx::query_as;

use super::workflow_execution_attempts::load_execution_attempts_in_tx;
use super::workflow_execution_rows::WorkflowExecutionRow;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::TaskBoardWorkflowExecutionRecord;

const SELECT_READY_EXECUTIONS: &str = "SELECT * FROM task_board_workflow_executions
    WHERE workflow_kind IN ('default_task', 'pr_fix', 'review', 'pr_review')
      AND completed_at IS NULL
      AND (state = 'pending' OR (state = 'retry_wait' AND available_at <= ?1))
    ORDER BY COALESCE(available_at, created_at), updated_at, execution_id
    LIMIT ?2";
const SELECT_PROJECTABLE_EXECUTIONS: &str = "SELECT execution.*
    FROM task_board_workflow_executions AS execution
    JOIN task_board_items AS item ON item.item_id = execution.item_id
    WHERE execution.workflow_kind IN ('default_task', 'pr_fix', 'review', 'pr_review')
      AND execution.state IN ('human_required', 'completed', 'failed', 'cancelled')
      AND (
          EXISTS(SELECT 1 FROM task_board_dispatch_admission_ledger AS ledger
              WHERE ledger.kind = 'concurrency' AND ledger.state = 'committed' AND
                    ledger.managed_worker_id = 'workflow-' || execution.execution_id)
          OR (item.deleted_at IS NULL AND item.workflow_kind IS execution.workflow_kind
          AND json_extract(item.workflow_json, '$.execution_id') IS execution.execution_id AND (
          json_extract(item.workflow_json, '$.current_step_id') IS NOT NULL
          OR item.status IS NOT CASE execution.state WHEN 'completed' THEN 'done'
              WHEN 'human_required' THEN 'human_required' ELSE 'failed' END
          OR json_extract(item.workflow_json, '$.status') IS NOT CASE execution.state
              WHEN 'completed' THEN 'completed' WHEN 'human_required' THEN 'paused'
              WHEN 'failed' THEN 'failed' ELSE 'cancelled' END
          OR json_extract(item.workflow_json, '$.last_error') IS NOT CASE execution.state
              WHEN 'completed' THEN NULL ELSE COALESCE(json_extract(execution.diagnostics_json,
              '$.artifacts.terminal_outcome.summary'), execution.blocked_reason, CASE execution.state
              WHEN 'human_required' THEN 'workflow requires human review' WHEN 'failed' THEN
              'workflow failed' ELSE 'workflow was cancelled' END) END))
      ) ORDER BY execution.updated_at, execution.execution_id LIMIT ?1";

impl AsyncDaemonDb {
    pub(crate) async fn ready_task_board_workflow_executions(
        &self,
        now: &str,
        limit: usize,
    ) -> Result<Vec<TaskBoardWorkflowExecutionRecord>, CliError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let limit = i64::try_from(limit.min(100))
            .map_err(|_| db_error("workflow execution ready limit is out of range"))?;
        let mut transaction =
            self.pool().begin().await.map_err(|error| {
                db_error(format!("begin ready workflow execution load: {error}"))
            })?;
        let rows = query_as::<_, WorkflowExecutionRow>(SELECT_READY_EXECUTIONS)
            .bind(now)
            .bind(limit)
            .fetch_all(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("load ready workflow executions: {error}")))?;
        let executions = load_candidates(&mut transaction, rows).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit ready workflow execution load: {error}")))?;
        Ok(executions)
    }

    pub(crate) async fn projectable_task_board_read_only_workflow_executions(
        &self,
        limit: usize,
    ) -> Result<Vec<TaskBoardWorkflowExecutionRecord>, CliError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let limit = i64::try_from(limit.min(100))
            .map_err(|_| db_error("workflow execution projection limit is out of range"))?;
        let mut transaction = self.pool().begin().await.map_err(|error| {
            db_error(format!(
                "begin projectable workflow execution load: {error}"
            ))
        })?;
        let rows = query_as::<_, WorkflowExecutionRow>(SELECT_PROJECTABLE_EXECUTIONS)
            .bind(limit)
            .fetch_all(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("load projectable workflow executions: {error}")))?;
        let executions = load_candidates(&mut transaction, rows).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit projectable workflow execution load: {error}"
            ))
        })?;
        Ok(executions)
    }
}

pub(super) async fn load_candidates(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    rows: Vec<WorkflowExecutionRow>,
) -> Result<Vec<TaskBoardWorkflowExecutionRecord>, CliError> {
    let mut executions = Vec::with_capacity(rows.len());
    for row in rows {
        let attempts = load_execution_attempts_in_tx(transaction, &row.execution_id).await?;
        executions.push(row.into_record(attempts)?);
    }
    Ok(executions)
}
