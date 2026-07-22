use chrono::{Duration, SecondsFormat};
use sha2::{Digest, Sha256};
use sqlx::{Sqlite, Transaction, query};

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::remote_assignment_lease::{commit_noop, require_assignment};
use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, canonical_time, concurrent, nonblank, to_i64,
};
use super::remote_assignment_start_authority::{
    executor_lifecycle_settings_still_compatible, remote_executor_identity,
};
use super::remote_start_receipts::durable_start_receipt_run_matches;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::TaskBoardRemoteAssignmentState;

const LIFECYCLE_OWNER_DOMAIN: &str = "harness.task-board.remote-executor-lifecycle-owner.v1";
const LIFECYCLE_OWNER_SECONDS: i64 = 30;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteExecutorLifecycleOwner {
    pub(crate) assignment_id: String,
    pub(crate) fencing_epoch: u64,
    pub(crate) owner_instance_id: String,
    pub(crate) owner_epoch: u64,
    pub(crate) acquired_at: String,
    pub(crate) expires_at: String,
    pub(crate) sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteExecutorLifecycleClaim {
    pub(crate) owner: TaskBoardRemoteExecutorLifecycleOwner,
    pub(crate) stop_only: bool,
}

impl AsyncDaemonDb {
    pub(crate) async fn claim_task_board_remote_executor_lifecycle_owner(
        &self,
        assignment_id: &str,
        owner_instance_id: &str,
        acquired_at: &str,
    ) -> Result<Option<TaskBoardRemoteExecutorLifecycleOwner>, CliError> {
        Ok(self
            .claim_task_board_remote_executor_lifecycle_owner_with_settings(
                assignment_id,
                owner_instance_id,
                acquired_at,
            )
            .await?
            .map(|claim| claim.owner))
    }

    pub(crate) async fn claim_task_board_remote_executor_lifecycle_owner_with_settings(
        &self,
        assignment_id: &str,
        owner_instance_id: &str,
        acquired_at: &str,
    ) -> Result<Option<TaskBoardRemoteExecutorLifecycleClaim>, CliError> {
        nonblank(assignment_id, "remote lifecycle assignment id")?;
        nonblank(owner_instance_id, "remote lifecycle owner instance")?;
        canonical_time(acquired_at, "remote lifecycle owner acquisition time")?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote executor lifecycle owner")
            .await?;
        let record = require_assignment(&mut transaction, assignment_id).await?;
        if !matches!(
            record.state,
            TaskBoardRemoteAssignmentState::Started | TaskBoardRemoteAssignmentState::Running
        ) || record.executor_start_authority_sha256.is_some()
            || record.executor_stop_pending.is_some()
            || !durable_lifecycle_run_matches(&mut transaction, &record).await?
        {
            commit_noop(transaction, "stale remote executor lifecycle owner").await?;
            return Ok(None);
        }
        let current = record.executor_lifecycle_owner.as_ref();
        if let Some(owner) = current {
            let now = canonical_time(acquired_at, "remote lifecycle owner acquisition time")?;
            let acquired = canonical_time(
                &owner.acquired_at,
                "current remote lifecycle owner acquisition time",
            )?;
            let expires = canonical_time(&owner.expires_at, "remote lifecycle owner expiry")?;
            if now < acquired || (owner.owner_instance_id != owner_instance_id && now < expires) {
                commit_noop(transaction, "live remote executor lifecycle owner").await?;
                return Ok(None);
            }
            if owner.owner_instance_id == owner_instance_id && now < expires {
                let replay = lifecycle_claim(&mut transaction, &record, owner.clone()).await?;
                commit_noop(transaction, "replayed remote executor lifecycle owner").await?;
                return Ok(Some(replay));
            }
        }
        let owner_epoch = current.map_or(1, |owner| owner.owner_epoch.saturating_add(1));
        let owner = lifecycle_owner(&record, owner_instance_id, owner_epoch, acquired_at)?;
        persist_lifecycle_owner(&mut transaction, &record, current, &owner).await?;
        let claim = lifecycle_claim(&mut transaction, &record, owner).await?;
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit remote executor lifecycle owner: {error}"))
        })?;
        Ok(Some(claim))
    }
}

