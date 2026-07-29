use sqlx::{Sqlite, Transaction, query_scalar};

use super::super::super::automation_cancel_targets::cancel_target_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::TaskBoardAutomationCancelTarget;

const MAX_CANCELABLE_TARGETS: usize = 100;
const SCAN_PAGE_SIZE: i64 = 101;
const SELECT_CANCEL_TARGET_IDS: &str = "SELECT executions.execution_id
    FROM task_board_workflow_executions AS executions
    JOIN task_board_remote_assignments AS assignments
      ON json_extract(executions.resource_ownership_json,
              '$.resources.execution_target') = 'remote:' || assignments.assignment_id
    JOIN task_board_execution_attempts AS attempts
      ON attempts.execution_id = executions.execution_id
     AND attempts.action_key = assignments.action_key
     AND attempts.attempt = assignments.attempt
     AND attempts.idempotency_key = assignments.idempotency_key
    WHERE executions.state = 'running'
      AND executions.host_id = assignments.host_id
      AND executions.fencing_epoch = assignments.fencing_epoch
      AND json_extract(executions.resource_ownership_json,
          '$.resources.execution_target_action_key') = assignments.action_key
      AND json_extract(executions.resource_ownership_json,
          '$.resources.execution_target_attempt') = CAST(assignments.attempt AS TEXT)
      AND assignments.legacy_migrated = 0
      AND assignments.state IN ('claimed', 'started', 'running')
      AND attempts.state = 'running'
      AND (
          assignments.controller_operation_kind IS NULL
          OR json_type(executions.resource_ownership_json,
              '$.resources.remote_cancel_intent') IS NOT NULL
      )
      AND NOT EXISTS (
          SELECT 1 FROM task_board_execution_attempts AS active_attempt
          WHERE active_attempt.execution_id = executions.execution_id
            AND active_attempt.state IN ('preparing', 'starting', 'running')
            AND (
                active_attempt.action_key != attempts.action_key
                OR active_attempt.attempt != attempts.attempt
            )
      )
    ORDER BY executions.execution_id
    LIMIT ?1";

pub(super) struct CancelTargetPage {
    pub(super) targets: Vec<TaskBoardAutomationCancelTarget>,
    pub(super) truncated: bool,
}

pub(super) async fn load(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<CancelTargetPage, CliError> {
    // The durable joins exclude rows which cannot be cancel targets, so the
    // 101st candidate proves truncation without scanning unrelated executions.
    // `cancel_target_in_tx` remains the sole exact projection and decoder.
    let execution_ids = query_scalar::<_, String>(SELECT_CANCEL_TARGET_IDS)
        .bind(SCAN_PAGE_SIZE)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load automation cancel target ids: {error}")))?;
    let mut targets = Vec::with_capacity(execution_ids.len());
    for execution_id in execution_ids {
        if let Some(target) = cancel_target_in_tx(transaction, &execution_id).await? {
            targets.push(target);
        }
    }
    let truncated = targets.len() > MAX_CANCELABLE_TARGETS;
    targets.truncate(MAX_CANCELABLE_TARGETS);
    Ok(CancelTargetPage { targets, truncated })
}

impl AsyncDaemonDb {
    pub(crate) async fn task_board_automation_cancel_target(
        &self,
        execution_id: &str,
    ) -> Result<Option<TaskBoardAutomationCancelTarget>, CliError> {
        let mut transaction =
            self.pool().begin().await.map_err(|error| {
                db_error(format!("begin automation cancel target read: {error}"))
            })?;
        let target = cancel_target_in_tx(&mut transaction, execution_id).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit automation cancel target read: {error}")))?;
        Ok(target)
    }
}
