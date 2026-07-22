use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::authority::{StopAuthorityKind, authority_fencing_epoch, source_matches};
use super::evidence::observed_launch_digest;
use super::{TaskBoardRemoteExecutorStopAuthority, TaskBoardRemoteExecutorStopReason};
use crate::daemon::db::task_board::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, canonical_time, nonblank,
};
use crate::daemon::db::task_board::remote_assignment_start_authority::{
    executor_start_authority, executor_start_io_permit, remote_executor_identity,
};
use crate::daemon::db::{CliError, db_error};
use crate::daemon::protocol::CodexRunSnapshot;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteSourceMaterial, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};

const STOP_PENDING_DOMAIN: &str = "harness.task-board.remote-executor-stop-pending.v1";
const MAX_STOP_PENDING_BYTES: usize = 32_768;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct TaskBoardRemoteExecutorStopPending {
    pub(crate) schema_version: u32,
    pub(crate) assignment_id: String,
    pub(crate) fencing_epoch: u64,
    pub(crate) offer_request_sha256: String,
    pub(crate) claim_receipt_sha256: String,
    pub(crate) start_receipt_sha256: Option<String>,
    authority_kind: StopAuthorityKind,
    pub(crate) authority_sha256: String,
    pub(crate) authority_acquired_at: String,
    pub(crate) session_id: String,
    pub(crate) run_id: String,
    pub(crate) workspace_ref: String,
    pub(crate) project_dir: String,
    pub(crate) run_started_at: String,
    pub(crate) observed_launch_sha256: String,
    pub(crate) executor_configuration_revision: u64,
    pub(crate) executor_checkout_path: String,
    pub(crate) source: RemoteSourceMaterial,
    pub(crate) reason: TaskBoardRemoteExecutorStopReason,
    pub(crate) acquired_at: String,
    #[serde(skip)]
    pub(crate) sha256: String,
}

pub(in super::super) fn decode_executor_stop_pending(
    record: &TaskBoardRemoteAssignmentRecord,
    pending_json: Option<String>,
    pending_sha256: Option<String>,
) -> Result<Option<TaskBoardRemoteExecutorStopPending>, CliError> {
    let (json, sha256) = match (pending_json, pending_sha256) {
        (None, None) => return Ok(None),
        (Some(json), Some(sha256)) => (json, sha256),
        _ => return Err(db_error("remote executor stop authority is incomplete")),
    };
    if json.len() > MAX_STOP_PENDING_BYTES {
        return Err(db_error("remote executor stop authority exceeds its size limit"));
    }
    let mut pending = serde_json::from_str::<TaskBoardRemoteExecutorStopPending>(&json)
        .map_err(|error| db_error(format!("decode remote executor stop authority: {error}")))?;
    if canonical_json(&pending)? != json {
        return Err(db_error("remote executor stop authority is not canonical"));
    }
    pending.sha256 = sha256;
    validate_stop_pending(record, &pending)?;
    Ok(Some(pending))
}

pub(crate) fn stop_pending_snapshot_matches(
    pending: &TaskBoardRemoteExecutorStopPending,
    snapshot: &CodexRunSnapshot,
) -> bool {
    snapshot.run_id == pending.run_id
        && snapshot.session_id == pending.session_id
        && snapshot.project_dir == pending.project_dir
        && snapshot.created_at == pending.run_started_at
}

pub(super) fn stop_pending(
    record: &TaskBoardRemoteAssignmentRecord,
    authority: &TaskBoardRemoteExecutorStopAuthority,
    snapshot: &CodexRunSnapshot,
    reason: TaskBoardRemoteExecutorStopReason,
    acquired_at: &str,
) -> Result<TaskBoardRemoteExecutorStopPending, CliError> {
    let offer = record.require_offer()?;
    let identity = remote_executor_identity(record)?;
    let mut pending = TaskBoardRemoteExecutorStopPending {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        assignment_id: record.assignment_id.clone(),
        fencing_epoch: record.fencing_epoch,
        offer_request_sha256: offer.request_sha256.clone(),
        claim_receipt_sha256: record
            .claim_receipt
            .as_ref()
            .ok_or_else(|| db_error("remote executor stop has no claim receipt"))?
            .sha256
            .clone(),
        start_receipt_sha256: record.start_receipt.as_ref().map(|receipt| receipt.sha256.clone()),
        authority_kind: authority.kind(),
        authority_sha256: authority.sha256().into(),
        authority_acquired_at: authority.acquired_at().into(),
        session_id: identity.session_id,
        run_id: identity.run_id,
        workspace_ref: identity.workspace_ref,
        project_dir: snapshot.project_dir.clone(),
        run_started_at: snapshot.created_at.clone(),
        observed_launch_sha256: observed_launch_digest(snapshot),
        executor_configuration_revision: record.executor_configuration_revision.ok_or_else(
            || db_error("remote executor stop has no executor configuration revision"),
        )?,
        executor_checkout_path: required(&record.executor_checkout_path, "checkout")?,
        source: offer.source.clone(),
        reason,
        acquired_at: acquired_at.into(),
        sha256: String::new(),
    };
    validate_stop_pending(record, &pending)?;
    pending.sha256 = stop_pending_digest(&pending)?;
    Ok(pending)
}

