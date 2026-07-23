use chrono::Duration;

use crate::daemon::db::TaskBoardRemoteOperationTrustFence;
use crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest;
use crate::errors::CliError;
use crate::task_board::{
    TaskBoardExecutionAttemptRecord, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionRecord,
};

pub(crate) struct PreparedRemoteReassignment {
    pub(crate) request: RemoteOfferRequest,
    pub(crate) offered_at: String,
    pub(crate) lease_expires_at: String,
}

pub(crate) fn prepare_source_reassignment(
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    predecessor: &RemoteOfferRequest,
    trust: &TaskBoardRemoteOperationTrustFence,
    now: &str,
) -> Result<PreparedRemoteReassignment, CliError> {
    let fencing_epoch = predecessor
        .binding
        .fencing_epoch
        .checked_add(1)
        .ok_or_else(|| super::invalid("remote source reassignment epoch overflow"))?;
    let mut binding = predecessor.binding.clone();
    binding.assignment_id =
        super::deterministic_assignment_id(execution, attempt, &binding.host_id, fencing_epoch);
    binding
        .host_instance_id
        .clone_from(&trust.observed_host_instance_id);
    binding.fencing_epoch = fencing_epoch;
    binding.execution_record_sha256 = TaskBoardWorkflowExecutionCas::from(execution).record_sha256;
    let mut request = predecessor.clone();
    request.binding = binding;
    request.request_sha256.clear();
    let request = request
        .seal()
        .map_err(|error| super::invalid(format!("seal replacement remote offer: {error}")))?;
    let offered_at = super::canonical_time(now, "source reassignment offer time")?;
    let lease_expires_at = offered_at + Duration::seconds(i64::from(request.lease_seconds));
    Ok(PreparedRemoteReassignment {
        request,
        offered_at: super::canonical(offered_at),
        lease_expires_at: super::canonical(lease_expires_at),
    })
}
