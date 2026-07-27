use sqlx::{Sqlite, Transaction, query, query_as};

use super::sql::{SCAN_CYCLE_AFTER, SCAN_CYCLE_FROM_START};
use super::{CONTROLLER_CYCLE_END_QUEUE, CONTROLLER_PENDING_QUEUE, CONTROLLER_QUEUE, ScanRow};
use crate::daemon::db::{CliError, db_error};

pub(super) async fn load_scan_row(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment_id: &str,
    order_at: &str,
) -> Result<Option<ScanRow>, CliError> {
    query_as::<_, ScanRow>(
        "SELECT assignment_id, offered_at AS order_at, fencing_epoch,
                state AS assignment_state, updated_at AS assignment_updated_at,
                request_sha256, lease_id
         FROM task_board_remote_assignments
         WHERE assignment_id = ?1 AND offered_at = ?2 AND legacy_migrated = 0",
    )
    .bind(assignment_id)
    .bind(order_at)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| scan_error(&error))
}

pub(super) async fn load_named_cursor(
    transaction: &mut Transaction<'_, Sqlite>,
    queue: &str,
) -> Result<Option<(String, String)>, CliError> {
    query_as(
        "SELECT sort_updated_at, sort_execution_id
         FROM task_board_reconciliation_cursors WHERE queue = ?1",
    )
    .bind(queue)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load remote controller cursor: {error}")))
}

pub(super) async fn store_named_cursor(
    transaction: &mut Transaction<'_, Sqlite>,
    queue: &str,
    row: &ScanRow,
) -> Result<(), CliError> {
    query(
        "INSERT INTO task_board_reconciliation_cursors (
             queue, sort_updated_at, sort_execution_id
         ) VALUES (?1, ?2, ?3)
         ON CONFLICT(queue) DO UPDATE SET
             sort_updated_at = excluded.sort_updated_at,
             sort_execution_id = excluded.sort_execution_id",
    )
    .bind(queue)
    .bind(&row.order_at)
    .bind(&row.assignment_id)
    .execute(transaction.as_mut())
    .await
    .map(|_| ())
    .map_err(|error| db_error(format!("store remote controller cursor: {error}")))
}

pub(super) async fn require_pending_cursor(
    transaction: &mut Transaction<'_, Sqlite>,
    expected: &ScanRow,
) -> Result<(), CliError> {
    let pending = load_named_cursor(transaction, CONTROLLER_PENDING_QUEUE).await?;
    if pending.as_ref() == Some(&(expected.order_at.clone(), expected.assignment_id.clone())) {
        Ok(())
    } else {
        Err(db_error(
            "remote controller scan completion lost its pending cursor",
        ))
    }
}

pub(super) async fn clear_named_cursor(
    transaction: &mut Transaction<'_, Sqlite>,
    queue: &str,
) -> Result<(), CliError> {
    query("DELETE FROM task_board_reconciliation_cursors WHERE queue = ?1")
        .bind(queue)
        .execute(transaction.as_mut())
        .await
        .map(|_| ())
        .map_err(|error| db_error(format!("clear remote controller cursor: {error}")))
}

pub(super) async fn clear_cycle(transaction: &mut Transaction<'_, Sqlite>) -> Result<(), CliError> {
    query(
        "DELETE FROM task_board_reconciliation_cursors
         WHERE queue IN (?1, ?2, ?3)",
    )
    .bind(CONTROLLER_QUEUE)
    .bind(CONTROLLER_CYCLE_END_QUEUE)
    .bind(CONTROLLER_PENDING_QUEUE)
    .execute(transaction.as_mut())
    .await
    .map(|_| ())
    .map_err(|error| db_error(format!("complete remote controller scan cycle: {error}")))
}

pub(super) async fn select_cycle_page(
    transaction: &mut Transaction<'_, Sqlite>,
    now: &str,
    cursor: Option<&(String, String)>,
    boundary: &ScanRow,
    limit: i64,
) -> Result<Vec<ScanRow>, CliError> {
    match cursor {
        Some((order_at, assignment_id)) => query_as::<_, ScanRow>(SCAN_CYCLE_AFTER)
            .bind(now)
            .bind(order_at)
            .bind(assignment_id)
            .bind(&boundary.order_at)
            .bind(&boundary.assignment_id)
            .bind(limit)
            .fetch_all(transaction.as_mut())
            .await
            .map_err(|error| scan_error(&error)),
        None => query_as::<_, ScanRow>(SCAN_CYCLE_FROM_START)
            .bind(now)
            .bind(&boundary.order_at)
            .bind(&boundary.assignment_id)
            .bind(limit)
            .fetch_all(transaction.as_mut())
            .await
            .map_err(|error| scan_error(&error)),
    }
}

pub(super) fn scan_error(error: &sqlx::Error) -> CliError {
    db_error(format!("scan remote controller assignments: {error}"))
}
