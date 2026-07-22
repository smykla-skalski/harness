use sqlx::{Sqlite, Transaction};

use super::ITEMS_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::remote_assignment_authority_settlement::adopt_remote_claim_evidence_in_tx;
use super::remote_assignment_io_authority::{active_target_matches, has_remote_io_authority};
use super::remote_assignment_lease::claim_request_for_record;
use super::remote_assignment_model::{TaskBoardRemoteAssignmentRecord, concurrent};
use super::workflow_executions::load_execution_in_tx;
use super::workflow_terminal::settle_prepared_dispatch_in_tx;
use crate::daemon::db::CliError;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteClaimRequest, RemoteStatusResponse,
};
use crate::task_board::{
    TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE, TaskBoardAttemptState, TaskBoardExecutionState,
    TaskBoardWorkflowExecutionRecord,
};

pub(super) struct StatusParentResolution {
    pub(super) parent: TaskBoardWorkflowExecutionRecord,
    pub(super) pending_claim: Option<RemoteClaimRequest>,
    pub(super) evidence_only: bool,
}

pub(super) async fn status_parent_for_response_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    response: &RemoteStatusResponse,
) -> Result<Option<StatusParentResolution>, CliError> {
    let Some(parent) = load_execution_in_tx(transaction, &assignment.execution_id).await? else {
        return Ok(None);
    };
    if !active_target_matches(&parent, assignment) {
        return Ok(None);
    }
    if recovered_unknown_status_is_definitive(&parent, assignment, response) {
        return Ok(Some(StatusParentResolution {
            parent,
            pending_claim: None,
            evidence_only: true,
        }));
    }
    if terminal(response.state) {
        // A raw executor status may only report Completed or Failed. Cancelled and
        // Superseded are controller determinations, and Unknown is recovery-only; those
        // arrive on the pending-cancel reconcile and recovered-unknown paths handled
        // above. Rejecting them here prevents a terminal assignment from being written
        // with no controller handoff and no parent projection (a permanent wedge).
        if !matches!(
            response.state,
            RemoteAssignmentWireState::Completed | RemoteAssignmentWireState::Failed
        ) {
            return Ok(None);
        }
        return provisional_terminal_parent(assignment, response, parent);
    }
    if parent.transition.execution_state == TaskBoardExecutionState::Running
        && exact_unique_active_attempt(&parent, assignment, TaskBoardAttemptState::Running)
        && !has_remote_io_authority(&parent)
    {
        if assignment.claim_receipt.is_none() && response.claimed_at.is_some() {
            return Ok(None);
        }
        return Ok(Some(StatusParentResolution {
            parent,
            pending_claim: None,
            evidence_only: false,
        }));
    }
    if parent.transition.execution_state != TaskBoardExecutionState::Starting
        || !exact_unique_active_attempt(&parent, assignment, TaskBoardAttemptState::Starting)
    {
        return Ok(None);
    }
    let Some(claimed_at) = response.claimed_at.as_deref() else {
        return Ok(
            (!has_remote_io_authority(&parent)).then_some(StatusParentResolution {
                parent,
                pending_claim: None,
                evidence_only: false,
            }),
        );
    };
    let (authority_digest, pending_claim) = match parent
        .ownership
        .resources
        .get(TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE)
    {
        Some(digest) => {
            let request = claim_request_for_record(assignment)?;
            if request.request_sha256 != *digest {
                return Err(concurrent(
                    "remote claim status conflicts with durable I/O authority",
                ));
            }
            (Some(digest.as_str()), Some(request))
        }
        None if assignment.claim_receipt.is_none() => return Ok(None),
        None if !has_remote_io_authority(&parent) => (None, None),
        None => return Ok(None),
    };
    let parent =
        adopt_remote_claim_evidence_in_tx(transaction, assignment, claimed_at, authority_digest)
            .await?;
    Ok(Some(StatusParentResolution {
        parent,
        pending_claim,
        evidence_only: false,
    }))
}

