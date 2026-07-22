use super::client::RemoteExecutionHttpError;
use super::controller::{RemoteExecutionControllerError, binding_error};
use super::wire::{
    RemoteAssignmentWireState, RemoteCancelRequest, RemoteCancelResponse,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::daemon::db::TaskBoardRemoteAssignmentRecord;
use crate::task_board::TaskBoardRemoteAssignmentState;

pub(super) fn durable_cancel_response(
    record: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteCancelRequest,
) -> Result<Option<RemoteCancelResponse>, RemoteExecutionControllerError> {
    if matches!(
        record.state,
        TaskBoardRemoteAssignmentState::Offered
            | TaskBoardRemoteAssignmentState::Claimed
            | TaskBoardRemoteAssignmentState::Started
            | TaskBoardRemoteAssignmentState::Running
    ) {
        return Ok(None);
    }
    if let Some(response) = status_reconciled_cancel_response(record, request)? {
        return Ok(Some(response));
    }
    let exact = record.state == TaskBoardRemoteAssignmentState::Cancelled
        && record.last_mutation_kind.as_deref() == Some("cancel_response")
        && record.error.as_deref() == Some(request.reason.as_str());
    if !exact {
        return Err(binding_error("remote cancel terminal evidence mismatched").into());
    }
    let expected_digest = record
        .last_mutation_sha256
        .as_deref()
        .ok_or_else(|| binding_error("remote cancel response digest is missing"))?;
    let mut matching = cancel_candidates(record, request)?
        .into_iter()
        .filter(|response| response.cancel_response_sha256 == expected_digest);
    let response = matching
        .next()
        .ok_or_else(|| binding_error("remote cancel response digest mismatched"))?;
    if matching.next().is_some() {
        return Err(binding_error("remote cancel response evidence is ambiguous").into());
    }
    Ok(Some(response))
}

fn status_reconciled_cancel_response(
    record: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteCancelRequest,
) -> Result<Option<RemoteCancelResponse>, RemoteExecutionControllerError> {
    if record.last_mutation_kind.as_deref() != Some("cancel") {
        return Ok(None);
    }
    let status = record
        .status_response
        .as_ref()
        .ok_or_else(|| binding_error("reconciled remote cancel status is missing"))?;
    let exact = record.state == TaskBoardRemoteAssignmentState::Cancelled
        && record.controller_operation.is_none()
        && record.last_mutation_sha256.as_deref() == Some(request.request_sha256.as_str())
        && record.error.as_deref() == Some(request.reason.as_str())
        && record.cancel_requested_at.is_some()
        && record.completed_at.as_deref() == Some(status.observed_at.as_str())
        && record.status_sha256.as_deref() == Some(status.status_sha256.as_str())
        && record.lease_id.as_deref() == Some(request.lease_id.as_str())
        && status.confirms_cancel(request)
        && status.claimed_at == record.claimed_at
        && status.started_at == record.started_at
        && status.workspace_ref == record.workspace_ref;
    if !exact {
        return Err(binding_error("reconciled remote cancel evidence mismatched").into());
    }
    RemoteCancelResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        offer_request_sha256: request.offer_request_sha256.clone(),
        cancel_response_sha256: String::new(),
        state: RemoteAssignmentWireState::Cancelled,
        claimed_at: status.claimed_at.clone(),
        started_at: status.started_at.clone(),
        workspace_ref: status.workspace_ref.clone(),
        observed_at: status.observed_at.clone(),
    }
    .seal(request)
    .map(Some)
    .map_err(RemoteExecutionHttpError::Wire)
    .map_err(Into::into)
}

fn cancel_candidates(
    record: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteCancelRequest,
) -> Result<Vec<RemoteCancelResponse>, RemoteExecutionControllerError> {
    let observed_at = record
        .completed_at
        .clone()
        .ok_or_else(|| binding_error("remote cancel time is missing"))?;
    let stages = match (
        &record.claimed_at,
        &record.started_at,
        &record.workspace_ref,
    ) {
        (None, None, None) => vec![(None, None, None)],
        (Some(claimed_at), None, None) => {
            vec![(None, None, None), (Some(claimed_at.clone()), None, None)]
        }
        (Some(claimed_at), Some(started_at), Some(workspace_ref)) => vec![(
            Some(claimed_at.clone()),
            Some(started_at.clone()),
            Some(workspace_ref.clone()),
        )],
        _ => return Err(binding_error("remote cancel run evidence is malformed").into()),
    };
    stages
        .into_iter()
        .map(|(claimed_at, started_at, workspace_ref)| {
            RemoteCancelResponse {
                schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
                binding: request.binding.clone(),
                offer_request_sha256: request.offer_request_sha256.clone(),
                cancel_response_sha256: String::new(),
                state: RemoteAssignmentWireState::Cancelled,
                claimed_at,
                started_at,
                workspace_ref,
                observed_at: observed_at.clone(),
            }
            .seal(request)
            .map_err(RemoteExecutionHttpError::Wire)
            .map_err(Into::into)
        })
        .collect()
}
