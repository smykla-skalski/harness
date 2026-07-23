use sqlx::{Sqlite, Transaction, query, query_as};

use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};

const ACTIVE_QUEUE: &str = "task_board_remote_executor_active";
const TERMINAL_QUEUE: &str = "task_board_remote_executor_terminal";
const SCAN_LIMIT: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteExecutorScan {
    pub(crate) active_assignment_ids: Vec<String>,
    pub(crate) terminal_assignment_ids: Vec<String>,
}

#[derive(Debug, Clone, sqlx::FromRow)]
struct ScanRow {
    assignment_id: String,
    updated_at: String,
}

#[derive(Debug, Clone, Copy)]
enum ScanClass {
    Active,
    Terminal,
}

impl ScanClass {
    const fn queue(self) -> &'static str {
        match self {
            Self::Active => ACTIVE_QUEUE,
            Self::Terminal => TERMINAL_QUEUE,
        }
    }

    const fn label(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Terminal => "terminal",
        }
    }
}

impl AsyncDaemonDb {
    /// Selects bounded, restart-fair executor work and durably advances both cursors.
    pub(crate) async fn scan_task_board_remote_executor_assignments(
        &self,
    ) -> Result<TaskBoardRemoteExecutorScan, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("remote executor assignment scan")
            .await?;
        let active = scan_class_page(&mut transaction, ScanClass::Active).await?;
        let terminal = scan_class_page(&mut transaction, ScanClass::Terminal).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote executor scan: {error}")))?;
        Ok(TaskBoardRemoteExecutorScan {
            active_assignment_ids: assignment_ids(active),
            terminal_assignment_ids: assignment_ids(terminal),
        })
    }
}

async fn scan_class_page(
    transaction: &mut Transaction<'_, Sqlite>,
    class: ScanClass,
) -> Result<Vec<ScanRow>, CliError> {
    let cursor = load_cursor(transaction, class).await?;
    let limit = i64::try_from(SCAN_LIMIT)
        .map_err(|_| db_error("remote executor scan limit is out of range"))?;
    let mut rows = match cursor.as_ref() {
        Some((updated_at, assignment_id)) => {
            select_after_cursor(transaction, class, updated_at, assignment_id, limit).await?
        }
        None => select_canonical(transaction, class, limit).await?,
    };
    if rows.len() < SCAN_LIMIT
        && let Some((updated_at, assignment_id)) = cursor.as_ref()
    {
        let remaining = i64::try_from(SCAN_LIMIT - rows.len())
            .map_err(|_| db_error("remote executor wrap limit is out of range"))?;
        let mut wrapped =
            select_through_cursor(transaction, class, updated_at, assignment_id, remaining).await?;
        rows.append(&mut wrapped);
    }
    if let Some(last) = rows.last() {
        store_cursor(transaction, class, last).await?;
    }
    Ok(rows)
}

async fn load_cursor(
    transaction: &mut Transaction<'_, Sqlite>,
    class: ScanClass,
) -> Result<Option<(String, String)>, CliError> {
    query_as(
        "SELECT sort_updated_at, sort_execution_id
         FROM task_board_reconciliation_cursors WHERE queue = ?1",
    )
    .bind(class.queue())
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "load {} remote executor cursor: {error}",
            class.label()
        ))
    })
}

async fn store_cursor(
    transaction: &mut Transaction<'_, Sqlite>,
    class: ScanClass,
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
    .bind(class.queue())
    .bind(&row.updated_at)
    .bind(&row.assignment_id)
    .execute(transaction.as_mut())
    .await
    .map(|_| ())
    .map_err(|error| {
        db_error(format!(
            "store {} remote executor cursor: {error}",
            class.label()
        ))
    })
}

async fn select_canonical(
    transaction: &mut Transaction<'_, Sqlite>,
    class: ScanClass,
    limit: i64,
) -> Result<Vec<ScanRow>, CliError> {
    let sql = class_query(class, CursorRange::All);
    query_as::<_, ScanRow>(sql)
        .bind(limit)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| scan_error(class, &error))
}

async fn select_after_cursor(
    transaction: &mut Transaction<'_, Sqlite>,
    class: ScanClass,
    updated_at: &str,
    assignment_id: &str,
    limit: i64,
) -> Result<Vec<ScanRow>, CliError> {
    let sql = class_query(class, CursorRange::After);
    query_as::<_, ScanRow>(sql)
        .bind(updated_at)
        .bind(assignment_id)
        .bind(limit)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| scan_error(class, &error))
}

async fn select_through_cursor(
    transaction: &mut Transaction<'_, Sqlite>,
    class: ScanClass,
    updated_at: &str,
    assignment_id: &str,
    limit: i64,
) -> Result<Vec<ScanRow>, CliError> {
    let sql = class_query(class, CursorRange::Through);
    query_as::<_, ScanRow>(sql)
        .bind(updated_at)
        .bind(assignment_id)
        .bind(limit)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| scan_error(class, &error))
}

#[derive(Debug, Clone, Copy)]
enum CursorRange {
    All,
    After,
    Through,
}

fn class_query(class: ScanClass, range: CursorRange) -> &'static str {
    match (class, range) {
        (ScanClass::Active, CursorRange::All) => ACTIVE_ALL,
        (ScanClass::Active, CursorRange::After) => ACTIVE_AFTER,
        (ScanClass::Active, CursorRange::Through) => ACTIVE_THROUGH,
        (ScanClass::Terminal, CursorRange::All) => TERMINAL_ALL,
        (ScanClass::Terminal, CursorRange::After) => TERMINAL_AFTER,
        (ScanClass::Terminal, CursorRange::Through) => TERMINAL_THROUGH,
    }
}

