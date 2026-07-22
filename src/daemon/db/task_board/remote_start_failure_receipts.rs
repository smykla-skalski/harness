use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, canonical_time, nonblank,
};
use super::remote_assignment_start_authority::{
    TaskBoardRemoteExecutorStartIoPermit, remote_executor_identity, start_authority_digest,
    start_io_permit_digest_from_evidence,
};
use crate::daemon::db::{CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteStatusRequest, RemoteStatusResponse,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::TaskBoardFailureClass;

const START_FAILURE_RECEIPT_DOMAIN: &str =
    "harness.task-board.remote-executor-start-failure-receipt.v1";
const MAX_START_FAILURE_RECEIPT_BYTES: usize = 32_768;

/// Immutable proof of a no-run Start failure for one remote assignment: the Start
/// I/O permit authorized a Codex run that was then proven never to exist. It
/// embeds the exact sealed Failed-at-Claimed status so the durable typed status
/// is returned byte-exact, tamper-bound by this receipt's own digest, without
/// overloading the `result_json` execution-result column.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct TaskBoardRemoteExecutorStartFailureReceipt {
    pub(crate) schema_version: u32,
    pub(crate) assignment_id: String,
    pub(crate) fencing_epoch: u64,
    pub(crate) offer_request_sha256: String,
    pub(crate) claim_receipt_sha256: String,
    pub(crate) start_authority_sha256: String,
    pub(crate) start_authority_at: String,
    pub(crate) start_io_permit_sha256: String,
    pub(crate) start_io_permit_at: String,
    pub(crate) run_id: String,
    pub(crate) error_code: String,
    pub(crate) failure_class: TaskBoardFailureClass,
    pub(crate) status_sha256: String,
    pub(crate) observed_at: String,
    pub(crate) status_response: RemoteStatusResponse,
    #[serde(skip)]
    pub(crate) sha256: String,
}

pub(super) fn start_failure_receipt(
    record: &TaskBoardRemoteAssignmentRecord,
    permit: &TaskBoardRemoteExecutorStartIoPermit,
    response: &RemoteStatusResponse,
) -> Result<TaskBoardRemoteExecutorStartFailureReceipt, CliError> {
    let offer = record.require_offer()?;
    let claim_receipt = record
        .claim_receipt
        .as_ref()
        .ok_or_else(|| db_error("remote executor start failure receipt has no claim receipt"))?;
    let error_code = response
        .error_code
        .clone()
        .ok_or_else(|| db_error("no-run Start failure has no error code"))?;
    let failure_class = response
        .failure_class
        .ok_or_else(|| db_error("no-run Start failure has no failure class"))?;
    let mut receipt = TaskBoardRemoteExecutorStartFailureReceipt {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        assignment_id: record.assignment_id.clone(),
        fencing_epoch: record.fencing_epoch,
        offer_request_sha256: offer.request_sha256.clone(),
        claim_receipt_sha256: claim_receipt.sha256.clone(),
        start_authority_sha256: permit.authority.sha256.clone(),
        start_authority_at: permit.authority.acquired_at.clone(),
        start_io_permit_sha256: permit.sha256.clone(),
        start_io_permit_at: permit.permitted_at.clone(),
        run_id: permit.identity.run_id.clone(),
        error_code,
        failure_class,
        status_sha256: response.status_sha256.clone(),
        observed_at: response.observed_at.clone(),
        status_response: response.clone(),
        sha256: String::new(),
    };
    validate_failure_receipt_evidence(record, &receipt)?;
    receipt.sha256 = receipt_digest(&receipt)?;
    Ok(receipt)
}

pub(super) fn start_failure_receipt_values(
    receipt: &TaskBoardRemoteExecutorStartFailureReceipt,
) -> Result<(String, String), CliError> {
    let json = canonical_json(receipt)?;
    if json.len() > MAX_START_FAILURE_RECEIPT_BYTES {
        return Err(db_error(
            "remote executor start failure receipt exceeds its size limit",
        ));
    }
    Ok((json, receipt.sha256.clone()))
}

pub(super) fn decode_start_failure_receipt(
    record: &TaskBoardRemoteAssignmentRecord,
    receipt_json: Option<String>,
    receipt_sha256: Option<String>,
) -> Result<Option<TaskBoardRemoteExecutorStartFailureReceipt>, CliError> {
    let (receipt_json, receipt_sha256) = match (receipt_json, receipt_sha256) {
        (None, None) => return Ok(None),
        (Some(json), Some(sha256)) => (json, sha256),
        _ => return Err(db_error("remote executor start failure receipt is incomplete")),
    };
    if receipt_json.len() > MAX_START_FAILURE_RECEIPT_BYTES {
        return Err(db_error(
            "remote executor start failure receipt exceeds its size limit",
        ));
    }
    let mut receipt =
        serde_json::from_str::<TaskBoardRemoteExecutorStartFailureReceipt>(&receipt_json)
            .map_err(|error| {
                db_error(format!("decode remote executor start failure receipt: {error}"))
            })?;
    if canonical_json(&receipt)? != receipt_json {
        return Err(db_error(
            "remote executor start failure receipt is not canonical",
        ));
    }
    receipt.sha256 = receipt_sha256;
    validate_failure_receipt_evidence(record, &receipt)?;
    if receipt_digest(&receipt)? != receipt.sha256 {
        return Err(db_error(
            "remote executor start failure receipt contradicts durable assignment evidence",
        ));
    }
    Ok(Some(receipt))
}

