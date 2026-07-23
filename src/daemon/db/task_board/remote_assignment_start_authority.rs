use std::path::Path;

use sqlx::{Sqlite, Transaction, query, query_scalar};

mod evidence;
mod failed_at_claimed;
mod settings_fence;
mod start_adoption;
mod start_io_permit;

pub(super) use evidence::start_authority_digest;
pub(crate) use evidence::{
    executor_lifecycle_settings_still_compatible, executor_settings_still_match,
};
pub(crate) use evidence::{remote_executor_identity, remote_executor_identity_from_parts};
pub(crate) use failed_at_claimed::{
    REMOTE_START_INTERRUPTED_WITHOUT_RUN_ERROR_CODE,
    REMOTE_START_INTERRUPTED_WITHOUT_RUN_FAILURE_CLASS, REMOTE_START_PREFLIGHT_ERROR_CODE,
    REMOTE_START_PREFLIGHT_FAILURE_CLASS,
};
pub(super) use settings_fence::refuse_settings_replacement_during_executor_start_io;
use settings_fence::revoke_unpermitted_start_in_tx;
use start_adoption::persist_start_adoption_in_tx;
pub(super) use start_io_permit::start_io_permit_digest_from_evidence;
pub(crate) use start_io_permit::{
    TaskBoardRemoteExecutorStartIoPermit, TaskBoardRemoteExecutorStartIoPermitOutcome,
    executor_start_io_permit,
};

