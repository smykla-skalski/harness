use std::path::{Component, Path};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::{Sqlite, Transaction, query_scalar};

use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, canonical_time, nonblank,
};
use super::remote_assignment_start_authority::{
    TaskBoardRemoteExecutorStartIoPermit, remote_executor_identity,
    start_io_permit_digest_from_evidence,
};
use crate::daemon::db::{CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteSourceMaterial, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::TaskBoardExecutionPhase;

const START_RECEIPT_DOMAIN: &str = "harness.task-board.remote-executor-start-receipt.v1";
const MAX_START_RECEIPT_BYTES: usize = 32_768;

/// Immutable proof of the exact local run adopted for one remote assignment.
///
/// The receipt deliberately preserves the initial lifecycle owner. Later owner
/// leases may rotate without changing the start decision or reopening Codex I/O.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct TaskBoardRemoteExecutorStartReceipt {
    pub(crate) schema_version: u32,
    pub(crate) assignment_id: String,
    pub(crate) fencing_epoch: u64,
    pub(crate) offer_request_sha256: String,
    pub(crate) claim_receipt_sha256: String,
    pub(crate) start_authority_sha256: String,
    pub(crate) start_authority_at: String,
    pub(crate) start_io_permit_sha256: String,
    pub(crate) start_io_permit_at: String,
    pub(crate) start_io_lease_id: String,
    pub(crate) start_io_lease_expires_at: String,
    pub(crate) start_io_deadline_at: String,
    pub(crate) session_id: String,
    pub(crate) run_id: String,
    pub(crate) workspace_ref: String,
    pub(crate) project_dir: String,
    pub(crate) started_at: String,
    pub(crate) executor_configuration_revision: u64,
    pub(crate) executor_checkout_path: String,
    pub(crate) source: RemoteSourceMaterial,
    pub(crate) initial_owner_instance_id: String,
    pub(crate) initial_owner_epoch: u64,
    pub(crate) initial_owner_acquired_at: String,
    pub(crate) initial_owner_expires_at: String,
    #[serde(skip)]
    pub(crate) sha256: String,
}

#[allow(clippy::too_many_arguments)]
pub(super) fn start_receipt(
    record: &TaskBoardRemoteAssignmentRecord,
    permit: &TaskBoardRemoteExecutorStartIoPermit,
    project_dir: &str,
    started_at: &str,
    owner_instance_id: &str,
    owner_acquired_at: &str,
    owner_expires_at: &str,
) -> Result<TaskBoardRemoteExecutorStartReceipt, CliError> {
    let offer = record.require_offer()?;
    let claim_receipt = record
        .claim_receipt
        .as_ref()
        .ok_or_else(|| db_error("remote executor start receipt has no claim receipt"))?;
    let mut receipt = TaskBoardRemoteExecutorStartReceipt {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        assignment_id: record.assignment_id.clone(),
        fencing_epoch: record.fencing_epoch,
        offer_request_sha256: offer.request_sha256.clone(),
        claim_receipt_sha256: claim_receipt.sha256.clone(),
        start_authority_sha256: permit.authority.sha256.clone(),
        start_authority_at: permit.authority.acquired_at.clone(),
        start_io_permit_sha256: permit.sha256.clone(),
        start_io_permit_at: permit.permitted_at.clone(),
        start_io_lease_id: permit.lease_id.clone(),
        start_io_lease_expires_at: permit.lease_expires_at.clone(),
        start_io_deadline_at: permit.deadline_at.clone(),
        session_id: permit.identity.session_id.clone(),
        run_id: permit.identity.run_id.clone(),
        workspace_ref: permit.identity.workspace_ref.clone(),
        project_dir: project_dir.into(),
        started_at: started_at.into(),
        executor_configuration_revision: record.executor_configuration_revision.ok_or_else(
            || db_error("remote executor start receipt has no executor revision"),
        )?,
        executor_checkout_path: required(&record.executor_checkout_path, "checkout")?,
        source: offer.source.clone(),
        initial_owner_instance_id: owner_instance_id.into(),
        initial_owner_epoch: 1,
        initial_owner_acquired_at: owner_acquired_at.into(),
        initial_owner_expires_at: owner_expires_at.into(),
        sha256: String::new(),
    };
    validate_receipt_evidence(record, &receipt)?;
    receipt.sha256 = receipt_digest(&receipt)?;
    Ok(receipt)
}

pub(super) fn start_receipt_values(
    receipt: &TaskBoardRemoteExecutorStartReceipt,
) -> Result<(String, String), CliError> {
    let json = canonical_json(receipt)?;
    if json.len() > MAX_START_RECEIPT_BYTES {
        return Err(db_error("remote executor start receipt exceeds its size limit"));
    }
    Ok((json, receipt.sha256.clone()))
}

