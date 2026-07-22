//! Durable linearization point immediately before external executor Start I/O.

use std::path::{Component, Path};

use sha2::{Digest, Sha256};
use sqlx::{Sqlite, Transaction, query, query_scalar};

use super::{
    TaskBoardRemoteExecutorIdentity, TaskBoardRemoteExecutorStartAuthority,
    executor_settings_still_match, executor_start_authority, start_authority_eligible,
};
use crate::daemon::db::task_board::ORCHESTRATOR_CHANGE_SCOPE;
use crate::daemon::db::task_board::items::bump_change_in_tx;
use crate::daemon::db::task_board::remote_assignment_lease::{commit_noop, require_assignment};
use crate::daemon::db::task_board::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, canonical_time, concurrent, to_i64,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::TaskBoardRemoteAssignmentState;

const START_IO_PERMIT_DOMAIN: &str = "harness.task-board.remote-executor-start-io-permit.v1";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteExecutorStartIoPermit {
    pub(crate) assignment_id: String,
    pub(crate) fencing_epoch: u64,
    pub(crate) sha256: String,
    pub(crate) permitted_at: String,
    pub(crate) authority: TaskBoardRemoteExecutorStartAuthority,
    pub(crate) identity: TaskBoardRemoteExecutorIdentity,
    pub(crate) lease_id: String,
    pub(crate) lease_expires_at: String,
    pub(crate) deadline_at: String,
}

/// Outcome of a Start-I/O permit claim. Only [`Acquired`](Self::Acquired) grants
/// authority to perform a fresh external Codex Start: it means this call is the
/// linearization point that first persisted the permit against durable evidence.
/// [`Replayed`](Self::Replayed) re-reads a permit an earlier attempt already
/// durably persisted, so the worker must recover (probe/adopt/stop) rather than
/// launch again. [`Stale`](Self::Stale) means no permit is durable and none may
/// be acquired for this generation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TaskBoardRemoteExecutorStartIoPermitOutcome {
    Acquired(TaskBoardRemoteExecutorStartIoPermit),
    Replayed(TaskBoardRemoteExecutorStartIoPermit),
    Stale,
}

#[cfg(test)]
impl TaskBoardRemoteExecutorStartIoPermitOutcome {
    #[track_caller]
    pub(crate) fn expect_acquired(self, message: &str) -> TaskBoardRemoteExecutorStartIoPermit {
        match self {
            Self::Acquired(permit) => permit,
            other => panic!("{message}: {other:?}"),
        }
    }

    #[track_caller]
    pub(crate) fn expect_replayed(self, message: &str) -> TaskBoardRemoteExecutorStartIoPermit {
        match self {
            Self::Replayed(permit) => permit,
            other => panic!("{message}: {other:?}"),
        }
    }
}

impl AsyncDaemonDb {
    pub(crate) async fn claim_task_board_remote_executor_start_io_permit(
        &self,
        authority: &TaskBoardRemoteExecutorStartAuthority,
        project_dir: &Path,
        permitted_at: &str,
    ) -> Result<TaskBoardRemoteExecutorStartIoPermitOutcome, CliError> {
        canonical_time(permitted_at, "remote executor Start I/O permit time")?;
        let project_dir = canonical_project_dir(project_dir)?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote executor Start I/O permit")
            .await?;
        let record = require_assignment(&mut transaction, &authority.assignment_id).await?;
        if executor_start_authority(&record)?.as_ref() != Some(authority)
            || record.executor_stop_pending.is_some()
        {
            commit_noop(transaction, "stale remote executor Start I/O permit").await?;
            return Ok(TaskBoardRemoteExecutorStartIoPermitOutcome::Stale);
        }
        if let Some(permit) = executor_start_io_permit(&record)? {
            if !exact_provisioned_session(&mut transaction, &record, &permit.identity, &project_dir)
                .await?
            {
                return Err(concurrent(
                    "remote executor Start I/O permit lost its provisioned session",
                ));
            }
            commit_noop(transaction, "replayed remote executor Start I/O permit").await?;
            return Ok(TaskBoardRemoteExecutorStartIoPermitOutcome::Replayed(
                permit,
            ));
        }
        let host_instance_id = record
            .claimed_host_instance_id
            .as_deref()
            .ok_or_else(|| db_error("remote executor start has no claimed host"))?;
        if canonical_time(permitted_at, "remote executor Start I/O permit time")?
            < canonical_time(
                &authority.acquired_at,
                "remote executor provisioning authority time",
            )?
        {
            commit_noop(transaction, "early remote executor Start I/O permit").await?;
            return Ok(TaskBoardRemoteExecutorStartIoPermitOutcome::Stale);
        }
        if !executor_settings_still_match(&mut transaction, &record).await?
            || !start_authority_eligible(&record, host_instance_id, permitted_at)?
            || !exact_provisioned_session(
                &mut transaction,
                &record,
                &authority.identity,
                &project_dir,
            )
            .await?
        {
            commit_noop(transaction, "unavailable remote executor Start I/O permit").await?;
            return Ok(TaskBoardRemoteExecutorStartIoPermitOutcome::Stale);
        }
        if deterministic_run_exists(&mut transaction, &authority.identity).await? {
            return Err(concurrent(
                "remote executor Start I/O permit found a pre-authority run",
            ));
        }
        let permit =
            persist_start_io_permit(&mut transaction, &record, authority, permitted_at).await?;
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit remote executor Start I/O permit: {error}"))
        })?;
        Ok(TaskBoardRemoteExecutorStartIoPermitOutcome::Acquired(
            permit,
        ))
    }
}

