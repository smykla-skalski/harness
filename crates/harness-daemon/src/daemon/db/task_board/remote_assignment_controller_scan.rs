use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};

use super::remote_assignment_model::{TaskBoardRemoteAssignmentRecord, canonical_time};
use super::remote_assignment_recovery_queue::{
    CONTROLLER_PROGRESSION_QUARANTINE_CODE, RawRecoveryCandidate,
    quarantine_remote_recovery_failure_in_tx,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};

#[path = "remote_assignment_controller_scan/sql.rs"]
mod sql;
use sql::SCAN_CYCLE_MAX;

mod cursor;
use cursor::{
    clear_cycle, clear_named_cursor, load_named_cursor, load_scan_row, require_pending_cursor,
    scan_error, select_cycle_page, store_named_cursor,
};

const CONTROLLER_QUEUE: &str = "task_board_remote_controller";
const CONTROLLER_CYCLE_END_QUEUE: &str = "task_board_remote_controller_cycle_end";
const CONTROLLER_PENDING_QUEUE: &str = "task_board_remote_controller_pending";

#[derive(Debug)]
pub(crate) struct TaskBoardRemoteControllerScanItem {
    pub(crate) assignment: TaskBoardRemoteAssignmentRecord,
    cursor: ScanRow,
}

#[derive(Debug)]
pub(crate) struct TaskBoardRemoteControllerScanFailure {
    pub(crate) assignment_id: String,
    pub(crate) code: String,
    pub(crate) message: String,
    pub(crate) scan_incomplete: bool,
}

#[derive(Debug)]
pub(crate) enum TaskBoardRemoteControllerScanStep {
    Assignment(Box<TaskBoardRemoteControllerScanItem>),
    Quarantined(TaskBoardRemoteControllerScanFailure),
}

#[derive(Debug, Clone, PartialEq, Eq, sqlx::FromRow)]
struct ScanRow {
    assignment_id: String,
    // `offered_at` is immutable; lifecycle `updated_at` cannot move an
    // unvisited generation beyond a captured scan cycle.
    order_at: String,
    fencing_epoch: i64,
    assignment_state: String,
    assignment_updated_at: String,
    request_sha256: Option<String>,
    lease_id: Option<String>,
}

impl AsyncDaemonDb {
    /// Claims one restart-replayable controller generation for remote verification.
    pub(crate) async fn next_task_board_remote_controller_assignment(
        &self,
        now: &str,
    ) -> Result<Option<TaskBoardRemoteControllerScanStep>, CliError> {
        canonical_time(now, "remote controller scan time")?;
        let Some(cursor) = self.claim_next_controller_scan_cursor(now).await? else {
            return Ok(None);
        };
        match self
            .task_board_remote_assignment(&cursor.assignment_id)
            .await
        {
            Ok(Some(assignment)) if assignment.offered_at == cursor.order_at => {
                Ok(Some(TaskBoardRemoteControllerScanStep::Assignment(
                    Box::new(TaskBoardRemoteControllerScanItem { assignment, cursor }),
                )))
            }
            Ok(Some(_)) => self
                .quarantine_controller_scan_decode(
                    cursor,
                    now,
                    db_error("remote controller scan cursor contradicts immutable offer time"),
                )
                .await
                .map(Some),
            Ok(None) => self
                .quarantine_controller_scan_decode(
                    cursor,
                    now,
                    db_error("scanned remote controller assignment disappeared"),
                )
                .await
                .map(Some),
            Err(error) => self
                .quarantine_controller_scan_decode(cursor, now, error)
                .await
                .map(Some),
        }
    }

