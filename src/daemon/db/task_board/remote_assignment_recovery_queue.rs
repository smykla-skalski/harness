use chrono::{Duration, SecondsFormat};
use sha2::{Digest, Sha256};
use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};

use super::remote_assignment_model::canonical_time;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};

const RECOVERY_QUEUE: &str = "task_board_remote_assignments";
const RECOVERY_BATCH_LIMIT: usize = 128;
pub(super) const CONTROLLER_PROGRESSION_QUARANTINE_CODE: &str = "controller_progression";

// The source-recovery-owned-offer and cancel-intent-owned predicates are inlined
// into these full static queries (and duplicated across the recovery module) so that
// every remote query is a fully audited &'static str with no runtime format!-built SQL.
// The two variants differ only in the cursor comparison operator, matching the merged
// SELECT_AFTER_CURSOR / SELECT_THROUGH_CURSOR convention.
const DUE_PAGE_AFTER_CURSOR: &str =
    "SELECT assignments.assignment_id, assignments.fencing_epoch,
            assignments.state AS assignment_state,
            assignments.updated_at AS assignment_updated_at,
            assignments.request_sha256, assignments.lease_id
     FROM task_board_remote_assignments AS assignments
     JOIN task_board_execution_hosts AS hosts USING (host_id)
     LEFT JOIN task_board_workflow_executions AS executions
       ON executions.execution_id = assignments.execution_id
     LEFT JOIN task_board_remote_recovery_quarantine AS quarantine
       ON quarantine.assignment_id = assignments.assignment_id
     WHERE assignments.assignment_id > ?2
       AND assignments.legacy_migrated = 0
       AND (quarantine.assignment_id IS NULL
            OR quarantine.fencing_epoch != assignments.fencing_epoch
            OR quarantine.assignment_state != assignments.state
            OR quarantine.assignment_updated_at != assignments.updated_at
            OR quarantine.next_attempt_at <= ?1)
       AND ((assignments.state = 'unknown'
            AND hosts.host_role = 'controller_remote'
            AND (executions.execution_id IS NULL
                 OR executions.state != 'human_required'
                 OR executions.blocked_reason IS NOT 'remote_assignment_outcome_unknown'
                 OR json_extract(executions.resource_ownership_json,
                                 '$.resources.remote_offer_io_authority') IS NOT NULL
                 OR json_extract(executions.resource_ownership_json,
                                 '$.resources.remote_claim_io_authority') IS NOT NULL
                 OR json_extract(executions.resource_ownership_json,
                                 '$.resources.remote_renew_io_authority') IS NOT NULL
                 OR json_extract(executions.resource_ownership_json,
                                 '$.resources.remote_cancel_io_authority') IS NOT NULL))
        OR (assignments.state IN ('offered', 'claimed', 'started', 'running')
            AND assignments.executor_start_authority_sha256 IS NULL
            AND (hosts.host_role = 'controller_remote'
                 OR assignments.state IN ('offered', 'claimed'))
            AND (assignments.lease_expires_at <= ?1
                 OR assignments.deadline_at <= ?1)))
       AND NOT (assignments.state = 'offered'
                AND assignments.lease_id IS NULL
                AND assignments.claim_receipt_sha256 IS NULL
                AND assignments.claimed_at IS NULL
                AND assignments.started_at IS NULL
                AND assignments.workspace_ref IS NULL
                AND assignments.controller_handoff_kind IS NULL
                AND (assignments.controller_operation_kind IS NULL
                     OR assignments.controller_operation_kind IN ('upload_source_bundle', 'offer'))
                AND EXISTS (
                  SELECT 1 FROM task_board_remote_outbound_sources AS source
                  WHERE source.assignment_id = assignments.assignment_id
                    AND source.fencing_epoch = assignments.fencing_epoch
                    AND source.offer_request_sha256 = assignments.request_sha256
                    AND source.source_kind IN ('prior_phase_bundle', 'repository_snapshot_bundle')
                    AND source.content_pruned_at IS NULL
                    AND length(source.content) = source.size_bytes
                )
                AND NOT EXISTS (
                  SELECT 1 FROM task_board_remote_offer_receipts AS receipt
                  WHERE receipt.assignment_id = assignments.assignment_id
                    AND receipt.fencing_epoch = assignments.fencing_epoch
                    AND receipt.request_sha256 = assignments.request_sha256
                ))
       AND NOT (executions.execution_id IS NOT NULL
                AND executions.fencing_epoch = assignments.fencing_epoch
                AND executions.host_id = assignments.host_id
                AND json_extract(executions.resource_ownership_json,
                                 '$.resources.execution_target') = 'remote:' || assignments.assignment_id
                AND (json_type(executions.resource_ownership_json,
                               '$.resources.remote_cancel_intent') IS NOT NULL
                     OR json_type(executions.resource_ownership_json,
                                  '$.resources.remote_cancel_intent_reason') IS NOT NULL
                     OR json_type(executions.resource_ownership_json,
                                  '$.resources.remote_cancel_intent_at') IS NOT NULL))
     ORDER BY assignments.assignment_id
     LIMIT ?3";

