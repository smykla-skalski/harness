use chrono::Duration;

use super::super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, canonical_time, concurrent, nonblank,
};
use super::super::remote_operation_trust::TaskBoardRemoteOperationTrustFence;
use super::super::remote_source_bundle_reassignment_evidence::SourceReassignmentEvidence;
use crate::daemon::db::{CliError, db_error};
use crate::task_board::remote_wire::wire::RemoteOfferRequest;
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE, TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE,
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TaskBoardRemoteAssignmentState,
    TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord,
};

pub(super) fn require_preclaim_predecessor(
    record: &TaskBoardRemoteAssignmentRecord,
    offer: &RemoteOfferRequest,
    principal: &str,
) -> Result<(), CliError> {
    let exact = record.state == TaskBoardRemoteAssignmentState::Offered
        && record.offer.as_ref() == Some(offer)
        && record.authenticated_principal.as_deref() == Some(principal)
        && record.claim_receipt.is_none()
        && record.lease_id.is_none()
        && record.claimed_at.is_none()
        && record.started_at.is_none()
        && record.workspace_ref.is_none()
        && record.start_receipt.is_none()
        && record.executor_start_authority_sha256.is_none()
        && record.executor_lifecycle_owner.is_none()
        && record.executor_stop_pending.is_none()
        && record.status_response.is_none()
        && record.result_sha256.is_none()
        && record.cleanup_completed_at.is_none();
    if exact {
        Ok(())
    } else {
        Err(concurrent(
            "source reassignment predecessor has accepted or running evidence",
        ))
    }
}

pub(super) fn validate_replacement(
    parent: &TaskBoardWorkflowExecutionRecord,
    predecessor: &TaskBoardRemoteAssignmentRecord,
    expected_execution: &TaskBoardWorkflowExecutionCas,
    replacement: &RemoteOfferRequest,
    trust: &TaskBoardRemoteOperationTrustFence,
) -> Result<(), CliError> {
    let old = predecessor.require_offer()?;
    let mut expected_binding = old.binding.clone();
    expected_binding
        .assignment_id
        .clone_from(&replacement.binding.assignment_id);
    expected_binding
        .host_instance_id
        .clone_from(&trust.observed_host_instance_id);
    expected_binding.fencing_epoch = old
        .binding
        .fencing_epoch
        .checked_add(1)
        .ok_or_else(|| db_error("remote source reassignment epoch overflow"))?;
    expected_binding
        .execution_record_sha256
        .clone_from(&expected_execution.record_sha256);
    let exact = replacement.binding == expected_binding
        && replacement.binding.assignment_id != old.binding.assignment_id
        && replacement.lease_seconds == old.lease_seconds
        && replacement.deadline_at == old.deadline_at
        && replacement.launch == old.launch
        && replacement.source == old.source
        && replacement.artifacts == old.artifacts
        && predecessor.host_id == trust.host.config.host_id
        && parent.ownership.fencing_epoch == predecessor.fencing_epoch
        && active_target_matches(parent, predecessor);
    if exact {
        Ok(())
    } else {
        Err(concurrent(
            "replacement offer changed the frozen source, launch, attempt, or host contract",
        ))
    }
}

fn active_target_matches(
    parent: &TaskBoardWorkflowExecutionRecord,
    predecessor: &TaskBoardRemoteAssignmentRecord,
) -> bool {
    let attempt = predecessor.attempt.map(|value| value.to_string());
    parent.ownership.host_id.as_deref() == Some(predecessor.host_id.as_str())
        && parent
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            .is_some_and(|target| target == &format!("remote:{}", predecessor.assignment_id))
        && parent
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE)
            == predecessor.action_key.as_ref()
        && parent
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE)
            .map(String::as_str)
            == attempt.as_deref()
}

pub(super) fn replacement_parent(
    parent: &TaskBoardWorkflowExecutionRecord,
    replacement: &RemoteOfferRequest,
    offered_at: &str,
) -> Result<TaskBoardWorkflowExecutionRecord, CliError> {
    if canonical_time(offered_at, "source reassignment offer time")?
        < canonical_time(&parent.updated_at, "source reassignment parent time")?
    {
        return Err(concurrent("source reassignment time precedes parent state"));
    }
    let mut updated = parent.clone();
    updated.ownership.fencing_epoch = replacement.binding.fencing_epoch;
    updated.ownership.resources.insert(
        TASK_BOARD_EXECUTION_TARGET_RESOURCE.into(),
        format!("remote:{}", replacement.binding.assignment_id),
    );
    updated.updated_at = offered_at.into();
    Ok(updated)
}

pub(super) fn validate_reassignment_input(
    evidence: SourceReassignmentEvidence<'_>,
    replacement: &RemoteOfferRequest,
    principal: &str,
    trust: &TaskBoardRemoteOperationTrustFence,
    offered_at: &str,
    lease_expires_at: &str,
) -> Result<(), CliError> {
    evidence.validate()?;
    replacement
        .validate()
        .map_err(|error| db_error(format!("validate replacement source offer: {error}")))?;
    nonblank(principal, "replacement source offer principal")?;
    let offered = canonical_time(offered_at, "replacement source offer time")?;
    let lease = canonical_time(lease_expires_at, "replacement source lease expiry")?;
    let deadline = canonical_time(&replacement.deadline_at, "replacement source deadline")?;
    let expected_lease = offered + Duration::seconds(i64::from(replacement.lease_seconds));
    let exact = lease == expected_lease
        && lease <= deadline
        && principal == replacement.binding.host_id
        && replacement.binding.host_id == trust.host.config.host_id
        && replacement.binding.host_instance_id == trust.observed_host_instance_id;
    if exact {
        Ok(())
    } else {
        Err(concurrent(
            "replacement source offer time, lease, principal, or trust mismatched",
        ))
    }
}
