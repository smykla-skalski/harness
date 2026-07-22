//! Deterministic no-run Start failure settlement: seals a self-verifying
//! Failed-at-Claimed failure receipt and atomically clears the exact Start-I/O
//! permit and start authority. Only a proven no-run (an unreachable Codex server,
//! verified by rereading `codex_runs`) may take this path; the provisioned session
//! is preserved for the later settlement-driven cleanup. The failure evidence
//! lives in the dedicated failure-receipt columns, never `result_json`, so the
//! execution-result column stays exclusive to runs that actually executed.

use sqlx::{query, query_scalar};

use super::super::remote_assignment_lease::{commit_noop, finish_mutation, require_assignment};
use super::super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome, concurrent, to_i64,
};
use super::super::remote_start_failure_receipts::{
    start_failure_receipt, start_failure_receipt_values,
};
use super::{TaskBoardRemoteExecutorStartIoPermit, executor_start_io_permit};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::RemoteStatusResponse;
use crate::task_board::TaskBoardFailureClass;

/// Canonical wire evidence for a failed fresh Codex endpoint preflight.
pub(crate) const REMOTE_START_PREFLIGHT_ERROR_CODE: &str = "CODEX001";
pub(crate) const REMOTE_START_PREFLIGHT_FAILURE_CLASS: TaskBoardFailureClass =
    TaskBoardFailureClass::Transient;

/// Canonical wire evidence for recovery after a durable Start-I/O permit was
/// committed but no deterministic run exists. This is distinct from a fresh
/// endpoint preflight: the recovery path performs no external Start.
pub(crate) const REMOTE_START_INTERRUPTED_WITHOUT_RUN_ERROR_CODE: &str =
    "remote_start_interrupted_without_run";
pub(crate) const REMOTE_START_INTERRUPTED_WITHOUT_RUN_FAILURE_CLASS: TaskBoardFailureClass =
    TaskBoardFailureClass::Transient;

impl AsyncDaemonDb {
    pub(crate) async fn fail_task_board_remote_executor_start_without_run(
        &self,
        permit: &TaskBoardRemoteExecutorStartIoPermit,
        response: &RemoteStatusResponse,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board remote executor Start failure")
            .await?;
        let record = require_assignment(&mut transaction, &permit.assignment_id).await?;
        if failed_at_claimed_replays(&record, response) {
            commit_noop(transaction, "replayed remote executor Start failure").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Replayed(record));
        }
        if record.executor_stop_pending.is_some()
            || executor_start_io_permit(&record)?.as_ref() != Some(permit)
        {
            commit_noop(transaction, "stale remote executor Start failure").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        let receipt = start_failure_receipt(&record, permit, response)?;
        let (receipt_json, receipt_sha256) = start_failure_receipt_values(&receipt)?;
        let run_exists =
            query_scalar::<_, bool>("SELECT EXISTS(SELECT 1 FROM codex_runs WHERE run_id = ?1)")
                .bind(&permit.identity.run_id)
                .fetch_one(transaction.as_mut())
                .await
                .map_err(|error| db_error(format!("reread Start-failure run: {error}")))?;
        if run_exists {
            return Err(concurrent(
                "remote executor Start failure observed a durable run",
            ));
        }
        let rows = query(
            "UPDATE task_board_remote_assignments
             SET state = 'failed', heartbeat_at = ?2, completed_at = ?2,
                 executor_start_failure_receipt_json = ?3,
                 executor_start_failure_receipt_sha256 = ?4, error = ?5,
                 executor_start_authority_sha256 = NULL,
                 executor_start_authority_at = NULL,
                 executor_start_io_permit_sha256 = NULL,
                 executor_start_io_permit_at = NULL, updated_at = ?2
             WHERE assignment_id = ?1 AND fencing_epoch = ?6 AND state = 'claimed'
               AND executor_start_io_permit_sha256 = ?7
               AND executor_start_io_permit_at = ?8
               AND executor_start_authority_sha256 = ?9
               AND executor_start_authority_at = ?10
               AND executor_start_receipt_sha256 IS NULL
               AND executor_start_failure_receipt_sha256 IS NULL
               AND executor_stop_pending_sha256 IS NULL
               AND result_json IS NULL AND status_sha256 IS NULL
               AND result_sha256 IS NULL
               AND NOT EXISTS(SELECT 1 FROM codex_runs WHERE run_id = ?11)",
        )
        .bind(&record.assignment_id)
        .bind(&response.observed_at)
        .bind(&receipt_json)
        .bind(&receipt_sha256)
        .bind(response.error_code.as_deref())
        .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
        .bind(&permit.sha256)
        .bind(&permit.permitted_at)
        .bind(&permit.authority.sha256)
        .bind(&permit.authority.acquired_at)
        .bind(&permit.identity.run_id)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("seal Failed-at-Claimed status: {error}")))?
        .rows_affected();
        if rows != 1 {
            return Err(concurrent("remote executor Start failure lost its fence"));
        }
        finish_mutation(transaction, &record.assignment_id, "executor Start failure").await
    }
}

/// A settled Failed-at-Claimed generation, matched byte-exactly on the durable
/// failure receipt and its derived status so a re-derived settlement replays
/// idempotently. `status_response` is derived from the receipt at load time, so a
/// matching response confirms the sealed receipt without re-reading its columns.
fn failed_at_claimed_replays(
    record: &TaskBoardRemoteAssignmentRecord,
    response: &RemoteStatusResponse,
) -> bool {
    record.state == crate::task_board::TaskBoardRemoteAssignmentState::Failed
        && record.start_receipt.is_none()
        && record.started_at.is_none()
        && record.executor_start_io_permit_sha256.is_none()
        && record.executor_start_authority_sha256.is_none()
        && record.executor_start_failure_receipt_sha256.is_some()
        && record.status_response.as_ref() == Some(response)
}
