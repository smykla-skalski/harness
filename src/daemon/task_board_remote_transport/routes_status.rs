use crate::daemon::db::{TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactManifest, RemoteAssignmentWireState, RemoteAttemptBinding, RemoteLease,
    RemoteStatusRequest, RemoteStatusResponse, RemoteWireError,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::errors::{CliError, CliErrorKind};

pub(super) fn mutation_record(
    outcome: TaskBoardRemoteMutationOutcome,
) -> Result<TaskBoardRemoteAssignmentRecord, CliError> {
    match outcome {
        TaskBoardRemoteMutationOutcome::Updated(record)
        | TaskBoardRemoteMutationOutcome::Replayed(record) => Ok(record),
        TaskBoardRemoteMutationOutcome::Stale(_) => Err(concurrent(
            "remote executor operation no longer matches its durable assignment",
        )),
    }
}

pub(super) fn verify_operation_record(
    record: &TaskBoardRemoteAssignmentRecord,
    binding: &RemoteAttemptBinding,
    lease_id: &str,
    offer_request_sha256: &str,
    principal: &str,
) -> Result<(), CliError> {
    let offer = record.require_offer()?;
    let matches = offer.binding == *binding
        && offer.request_sha256 == offer_request_sha256
        && record.authenticated_principal.as_deref() == Some(principal)
        && record.lease_id.as_deref() == Some(lease_id)
        && record.target_host_instance_id.as_deref() == Some(binding.host_instance_id.as_str());
    if matches {
        Ok(())
    } else {
        Err(concurrent(
            "remote executor request does not match its durable assignment evidence",
        ))
    }
}

pub(super) fn status_response(
    record: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteStatusRequest,
) -> Result<RemoteStatusResponse, CliError> {
    if let Some(response) = &record.status_response {
        response
            .validate(request)
            .map_err(wire_error("validate durable remote status"))?;
        return Ok(response.clone());
    }
    if matches!(
        record.wire_state(),
        RemoteAssignmentWireState::Completed | RemoteAssignmentWireState::Failed
    ) {
        return Err(concurrent(
            "terminal remote assignment has no durable typed status evidence",
        ));
    }
    let response = RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        state: record.wire_state(),
        offer_request_sha256: request.offer_request_sha256.clone(),
        status_sha256: String::new(),
        lease: durable_lease(record)?,
        result: None,
        output_artifacts: RemoteArtifactManifest::default(),
        claimed_at: record.claimed_at.clone(),
        started_at: record.started_at.clone(),
        workspace_ref: record.workspace_ref.clone(),
        error_code: record.error.clone(),
        failure_class: None,
        observed_at: record.updated_at.clone(),
    }
    .seal()
    .map_err(wire_error("seal remote status"))?;
    response
        .validate(request)
        .map_err(wire_error("validate remote status"))?;
    Ok(response)
}

fn durable_lease(
    record: &TaskBoardRemoteAssignmentRecord,
) -> Result<Option<RemoteLease>, CliError> {
    match (&record.lease_id, &record.lease_expires_at) {
        (Some(lease_id), Some(expires_at)) => Ok(Some(RemoteLease {
            lease_id: lease_id.clone(),
            expires_at: expires_at.clone(),
        })),
        (None, None) => Ok(None),
        _ => Err(concurrent(
            "remote assignment has incomplete durable lease evidence",
        )),
    }
}

fn wire_error(context: &'static str) -> impl FnOnce(RemoteWireError) -> CliError {
    move |error| CliErrorKind::workflow_parse(format!("{context}: {error}")).into()
}

fn concurrent(message: &'static str) -> CliError {
    CliErrorKind::concurrent_modification(message).into()
}