async fn persist_start_io_permit(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    authority: &TaskBoardRemoteExecutorStartAuthority,
    permitted_at: &str,
) -> Result<TaskBoardRemoteExecutorStartIoPermit, CliError> {
    let sha256 = start_io_permit_digest(record, authority, permitted_at)?;
    let rows = query(
        "UPDATE task_board_remote_assignments
             SET executor_start_io_permit_sha256 = ?2,
                 executor_start_io_permit_at = ?3, updated_at = ?3
             WHERE assignment_id = ?1 AND fencing_epoch = ?4 AND state = 'claimed'
               AND executor_start_authority_sha256 = ?5
               AND executor_start_authority_at = ?6
               AND executor_start_io_permit_sha256 IS NULL
               AND executor_start_io_permit_at IS NULL
               AND executor_start_receipt_sha256 IS NULL
               AND executor_stop_pending_sha256 IS NULL",
    )
    .bind(&record.assignment_id)
    .bind(&sha256)
    .bind(permitted_at)
    .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
    .bind(&authority.sha256)
    .bind(&authority.acquired_at)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("claim remote executor Start I/O permit: {error}")))?
    .rows_affected();
    if rows != 1 {
        return Err(concurrent(
            "remote executor Start I/O permit lost its fence",
        ));
    }
    Ok(TaskBoardRemoteExecutorStartIoPermit {
        assignment_id: record.assignment_id.clone(),
        fencing_epoch: record.fencing_epoch,
        sha256,
        permitted_at: permitted_at.into(),
        authority: authority.clone(),
        identity: authority.identity.clone(),
        lease_id: required(&record.lease_id, "lease")?,
        lease_expires_at: required(&record.lease_expires_at, "lease expiry")?,
        deadline_at: required(&record.deadline_at, "deadline")?,
    })
}

pub(crate) fn executor_start_io_permit(
    record: &TaskBoardRemoteAssignmentRecord,
) -> Result<Option<TaskBoardRemoteExecutorStartIoPermit>, CliError> {
    let (Some(sha256), Some(permitted_at)) = (
        record.executor_start_io_permit_sha256.as_deref(),
        record.executor_start_io_permit_at.as_deref(),
    ) else {
        if record.executor_start_io_permit_sha256.is_some()
            || record.executor_start_io_permit_at.is_some()
        {
            return Err(db_error("remote executor Start I/O permit is incomplete"));
        }
        return Ok(None);
    };
    canonical_time(permitted_at, "remote executor Start I/O permit time")?;
    let authority = executor_start_authority(record)?.ok_or_else(|| {
        db_error("remote executor Start I/O permit has no provisioning authority")
    })?;
    let permit_time = canonical_time(permitted_at, "remote executor Start I/O permit time")?;
    let authority_time = canonical_time(
        &authority.acquired_at,
        "remote executor provisioning authority time",
    )?;
    let lease_time = canonical_time(
        record
            .lease_expires_at
            .as_deref()
            .ok_or_else(|| db_error("remote executor Start I/O permit has no lease expiry"))?,
        "remote executor Start I/O lease expiry",
    )?;
    let deadline_time = canonical_time(
        record
            .deadline_at
            .as_deref()
            .ok_or_else(|| db_error("remote executor Start I/O permit has no deadline"))?,
        "remote executor Start I/O deadline",
    )?;
    if permit_time < authority_time || permit_time >= lease_time || permit_time >= deadline_time {
        return Err(db_error(
            "remote executor Start I/O permit chronology is invalid",
        ));
    }
    if record.legacy_migrated
        || record.state != TaskBoardRemoteAssignmentState::Claimed
        || record.start_receipt.is_some()
        || record.started_at.is_some()
        || record.workspace_ref.is_some()
        || record.completed_at.is_some()
        || record.executor_lifecycle_owner.is_some()
    {
        return Err(db_error(
            "remote executor Start I/O permit has incompatible assignment state",
        ));
    }
    let expected = start_io_permit_digest(record, &authority, permitted_at)?;
    if sha256 != expected {
        return Err(db_error(
            "remote executor Start I/O permit contradicts durable assignment evidence",
        ));
    }
    Ok(Some(TaskBoardRemoteExecutorStartIoPermit {
        assignment_id: record.assignment_id.clone(),
        fencing_epoch: record.fencing_epoch,
        sha256: sha256.into(),
        permitted_at: permitted_at.into(),
        identity: authority.identity.clone(),
        lease_id: required(&record.lease_id, "lease")?,
        lease_expires_at: required(&record.lease_expires_at, "lease expiry")?,
        deadline_at: required(&record.deadline_at, "deadline")?,
        authority,
    }))
}

