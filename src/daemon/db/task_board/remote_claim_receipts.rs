use sha2::{Digest, Sha256};

use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, concurrent, nonblank,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteClaimRequest, RemoteClaimResponse, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};

const CLAIM_RECEIPT_DOMAIN: &str = "harness.task-board.remote-claim-receipt.v1";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteClaimReceipt {
    pub(crate) request_sha256: String,
    pub(crate) response: RemoteClaimResponse,
    pub(crate) sha256: String,
}

impl AsyncDaemonDb {
    pub(crate) async fn exact_task_board_remote_claim_receipt(
        &self,
        request: &RemoteClaimRequest,
        principal: &str,
    ) -> Result<Option<(RemoteClaimResponse, TaskBoardRemoteAssignmentRecord)>, CliError> {
        request
            .validate()
            .map_err(|error| db_error(format!("validate remote claim replay: {error}")))?;
        nonblank(principal, "remote claim replay principal")?;
        let Some(record) = self
            .task_board_remote_assignment(&request.binding.assignment_id)
            .await?
        else {
            return Ok(None);
        };
        match exact_claim_response(&record, request, principal)? {
            Some(response) => Ok(Some((response, record))),
            None if record.claim_receipt.is_none() => Ok(None),
            None => Err(concurrent("remote claim receipt conflicts with replay")),
        }
    }
}

pub(super) fn claim_response_for_record(
    record: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteClaimRequest,
    claimed_at: &str,
) -> Result<RemoteClaimResponse, CliError> {
    let lease_expires_at = record
        .lease_expires_at
        .clone()
        .ok_or_else(|| db_error("remote claim receipt has no lease expiry"))?;
    Ok(RemoteClaimResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        offer_request_sha256: request.offer_request_sha256.clone(),
        lease: crate::daemon::task_board_remote_transport::wire::RemoteLease {
            lease_id: request.lease_id.clone(),
            expires_at: lease_expires_at,
        },
        claimed_at: claimed_at.into(),
    })
}

pub(super) fn claim_receipt_values(
    record: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteClaimRequest,
    response: &RemoteClaimResponse,
    principal: &str,
) -> Result<(String, String), CliError> {
    request
        .validate()
        .map_err(|error| db_error(format!("validate remote claim receipt request: {error}")))?;
    response
        .validate(request)
        .map_err(|error| db_error(format!("validate remote claim receipt response: {error}")))?;
    if response.lease.lease_id != request.lease_id
        || record.authenticated_principal.as_deref() != Some(principal)
    {
        return Err(concurrent("remote claim receipt evidence mismatched"));
    }
    let response_json = serde_json::to_string(response)
        .map_err(|error| db_error(format!("serialize remote claim receipt: {error}")))?;
    if response_json.len() > 16_384 {
        return Err(db_error("remote claim receipt exceeds its size limit"));
    }
    let sha256 = receipt_digest(
        &record.assignment_id,
        record.fencing_epoch,
        principal,
        &request.request_sha256,
        &response_json,
    );
    Ok((response_json, sha256))
}

#[allow(clippy::too_many_arguments)]
pub(super) fn decode_claim_receipt(
    assignment_id: &str,
    fencing_epoch: u64,
    offer: Option<&crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest>,
    principal: Option<&str>,
    claimed_at: Option<&str>,
    request_sha256: Option<String>,
    response_json: Option<String>,
    receipt_sha256: Option<String>,
) -> Result<Option<TaskBoardRemoteClaimReceipt>, CliError> {
    let (request_sha256, response_json, receipt_sha256) =
        match (request_sha256, response_json, receipt_sha256) {
            (Some(request), Some(response), Some(receipt)) => (request, response, receipt),
            (None, None, None) => return Ok(None),
            _ => return Err(db_error("remote claim receipt is incomplete")),
        };
    let offer = offer.ok_or_else(|| db_error("remote claim receipt has no offer"))?;
    let principal = principal.ok_or_else(|| db_error("remote claim receipt has no principal"))?;
    let response = serde_json::from_str::<RemoteClaimResponse>(&response_json)
        .map_err(|error| db_error(format!("decode remote claim receipt: {error}")))?;
    let request = RemoteClaimRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: response.lease.lease_id.clone(),
        offer_request_sha256: offer.request_sha256.clone(),
        request_sha256: request_sha256.clone(),
    };
    request
        .validate()
        .map_err(|error| db_error(format!("validate remote claim receipt request: {error}")))?;
    response
        .validate(&request)
        .map_err(|error| db_error(format!("validate remote claim receipt response: {error}")))?;
    if claimed_at != Some(response.claimed_at.as_str())
        || receipt_sha256
            != receipt_digest(
                assignment_id,
                fencing_epoch,
                principal,
                &request_sha256,
                &response_json,
            )
    {
        return Err(db_error(
            "remote claim receipt contradicts durable assignment evidence",
        ));
    }
    Ok(Some(TaskBoardRemoteClaimReceipt {
        request_sha256,
        response,
        sha256: receipt_sha256,
    }))
}

pub(super) fn exact_claim_response(
    record: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteClaimRequest,
    principal: &str,
) -> Result<Option<RemoteClaimResponse>, CliError> {
    let Some(receipt) = record.claim_receipt.as_ref() else {
        return Ok(None);
    };
    let exact = record.authenticated_principal.as_deref() == Some(principal)
        && receipt.request_sha256 == request.request_sha256
        && receipt.response.binding == request.binding
        && receipt.response.offer_request_sha256 == request.offer_request_sha256
        && receipt.response.lease.lease_id == request.lease_id;
    Ok(exact.then(|| receipt.response.clone()))
}

fn receipt_digest(
    assignment_id: &str,
    fencing_epoch: u64,
    principal: &str,
    request_sha256: &str,
    response_json: &str,
) -> String {
    let mut hasher = Sha256::new();
    let fencing_epoch = fencing_epoch.to_string();
    for value in [
        CLAIM_RECEIPT_DOMAIN,
        assignment_id,
        &fencing_epoch,
        principal,
        request_sha256,
        response_json,
    ] {
        hasher.update(value.len().to_be_bytes());
        hasher.update(value.as_bytes());
    }
    hex::encode(hasher.finalize())
}