fn validate_failure_receipt_evidence(
    record: &TaskBoardRemoteAssignmentRecord,
    receipt: &TaskBoardRemoteExecutorStartFailureReceipt,
) -> Result<(), CliError> {
    let offer = record.require_offer()?;
    let identity = remote_executor_identity(record)?;
    let expected_authority_sha256 =
        start_authority_digest(record, &identity, &receipt.start_authority_at)?;
    let expected_permit_sha256 = start_io_permit_digest_from_evidence(
        record,
        &expected_authority_sha256,
        &receipt.start_authority_at,
        required(&record.lease_id, "lease")?.as_str(),
        required(&record.lease_expires_at, "lease expiry")?.as_str(),
        required(&record.deadline_at, "deadline")?.as_str(),
        &receipt.start_io_permit_at,
    )?;
    if receipt.schema_version != TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION
        || receipt.assignment_id != record.assignment_id
        || receipt.fencing_epoch != record.fencing_epoch
        || receipt.offer_request_sha256 != offer.request_sha256
        || receipt.claim_receipt_sha256
            != record
                .claim_receipt
                .as_ref()
                .ok_or_else(|| {
                    db_error("remote executor start failure receipt has no claim receipt")
                })?
                .sha256
        || receipt.run_id != identity.run_id
        || !lower_sha256(&receipt.start_authority_sha256)
        || !lower_sha256(&receipt.start_io_permit_sha256)
        || !lower_sha256(&receipt.status_sha256)
        || receipt.start_authority_sha256 != expected_authority_sha256
        || receipt.start_io_permit_sha256 != expected_permit_sha256
        || receipt.failure_class == TaskBoardFailureClass::UnknownOutcome
    {
        return Err(db_error(
            "remote executor start failure receipt contradicts immutable assignment evidence",
        ));
    }
    nonblank(&receipt.error_code, "remote executor start failure error code")?;
    validate_embedded_status(record, receipt)?;
    validate_failure_receipt_times(receipt)
}

fn validate_embedded_status(
    record: &TaskBoardRemoteAssignmentRecord,
    receipt: &TaskBoardRemoteExecutorStartFailureReceipt,
) -> Result<(), CliError> {
    let status = &receipt.status_response;
    let request = RemoteStatusRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: record.require_offer()?.binding.clone(),
        lease_id: required(&record.lease_id, "lease")?,
        offer_request_sha256: record.require_offer()?.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .map_err(|error| db_error(format!("seal no-run failure status request: {error}")))?;
    status
        .validate(&request)
        .map_err(|error| db_error(format!("validate no-run failure status response: {error}")))?;
    let exact = status.state == RemoteAssignmentWireState::Failed
        && status.status_sha256 == receipt.status_sha256
        && status.observed_at == receipt.observed_at
        && status.claimed_at == record.claimed_at
        && status.started_at.is_none()
        && status.workspace_ref.is_none()
        && status.result.is_none()
        && status.output_artifacts.entries.is_empty()
        && status.error_code.as_deref() == Some(receipt.error_code.as_str())
        && status.failure_class == Some(receipt.failure_class)
        && status.lease.as_ref().is_some_and(|lease| {
            record.lease_id.as_deref() == Some(lease.lease_id.as_str())
                && record.lease_expires_at.as_deref() == Some(lease.expires_at.as_str())
        });
    if !exact {
        return Err(db_error(
            "remote executor start failure receipt status contradicts durable evidence",
        ));
    }
    Ok(())
}

fn required(value: &Option<String>, label: &str) -> Result<String, CliError> {
    value
        .clone()
        .ok_or_else(|| db_error(format!("remote executor start failure receipt has no {label}")))
}

fn validate_failure_receipt_times(
    receipt: &TaskBoardRemoteExecutorStartFailureReceipt,
) -> Result<(), CliError> {
    let authority = canonical_time(
        &receipt.start_authority_at,
        "remote executor start failure receipt authority time",
    )?;
    let permit = canonical_time(
        &receipt.start_io_permit_at,
        "remote executor start failure receipt Start I/O permit time",
    )?;
    let observed = canonical_time(
        &receipt.observed_at,
        "remote executor start failure receipt observation time",
    )?;
    if authority > permit || permit > observed {
        return Err(db_error(
            "remote executor start failure receipt chronology is invalid",
        ));
    }
    Ok(())
}

fn canonical_json(
    receipt: &TaskBoardRemoteExecutorStartFailureReceipt,
) -> Result<String, CliError> {
    serde_json::to_string(receipt).map_err(|error| {
        db_error(format!("serialize remote executor start failure receipt: {error}"))
    })
}

fn receipt_digest(
    receipt: &TaskBoardRemoteExecutorStartFailureReceipt,
) -> Result<String, CliError> {
    let json = canonical_json(receipt)?;
    let mut hasher = Sha256::new();
    for value in [START_FAILURE_RECEIPT_DOMAIN, json.as_str()] {
        hasher.update(value.len().to_be_bytes());
        hasher.update(value.as_bytes());
    }
    Ok(hex::encode(hasher.finalize()))
}

fn lower_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[cfg(test)]
#[path = "remote_start_failure_receipt_tests.rs"]
mod tests;