async fn lifecycle_claim(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    owner: TaskBoardRemoteExecutorLifecycleOwner,
) -> Result<TaskBoardRemoteExecutorLifecycleClaim, CliError> {
    Ok(TaskBoardRemoteExecutorLifecycleClaim {
        owner,
        stop_only: !executor_lifecycle_settings_still_compatible(transaction, record).await?,
    })
}

pub(crate) fn executor_lifecycle_owner(
    record: &TaskBoardRemoteAssignmentRecord,
) -> Option<TaskBoardRemoteExecutorLifecycleOwner> {
    record.executor_lifecycle_owner.clone()
}

#[allow(clippy::too_many_arguments)]
pub(super) fn decode_executor_lifecycle_owner(
    record: &TaskBoardRemoteAssignmentRecord,
    instance_id: Option<String>,
    owner_epoch: Option<i64>,
    acquired_at: Option<String>,
    expires_at: Option<String>,
    sha256: Option<String>,
) -> Result<Option<TaskBoardRemoteExecutorLifecycleOwner>, CliError> {
    let (instance_id, owner_epoch, acquired_at, expires_at, sha256) =
        match (instance_id, owner_epoch, acquired_at, expires_at, sha256) {
            (None, None, None, None, None) => return Ok(None),
            (Some(instance), Some(epoch), Some(acquired), Some(expires), Some(sha)) => {
                (instance, epoch, acquired, expires, sha)
            }
            _ => return Err(db_error("remote executor lifecycle owner is incomplete")),
        };
    nonblank(&instance_id, "remote lifecycle owner instance")?;
    let owner_epoch = u64::try_from(owner_epoch)
        .ok()
        .filter(|epoch| *epoch > 0)
        .ok_or_else(|| db_error("remote lifecycle owner epoch is not positive"))?;
    let acquired = canonical_time(&acquired_at, "remote lifecycle owner acquisition time")?;
    let expires = canonical_time(&expires_at, "remote lifecycle owner expiry")?;
    if acquired >= expires {
        return Err(db_error(
            "remote lifecycle owner expiry is not after acquisition",
        ));
    }
    let expected =
        lifecycle_owner_digest(record, &instance_id, owner_epoch, &acquired_at, &expires_at)?;
    if sha256 != expected {
        return Err(db_error(
            "remote executor lifecycle owner contradicts durable assignment evidence",
        ));
    }
    Ok(Some(TaskBoardRemoteExecutorLifecycleOwner {
        assignment_id: record.assignment_id.clone(),
        fencing_epoch: record.fencing_epoch,
        owner_instance_id: instance_id,
        owner_epoch,
        acquired_at,
        expires_at,
        sha256,
    }))
}

pub(super) fn lifecycle_owner(
    record: &TaskBoardRemoteAssignmentRecord,
    owner_instance_id: &str,
    owner_epoch: u64,
    acquired_at: &str,
) -> Result<TaskBoardRemoteExecutorLifecycleOwner, CliError> {
    let expires_at = lifecycle_owner_expiry(acquired_at)?;
    let sha256 = lifecycle_owner_digest(
        record,
        owner_instance_id,
        owner_epoch,
        acquired_at,
        &expires_at,
    )?;
    Ok(TaskBoardRemoteExecutorLifecycleOwner {
        assignment_id: record.assignment_id.clone(),
        fencing_epoch: record.fencing_epoch,
        owner_instance_id: owner_instance_id.into(),
        owner_epoch,
        acquired_at: acquired_at.into(),
        expires_at,
        sha256,
    })
}

