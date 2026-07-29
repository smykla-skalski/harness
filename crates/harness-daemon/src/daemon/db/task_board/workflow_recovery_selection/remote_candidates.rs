use std::collections::BTreeSet;

use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};

use super::super::workflow_execution_candidates::load_candidates;
use super::super::workflow_execution_rows::WorkflowExecutionRow;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::TaskBoardWorkflowExecutionRecord;

const REMOTE_CANDIDATE_QUEUE: &str = "remote_target_candidates";
const REMOTE_CANDIDATE_COUNT: &str = "SELECT COUNT(*) FROM task_board_workflow_executions
    WHERE workflow_kind IN ('default_task', 'pr_fix', 'pr_fix_review', 'review', 'pr_review')
      AND completed_at IS NULL
      AND state = 'preparing'
      AND json_type(resource_ownership_json,
          '$.resources.execution_target') IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM task_board_remote_assignments AS remote
          JOIN task_board_execution_hosts AS host USING (host_id)
          WHERE remote.execution_id = task_board_workflow_executions.execution_id
            AND host.host_role = 'controller_remote'
            AND remote.legacy_migrated = 0
            AND remote.state IN ('offered', 'claimed', 'started', 'running', 'unknown')
      )";
const SELECT_REMOTE_CANONICAL: &str = "SELECT * FROM task_board_workflow_executions
    WHERE workflow_kind IN ('default_task', 'pr_fix', 'pr_fix_review', 'review', 'pr_review')
      AND completed_at IS NULL
      AND state = 'preparing'
      AND json_type(resource_ownership_json,
          '$.resources.execution_target') IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM task_board_remote_assignments AS remote
          JOIN task_board_execution_hosts AS host USING (host_id)
          WHERE remote.execution_id = task_board_workflow_executions.execution_id
            AND host.host_role = 'controller_remote'
            AND remote.legacy_migrated = 0
            AND remote.state IN ('offered', 'claimed', 'started', 'running', 'unknown')
      )
    ORDER BY updated_at, execution_id LIMIT ?1";
const SELECT_REMOTE_AFTER_CURSOR: &str = "SELECT * FROM task_board_workflow_executions
    WHERE workflow_kind IN ('default_task', 'pr_fix', 'pr_fix_review', 'review', 'pr_review')
      AND completed_at IS NULL
      AND state = 'preparing'
      AND json_type(resource_ownership_json,
          '$.resources.execution_target') IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM task_board_remote_assignments AS remote
          JOIN task_board_execution_hosts AS host USING (host_id)
          WHERE remote.execution_id = task_board_workflow_executions.execution_id
            AND host.host_role = 'controller_remote'
            AND remote.legacy_migrated = 0
            AND remote.state IN ('offered', 'claimed', 'started', 'running', 'unknown')
      )
      AND (updated_at > ?1 OR (updated_at = ?1 AND execution_id > ?2))
    ORDER BY updated_at, execution_id LIMIT ?3";
const SELECT_REMOTE_THROUGH_CURSOR: &str = "SELECT * FROM task_board_workflow_executions
    WHERE workflow_kind IN ('default_task', 'pr_fix', 'pr_fix_review', 'review', 'pr_review')
      AND completed_at IS NULL
      AND state = 'preparing'
      AND json_type(resource_ownership_json,
          '$.resources.execution_target') IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM task_board_remote_assignments AS remote
          JOIN task_board_execution_hosts AS host USING (host_id)
          WHERE remote.execution_id = task_board_workflow_executions.execution_id
            AND host.host_role = 'controller_remote'
            AND remote.legacy_migrated = 0
            AND remote.state IN ('offered', 'claimed', 'started', 'running', 'unknown')
      )
      AND (updated_at < ?1 OR (updated_at = ?1 AND execution_id <= ?2))
    ORDER BY updated_at, execution_id LIMIT ?3";

#[derive(Clone, Copy)]
struct WorkflowSelection {
    queue: &'static str,
    count_sql: &'static str,
    canonical_sql: &'static str,
    after_cursor_sql: &'static str,
    through_cursor_sql: &'static str,
    context: &'static str,
}

pub(super) async fn remote_candidate_task_board_workflow_executions(
    db: &AsyncDaemonDb,
    limit: usize,
) -> Result<Vec<TaskBoardWorkflowExecutionRecord>, CliError> {
    select_workflow_execution_page(
        db,
        limit,
        WorkflowSelection {
            queue: REMOTE_CANDIDATE_QUEUE,
            count_sql: REMOTE_CANDIDATE_COUNT,
            canonical_sql: SELECT_REMOTE_CANONICAL,
            after_cursor_sql: SELECT_REMOTE_AFTER_CURSOR,
            through_cursor_sql: SELECT_REMOTE_THROUGH_CURSOR,
            context: "remote candidate workflow execution",
        },
    )
    .await
}