fn scan_error(class: ScanClass, error: &sqlx::Error) -> CliError {
    db_error(format!(
        "scan {} remote executor assignments: {error}",
        class.label()
    ))
}

fn assignment_ids(rows: Vec<ScanRow>) -> Vec<String> {
    rows.into_iter().map(|row| row.assignment_id).collect()
}

const ACTIVE_ALL: &str = "SELECT assignments.assignment_id, assignments.updated_at
    FROM task_board_remote_assignments AS assignments
    JOIN task_board_execution_hosts AS hosts ON hosts.host_id = assignments.host_id
    WHERE hosts.host_role = 'executor_self'
      AND assignments.legacy_migrated = 0
      AND assignments.claimed_host_instance_id = assignments.target_host_instance_id
      AND assignments.state IN ('claimed', 'started', 'running')
    ORDER BY assignments.updated_at, assignments.assignment_id LIMIT ?1";

const ACTIVE_AFTER: &str = "SELECT assignments.assignment_id, assignments.updated_at
    FROM task_board_remote_assignments AS assignments
    JOIN task_board_execution_hosts AS hosts ON hosts.host_id = assignments.host_id
    WHERE hosts.host_role = 'executor_self'
      AND assignments.legacy_migrated = 0
      AND assignments.claimed_host_instance_id = assignments.target_host_instance_id
      AND assignments.state IN ('claimed', 'started', 'running')
      AND (assignments.updated_at > ?1
           OR (assignments.updated_at = ?1 AND assignments.assignment_id > ?2))
    ORDER BY assignments.updated_at, assignments.assignment_id LIMIT ?3";

const ACTIVE_THROUGH: &str = "SELECT assignments.assignment_id, assignments.updated_at
    FROM task_board_remote_assignments AS assignments
    JOIN task_board_execution_hosts AS hosts ON hosts.host_id = assignments.host_id
    WHERE hosts.host_role = 'executor_self'
      AND assignments.legacy_migrated = 0
      AND assignments.claimed_host_instance_id = assignments.target_host_instance_id
      AND assignments.state IN ('claimed', 'started', 'running')
      AND (assignments.updated_at < ?1
           OR (assignments.updated_at = ?1 AND assignments.assignment_id <= ?2))
    ORDER BY assignments.updated_at, assignments.assignment_id LIMIT ?3";

const TERMINAL_ALL: &str = "SELECT assignments.assignment_id, assignments.updated_at
    FROM task_board_remote_assignments AS assignments
    JOIN task_board_execution_hosts AS hosts ON hosts.host_id = assignments.host_id
    WHERE hosts.host_role = 'executor_self'
      AND assignments.legacy_migrated = 0
      AND assignments.target_host_instance_id IS NOT NULL
      AND assignments.cleanup_completed_at IS NULL
      AND (
        assignments.state IN ('cancelled', 'unknown')
        OR (
          assignments.state IN ('completed', 'failed', 'superseded')
          AND EXISTS (
            SELECT 1 FROM task_board_remote_settlement_receipts AS receipt
            WHERE receipt.assignment_id = assignments.assignment_id
              AND receipt.fencing_epoch = assignments.fencing_epoch
          )
        )
      )
    ORDER BY assignments.updated_at, assignments.assignment_id LIMIT ?1";

const TERMINAL_AFTER: &str = "SELECT assignments.assignment_id, assignments.updated_at
    FROM task_board_remote_assignments AS assignments
    JOIN task_board_execution_hosts AS hosts ON hosts.host_id = assignments.host_id
    WHERE hosts.host_role = 'executor_self'
      AND assignments.legacy_migrated = 0
      AND assignments.target_host_instance_id IS NOT NULL
      AND assignments.cleanup_completed_at IS NULL
      AND (
        assignments.state IN ('cancelled', 'unknown')
        OR (
          assignments.state IN ('completed', 'failed', 'superseded')
          AND EXISTS (
            SELECT 1 FROM task_board_remote_settlement_receipts AS receipt
            WHERE receipt.assignment_id = assignments.assignment_id
              AND receipt.fencing_epoch = assignments.fencing_epoch
          )
        )
      )
      AND (assignments.updated_at > ?1
           OR (assignments.updated_at = ?1 AND assignments.assignment_id > ?2))
    ORDER BY assignments.updated_at, assignments.assignment_id LIMIT ?3";

const TERMINAL_THROUGH: &str = "SELECT assignments.assignment_id, assignments.updated_at
    FROM task_board_remote_assignments AS assignments
    JOIN task_board_execution_hosts AS hosts ON hosts.host_id = assignments.host_id
    WHERE hosts.host_role = 'executor_self'
      AND assignments.legacy_migrated = 0
      AND assignments.target_host_instance_id IS NOT NULL
      AND assignments.cleanup_completed_at IS NULL
      AND (
        assignments.state IN ('cancelled', 'unknown')
        OR (
          assignments.state IN ('completed', 'failed', 'superseded')
          AND EXISTS (
            SELECT 1 FROM task_board_remote_settlement_receipts AS receipt
            WHERE receipt.assignment_id = assignments.assignment_id
              AND receipt.fencing_epoch = assignments.fencing_epoch
          )
        )
      )
      AND (assignments.updated_at < ?1
           OR (assignments.updated_at = ?1 AND assignments.assignment_id <= ?2))
    ORDER BY assignments.updated_at, assignments.assignment_id LIMIT ?3";