pub(super) fn lifecycle_owner_expiry(acquired_at: &str) -> Result<String, CliError> {
    let acquired = canonical_time(acquired_at, "remote lifecycle owner acquisition time")?;
    Ok((acquired + Duration::seconds(LIFECYCLE_OWNER_SECONDS))
        .to_rfc3339_opts(SecondsFormat::AutoSi, true))
}

async fn persist_lifecycle_owner(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    current: Option<&TaskBoardRemoteExecutorLifecycleOwner>,
    owner: &TaskBoardRemoteExecutorLifecycleOwner,
) -> Result<(), CliError> {
    let rows = query(
        "UPDATE task_board_remote_assignments SET
           executor_lifecycle_owner_instance_id = ?2,
           executor_lifecycle_owner_epoch = ?3,
           executor_lifecycle_owner_acquired_at = ?4,
           executor_lifecycle_owner_expires_at = ?5,
           executor_lifecycle_owner_sha256 = ?6, updated_at = ?4
         WHERE assignment_id = ?1 AND fencing_epoch = ?7
           AND state IN ('started', 'running')
           AND executor_start_authority_sha256 IS NULL
           AND executor_stop_pending_sha256 IS NULL
           AND executor_lifecycle_owner_sha256 IS ?8",
    )
    .bind(&record.assignment_id)
    .bind(&owner.owner_instance_id)
    .bind(to_i64(owner.owner_epoch, "remote lifecycle owner epoch")?)
    .bind(&owner.acquired_at)
    .bind(&owner.expires_at)
    .bind(&owner.sha256)
    .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
    .bind(current.map(|owner| owner.sha256.as_str()))
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("persist remote executor lifecycle owner: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(())
    } else {
        Err(concurrent("remote executor lifecycle owner lost its fence"))
    }
}

async fn durable_lifecycle_run_matches(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
) -> Result<bool, CliError> {
    let receipt = record
        .start_receipt
        .as_ref()
        .ok_or_else(|| db_error("remote lifecycle owner has no start receipt"))?;
    durable_start_receipt_run_matches(transaction, record, receipt).await
}

fn lifecycle_owner_digest(
    record: &TaskBoardRemoteAssignmentRecord,
    owner_instance_id: &str,
    owner_epoch: u64,
    acquired_at: &str,
    expires_at: &str,
) -> Result<String, CliError> {
    let offer = record.require_offer()?;
    let identity = remote_executor_identity(record)?;
    let values = [
        LIFECYCLE_OWNER_DOMAIN.to_string(),
        record.assignment_id.clone(),
        record.fencing_epoch.to_string(),
        offer.request_sha256.clone(),
        record
            .claim_receipt
            .as_ref()
            .ok_or_else(|| db_error("remote lifecycle owner has no claim receipt"))?
            .sha256
            .clone(),
        record
            .start_receipt
            .as_ref()
            .ok_or_else(|| db_error("remote lifecycle owner has no start receipt"))?
            .sha256
            .clone(),
        required(&record.claimed_host_instance_id, "claimed host")?,
        record
            .executor_configuration_revision
            .ok_or_else(|| db_error("remote lifecycle owner has no executor revision"))?
            .to_string(),
        required(&record.executor_checkout_path, "checkout")?,
        required(&record.started_at, "start time")?,
        required(&record.workspace_ref, "workspace")?,
        identity.session_id,
        identity.run_id,
        owner_instance_id.into(),
        owner_epoch.to_string(),
        acquired_at.into(),
        expires_at.into(),
    ];
    let mut hasher = Sha256::new();
    for value in values {
        hasher.update(value.len().to_be_bytes());
        hasher.update(value.as_bytes());
    }
    Ok(hex::encode(hasher.finalize()))
}

fn required(value: &Option<String>, label: &str) -> Result<String, CliError> {
    value
        .clone()
        .ok_or_else(|| db_error(format!("remote lifecycle owner has no {label}")))
}