    async fn claim_next_controller_scan_cursor(
        &self,
        now: &str,
    ) -> Result<Option<ScanRow>, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("remote controller assignment scan")
            .await?;
        let cursor = next_scan_item_in_tx(&mut transaction, now).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit remote controller assignment scan: {error}"))
        })?;
        Ok(cursor)
    }

    /// Acknowledges one attempted controller generation and advances the durable cycle.
    pub(crate) async fn complete_task_board_remote_controller_assignment_scan(
        &self,
        item: &TaskBoardRemoteControllerScanItem,
        now: &str,
    ) -> Result<bool, CliError> {
        canonical_time(now, "remote controller scan completion time")?;
        let mut transaction = self
            .begin_immediate_transaction("remote controller assignment scan completion")
            .await?;
        let incomplete = complete_scan_item_in_tx(&mut transaction, &item.cursor, now).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit remote controller scan completion: {error}"))
        })?;
        Ok(incomplete)
    }

    pub(crate) async fn clear_task_board_remote_controller_progression_quarantine(
        &self,
        item: &TaskBoardRemoteControllerScanItem,
    ) -> Result<(), CliError> {
        query(
            "DELETE FROM task_board_remote_recovery_quarantine
             WHERE assignment_id = ?1 AND fencing_epoch = ?2
               AND assignment_state = ?3 AND assignment_updated_at = ?4",
        )
        .bind(&item.cursor.assignment_id)
        .bind(item.cursor.fencing_epoch)
        .bind(&item.cursor.assignment_state)
        .bind(&item.cursor.assignment_updated_at)
        .execute(self.pool())
        .await
        .map(|_| ())
        .map_err(|error| db_error(format!("clear remote controller quarantine: {error}")))
    }

    /// Defers one exact generation after a transient controller operation fails.
    ///
    /// The quarantine snapshot prevents the failed row from monopolizing the
    /// finite scan cycle, while the foreground caller remains fail-closed.
    pub(crate) async fn defer_task_board_remote_controller_assignment_scan(
        &self,
        item: &TaskBoardRemoteControllerScanItem,
        now: &str,
    ) -> Result<bool, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("remote controller progression deferral")
            .await?;
        quarantine_remote_recovery_failure_in_tx(
            &mut transaction,
            &item.cursor.recovery_candidate(),
            now,
            CONTROLLER_PROGRESSION_QUARANTINE_CODE,
        )
        .await?;
        let incomplete = complete_scan_item_in_tx(&mut transaction, &item.cursor, now).await?;
        transaction.commit().await.map_err(|commit_error| {
            db_error(format!(
                "commit remote controller progression deferral: {commit_error}"
            ))
        })?;
        Ok(incomplete)
    }

    pub(crate) async fn task_board_remote_controller_progression_is_blocked(
        &self,
    ) -> Result<bool, CliError> {
        query_scalar(
            "SELECT EXISTS (
                 SELECT 1
                 FROM task_board_remote_recovery_quarantine AS quarantine
                 JOIN task_board_remote_assignments AS assignment
                   ON assignment.assignment_id = quarantine.assignment_id
                 JOIN task_board_execution_hosts AS host
                   ON host.host_id = assignment.host_id
                 WHERE quarantine.last_error_code = ?1
                   AND quarantine.fencing_epoch = assignment.fencing_epoch
                   AND quarantine.assignment_state = assignment.state
                   AND quarantine.assignment_updated_at = assignment.updated_at
                   AND host.host_role = 'controller_remote'
                   AND assignment.legacy_migrated = 0
                   AND NOT (
                       assignment.controller_handoff_kind IN (
                           'local_fallback', 'result_adopted', 'evidence_only',
                           'terminal_projection', 'terminal_cleanup'
                       )
                       AND length(assignment.controller_handoff_execution_sha256) = 64
                       AND assignment.controller_handoff_execution_sha256
                           NOT GLOB '*[^0-9a-f]*'
                       AND length(trim(assignment.controller_handoff_at)) > 0
                       AND assignment.controller_handoff_successor_assignment_id IS NULL
                       AND assignment.controller_handoff_successor_fencing_epoch IS NULL
                       AND (
                           -- A resolved local fallback advanced the parent to a local
                           -- attempt; it is settled and must not block local progression.
                           (assignment.controller_handoff_kind = 'local_fallback'
                            AND assignment.state = 'superseded')
                           OR (assignment.controller_handoff_kind = 'result_adopted'
                            AND assignment.state IN ('completed', 'failed'))
                           OR (assignment.controller_handoff_kind = 'evidence_only'
                               AND assignment.state IN (
                                   'completed', 'failed', 'cancelled', 'unknown'
                               ))
                           OR (assignment.controller_handoff_kind = 'terminal_projection'
                               AND assignment.state IN ('completed', 'failed', 'cancelled'))
                           OR (assignment.controller_handoff_kind = 'terminal_cleanup'
                               AND assignment.state IN (
                                   'completed', 'failed', 'cancelled', 'superseded', 'unknown'
                               ))
                       )
                   )
                   AND (
                       assignment.state IN ('offered', 'claimed', 'started', 'running')
                       OR (assignment.state IN ('completed', 'failed', 'cancelled', 'unknown')
                           AND assignment.cleanup_completed_at IS NULL)
                       OR (assignment.state = 'superseded' AND assignment.lease_id IS NOT NULL
                           AND assignment.cleanup_completed_at IS NULL)
                   )
             )",
        )
        .bind(CONTROLLER_PROGRESSION_QUARANTINE_CODE)
        .fetch_one(self.pool())
        .await
        .map_err(|query_error| {
            db_error(format!(
                "load unresolved remote controller progression: {query_error}"
            ))
        })
    }

    async fn quarantine_controller_scan_decode(
        &self,
        cursor: ScanRow,
        now: &str,
        error: CliError,
    ) -> Result<TaskBoardRemoteControllerScanStep, CliError> {
        self.quarantine_remote_recovery_failure(&cursor.recovery_candidate(), now, &error)
            .await?;
        let mut transaction = self
            .begin_immediate_transaction("remote controller decode failure completion")
            .await?;
        let scan_incomplete = complete_scan_item_in_tx(&mut transaction, &cursor, now).await?;
        transaction.commit().await.map_err(|commit_error| {
            db_error(format!(
                "commit remote controller decode quarantine: {commit_error}"
            ))
        })?;
        Ok(TaskBoardRemoteControllerScanStep::Quarantined(
            TaskBoardRemoteControllerScanFailure {
                assignment_id: cursor.assignment_id,
                code: error.code().to_owned(),
                message: error.to_string(),
                scan_incomplete,
            },
        ))
    }
}