const DUE_PAGE_THROUGH_CURSOR: &str =
    "SELECT assignments.assignment_id, assignments.fencing_epoch,
            assignments.state AS assignment_state,
            assignments.updated_at AS assignment_updated_at,
            assignments.request_sha256, assignments.lease_id
     FROM task_board_remote_assignments AS assignments
     JOIN task_board_execution_hosts AS hosts USING (host_id)
     LEFT JOIN task_board_workflow_executions AS executions
       ON executions.execution_id = assignments.execution_id
     LEFT JOIN task_board_remote_recovery_quarantine AS quarantine
       ON quarantine.assignment_id = assignments.assignment_id
     WHERE assignments.assignment_id <= ?2
       AND assignments.legacy_migrated = 0
       AND (quarantine.assignment_id IS NULL
            OR quarantine.fencing_epoch != assignments.fencing_epoch
            OR quarantine.assignment_state != assignments.state
            OR quarantine.assignment_updated_at != assignments.updated_at
            OR quarantine.next_attempt_at <= ?1)
       AND ((assignments.state = 'unknown'
            AND hosts.host_role = 'controller_remote'
            AND (executions.execution_id IS NULL
                 OR executions.state != 'human_required'
                 OR executions.blocked_reason IS NOT 'remote_assignment_outcome_unknown'
                 OR json_extract(executions.resource_ownership_json,
                                 '$.resources.remote_offer_io_authority') IS NOT NULL
                 OR json_extract(executions.resource_ownership_json,
                                 '$.resources.remote_claim_io_authority') IS NOT NULL
                 OR json_extract(executions.resource_ownership_json,
                                 '$.resources.remote_renew_io_authority') IS NOT NULL
                 OR json_extract(executions.resource_ownership_json,
                                 '$.resources.remote_cancel_io_authority') IS NOT NULL))
        OR (assignments.state IN ('offered', 'claimed', 'started', 'running')
            AND assignments.executor_start_authority_sha256 IS NULL
            AND (hosts.host_role = 'controller_remote'
                 OR assignments.state IN ('offered', 'claimed'))
            AND (assignments.lease_expires_at <= ?1
                 OR assignments.deadline_at <= ?1)))
       AND NOT (assignments.state = 'offered'
                AND assignments.lease_id IS NULL
                AND assignments.claim_receipt_sha256 IS NULL
                AND assignments.claimed_at IS NULL
                AND assignments.started_at IS NULL
                AND assignments.workspace_ref IS NULL
                AND assignments.controller_handoff_kind IS NULL
                AND (assignments.controller_operation_kind IS NULL
                     OR assignments.controller_operation_kind IN ('upload_source_bundle', 'offer'))
                AND EXISTS (
                  SELECT 1 FROM task_board_remote_outbound_sources AS source
                  WHERE source.assignment_id = assignments.assignment_id
                    AND source.fencing_epoch = assignments.fencing_epoch
                    AND source.offer_request_sha256 = assignments.request_sha256
                    AND source.source_kind IN ('prior_phase_bundle', 'repository_snapshot_bundle')
                    AND source.content_pruned_at IS NULL
                    AND length(source.content) = source.size_bytes
                )
                AND NOT EXISTS (
                  SELECT 1 FROM task_board_remote_offer_receipts AS receipt
                  WHERE receipt.assignment_id = assignments.assignment_id
                    AND receipt.fencing_epoch = assignments.fencing_epoch
                    AND receipt.request_sha256 = assignments.request_sha256
                ))
       AND NOT (executions.execution_id IS NOT NULL
                AND executions.fencing_epoch = assignments.fencing_epoch
                AND executions.host_id = assignments.host_id
                AND json_extract(executions.resource_ownership_json,
                                 '$.resources.execution_target') = 'remote:' || assignments.assignment_id
                AND (json_type(executions.resource_ownership_json,
                               '$.resources.remote_cancel_intent') IS NOT NULL
                     OR json_type(executions.resource_ownership_json,
                                  '$.resources.remote_cancel_intent_reason') IS NOT NULL
                     OR json_type(executions.resource_ownership_json,
                                  '$.resources.remote_cancel_intent_at') IS NOT NULL))
     ORDER BY assignments.assignment_id
     LIMIT ?3";