pub(crate) const EXECUTOR_RESTARTED_BEFORE_START: &str =
    "remote executor restarted before worker start";

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::remote_assignment_lease::{commit_noop, finish_mutation, require_assignment};
use super::remote_assignment_lifecycle_owner::lifecycle_owner_expiry;
use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome, canonical_time, concurrent,
    nonblank, to_i64,
};
use super::remote_start_receipts::{
    durable_start_receipt_run_matches, receipt_matches_permit, start_receipt,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::TaskBoardRemoteAssignmentState;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteExecutorIdentity {
    pub(crate) session_id: String,
    pub(crate) run_id: String,
    pub(crate) workspace_ref: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteExecutorStartAuthority {
    pub(crate) assignment_id: String,
    pub(crate) fencing_epoch: u64,
    pub(crate) sha256: String,
    pub(crate) acquired_at: String,
    pub(crate) identity: TaskBoardRemoteExecutorIdentity,
}

impl AsyncDaemonDb {
    pub(crate) async fn claim_task_board_remote_executor_start_authority(
        &self,
        assignment_id: &str,
        host_instance_id: &str,
        authority_at: &str,
    ) -> Result<Option<TaskBoardRemoteExecutorStartAuthority>, CliError> {
        nonblank(assignment_id, "remote executor start assignment id")?;
        nonblank(host_instance_id, "remote executor start host instance")?;
        canonical_time(authority_at, "remote executor start authority time")?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote executor start authority")
            .await?;
        let record = require_assignment(&mut transaction, assignment_id).await?;
        if record.executor_stop_pending.is_some() {
            commit_noop(transaction, "remote executor is permanently stop-only").await?;
            return Ok(None);
        }
        if let Some(authority) = executor_start_authority(&record)? {
            if record.claimed_host_instance_id.as_deref() != Some(host_instance_id) {
                return Err(concurrent(
                    "remote executor start authority belongs to another host instance",
                ));
            }
            commit_noop(transaction, "replayed remote executor start authority").await?;
            return Ok(Some(authority));
        }
        if !start_authority_eligible(&record, host_instance_id, authority_at)? {
            commit_noop(transaction, "stale remote executor start authority").await?;
            return Ok(None);
        }
        let identity = remote_executor_identity(&record)?;
        if !executor_settings_still_match(&mut transaction, &record).await? {
            revoke_unpermitted_start_in_tx(transaction, &record, &identity, authority_at).await?;
            return Ok(None);
        }
        let sha256 = start_authority_digest(&record, &identity, authority_at)?;
        let claim_receipt_sha256 = record
            .claim_receipt
            .as_ref()
            .ok_or_else(|| db_error("remote executor start has no claim receipt"))?
            .sha256
            .as_str();
        let rows = query(
            "UPDATE task_board_remote_assignments
             SET executor_start_authority_sha256 = ?2,
                 executor_start_authority_at = ?3, updated_at = ?3
             WHERE assignment_id = ?1 AND fencing_epoch = ?4 AND state = 'claimed'
               AND target_host_instance_id = ?5 AND claimed_host_instance_id = ?5
               AND lease_id = ?6 AND lease_expires_at = ?7
               AND claim_receipt_sha256 = ?8
               AND executor_start_authority_sha256 IS NULL
               AND executor_start_authority_at IS NULL
               AND executor_stop_pending_sha256 IS NULL",
        )
        .bind(assignment_id)
        .bind(&sha256)
        .bind(authority_at)
        .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
        .bind(host_instance_id)
        .bind(record.lease_id.as_deref())
        .bind(record.lease_expires_at.as_deref())
        .bind(claim_receipt_sha256)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("claim remote executor start authority: {error}")))?
        .rows_affected();
        if rows != 1 {
            return Err(concurrent("remote executor start authority lost its fence"));
        }
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit remote executor start authority: {error}"))
        })?;
        Ok(Some(TaskBoardRemoteExecutorStartAuthority {
            assignment_id: assignment_id.into(),
            fencing_epoch: record.fencing_epoch,
            sha256,
            acquired_at: authority_at.into(),
            identity,
        }))
    }

    pub(crate) async fn adopt_task_board_remote_executor_start(
        &self,
        permit: &TaskBoardRemoteExecutorStartIoPermit,
        project_dir: &Path,
        started_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        let record = self
            .task_board_remote_assignment(&permit.assignment_id)
            .await?
            .ok_or_else(|| db_error("remote executor start assignment disappeared"))?;
        let owner_instance_id = record
            .claimed_host_instance_id
            .ok_or_else(|| db_error("remote executor start has no claimed host"))?;
        self.adopt_task_board_remote_executor_start_owned(
            permit,
            project_dir,
            started_at,
            &owner_instance_id,
            started_at,
        )
        .await
    }

    pub(crate) async fn adopt_task_board_remote_executor_start_owned(
        &self,
        permit: &TaskBoardRemoteExecutorStartIoPermit,
        project_dir: &Path,
        started_at: &str,
        owner_instance_id: &str,
        owner_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        let started = canonical_time(started_at, "remote executor durable start time")?;
        nonblank(
            owner_instance_id,
            "remote executor lifecycle owner instance",
        )?;
        let owner_at_time = canonical_time(owner_at, "remote executor lifecycle owner time")?;
        let project_dir = project_dir.to_string_lossy().into_owned();
        let mut transaction = self
            .begin_immediate_transaction("task board remote executor start adoption")
            .await?;
        let record = require_assignment(&mut transaction, &permit.assignment_id).await?;
        if record.executor_stop_pending.is_some() {
            commit_noop(
                transaction,
                "remote executor start is permanently stop-only",
            )
            .await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        if start_adoption_replays(&record, permit, &project_dir, started_at, &mut transaction)
            .await?
        {
            commit_noop(transaction, "replayed remote executor start adoption").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Replayed(record));
        }
        let Some(current) = executor_start_io_permit(&record)? else {
            commit_noop(transaction, "stale remote executor start adoption").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        };
        if current != *permit {
            commit_noop(transaction, "stale durable remote executor start").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        if !executor_settings_still_match(&mut transaction, &record).await? {
            commit_noop(
                transaction,
                "remote executor settings changed before start adoption",
            )
            .await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        let authority_at =
            canonical_time(&permit.permitted_at, "remote executor start authority time")?;
        if started < authority_at || owner_at_time < started {
            commit_noop(
                transaction,
                "stale durable remote executor start chronology",
            )
            .await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        let owner_expires_at = lifecycle_owner_expiry(owner_at)?;
        let receipt = start_receipt(
            &record,
            permit,
            &project_dir,
            started_at,
            owner_instance_id,
            owner_at,
            &owner_expires_at,
        )?;
        if !durable_start_receipt_run_matches(&mut transaction, &record, &receipt).await? {
            commit_noop(transaction, "stale durable remote executor start").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        persist_start_adoption_in_tx(
            &mut transaction,
            &record,
            permit,
            &receipt,
            start_adoption::TaskBoardRemoteStartAdoptionContext {
                started_at,
                owner_instance_id,
                owner_at,
                owner_expires_at: &owner_expires_at,
            },
        )
        .await?;
        finish_mutation(
            transaction,
            &record.assignment_id,
            "executor start adoption",
        )
        .await
    }

    pub(crate) async fn expire_task_board_remote_executor_start_without_run(
        &self,
        authority: &TaskBoardRemoteExecutorStartAuthority,
        reason: &str,
        observed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        nonblank(reason, "remote executor start expiry reason")?;
        canonical_time(observed_at, "remote executor start expiry time")?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote executor start expiry")
            .await?;
        let record = require_assignment(&mut transaction, &authority.assignment_id).await?;
        if record.executor_stop_pending.is_some()
            || executor_start_authority(&record)?.as_ref() != Some(authority)
            || executor_start_io_permit(&record)?.is_some()
        {
            commit_noop(transaction, "stale remote executor start expiry").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        let observed = canonical_time(observed_at, "remote executor start expiry time")?;
        let lease = canonical_time(
            record
                .lease_expires_at
                .as_deref()
                .ok_or_else(|| db_error("remote executor start has no lease expiry"))?,
            "remote executor lease expiry",
        )?;
        let deadline = canonical_time(
            record
                .deadline_at
                .as_deref()
                .ok_or_else(|| db_error("remote executor start has no deadline"))?,
            "remote executor deadline",
        )?;
        if observed < lease && observed < deadline {
            commit_noop(transaction, "early remote executor start expiry").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        let run_exists =
            query_scalar::<_, bool>("SELECT EXISTS(SELECT 1 FROM codex_runs WHERE run_id = ?1)")
                .bind(&authority.identity.run_id)
                .fetch_one(transaction.as_mut())
                .await
                .map_err(|error| db_error(format!("check remote executor start run: {error}")))?;
        let session_exists =
            query_scalar::<_, bool>("SELECT EXISTS(SELECT 1 FROM sessions WHERE session_id = ?1)")
                .bind(&authority.identity.session_id)
                .fetch_one(transaction.as_mut())
                .await
                .map_err(|error| {
                    db_error(format!("check remote executor start session: {error}"))
                })?;
        if run_exists || session_exists {
            return Err(concurrent(
                "remote executor start authority has durable provisioning evidence",
            ));
        }
        let rows = query(
            "UPDATE task_board_remote_assignments
             SET state = 'unknown', error = ?2,
                 executor_start_authority_sha256 = NULL,
                 executor_start_authority_at = NULL, updated_at = ?3
             WHERE assignment_id = ?1 AND fencing_epoch = ?4 AND state = 'claimed'
               AND executor_start_authority_sha256 = ?5
               AND executor_start_authority_at = ?6
               AND executor_start_io_permit_sha256 IS NULL
               AND executor_start_io_permit_at IS NULL
               AND NOT EXISTS(SELECT 1 FROM sessions WHERE session_id = ?7)",
        )
        .bind(&record.assignment_id)
        .bind(reason)
        .bind(observed_at)
        .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
        .bind(&authority.sha256)
        .bind(&authority.acquired_at)
        .bind(&authority.identity.session_id)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("expire remote executor start: {error}")))?
        .rows_affected();
        if rows != 1 {
            return Err(concurrent("remote executor start expiry lost its fence"));
        }
        finish_mutation(transaction, &record.assignment_id, "executor start expiry").await
    }
}

pub(super) fn validate_executor_start_authority(
    record: &TaskBoardRemoteAssignmentRecord,
) -> Result<(), CliError> {
    let _ = executor_start_authority(record)?;
    Ok(())
}

pub(crate) fn executor_start_authority(
    record: &TaskBoardRemoteAssignmentRecord,
) -> Result<Option<TaskBoardRemoteExecutorStartAuthority>, CliError> {
    let (Some(sha256), Some(acquired_at)) = (
        record.executor_start_authority_sha256.as_deref(),
        record.executor_start_authority_at.as_deref(),
    ) else {
        if record.executor_start_authority_sha256.is_some()
            || record.executor_start_authority_at.is_some()
        {
            return Err(db_error("remote executor start authority is incomplete"));
        }
        return Ok(None);
    };
    canonical_time(acquired_at, "remote executor start authority time")?;
    if record.legacy_migrated
        || record.state != TaskBoardRemoteAssignmentState::Claimed
        || record.claimed_host_instance_id != record.target_host_instance_id
        || record.executor_configuration_revision.is_none()
        || record.executor_checkout_path.is_none()
        || record.claim_receipt.is_none()
        || record.start_receipt.is_some()
        || record.started_at.is_some()
        || record.workspace_ref.is_some()
        || record.completed_at.is_some()
        || record.status_response.is_some()
        || record.status_sha256.is_some()
        || record.result_sha256.is_some()
        || record.cleanup_settlement_request_sha256.is_some()
        || record.cleanup_completed_at.is_some()
    {
        return Err(db_error(
            "remote executor start authority has incompatible assignment state",
        ));
    }
    let identity = remote_executor_identity(record)?;
    let expected = start_authority_digest(record, &identity, acquired_at)?;
    if sha256 != expected {
        return Err(db_error(
            "remote executor start authority contradicts durable assignment evidence",
        ));
    }
    Ok(Some(TaskBoardRemoteExecutorStartAuthority {
        assignment_id: record.assignment_id.clone(),
        fencing_epoch: record.fencing_epoch,
        sha256: sha256.into(),
        acquired_at: acquired_at.into(),
        identity,
    }))
}

fn start_authority_eligible(
    record: &TaskBoardRemoteAssignmentRecord,
    host_instance_id: &str,
    authority_at: &str,
) -> Result<bool, CliError> {
    if record.state != TaskBoardRemoteAssignmentState::Claimed
        || record.claimed_host_instance_id.as_deref() != Some(host_instance_id)
        || record.target_host_instance_id.as_deref() != Some(host_instance_id)
        || record.claim_receipt.is_none()
        || record.start_receipt.is_some()
        || record.started_at.is_some()
        || record.workspace_ref.is_some()
    {
        return Ok(false);
    }
    let now = canonical_time(authority_at, "remote executor start authority time")?;
    let claimed_at = canonical_time(
        record
            .claimed_at
            .as_deref()
            .ok_or_else(|| db_error("remote executor start has no claim time"))?,
        "remote executor claim time",
    )?;
    let lease = canonical_time(
        record
            .lease_expires_at
            .as_deref()
            .ok_or_else(|| db_error("remote executor start has no lease expiry"))?,
        "remote executor lease expiry",
    )?;
    let deadline = canonical_time(
        record
            .deadline_at
            .as_deref()
            .ok_or_else(|| db_error("remote executor start has no deadline"))?,
        "remote executor deadline",
    )?;
    Ok(now >= claimed_at && now < lease && now < deadline)
}

async fn start_adoption_replays(
    record: &TaskBoardRemoteAssignmentRecord,
    permit: &TaskBoardRemoteExecutorStartIoPermit,
    project_dir: &str,
    started_at: &str,
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<bool, CliError> {
    let replay_state = matches!(
        record.state,
        TaskBoardRemoteAssignmentState::Started | TaskBoardRemoteAssignmentState::Running
    );
    if !replay_state
        || record.fencing_epoch != permit.fencing_epoch
        || record.started_at.as_deref() != Some(started_at)
        || record.workspace_ref.as_deref() != Some(&permit.identity.workspace_ref)
        || record.executor_start_authority_sha256.is_some()
        || record.executor_start_authority_at.is_some()
        || record.executor_start_io_permit_sha256.is_some()
        || record.executor_start_io_permit_at.is_some()
    {
        return Ok(false);
    }
    let Some(receipt) = record.start_receipt.as_ref() else {
        return Ok(false);
    };
    Ok(
        receipt_matches_permit(receipt, permit, project_dir, started_at)
            && durable_start_receipt_run_matches(transaction, record, receipt).await?,
    )
}