impl ScanRow {
    fn cursor_only(assignment_id: String, order_at: String) -> Self {
        Self {
            assignment_id,
            order_at,
            fencing_epoch: -1,
            assignment_state: String::new(),
            assignment_updated_at: String::new(),
            request_sha256: None,
            lease_id: None,
        }
    }

    fn recovery_candidate(&self) -> RawRecoveryCandidate {
        RawRecoveryCandidate {
            assignment_id: self.assignment_id.clone(),
            fencing_epoch: self.fencing_epoch,
            assignment_state: self.assignment_state.clone(),
            assignment_updated_at: self.assignment_updated_at.clone(),
            request_sha256: self.request_sha256.clone(),
            lease_id: self.lease_id.clone(),
        }
    }
}

async fn advance_pending_cursor_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    cursor: &ScanRow,
) -> Result<(), CliError> {
    require_pending_cursor(transaction, cursor).await?;
    store_named_cursor(transaction, CONTROLLER_QUEUE, cursor).await?;
    clear_named_cursor(transaction, CONTROLLER_PENDING_QUEUE).await?;
    Ok(())
}

async fn complete_scan_item_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    cursor: &ScanRow,
    now: &str,
) -> Result<bool, CliError> {
    advance_pending_cursor_in_tx(transaction, cursor).await?;
    let boundary = load_cycle_boundary_in_tx(transaction).await?;
    let acknowledged = (cursor.order_at.clone(), cursor.assignment_id.clone());
    let incomplete = !select_cycle_page(transaction, now, Some(&acknowledged), &boundary, 1)
        .await?
        .is_empty();
    if !incomplete {
        clear_cycle(transaction).await?;
    }
    Ok(incomplete)
}

async fn load_cycle_boundary_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<ScanRow, CliError> {
    let (order_at, assignment_id) = load_named_cursor(transaction, CONTROLLER_CYCLE_END_QUEUE)
        .await?
        .ok_or_else(|| db_error("remote controller scan cycle boundary disappeared"))?;
    Ok(ScanRow {
        assignment_id,
        order_at,
        ..ScanRow::cursor_only(String::new(), String::new())
    })
}

async fn next_scan_item_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    now: &str,
) -> Result<Option<ScanRow>, CliError> {
    let Some(boundary) = load_or_start_cycle(transaction, now).await? else {
        return Ok(None);
    };
    if let Some((order_at, assignment_id)) =
        load_named_cursor(transaction, CONTROLLER_PENDING_QUEUE).await?
    {
        return resume_pending_scan_row_in_tx(transaction, order_at, assignment_id)
            .await
            .map(Some);
    }
    claim_next_cycle_page_in_tx(transaction, now, &boundary).await
}

async fn resume_pending_scan_row_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    order_at: String,
    assignment_id: String,
) -> Result<ScanRow, CliError> {
    let row = load_scan_row(transaction, &assignment_id, &order_at).await?;
    Ok(row.unwrap_or_else(|| ScanRow::cursor_only(assignment_id, order_at)))
}

async fn claim_next_cycle_page_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    now: &str,
    boundary: &ScanRow,
) -> Result<Option<ScanRow>, CliError> {
    let cursor = load_named_cursor(transaction, CONTROLLER_QUEUE).await?;
    let next = select_cycle_page(transaction, now, cursor.as_ref(), boundary, 1)
        .await?
        .into_iter()
        .next();
    if let Some(next) = next.as_ref() {
        store_named_cursor(transaction, CONTROLLER_PENDING_QUEUE, next).await?;
    } else {
        clear_cycle(transaction).await?;
    }
    Ok(next)
}

async fn load_or_start_cycle(
    transaction: &mut Transaction<'_, Sqlite>,
    now: &str,
) -> Result<Option<ScanRow>, CliError> {
    let Some((updated_at, assignment_id)) =
        load_named_cursor(transaction, CONTROLLER_CYCLE_END_QUEUE).await?
    else {
        return load_or_start_new_cycle(transaction, now).await;
    };
    Ok(Some(ScanRow {
        assignment_id,
        order_at: updated_at,
        ..ScanRow::cursor_only(String::new(), String::new())
    }))
}

async fn load_or_start_new_cycle(
    transaction: &mut Transaction<'_, Sqlite>,
    now: &str,
) -> Result<Option<ScanRow>, CliError> {
    let boundary = query_as::<_, ScanRow>(SCAN_CYCLE_MAX)
        .bind(now)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| scan_error(&error))?;
    clear_named_cursor(transaction, CONTROLLER_QUEUE).await?;
    clear_named_cursor(transaction, CONTROLLER_PENDING_QUEUE).await?;
    if let Some(boundary) = boundary.as_ref() {
        store_named_cursor(transaction, CONTROLLER_CYCLE_END_QUEUE, boundary).await?;
    }
    Ok(boundary)
}

#[cfg(test)]
#[path = "remote_assignment_controller_scan_cycle_tests.rs"]
mod cycle_tests;
