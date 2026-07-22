//! Durable executor stop-only authority for invalid remote Codex runs.

use sqlx::query;

mod authority;
mod evidence;
mod pending;

use authority::{authority_assignment_id, source_matches};
use evidence::{durable_run_matches_snapshot, durable_stopped_run_matches, settled_stop_replays};
use pending::{stop_pending, stop_pending_values, stop_request_replays};

pub(crate) use authority::{
    TaskBoardRemoteExecutorStopAuthority, TaskBoardRemoteExecutorStopReason,
};
pub(crate) use pending::{TaskBoardRemoteExecutorStopPending, stop_pending_snapshot_matches};
pub(super) use pending::{decode_executor_stop_pending, stop_pending_digest};

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::remote_assignment_lease::{commit_noop, finish_mutation, require_assignment};
use super::remote_assignment_model::{
    TaskBoardRemoteMutationOutcome, canonical_time, concurrent, to_i64,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::protocol::CodexRunSnapshot;

impl AsyncDaemonDb {
    pub(crate) async fn claim_task_board_remote_executor_stop_pending(
        &self,
        authority: &TaskBoardRemoteExecutorStopAuthority,
        snapshot: &CodexRunSnapshot,
        reason: TaskBoardRemoteExecutorStopReason,
        acquired_at: &str,
    ) -> Result<Option<TaskBoardRemoteExecutorStopPending>, CliError> {
        canonical_time(acquired_at, "remote executor stop authority time")?;
        let assignment_id = authority_assignment_id(authority);
        let mut transaction = self
            .begin_immediate_transaction("task board remote executor stop authority")
            .await?;
        let record = require_assignment(&mut transaction, assignment_id).await?;
        if let Some(current) = record.executor_stop_pending.as_ref() {
            if stop_request_replays(current, authority, snapshot, reason) {
                let replay = current.clone();
                commit_noop(transaction, "replayed remote executor stop authority").await?;
                return Ok(Some(replay));
            }
            return Err(concurrent(
                "remote executor stop authority conflicts with durable intent",
            ));
        }
        if !source_matches(&record, authority, reason)?
            || !durable_run_matches_snapshot(&mut transaction, &record, snapshot).await?
        {
            commit_noop(transaction, "stale remote executor stop authority").await?;
            return Ok(None);
        }
        let pending = stop_pending(&record, authority, snapshot, reason, acquired_at)?;
        let (json, sha256) = stop_pending_values(&pending)?;
        let rows = query(
            "UPDATE task_board_remote_assignments
             SET executor_stop_pending_json = ?2, executor_stop_pending_sha256 = ?3,
                 updated_at = ?4
             WHERE assignment_id = ?1 AND fencing_epoch = ?5
               AND executor_stop_pending_json IS NULL
               AND executor_stop_pending_sha256 IS NULL",
        )
        .bind(&record.assignment_id)
        .bind(json)
        .bind(sha256)
        .bind(acquired_at)
        .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("claim remote executor stop authority: {error}")))?
        .rows_affected();
        if rows != 1 {
            return Err(concurrent("remote executor stop authority lost its fence"));
        }
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote executor stop authority: {error}")))?;
        Ok(Some(pending))
    }

    pub(crate) async fn settle_task_board_remote_executor_stop_pending(
        &self,
        pending: &TaskBoardRemoteExecutorStopPending,
        observed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        canonical_time(observed_at, "remote executor stop settlement time")?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote executor stop settlement")
            .await?;
        let record = require_assignment(&mut transaction, &pending.assignment_id).await?;
        if record.executor_stop_pending.as_ref() != Some(pending) {
            if settled_stop_replays(&record, pending)?
                && durable_stopped_run_matches(&mut transaction, &record, pending).await?
            {
                commit_noop(transaction, "replayed remote executor stop settlement").await?;
                return Ok(TaskBoardRemoteMutationOutcome::Replayed(record));
            }
            commit_noop(transaction, "stale remote executor stop settlement").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        if !durable_stopped_run_matches(&mut transaction, &record, pending).await? {
            commit_noop(transaction, "remote executor stop remains ambiguous").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        let rows = query(
            "UPDATE task_board_remote_assignments
             SET state = 'unknown', heartbeat_at = ?2, error = ?3,
                 executor_start_authority_sha256 = NULL,
                 executor_start_authority_at = NULL,
                 executor_start_io_permit_sha256 = NULL,
                 executor_start_io_permit_at = NULL,
                 executor_lifecycle_owner_instance_id = NULL,
                 executor_lifecycle_owner_epoch = NULL,
                 executor_lifecycle_owner_acquired_at = NULL,
                 executor_lifecycle_owner_expires_at = NULL,
                 executor_lifecycle_owner_sha256 = NULL,
                 executor_stop_pending_json = NULL,
                 executor_stop_pending_sha256 = NULL, updated_at = ?2
             WHERE assignment_id = ?1 AND fencing_epoch = ?4
               AND executor_stop_pending_sha256 = ?5",
        )
        .bind(&record.assignment_id)
        .bind(observed_at)
        .bind(pending.reason.message())
        .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
        .bind(&pending.sha256)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("settle remote executor stop: {error}")))?
        .rows_affected();
        if rows != 1 {
            return Err(concurrent("remote executor stop settlement lost its fence"));
        }
        finish_mutation(
            transaction,
            &record.assignment_id,
            "remote executor stop settlement",
        )
        .await
    }
}
