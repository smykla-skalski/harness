use sqlx::{Sqlite, Transaction};

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::remote_assignment_cancel_journal::journal_cancel_claim_in_tx;
use super::remote_assignment_lease::commit_noop;
use super::remote_assignment_lease::renew_request_for_record;
use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, canonical_time, concurrent, load_assignment_in_tx,
};
use super::remote_operation_trust::{
    TaskBoardRemoteOperationKind, TaskBoardRemoteOperationTrustFence,
    claim_controller_operation_trust_in_tx,
};
use super::workflow_executions::{load_execution_in_tx, update_execution_in_tx};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteCancelRequest, RemoteAttemptBinding, RemoteLeaseRenewRequest,
};
#[cfg(test)]
use crate::daemon::task_board_remote_transport::wire::{RemoteClaimRequest, RemoteOfferRequest};
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE, TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE,
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TASK_BOARD_REMOTE_CANCEL_IO_AUTHORITY_RESOURCE,
    TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE, TASK_BOARD_REMOTE_OFFER_IO_AUTHORITY_RESOURCE,
    TASK_BOARD_REMOTE_RENEW_IO_AUTHORITY_RESOURCE, TaskBoardAttemptState, TaskBoardExecutionState,
    TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE, TaskBoardRemoteAssignmentState,
    TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionRecord, validate_task_board_workflow_execution,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TaskBoardRemoteIoAuthorityKind {
    Offer,
    Claim,
    Renew,
    Cancel,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteIoAuthority {
    pub(crate) assignment_id: String,
    pub(crate) kind: TaskBoardRemoteIoAuthorityKind,
    pub(crate) request_sha256: String,
}

impl AsyncDaemonDb {
    #[cfg(test)]
    pub(crate) async fn claim_task_board_remote_offer_io_authority(
        &self,
        request: &RemoteOfferRequest,
        authenticated_principal: &str,
        authority_at: &str,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
        request
            .validate()
            .map_err(|error| db_error(format!("validate remote offer I/O authority: {error}")))?;
        self.claim_remote_io_authority(
            &request.binding,
            &request.request_sha256,
            &request.request_sha256,
            None,
            authenticated_principal,
            TaskBoardRemoteIoAuthorityKind::Offer,
            authority_at,
            None,
            None,
            None,
        )
        .await
    }

    #[cfg(test)]
    pub(crate) async fn claim_task_board_remote_claim_io_authority(
        &self,
        request: &RemoteClaimRequest,
        authenticated_principal: &str,
        authority_at: &str,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
        request
            .validate()
            .map_err(|error| db_error(format!("validate remote claim I/O authority: {error}")))?;
        self.claim_remote_io_authority(
            &request.binding,
            &request.request_sha256,
            &request.offer_request_sha256,
            Some(&request.lease_id),
            authenticated_principal,
            TaskBoardRemoteIoAuthorityKind::Claim,
            authority_at,
            None,
            None,
            None,
        )
        .await
    }

    #[cfg(test)]
    pub(crate) async fn claim_task_board_remote_renew_io_authority(
        &self,
        request: &RemoteLeaseRenewRequest,
        authenticated_principal: &str,
        authority_at: &str,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
        request
            .validate()
            .map_err(|error| db_error(format!("validate remote renewal I/O authority: {error}")))?;
        self.claim_remote_io_authority(
            &request.binding,
            &request.request_sha256,
            &request.offer_request_sha256,
            Some(&request.lease_id),
            authenticated_principal,
            TaskBoardRemoteIoAuthorityKind::Renew,
            authority_at,
            Some(request),
            None,
            None,
        )
        .await
    }

    #[cfg(test)]
    pub(crate) async fn claim_task_board_remote_cancel_io_authority(
        &self,
        request: &RemoteCancelRequest,
        authenticated_principal: &str,
        authority_at: &str,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
        request
            .validate()
            .map_err(|error| db_error(format!("validate remote cancel I/O authority: {error}")))?;
        self.claim_remote_io_authority(
            &request.binding,
            &request.request_sha256,
            &request.offer_request_sha256,
            Some(&request.lease_id),
            authenticated_principal,
            TaskBoardRemoteIoAuthorityKind::Cancel,
            authority_at,
            None,
            Some(request),
            None,
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) async fn claim_remote_io_authority(
        &self,
        binding: &RemoteAttemptBinding,
        operation_digest: &str,
        offer_digest: &str,
        lease_id: Option<&str>,
        principal: &str,
        kind: TaskBoardRemoteIoAuthorityKind,
        authority_at: &str,
        renew_request: Option<&RemoteLeaseRenewRequest>,
        cancel_request: Option<&RemoteCancelRequest>,
        expected_trust: Option<&TaskBoardRemoteOperationTrustFence>,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board remote I/O authority")
            .await?;
        let Some(assignment) =
            load_assignment_in_tx(&mut transaction, &binding.assignment_id).await?
        else {
            commit_noop(transaction, "missing remote I/O authority assignment").await?;
            return Ok(None);
        };
        validate_authority_assignment(
            &assignment,
            binding,
            offer_digest,
            lease_id,
            principal,
            kind,
        )?;
        if let Some(request) = renew_request
            && renew_request_for_record(&assignment)? != *request
        {
            return Err(concurrent(
                "remote renewal request differs from deterministic durable evidence",
            ));
        }
        let Some(parent) = load_execution_in_tx(&mut transaction, &binding.execution_id).await?
        else {
            commit_noop(transaction, "missing remote I/O authority execution").await?;
            return Ok(None);
        };
        if !active_target_matches(&parent, &assignment)
            || parent.transition.execution_state != authority_execution_state(kind, &assignment)
        {
            commit_noop(transaction, "stopped remote I/O authority target").await?;
            return Ok(None);
        }
        let Some(attempt) = exact_target_attempt(&parent, binding) else {
            commit_noop(transaction, "missing remote I/O authority attempt").await?;
            return Ok(None);
        };
        if attempt.state != authority_attempt_state(kind, &assignment) {
            commit_noop(transaction, "inactive remote I/O authority attempt").await?;
            return Ok(None);
        }
        claim_controller_operation_trust_in_tx(
            &mut transaction,
            &assignment,
            operation_kind(kind),
            operation_digest,
            expected_trust,
        )
        .await?;
        journal_cancel_claim_in_tx(
            &mut transaction, &binding.assignment_id, cancel_request, authority_at,
        )
        .await?;
        let resource = authority_resource(kind);
        if let Some(current) = parent.ownership.resources.get(resource) {
            ensure_authority_window(&assignment, authority_at)?;
            if current == operation_digest && no_other_authority(&parent, kind) {
                commit_noop(transaction, "replayed remote I/O authority").await?;
                return Ok(Some(authority(binding, kind, operation_digest)));
            }
            return Err(concurrent("remote workflow has conflicting I/O authority"));
        }
        if !no_other_authority(&parent, kind) {
            return Err(concurrent(
                "remote workflow has another active I/O authority",
            ));
        }
        ensure_authority_window(&assignment, authority_at)?;
        let mut updated = parent.clone();
        updated
            .ownership
            .resources
            .insert(resource.into(), operation_digest.into());
        updated.updated_at = monotonic_time(&parent.updated_at, authority_at)?;
        validate_task_board_workflow_execution(&updated)
            .map_err(|error| db_error(format!("validate remote I/O authority: {error}")))?;
        let expected = TaskBoardWorkflowExecutionCas::from(&parent);
        update_execution_in_tx(&mut transaction, &expected, &updated).await?;
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        commit_noop(transaction, "remote I/O authority").await?;
        Ok(Some(authority(binding, kind, operation_digest)))
    }
}

const fn operation_kind(kind: TaskBoardRemoteIoAuthorityKind) -> TaskBoardRemoteOperationKind {
    match kind {
        TaskBoardRemoteIoAuthorityKind::Offer => TaskBoardRemoteOperationKind::Offer,
        TaskBoardRemoteIoAuthorityKind::Claim => TaskBoardRemoteOperationKind::Claim,
        TaskBoardRemoteIoAuthorityKind::Renew => TaskBoardRemoteOperationKind::Renew,
        TaskBoardRemoteIoAuthorityKind::Cancel => TaskBoardRemoteOperationKind::Cancel,
    }
}

pub(super) fn has_remote_io_authority(execution: &TaskBoardWorkflowExecutionRecord) -> bool {
    execution
        .ownership
        .resources
        .contains_key(TASK_BOARD_REMOTE_OFFER_IO_AUTHORITY_RESOURCE)
        || execution
            .ownership
            .resources
            .contains_key(TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE)
        || execution
            .ownership
            .resources
            .contains_key(TASK_BOARD_REMOTE_RENEW_IO_AUTHORITY_RESOURCE)
        || execution
            .ownership
            .resources
            .contains_key(TASK_BOARD_REMOTE_CANCEL_IO_AUTHORITY_RESOURCE)
        || execution
            .ownership
            .resources
            .contains_key(TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE)
}

pub(super) async fn require_authority_parent(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    kind: TaskBoardRemoteIoAuthorityKind,
    digest: &str,
) -> Result<TaskBoardWorkflowExecutionRecord, CliError> {
    let parent = load_execution_in_tx(transaction, &assignment.execution_id)
        .await?
        .ok_or_else(|| concurrent("remote I/O authority execution disappeared"))?;
    let required_state = match kind {
        TaskBoardRemoteIoAuthorityKind::Offer | TaskBoardRemoteIoAuthorityKind::Claim => {
            TaskBoardExecutionState::Starting
        }
        TaskBoardRemoteIoAuthorityKind::Renew => TaskBoardExecutionState::Running,
        TaskBoardRemoteIoAuthorityKind::Cancel => authority_execution_state(kind, assignment),
    };
    if !active_target_matches(&parent, assignment)
        || parent.transition.execution_state != required_state
        || parent
            .ownership
            .resources
            .get(authority_resource(kind))
            .map(String::as_str)
            != Some(digest)
    {
        return Err(concurrent(
            "remote I/O authority no longer matches durable workflow state",
        ));
    }
    Ok(parent)
}

fn validate_authority_assignment(
    assignment: &TaskBoardRemoteAssignmentRecord,
    binding: &RemoteAttemptBinding,
    offer_digest: &str,
    lease_id: Option<&str>,
    principal: &str,
    kind: TaskBoardRemoteIoAuthorityKind,
) -> Result<(), CliError> {
    let exact_binding = assignment
        .offer
        .as_ref()
        .is_some_and(|offer| offer.binding == *binding)
        && assignment.request_sha256.as_deref() == Some(offer_digest)
        && assignment.authenticated_principal.as_deref() == Some(principal)
        && assignment.fencing_epoch == binding.fencing_epoch;
    let exact_state = match kind {
        TaskBoardRemoteIoAuthorityKind::Offer | TaskBoardRemoteIoAuthorityKind::Claim => {
            assignment.state == TaskBoardRemoteAssignmentState::Offered
                && assignment.claimed_at.is_none()
        }
        TaskBoardRemoteIoAuthorityKind::Renew => matches!(
            assignment.state,
            TaskBoardRemoteAssignmentState::Claimed
                | TaskBoardRemoteAssignmentState::Started
                | TaskBoardRemoteAssignmentState::Running
        ),
        TaskBoardRemoteIoAuthorityKind::Cancel => matches!(
            assignment.state,
            TaskBoardRemoteAssignmentState::Offered
                | TaskBoardRemoteAssignmentState::Claimed
                | TaskBoardRemoteAssignmentState::Started
                | TaskBoardRemoteAssignmentState::Running
        ),
    };
    let exact_lease = match kind {
        TaskBoardRemoteIoAuthorityKind::Offer => assignment.lease_id.is_none(),
        TaskBoardRemoteIoAuthorityKind::Claim
        | TaskBoardRemoteIoAuthorityKind::Renew
        | TaskBoardRemoteIoAuthorityKind::Cancel => assignment.lease_id.as_deref() == lease_id,
    };
    if exact_binding && exact_state && exact_lease {
        Ok(())
    } else {
        Err(concurrent(
            "remote assignment changed before I/O authority claim",
        ))
    }
}

fn authority_execution_state(
    kind: TaskBoardRemoteIoAuthorityKind,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> TaskBoardExecutionState {
    match kind {
        TaskBoardRemoteIoAuthorityKind::Offer | TaskBoardRemoteIoAuthorityKind::Claim => {
            TaskBoardExecutionState::Starting
        }
        TaskBoardRemoteIoAuthorityKind::Renew => TaskBoardExecutionState::Running,
        TaskBoardRemoteIoAuthorityKind::Cancel => {
            if assignment.state == TaskBoardRemoteAssignmentState::Offered {
                TaskBoardExecutionState::Starting
            } else {
                TaskBoardExecutionState::Running
            }
        }
    }
}

fn authority_attempt_state(
    kind: TaskBoardRemoteIoAuthorityKind,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> TaskBoardAttemptState {
    match kind {
        TaskBoardRemoteIoAuthorityKind::Offer | TaskBoardRemoteIoAuthorityKind::Claim => {
            TaskBoardAttemptState::Starting
        }
        TaskBoardRemoteIoAuthorityKind::Renew => TaskBoardAttemptState::Running,
        TaskBoardRemoteIoAuthorityKind::Cancel => {
            if assignment.state == TaskBoardRemoteAssignmentState::Offered {
                TaskBoardAttemptState::Starting
            } else {
                TaskBoardAttemptState::Running
            }
        }
    }
}

pub(super) fn active_target_matches(
    parent: &TaskBoardWorkflowExecutionRecord,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> bool {
    let Some(offer) = assignment.offer.as_ref() else {
        return false;
    };
    parent.ownership.host_id.as_deref() == Some(assignment.host_id.as_str())
        && parent.ownership.fencing_epoch == assignment.fencing_epoch
        && parent
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            .is_some_and(|target| target == &format!("remote:{}", assignment.assignment_id))
        && parent
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE)
            == Some(&offer.binding.action_key)
        && parent
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE)
            .is_some_and(|attempt| attempt == &offer.binding.attempt.to_string())
}

fn exact_target_attempt<'a>(
    parent: &'a TaskBoardWorkflowExecutionRecord,
    binding: &RemoteAttemptBinding,
) -> Option<&'a crate::task_board::TaskBoardExecutionAttemptRecord> {
    parent.attempts.iter().find(|attempt| {
        attempt.action_key == binding.action_key
            && attempt.attempt == binding.attempt
            && attempt.idempotency_key == binding.idempotency_key
    })
}

pub(super) const fn authority_resource(kind: TaskBoardRemoteIoAuthorityKind) -> &'static str {
    match kind {
        TaskBoardRemoteIoAuthorityKind::Offer => TASK_BOARD_REMOTE_OFFER_IO_AUTHORITY_RESOURCE,
        TaskBoardRemoteIoAuthorityKind::Claim => TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE,
        TaskBoardRemoteIoAuthorityKind::Renew => TASK_BOARD_REMOTE_RENEW_IO_AUTHORITY_RESOURCE,
        TaskBoardRemoteIoAuthorityKind::Cancel => TASK_BOARD_REMOTE_CANCEL_IO_AUTHORITY_RESOURCE,
    }
}