async fn select_workflow_execution_page(
    db: &AsyncDaemonDb,
    limit: usize,
    selection: WorkflowSelection,
) -> Result<Vec<TaskBoardWorkflowExecutionRecord>, CliError> {
    if limit == 0 {
        return Ok(Vec::new());
    }
    let effective_limit = limit.min(100);
    let sql_limit = i64::try_from(effective_limit)
        .map_err(|_| db_error(format!("{} limit is out of range", selection.context)))?;
    let mut transaction = db.begin_immediate_transaction(selection.context).await?;
    let eligible_count = selection_eligible_count(&mut transaction, selection).await?;
    let rows = load_selection_page(
        &mut transaction,
        selection,
        eligible_count,
        effective_limit,
        sql_limit,
    )
    .await?;
    let cursor = rows
        .last()
        .map(|row| (row.updated_at.clone(), row.execution_id.clone()));
    let executions = load_candidates(&mut transaction, rows).await?;
    advance_selection_cursor_if_truncated(
        &mut transaction,
        selection,
        eligible_count,
        effective_limit,
        cursor,
    )
    .await?;
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit {} selection: {error}", selection.context)))?;
    Ok(executions)
}

async fn load_selection_page(
    transaction: &mut Transaction<'_, Sqlite>,
    selection: WorkflowSelection,
    eligible_count: usize,
    effective_limit: usize,
    sql_limit: i64,
) -> Result<Vec<WorkflowExecutionRow>, CliError> {
    if eligible_count <= effective_limit {
        load_selection_canonical_page(transaction, selection, sql_limit).await
    } else {
        load_selection_truncated_page(transaction, selection, effective_limit, sql_limit).await
    }
}

/// Advances the durable scan cursor only when this page was truncated,
/// leaving it untouched once a scan sees every eligible row in one pass.
async fn advance_selection_cursor_if_truncated(
    transaction: &mut Transaction<'_, Sqlite>,
    selection: WorkflowSelection,
    eligible_count: usize,
    effective_limit: usize,
    cursor: Option<(String, String)>,
) -> Result<(), CliError> {
    if eligible_count <= effective_limit {
        return Ok(());
    }
    let (updated_at, execution_id) = cursor.ok_or_else(|| {
        db_error(format!(
            "truncated {} page has no cursor",
            selection.context
        ))
    })?;
    store_selection_cursor(transaction, selection, &updated_at, &execution_id).await
}

async fn selection_eligible_count(
    transaction: &mut Transaction<'_, Sqlite>,
    selection: WorkflowSelection,
) -> Result<usize, CliError> {
    let count = query_scalar::<_, i64>(selection.count_sql)
        .fetch_one(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("count {}s: {error}", selection.context)))?;
    usize::try_from(count)
        .map_err(|_| db_error(format!("{} count is out of range", selection.context)))
}

async fn load_selection_canonical_page(
    transaction: &mut Transaction<'_, Sqlite>,
    selection: WorkflowSelection,
    limit: i64,
) -> Result<Vec<WorkflowExecutionRow>, CliError> {
    query_as::<_, WorkflowExecutionRow>(selection.canonical_sql)
        .bind(limit)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| {
            db_error(format!(
                "load canonical {} page: {error}",
                selection.context
            ))
        })
}

async fn load_selection_truncated_page(
    transaction: &mut Transaction<'_, Sqlite>,
    selection: WorkflowSelection,
    limit: usize,
    sql_limit: i64,
) -> Result<Vec<WorkflowExecutionRow>, CliError> {
    let cursor = load_selection_cursor(transaction, selection).await?;
    let mut rows = if let Some((updated_at, execution_id)) = cursor.as_ref() {
        query_as::<_, WorkflowExecutionRow>(selection.after_cursor_sql)
            .bind(updated_at)
            .bind(execution_id)
            .bind(sql_limit)
            .fetch_all(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("load {} page: {error}", selection.context)))?
    } else {
        load_selection_canonical_page(transaction, selection, sql_limit).await?
    };
    if rows.len() < limit
        && let Some((updated_at, execution_id)) = cursor.as_ref()
    {
        let remaining = i64::try_from(limit - rows.len())
            .map_err(|_| db_error(format!("{} wrap limit is out of range", selection.context)))?;
        let mut wrapped = query_as::<_, WorkflowExecutionRow>(selection.through_cursor_sql)
            .bind(updated_at)
            .bind(execution_id)
            .bind(remaining)
            .fetch_all(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("wrap {} page: {error}", selection.context)))?;
        rows.append(&mut wrapped);
    }
    let unique = rows
        .iter()
        .map(|row| row.execution_id.as_str())
        .collect::<BTreeSet<_>>()
        .len();
    if rows.len() != limit || unique != limit {
        return Err(db_error(format!(
            "truncated {} page returned {} rows and {unique} unique executions, expected {limit}",
            selection.context,
            rows.len()
        )));
    }
    Ok(rows)
}

async fn load_selection_cursor(
    transaction: &mut Transaction<'_, Sqlite>,
    selection: WorkflowSelection,
) -> Result<Option<(String, String)>, CliError> {
    query_as::<_, (String, String)>(
        "SELECT sort_updated_at, sort_execution_id
         FROM task_board_reconciliation_cursors WHERE queue = ?1",
    )
    .bind(selection.queue)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load {} cursor: {error}", selection.context)))
}

async fn store_selection_cursor(
    transaction: &mut Transaction<'_, Sqlite>,
    selection: WorkflowSelection,
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
    .bind(selection.queue)
    .bind(updated_at)
    .bind(execution_id)
    .execute(transaction.as_mut())
    .await
    .map(|_| ())
    .map_err(|error| db_error(format!("store {} cursor: {error}", selection.context)))
}
