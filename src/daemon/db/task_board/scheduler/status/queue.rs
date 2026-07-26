use sqlx::{SqliteConnection, query_as};

use crate::daemon::db::{CliError, db_error};
use crate::task_board::TaskBoardAutomationQueueSummary;

#[derive(sqlx::FromRow)]
struct QueueSummaryRow {
    ready: i64,
    awaiting_approval: i64,
    policy_blocked: i64,
    preparing: i64,
    retrying: i64,
    starting: i64,
    active: i64,
    draining: i64,
    cleanup_required: i64,
}

pub(super) async fn load(
    connection: &mut SqliteConnection,
) -> Result<TaskBoardAutomationQueueSummary, CliError> {
    let row = query_as::<_, QueueSummaryRow>(
        "SELECT
            COALESCE(SUM(CASE
                WHEN phase != 'cleanup' AND state = 'pending' THEN 1 ELSE 0
            END), 0) AS ready,
            COALESCE(SUM(CASE
                WHEN phase != 'cleanup' AND state = 'awaiting_approval' THEN 1 ELSE 0
            END), 0) AS awaiting_approval,
            COALESCE(SUM(CASE
                WHEN phase != 'cleanup' AND state = 'blocked' THEN 1 ELSE 0
            END), 0) AS policy_blocked,
            COALESCE(SUM(CASE
                WHEN phase != 'cleanup' AND state = 'preparing' THEN 1 ELSE 0
            END), 0)
                AS preparing,
            COALESCE(SUM(CASE
                WHEN phase != 'cleanup' AND state = 'retry_wait' THEN 1 ELSE 0
            END), 0)
                AS retrying,
            COALESCE(SUM(CASE
                WHEN phase != 'cleanup' AND state = 'starting' THEN 1 ELSE 0
            END), 0)
                AS starting,
            COALESCE(SUM(CASE
                WHEN phase != 'cleanup' AND state = 'running' THEN 1 ELSE 0
            END), 0)
                AS active,
            COALESCE(SUM(CASE
                WHEN phase != 'cleanup' AND state = 'draining' THEN 1 ELSE 0
            END), 0)
                AS draining,
            COALESCE(SUM(CASE
                WHEN (phase = 'cleanup' OR state = 'human_required')
                    AND state NOT IN ('completed', 'failed', 'cancelled')
                    THEN 1 ELSE 0
            END), 0) AS cleanup_required
         FROM task_board_workflow_executions
         WHERE workflow_kind IN ('default_task', 'pr_fix', 'review', 'pr_review')
           AND completed_at IS NULL
           AND state IN (
            'pending', 'awaiting_approval', 'blocked', 'preparing', 'retry_wait',
            'starting', 'running', 'draining', 'human_required'
         )",
    )
    .fetch_one(&mut *connection)
    .await
    .map_err(|error| db_error(format!("load task board automation queue: {error}")))?;
    Ok(TaskBoardAutomationQueueSummary {
        ready: count(row.ready, "ready")?,
        awaiting_approval: count(row.awaiting_approval, "awaiting approval")?,
        policy_blocked: count(row.policy_blocked, "policy blocked")?,
        preparing: count(row.preparing, "preparing")?,
        retrying: count(row.retrying, "retrying")?,
        starting: count(row.starting, "starting")?,
        active: count(row.active, "active")?,
        draining: count(row.draining, "draining")?,
        cleanup_required: count(row.cleanup_required, "cleanup required")?,
    })
}

fn count(value: i64, label: &str) -> Result<usize, CliError> {
    usize::try_from(value)
        .map_err(|error| db_error(format!("parse task board {label} queue count: {error}")))
}