fn no_other_authority(
    parent: &TaskBoardWorkflowExecutionRecord,
    kind: TaskBoardRemoteIoAuthorityKind,
) -> bool {
    [
        TASK_BOARD_REMOTE_OFFER_IO_AUTHORITY_RESOURCE,
        TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE,
        TASK_BOARD_REMOTE_RENEW_IO_AUTHORITY_RESOURCE,
        TASK_BOARD_REMOTE_CANCEL_IO_AUTHORITY_RESOURCE,
        TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE,
    ]
    .into_iter()
    .filter(|resource| *resource != authority_resource(kind))
    .all(|resource| !parent.ownership.resources.contains_key(resource))
}

fn authority(
    binding: &RemoteAttemptBinding,
    kind: TaskBoardRemoteIoAuthorityKind,
    request_sha256: &str,
) -> TaskBoardRemoteIoAuthority {
    TaskBoardRemoteIoAuthority {
        assignment_id: binding.assignment_id.clone(),
        kind,
        request_sha256: request_sha256.into(),
    }
}

pub(super) fn monotonic_time(current: &str, candidate: &str) -> Result<String, CliError> {
    let current_time = canonical_time(current, "current workflow update time")?;
    let candidate_time = canonical_time(candidate, "remote I/O settlement time")?;
    Ok(if candidate_time > current_time {
        candidate.into()
    } else {
        current.into()
    })
}

fn ensure_authority_window(
    assignment: &TaskBoardRemoteAssignmentRecord,
    authority_at: &str,
) -> Result<(), CliError> {
    let now = canonical_time(authority_at, "remote I/O authority time")?;
    let lease = assignment
        .lease_expires_at
        .as_deref()
        .ok_or_else(|| db_error("remote I/O authority lease expiry is missing"))?;
    let deadline = assignment
        .deadline_at
        .as_deref()
        .ok_or_else(|| db_error("remote I/O authority deadline is missing"))?;
    if now < canonical_time(lease, "remote I/O authority lease expiry")?
        && now < canonical_time(deadline, "remote I/O authority deadline")?
    {
        Ok(())
    } else {
        Err(concurrent("remote I/O authority lease or deadline expired"))
    }
}