fn validate_stop_pending(
    record: &TaskBoardRemoteAssignmentRecord,
    pending: &TaskBoardRemoteExecutorStopPending,
) -> Result<(), CliError> {
    let offer = record.require_offer()?;
    let identity = remote_executor_identity(record)?;
    if pending.schema_version != TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION
        || pending.assignment_id != record.assignment_id
        || pending.fencing_epoch != record.fencing_epoch
        || pending.offer_request_sha256 != offer.request_sha256
        || pending.claim_receipt_sha256
            != record
                .claim_receipt
                .as_ref()
                .ok_or_else(|| db_error("remote executor stop has no claim receipt"))?
                .sha256
        || pending.executor_configuration_revision != record.executor_configuration_revision
            .ok_or_else(|| db_error("remote executor stop has no executor revision"))?
        || pending.executor_checkout_path != required(&record.executor_checkout_path, "checkout")?
        || pending.source != offer.source
        || pending.session_id != identity.session_id
        || pending.run_id != identity.run_id
        || pending.workspace_ref != identity.workspace_ref
    {
        return Err(db_error(
            "remote executor stop authority contradicts assignment evidence",
        ));
    }
    let authority = stop_source_from_record(record, pending)?;
    if pending.authority_sha256 != authority.sha256()
        || pending.authority_acquired_at != authority.acquired_at()
        || !source_matches(record, &authority, pending.reason)?
    {
        return Err(db_error(
            "remote executor stop authority contradicts mutation authority",
        ));
    }
    nonblank(&pending.project_dir, "remote executor stop project directory")?;
    if pending.observed_launch_sha256.len() != 64
        || pending
            .observed_launch_sha256
            .chars()
            .any(|character| !character.is_ascii_digit() && !('a'..='f').contains(&character))
    {
        return Err(db_error(
            "remote executor stop observed launch digest is invalid",
        ));
    }
    canonical_time(&pending.run_started_at, "remote executor stop run start time")?;
    let authority_at = canonical_time(
        &pending.authority_acquired_at,
        "remote executor stop source authority time",
    )?;
    let acquired_at = canonical_time(&pending.acquired_at, "remote executor stop authority time")?;
    let run_started_at = canonical_time(&pending.run_started_at, "remote executor run start time")?;
    if acquired_at < authority_at || acquired_at < run_started_at {
        return Err(db_error("remote executor stop authority chronology is invalid"));
    }
    if stop_pending_digest(pending)? != pending.sha256 && !pending.sha256.is_empty() {
        return Err(db_error("remote executor stop authority digest mismatched"));
    }
    Ok(())
}

fn stop_source_from_record(
    record: &TaskBoardRemoteAssignmentRecord,
    pending: &TaskBoardRemoteExecutorStopPending,
) -> Result<TaskBoardRemoteExecutorStopAuthority, CliError> {
    match pending.authority_kind {
        StopAuthorityKind::Start => {
            if pending.start_receipt_sha256.is_some() {
                return Err(db_error("start stop authority unexpectedly has a start receipt"));
            }
            executor_start_io_permit(record)?
                .map(TaskBoardRemoteExecutorStopAuthority::Start)
                .ok_or_else(|| db_error("remote executor stop has no start authority"))
        }
        StopAuthorityKind::PrePermit => {
            if pending.start_receipt_sha256.is_some() {
                return Err(db_error(
                    "pre-permit stop authority unexpectedly has a start receipt",
                ));
            }
            if record.executor_start_io_permit_sha256.is_some() {
                return Err(db_error(
                    "pre-permit stop authority unexpectedly has a Start I/O permit",
                ));
            }
            executor_start_authority(record)?
                .map(TaskBoardRemoteExecutorStopAuthority::PrePermit)
                .ok_or_else(|| db_error("remote executor stop has no start authority"))
        }
        StopAuthorityKind::Lifecycle => {
            let receipt = record
                .start_receipt
                .as_ref()
                .ok_or_else(|| db_error("lifecycle stop authority has no start receipt"))?;
            if pending.start_receipt_sha256.as_deref() != Some(receipt.sha256.as_str()) {
                return Err(db_error("lifecycle stop authority start receipt mismatched"));
            }
            record
                .executor_lifecycle_owner
                .clone()
                .map(TaskBoardRemoteExecutorStopAuthority::Lifecycle)
                .ok_or_else(|| db_error("remote executor stop has no lifecycle owner"))
        }
    }
}

pub(super) fn stop_request_replays(
    pending: &TaskBoardRemoteExecutorStopPending,
    authority: &TaskBoardRemoteExecutorStopAuthority,
    snapshot: &CodexRunSnapshot,
    reason: TaskBoardRemoteExecutorStopReason,
) -> bool {
    pending.fencing_epoch == authority_fencing_epoch(authority)
        && pending.authority_kind == authority.kind()
        && pending.authority_sha256 == authority.sha256()
        && pending.authority_acquired_at == authority.acquired_at()
        && pending.reason == reason
        && stop_pending_snapshot_matches(pending, snapshot)
}

pub(super) fn stop_pending_values(
    pending: &TaskBoardRemoteExecutorStopPending,
) -> Result<(String, String), CliError> {
    let json = canonical_json(pending)?;
    if json.len() > MAX_STOP_PENDING_BYTES {
        return Err(db_error("remote executor stop authority exceeds its size limit"));
    }
    Ok((json, pending.sha256.clone()))
}

fn canonical_json(pending: &TaskBoardRemoteExecutorStopPending) -> Result<String, CliError> {
    serde_json::to_string(pending)
        .map_err(|error| db_error(format!("serialize remote executor stop authority: {error}")))
}

pub(in super::super) fn stop_pending_digest(
    pending: &TaskBoardRemoteExecutorStopPending,
) -> Result<String, CliError> {
    let json = canonical_json(pending)?;
    let mut hasher = Sha256::new();
    for value in [STOP_PENDING_DOMAIN, json.as_str()] {
        hasher.update(value.len().to_be_bytes());
        hasher.update(value.as_bytes());
    }
    Ok(hex::encode(hasher.finalize()))
}

fn required(value: &Option<String>, label: &str) -> Result<String, CliError> {
    value
        .clone()
        .ok_or_else(|| db_error(format!("remote executor stop has no {label}")))
}
