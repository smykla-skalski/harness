use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::remote_assignment_controller_recovery::recover_controller_remote_assignment_in_tx;
use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, canonical_time, concurrent, load_assignment_in_tx, to_i64,
};
use super::remote_assignment_recovery_queue::{
    RawRecoveryCandidate, clear_recovery_quarantine_in_tx, due_assignment_page,
};
use super::remote_operation_trust::abandon_controller_operation_trust_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::TaskBoardRemoteAssignmentState;

#[derive(sqlx::FromRow)]
struct RecoveryRow {
    assignment_id: String,
    fencing_epoch: i64,
    state: String,
    host_role: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteRecoveryFailure {
    pub(crate) assignment_id: String,
    pub(crate) code: String,
    pub(crate) message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct TaskBoardRemoteRecoveryBatch {
    pub(crate) recovered: Vec<TaskBoardRemoteAssignmentRecord>,
    pub(crate) failures: Vec<TaskBoardRemoteRecoveryFailure>,
    pub(crate) incomplete: bool,
}

impl AsyncDaemonDb {
    pub(crate) async fn recover_task_board_remote_assignments(
        &self,
        now: &str,
    ) -> Result<TaskBoardRemoteRecoveryBatch, CliError> {
        canonical_time(now, "remote assignment recovery time")?;
        let (due, incomplete) = due_assignment_page(self, now).await?;
        let mut batch = TaskBoardRemoteRecoveryBatch {
            incomplete,
            ..TaskBoardRemoteRecoveryBatch::default()
        };
        for candidate in due {
            match Box::pin(self.recover_one_remote_assignment(&candidate, now)).await {
                Ok(Some(assignment)) => batch.recovered.push(assignment),
                Ok(None) => {}
                Err(error) => {
                    self.quarantine_remote_recovery_failure(&candidate, now, &error)
                        .await?;
                    batch.failures.push(TaskBoardRemoteRecoveryFailure {
                        assignment_id: candidate.assignment_id,
                        code: error.code().to_string(),
                        message: error.to_string(),
                    });
                }
            }
        }
        Ok(batch)
    }

    pub(crate) async fn task_board_remote_assignment_recovery_deadline(
        &self,
    ) -> Result<Option<String>, CliError> {
        const STATEMENT: &str =
            "SELECT MIN(CASE
                 WHEN quarantine.assignment_id IS NOT NULL
                   AND quarantine.fencing_epoch = assignments.fencing_epoch
                   AND quarantine.assignment_state = assignments.state
                   AND quarantine.assignment_updated_at = assignments.updated_at
                 THEN MAX(quarantine.next_attempt_at, CASE
                     WHEN assignments.state = 'unknown' THEN assignments.updated_at
                     WHEN assignments.lease_expires_at <= assignments.deadline_at
                       THEN assignments.lease_expires_at
                     ELSE assignments.deadline_at
                 END)
                 WHEN assignments.state = 'unknown' THEN assignments.updated_at
                 WHEN assignments.lease_expires_at <= assignments.deadline_at
                   THEN assignments.lease_expires_at
                 ELSE assignments.deadline_at
             END)
             FROM task_board_remote_assignments AS assignments
             JOIN task_board_execution_hosts AS hosts USING (host_id)
             LEFT JOIN task_board_workflow_executions AS executions
               ON executions.execution_id = assignments.execution_id
             LEFT JOIN task_board_remote_recovery_quarantine AS quarantine
               ON quarantine.assignment_id = assignments.assignment_id
             WHERE assignments.legacy_migrated = 0
               AND (
                 (assignments.state IN ('offered', 'claimed', 'started', 'running')
                  AND assignments.executor_start_authority_sha256 IS NULL
                  AND (hosts.host_role = 'controller_remote'
                       OR assignments.state IN ('offered', 'claimed')))
                 OR (assignments.state = 'unknown'
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
               )
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
                                          '$.resources.remote_cancel_intent_at') IS NOT NULL))";
        query_scalar(STATEMENT)
            .fetch_one(self.pool())
            .await
            .map_err(|error| db_error(format!("load remote assignment recovery deadline: {error}")))
    }

    pub(super) async fn recover_one_remote_assignment(
        &self,
        candidate: &RawRecoveryCandidate,
        now: &str,
    ) -> Result<Option<TaskBoardRemoteAssignmentRecord>, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("one task board remote assignment recovery")
            .await?;
        let Some(row) = due_assignment(&mut transaction, candidate, now).await? else {
            // The captured generation may have been replaced or quarantined after paging.
            // Never clear by assignment id until this transaction proves the exact snapshot.
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit no-op remote assignment recovery: {error}"))
            })?;
            return Ok(None);
        };
        let changed = match Box::pin(recover_one(&mut transaction, &row, now)).await {
            Ok(changed) => changed,
            Err(error) => {
                transaction.rollback().await.map_err(|rollback| {
                    db_error(format!(
                        "rollback failed remote recovery: {rollback}; {error}"
                    ))
                })?;
                return Err(error);
            }
        };
        if !changed {
            clear_recovery_quarantine_in_tx(&mut transaction, &candidate.assignment_id).await?;
            transaction.commit().await.map_err(|error| {
                db_error(format!(
                    "commit unchanged remote assignment recovery: {error}"
                ))
            })?;
            return Ok(None);
        }
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        clear_recovery_quarantine_in_tx(&mut transaction, &candidate.assignment_id).await?;
        let assignment = load_assignment_in_tx(&mut transaction, &candidate.assignment_id)
            .await?
            .ok_or_else(|| db_error("recovered remote assignment disappeared"))?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit one remote assignment recovery: {error}")))?;
        Ok(Some(assignment))
    }
}