#[derive(Debug, Clone, sqlx::FromRow)]
pub(super) struct RawRecoveryCandidate {
    pub(super) assignment_id: String,
    pub(super) fencing_epoch: i64,
    pub(super) assignment_state: String,
    pub(super) assignment_updated_at: String,
    pub(super) request_sha256: Option<String>,
    pub(super) lease_id: Option<String>,
}

impl AsyncDaemonDb {
    pub(super) async fn quarantine_remote_recovery_failure(
        &self,
        candidate: &RawRecoveryCandidate,
        now: &str,
        error: &CliError,
    ) -> Result<(), CliError> {
        let mut transaction = self
            .begin_immediate_transaction("remote recovery quarantine")
            .await?;
        quarantine_remote_recovery_failure_in_tx(
            &mut transaction,
            candidate,
            now,
            error.code(),
        )
        .await?;
        transaction.commit().await.map_err(|commit_error| {
            db_error(format!("commit remote recovery quarantine: {commit_error}"))
        })
    }
}

pub(super) async fn quarantine_remote_recovery_failure_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    candidate: &RawRecoveryCandidate,
    now: &str,
    error_code: &str,
) -> Result<(), CliError> {
    let prior = query_as::<_, (i64, String, String, i64)>(
        "SELECT fencing_epoch, assignment_state, assignment_updated_at, failure_count
         FROM task_board_remote_recovery_quarantine WHERE assignment_id = ?1",
    )
    .bind(&candidate.assignment_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|query_error| db_error(format!("load remote recovery quarantine: {query_error}")))?;
    let same_generation = prior.as_ref().is_some_and(|(epoch, state, updated_at, _)| {
        *epoch == candidate.fencing_epoch
            && state == &candidate.assignment_state
            && updated_at == &candidate.assignment_updated_at
    });
    let failure_count = if same_generation {
        prior
            .as_ref()
            .and_then(|(_, _, _, count)| count.checked_add(1))
            .unwrap_or(i64::MAX)
    } else {
        1
    };
    let exponent = u32::try_from(failure_count.saturating_sub(1).min(6))
        .map_err(|_| db_error("remote recovery backoff exponent is out of range"))?;
    let delay_seconds = 5_i64
        .checked_mul(1_i64 << exponent)
        .ok_or_else(|| db_error("remote recovery backoff is out of range"))?;
    let next_attempt_at = (canonical_time(now, "remote recovery quarantine time")?
        + Duration::seconds(delay_seconds))
    .to_rfc3339_opts(SecondsFormat::AutoSi, true);
    query(
        "INSERT INTO task_board_remote_recovery_quarantine (
             assignment_id, fencing_epoch, assignment_state, assignment_updated_at,
             state_fingerprint, failure_count, next_attempt_at, last_error_code, updated_at
         )
         SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9
         WHERE EXISTS (
             SELECT 1 FROM task_board_remote_assignments AS assignment
             WHERE assignment.assignment_id = ?1
               AND assignment.fencing_epoch = ?2
               AND assignment.state = ?3
               AND assignment.updated_at = ?4
               AND assignment.request_sha256 IS ?10
               AND assignment.lease_id IS ?11
               AND assignment.legacy_migrated = 0
         )
         ON CONFLICT(assignment_id) DO UPDATE SET
             fencing_epoch = excluded.fencing_epoch,
             assignment_state = excluded.assignment_state,
             assignment_updated_at = excluded.assignment_updated_at,
             state_fingerprint = excluded.state_fingerprint,
             failure_count = excluded.failure_count,
             next_attempt_at = excluded.next_attempt_at,
             last_error_code = excluded.last_error_code,
             updated_at = excluded.updated_at",
    )
    .bind(&candidate.assignment_id)
    .bind(candidate.fencing_epoch)
    .bind(&candidate.assignment_state)
    .bind(&candidate.assignment_updated_at)
    .bind(recovery_fingerprint(candidate))
    .bind(failure_count)
    .bind(next_attempt_at)
    .bind(error_code)
    .bind(now)
    .bind(&candidate.request_sha256)
    .bind(&candidate.lease_id)
    .execute(transaction.as_mut())
    .await
    .map(|_| ())
    .map_err(|query_error| db_error(format!("persist remote recovery quarantine: {query_error}")))
}