pub(super) fn decode_start_receipt(
    record: &TaskBoardRemoteAssignmentRecord,
    receipt_json: Option<String>,
    receipt_sha256: Option<String>,
) -> Result<Option<TaskBoardRemoteExecutorStartReceipt>, CliError> {
    let (receipt_json, receipt_sha256) = match (receipt_json, receipt_sha256) {
        (None, None) => {
            if receipt_required(record) {
                return Err(db_error("remote executor start receipt is missing"));
            }
            return Ok(None);
        }
        (Some(json), Some(sha256)) => (json, sha256),
        _ => return Err(db_error("remote executor start receipt is incomplete")),
    };
    if receipt_json.len() > MAX_START_RECEIPT_BYTES {
        return Err(db_error("remote executor start receipt exceeds its size limit"));
    }
    let mut receipt = serde_json::from_str::<TaskBoardRemoteExecutorStartReceipt>(&receipt_json)
        .map_err(|error| db_error(format!("decode remote executor start receipt: {error}")))?;
    if canonical_json(&receipt)? != receipt_json {
        return Err(db_error("remote executor start receipt is not canonical"));
    }
    receipt.sha256 = receipt_sha256;
    validate_receipt_evidence(record, &receipt)?;
    if record.started_at.as_deref() != Some(receipt.started_at.as_str())
        || record.workspace_ref.as_deref() != Some(receipt.workspace_ref.as_str())
        || receipt_digest(&receipt)? != receipt.sha256
    {
        return Err(db_error(
            "remote executor start receipt contradicts durable assignment evidence",
        ));
    }
    Ok(Some(receipt))
}

pub(super) fn receipt_matches_permit(
    receipt: &TaskBoardRemoteExecutorStartReceipt,
    permit: &TaskBoardRemoteExecutorStartIoPermit,
    project_dir: &str,
    started_at: &str,
) -> bool {
    receipt.assignment_id == permit.assignment_id
        && receipt.fencing_epoch == permit.fencing_epoch
        && receipt.start_authority_sha256 == permit.authority.sha256
        && receipt.start_authority_at == permit.authority.acquired_at
        && receipt.start_io_permit_sha256 == permit.sha256
        && receipt.start_io_permit_at == permit.permitted_at
        && receipt.start_io_lease_id == permit.lease_id
        && receipt.start_io_lease_expires_at == permit.lease_expires_at
        && receipt.start_io_deadline_at == permit.deadline_at
        && receipt.session_id == permit.identity.session_id
        && receipt.run_id == permit.identity.run_id
        && receipt.workspace_ref == permit.identity.workspace_ref
        && receipt.project_dir == project_dir
        && receipt.started_at == started_at
}

pub(super) async fn durable_start_receipt_run_matches(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    receipt: &TaskBoardRemoteExecutorStartReceipt,
) -> Result<bool, CliError> {
    let offer = record.require_offer()?;
    let mode = match offer.binding.phase {
        TaskBoardExecutionPhase::Implementation => "workspace_write",
        TaskBoardExecutionPhase::Review | TaskBoardExecutionPhase::Evaluate => "report",
        _ => return Err(db_error("remote executor start has an unsupported phase")),
    };
    query_scalar::<_, bool>(
        "SELECT EXISTS(
           SELECT 1 FROM codex_runs AS runs
           JOIN sessions ON sessions.session_id = runs.session_id
           WHERE runs.run_id = ?1 AND runs.session_id = ?2
             AND runs.workflow_execution_id = ?3 AND runs.project_dir = ?4
             AND runs.mode = ?5 AND runs.prompt = ?6 AND runs.created_at = ?7
             AND runs.task_id IS ?8 AND runs.board_item_id = ?9
             AND runs.display_name = ?10
             AND (runs.thread_id IS NULL OR length(trim(runs.thread_id)) > 0)
             AND runs.model IS ?11 AND runs.effort IS ?12
             AND json_valid(sessions.state_json)
             AND json_extract(sessions.state_json, '$.session_id') = ?2
             AND json_extract(sessions.state_json, '$.worktree_path') = ?4
         )",
    )
    .bind(&receipt.run_id)
    .bind(&receipt.session_id)
    .bind(&record.execution_id)
    .bind(&receipt.project_dir)
    .bind(mode)
    .bind(&offer.launch.prompt)
    .bind(&receipt.started_at)
    .bind(&offer.launch.task_id)
    .bind(&offer.launch.board_item_id)
    .bind(&offer.launch.display_name)
    .bind(&offer.launch.model)
    .bind(&offer.launch.effort)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("verify remote executor start receipt run: {error}")))
}

fn receipt_required(record: &TaskBoardRemoteAssignmentRecord) -> bool {
    !record.legacy_migrated
        && record.executor_configuration_revision.is_some()
        && (record.started_at.is_some()
            || record.workspace_ref.is_some()
            || record.executor_lifecycle_owner.is_some())
}