fn start_io_permit_digest(
    record: &TaskBoardRemoteAssignmentRecord,
    authority: &TaskBoardRemoteExecutorStartAuthority,
    permitted_at: &str,
) -> Result<String, CliError> {
    start_io_permit_digest_from_evidence(
        record,
        &authority.sha256,
        &authority.acquired_at,
        &required(&record.lease_id, "lease")?,
        &required(&record.lease_expires_at, "lease expiry")?,
        &required(&record.deadline_at, "deadline")?,
        permitted_at,
    )
}

pub(crate) fn start_io_permit_digest_from_evidence(
    record: &TaskBoardRemoteAssignmentRecord,
    start_authority_sha256: &str,
    start_authority_at: &str,
    lease_id: &str,
    lease_expires_at: &str,
    deadline_at: &str,
    permitted_at: &str,
) -> Result<String, CliError> {
    let offer = record.require_offer()?;
    let identity = super::remote_executor_identity(record)?;
    let values = [
        START_IO_PERMIT_DOMAIN.to_string(),
        record.assignment_id.clone(),
        record.execution_id.clone(),
        record.fencing_epoch.to_string(),
        offer.request_sha256.clone(),
        start_authority_sha256.into(),
        start_authority_at.into(),
        required(&record.claimed_host_instance_id, "claimed host")?,
        required(&record.authenticated_principal, "principal")?,
        lease_id.into(),
        lease_expires_at.into(),
        deadline_at.into(),
        record
            .executor_configuration_revision
            .ok_or_else(|| db_error("remote executor Start I/O permit has no revision"))?
            .to_string(),
        required(&record.executor_checkout_path, "checkout")?,
        identity.session_id,
        identity.run_id,
        identity.workspace_ref,
        permitted_at.into(),
    ];
    let mut hasher = Sha256::new();
    for value in values {
        hasher.update(value.len().to_be_bytes());
        hasher.update(value.as_bytes());
    }
    Ok(hex::encode(hasher.finalize()))
}

async fn exact_provisioned_session(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &TaskBoardRemoteExecutorIdentity,
    project_dir: &str,
) -> Result<bool, CliError> {
    let origin_path = canonical_executor_checkout_path(record)?;
    query_scalar::<_, bool>(
        "SELECT EXISTS(
           SELECT 1 FROM sessions
           WHERE session_id = ?1 AND title = ?2 AND context = ?3
             AND json_valid(state_json)
             AND json_extract(state_json, '$.session_id') = ?1
             AND json_extract(state_json, '$.worktree_path') = ?4
             AND json_extract(state_json, '$.origin_path') = ?5
             AND json_extract(state_json, '$.branch_ref') = ?6
         )",
    )
    .bind(&identity.session_id)
    .bind(format!("Remote Task Board {}", record.execution_id))
    .bind(format!(
        "Remote Task Board assignment {} fencing epoch {}",
        record.assignment_id, record.fencing_epoch
    ))
    .bind(project_dir)
    .bind(origin_path)
    .bind(format!("harness/{}", identity.session_id))
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "verify provisioned remote executor session: {error}"
        ))
    })
}

fn canonical_executor_checkout_path(
    record: &TaskBoardRemoteAssignmentRecord,
) -> Result<String, CliError> {
    let checkout = record
        .executor_checkout_path
        .as_deref()
        .ok_or_else(|| db_error("remote executor Start I/O permit has no frozen checkout path"))?;
    let canonical = Path::new(checkout).canonicalize().map_err(|error| {
        db_error(format!(
            "canonicalize remote executor Start I/O checkout: {error}"
        ))
    })?;
    canonical_project_dir(&canonical)
}

async fn deterministic_run_exists(
    transaction: &mut Transaction<'_, Sqlite>,
    identity: &TaskBoardRemoteExecutorIdentity,
) -> Result<bool, CliError> {
    query_scalar("SELECT EXISTS(SELECT 1 FROM codex_runs WHERE run_id = ?1)")
        .bind(&identity.run_id)
        .fetch_one(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("check pre-permit remote executor run: {error}")))
}

fn canonical_project_dir(project_dir: &Path) -> Result<String, CliError> {
    if !project_dir.is_absolute()
        || project_dir
            .components()
            .any(|component| matches!(component, Component::CurDir | Component::ParentDir))
    {
        return Err(db_error(
            "remote executor Start I/O project path is not canonical",
        ));
    }
    project_dir
        .to_str()
        .map(str::to_string)
        .ok_or_else(|| db_error("remote executor Start I/O project path is not UTF-8"))
}

fn required(value: &Option<String>, label: &str) -> Result<String, CliError> {
    value
        .clone()
        .ok_or_else(|| db_error(format!("remote executor Start I/O permit has no {label}")))
}