pub(super) async fn clear_recovery_quarantine_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment_id: &str,
) -> Result<(), CliError> {
    query("DELETE FROM task_board_remote_recovery_quarantine WHERE assignment_id = ?1")
        .bind(assignment_id)
        .execute(transaction.as_mut())
        .await
        .map(|_| ())
        .map_err(|error| db_error(format!("clear remote recovery quarantine: {error}")))
}

pub(super) async fn due_assignment_page(
    db: &AsyncDaemonDb,
    now: &str,
) -> Result<(Vec<RawRecoveryCandidate>, bool), CliError> {
    let mut transaction = db
        .begin_immediate_transaction("remote assignment recovery page")
        .await?;
    let cursor = query_scalar::<_, String>(
        "SELECT sort_execution_id FROM task_board_reconciliation_cursors
         WHERE queue = ?1",
    )
    .bind(RECOVERY_QUEUE)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load remote recovery cursor: {error}")))?;
    let sql_limit = i64::try_from(RECOVERY_BATCH_LIMIT + 1)
        .map_err(|_| db_error("remote recovery page limit is out of range"))?;
    let mut due = select_due_assignment_page(
        &mut transaction,
        now,
        cursor.as_deref().unwrap_or(""),
        sql_limit,
        false,
    )
    .await?;
    if let Some(cursor) = cursor.as_deref()
        && due.len() < RECOVERY_BATCH_LIMIT + 1
    {
        let remaining = i64::try_from(RECOVERY_BATCH_LIMIT + 1 - due.len())
            .map_err(|_| db_error("remote recovery wrap limit is out of range"))?;
        let mut wrapped =
            select_due_assignment_page(&mut transaction, now, cursor, remaining, true).await?;
        due.append(&mut wrapped);
    }
    let incomplete = due.len() > RECOVERY_BATCH_LIMIT;
    due.truncate(RECOVERY_BATCH_LIMIT);
    let scanned_last = due.last().cloned();
    if let Some(last) = scanned_last {
        query(
            "INSERT INTO task_board_reconciliation_cursors (
                 queue, sort_updated_at, sort_execution_id
             ) VALUES (?1, ?2, ?3)
             ON CONFLICT(queue) DO UPDATE SET
                 sort_updated_at = excluded.sort_updated_at,
                 sort_execution_id = excluded.sort_execution_id",
        )
        .bind(RECOVERY_QUEUE)
        .bind(now)
        .bind(last.assignment_id)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("store remote recovery cursor: {error}")))?;
    }
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit remote recovery page: {error}")))?;
    Ok((due, incomplete))
}

async fn select_due_assignment_page(
    transaction: &mut Transaction<'_, Sqlite>,
    now: &str,
    cursor: &str,
    limit: i64,
    through_cursor: bool,
) -> Result<Vec<RawRecoveryCandidate>, CliError> {
    let statement = if through_cursor {
        DUE_PAGE_THROUGH_CURSOR
    } else {
        DUE_PAGE_AFTER_CURSOR
    };
    query_as(statement)
        .bind(now)
        .bind(cursor)
        .bind(limit)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("select remote recovery page: {error}")))
}

fn recovery_fingerprint(candidate: &RawRecoveryCandidate) -> String {
    let encoded = format!(
        "{}\0{}\0{}\0{}\0{}",
        candidate.fencing_epoch,
        candidate.assignment_state,
        candidate.assignment_updated_at,
        candidate.request_sha256.as_deref().unwrap_or_default(),
        candidate.lease_id.as_deref().unwrap_or_default(),
    );
    hex::encode(Sha256::digest(encoded.as_bytes()))
}