fn provisional_terminal_parent(
    assignment: &TaskBoardRemoteAssignmentRecord,
    response: &RemoteStatusResponse,
    parent: TaskBoardWorkflowExecutionRecord,
) -> Result<Option<StatusParentResolution>, CliError> {
    if parent.transition.execution_state == TaskBoardExecutionState::Running
        && exact_unique_active_attempt(&parent, assignment, TaskBoardAttemptState::Running)
        && !has_remote_io_authority(&parent)
    {
        if assignment.claim_receipt.is_none() && response.claimed_at.is_some() {
            return Ok(None);
        }
        return Ok(Some(StatusParentResolution {
            parent,
            pending_claim: None,
            evidence_only: false,
        }));
    }
    if parent.transition.execution_state != TaskBoardExecutionState::Starting
        || !exact_unique_active_attempt(&parent, assignment, TaskBoardAttemptState::Starting)
    {
        return Ok(None);
    }
    if response.claimed_at.is_none() {
        return Ok(
            (!has_remote_io_authority(&parent)).then_some(StatusParentResolution {
                parent,
                pending_claim: None,
                evidence_only: false,
            }),
        );
    }
    let pending_claim = match parent
        .ownership
        .resources
        .get(TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE)
    {
        Some(digest) => {
            let request = claim_request_for_record(assignment)?;
            if request.request_sha256 != *digest {
                return Err(concurrent(
                    "remote terminal status conflicts with durable claim authority",
                ));
            }
            Some(request)
        }
        None if assignment.claim_receipt.is_none() => return Ok(None),
        None if !has_remote_io_authority(&parent) => None,
        None => return Ok(None),
    };
    Ok(Some(StatusParentResolution {
        parent,
        pending_claim,
        evidence_only: false,
    }))
}

fn exact_unique_active_attempt(
    parent: &TaskBoardWorkflowExecutionRecord,
    assignment: &TaskBoardRemoteAssignmentRecord,
    expected_state: TaskBoardAttemptState,
) -> bool {
    let Some(offer) = assignment.offer.as_ref() else {
        return false;
    };
    let mut active = parent.attempts.iter().filter(|attempt| {
        matches!(
            attempt.state,
            TaskBoardAttemptState::Preparing
                | TaskBoardAttemptState::Starting
                | TaskBoardAttemptState::Running
        )
    });
    active.next().is_some_and(|attempt| {
        attempt.action_key == offer.binding.action_key
            && attempt.attempt == offer.binding.attempt
            && attempt.idempotency_key == offer.binding.idempotency_key
            && attempt.state == expected_state
    }) && active.next().is_none()
}

pub(super) async fn settle_running_status_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    parent: &TaskBoardWorkflowExecutionRecord,
    response: &RemoteStatusResponse,
) -> Result<(), CliError> {
    if response.state != RemoteAssignmentWireState::Running {
        return Ok(());
    }
    let prepared = settle_prepared_dispatch_in_tx(transaction, parent).await?;
    if prepared.changed {
        bump_change_in_tx(transaction, ITEMS_CHANGE_SCOPE).await?;
    }
    Ok(())
}

fn recovered_unknown_status_is_definitive(
    parent: &TaskBoardWorkflowExecutionRecord,
    assignment: &TaskBoardRemoteAssignmentRecord,
    response: &RemoteStatusResponse,
) -> bool {
    assignment.state == crate::task_board::TaskBoardRemoteAssignmentState::Unknown
        && matches!(
            response.state,
            RemoteAssignmentWireState::Completed
                | RemoteAssignmentWireState::Failed
                | RemoteAssignmentWireState::Cancelled
        )
        && parent.transition.execution_state == TaskBoardExecutionState::HumanRequired
        && parent.blocked_reason.as_deref() == Some("remote_assignment_outcome_unknown")
        && exact_unique_recovered_attempt(parent, assignment)
        && !has_remote_io_authority(parent)
}

fn exact_unique_recovered_attempt(
    parent: &TaskBoardWorkflowExecutionRecord,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> bool {
    let Some(offer) = assignment.offer.as_ref() else {
        return false;
    };
    let matching = parent.attempts.iter().filter(|attempt| {
        attempt.action_key == offer.binding.action_key
            && attempt.attempt == offer.binding.attempt
            && attempt.idempotency_key == offer.binding.idempotency_key
            && attempt.state == TaskBoardAttemptState::Unknown
    });
    matching.count() == 1
        && parent.attempts.iter().all(|attempt| {
            !matches!(
                attempt.state,
                TaskBoardAttemptState::Preparing
                    | TaskBoardAttemptState::Starting
                    | TaskBoardAttemptState::Running
            )
        })
}

const fn terminal(state: RemoteAssignmentWireState) -> bool {
    matches!(
        state,
        RemoteAssignmentWireState::Completed
            | RemoteAssignmentWireState::Failed
            | RemoteAssignmentWireState::Cancelled
            | RemoteAssignmentWireState::Superseded
            | RemoteAssignmentWireState::Unknown
    )
}