async fn due_assignment(
    transaction: &mut Transaction<'_, Sqlite>,
    candidate: &RawRecoveryCandidate,
    now: &str,
) -> Result<Option<RecoveryRow>, CliError> {
    const STATEMENT: &str =
        "SELECT assignments.assignment_id, assignments.fencing_epoch,
                assignments.state, hosts.host_role
         FROM task_board_remote_assignments AS assignments
         JOIN task_board_execution_hosts AS hosts USING (host_id)
         LEFT JOIN task_board_workflow_executions AS executions
           ON executions.execution_id = assignments.execution_id
         LEFT JOIN task_board_remote_recovery_quarantine AS quarantine
           ON quarantine.assignment_id = assignments.assignment_id
         WHERE assignments.assignment_id = ?2
           AND assignments.legacy_migrated = 0
           AND assignments.fencing_epoch = ?3
           AND assignments.state = ?4
           AND assignments.updated_at = ?5
           AND assignments.request_sha256 IS ?6
           AND assignments.lease_id IS ?7
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
                                      '$.resources.remote_cancel_intent_at') IS NOT NULL))";
    query_as(STATEMENT)
        .bind(now)
        .bind(&candidate.assignment_id)
        .bind(candidate.fencing_epoch)
        .bind(&candidate.assignment_state)
        .bind(&candidate.assignment_updated_at)
        .bind(&candidate.request_sha256)
        .bind(&candidate.lease_id)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("reload recoverable remote assignment: {error}")))
}

async fn recover_one(
    transaction: &mut Transaction<'_, Sqlite>,
    row: &RecoveryRow,
    now: &str,
) -> Result<bool, CliError> {
    let state = TaskBoardRemoteAssignmentState::decode(&row.state)?;
    if state == TaskBoardRemoteAssignmentState::Unknown && row.host_role != "controller_remote" {
        return Ok(false);
    }
    if state == TaskBoardRemoteAssignmentState::Offered && row.host_role == "executor_self" {
        return supersede_unclaimed_host_offer(transaction, row, now).await;
    }
    if row.host_role == "executor_self"
        && matches!(
            state,
            TaskBoardRemoteAssignmentState::Started | TaskBoardRemoteAssignmentState::Running
        )
    {
        return Ok(false);
    }
    if row.host_role == "controller_remote" {
        let assignment = load_assignment_in_tx(transaction, &row.assignment_id)
            .await?
            .ok_or_else(|| db_error("recoverable controller assignment disappeared"))?;
        // Preserve an in-flight offer or renew token. A late accepted offer retains
        // the executor's immutable initial lease; a late renewal response retains the
        // executor's rotated lease and un-strands the observational Unknown via the
        // settlement-only renewal path (a validly-renewed live worker must not be
        // stranded to HumanRequired by a recovery race). Other operations recover to
        // an observational Unknown state and release their token before a later
        // exact-generation status probe.
        if assignment
            .controller_operation
            .as_ref()
            .is_some_and(|operation| operation.kind != "offer" && operation.kind != "renew")
        {
            abandon_controller_operation_trust_in_tx(transaction, &assignment).await?;
        }
        return Box::pin(recover_controller_remote_assignment_in_tx(
            transaction,
            &assignment,
            now,
        ))
        .await;
    }
    mark_outcome_unknown(transaction, row, now).await
}

async fn supersede_unclaimed_host_offer(
    transaction: &mut Transaction<'_, Sqlite>,
    row: &RecoveryRow,
    now: &str,
) -> Result<bool, CliError> {
    let rows = query(
        "UPDATE task_board_remote_assignments SET state = 'superseded',
         completed_at = ?2, error = 'remote offer expired before durable claim', updated_at = ?2
         WHERE assignment_id = ?1 AND fencing_epoch = ?3 AND state = 'offered'
           AND claimed_at IS NULL AND legacy_migrated = 0",
    )
    .bind(&row.assignment_id)
    .bind(now)
    .bind(to_i64(
        u64::try_from(row.fencing_epoch)
            .map_err(|_| db_error("remote recovery fencing epoch is out of range"))?,
        "remote recovery fencing epoch",
    )?)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("supersede expired host offer: {error}")))?
    .rows_affected();
    require_one(rows, "expired host offer recovery lost its fence")?;
    Ok(true)
}

async fn mark_outcome_unknown(
    transaction: &mut Transaction<'_, Sqlite>,
    row: &RecoveryRow,
    now: &str,
) -> Result<bool, CliError> {
    let rows = query(
        "UPDATE task_board_remote_assignments SET state = 'unknown',
         error = 'remote assignment outcome is unknown after lease or deadline expiry',
         updated_at = ?2 WHERE assignment_id = ?1 AND fencing_epoch = ?3
           AND state IN ('offered', 'claimed', 'started', 'running')
           AND executor_start_authority_sha256 IS NULL AND legacy_migrated = 0",
    )
    .bind(&row.assignment_id)
    .bind(now)
    .bind(row.fencing_epoch)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("mark expired assignment unknown: {error}")))?
    .rows_affected();
    require_one(rows, "remote assignment recovery lost its fence")?;
    Ok(true)
}

fn require_one(rows: u64, message: &'static str) -> Result<(), CliError> {
    if rows == 1 {
        Ok(())
    } else {
        Err(concurrent(message))
    }
}