fn validate_receipt_evidence(
    record: &TaskBoardRemoteAssignmentRecord,
    receipt: &TaskBoardRemoteExecutorStartReceipt,
) -> Result<(), CliError> {
    let offer = record.require_offer()?;
    if receipt.schema_version != TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION
        || receipt.assignment_id != record.assignment_id
        || receipt.fencing_epoch != record.fencing_epoch
        || receipt.offer_request_sha256 != offer.request_sha256
        || receipt.claim_receipt_sha256
            != record
                .claim_receipt
                .as_ref()
                .ok_or_else(|| db_error("remote executor start receipt has no claim receipt"))?
                .sha256
        || receipt.executor_configuration_revision != record.executor_configuration_revision
            .ok_or_else(|| db_error("remote executor start receipt has no executor revision"))?
        || receipt.executor_checkout_path
            != required(&record.executor_checkout_path, "checkout")?
        || receipt.source != offer.source
        || !lower_sha256(&receipt.start_authority_sha256)
        || !lower_sha256(&receipt.start_io_permit_sha256)
        || receipt.start_io_permit_sha256
            != start_io_permit_digest_from_evidence(
                record,
                &receipt.start_authority_sha256,
                &receipt.start_authority_at,
                &receipt.start_io_lease_id,
                &receipt.start_io_lease_expires_at,
                &receipt.start_io_deadline_at,
                &receipt.start_io_permit_at,
            )?
    {
        return Err(db_error(
            "remote executor start receipt contradicts immutable assignment evidence",
        ));
    }
    validate_receipt_identity(record, receipt)?;
    validate_receipt_times(receipt)
}

fn validate_receipt_identity(
    record: &TaskBoardRemoteAssignmentRecord,
    receipt: &TaskBoardRemoteExecutorStartReceipt,
) -> Result<(), CliError> {
    let identity = remote_executor_identity(record)?;
    for (field, value) in [
        ("session", receipt.session_id.as_str()),
        ("run", receipt.run_id.as_str()),
        ("workspace", receipt.workspace_ref.as_str()),
        ("project directory", receipt.project_dir.as_str()),
        ("initial owner", receipt.initial_owner_instance_id.as_str()),
        ("Start I/O lease", receipt.start_io_lease_id.as_str()),
    ] {
        nonblank(value, &format!("remote executor start receipt {field}"))?;
    }
    let path = Path::new(&receipt.project_dir);
    if !path.is_absolute()
        || path.components().any(|component| {
            matches!(component, Component::CurDir | Component::ParentDir)
        })
        || receipt.session_id != identity.session_id
        || receipt.run_id != identity.run_id
        || receipt.workspace_ref != identity.workspace_ref
        || receipt.initial_owner_epoch != 1
    {
        return Err(db_error("remote executor start receipt identity is invalid"));
    }
    Ok(())
}

fn validate_receipt_times(
    receipt: &TaskBoardRemoteExecutorStartReceipt,
) -> Result<(), CliError> {
    let authority = canonical_time(
        &receipt.start_authority_at,
        "remote executor start receipt authority time",
    )?;
    let permit = canonical_time(
        &receipt.start_io_permit_at,
        "remote executor start receipt Start I/O permit time",
    )?;
    let lease = canonical_time(
        &receipt.start_io_lease_expires_at,
        "remote executor start receipt Start I/O lease expiry",
    )?;
    let deadline = canonical_time(
        &receipt.start_io_deadline_at,
        "remote executor start receipt Start I/O deadline",
    )?;
    let started = canonical_time(
        &receipt.started_at,
        "remote executor start receipt durable start time",
    )?;
    let owner = canonical_time(
        &receipt.initial_owner_acquired_at,
        "remote executor start receipt owner time",
    )?;
    let owner_expiry = canonical_time(
        &receipt.initial_owner_expires_at,
        "remote executor start receipt owner expiry",
    )?;
    if authority > permit
        || permit > started
        || permit >= lease
        || permit >= deadline
        || started > owner
        || owner >= owner_expiry
    {
        return Err(db_error("remote executor start receipt chronology is invalid"));
    }
    Ok(())
}

fn canonical_json(receipt: &TaskBoardRemoteExecutorStartReceipt) -> Result<String, CliError> {
    serde_json::to_string(receipt)
        .map_err(|error| db_error(format!("serialize remote executor start receipt: {error}")))
}

fn receipt_digest(receipt: &TaskBoardRemoteExecutorStartReceipt) -> Result<String, CliError> {
    let json = canonical_json(receipt)?;
    let mut hasher = Sha256::new();
    for value in [START_RECEIPT_DOMAIN, json.as_str()] {
        hasher.update(value.len().to_be_bytes());
        hasher.update(value.as_bytes());
    }
    Ok(hex::encode(hasher.finalize()))
}

fn required(value: &Option<String>, label: &str) -> Result<String, CliError> {
    value
        .clone()
        .ok_or_else(|| db_error(format!("remote executor start receipt has no {label}")))
}

fn lower_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
