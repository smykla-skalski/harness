//! Exact status polling fence for a durably journaled controller cancellation.

use sqlx::{Sqlite, Transaction};

use super::remote_assignment_authority_settlement::settle_cancel_io_authority_in_tx;
use super::remote_assignment_cancel_journal::pending_cancel_request_for_record;
use super::remote_assignment_io_authority::{
    TaskBoardRemoteIoAuthorityKind, require_authority_parent,
};
use super::remote_assignment_model::{TaskBoardRemoteAssignmentRecord, concurrent};
use super::remote_assignment_status_persistence::{persist_status, status_update_allowed};
use super::remote_operation_trust::{
    TaskBoardRemoteOperationKind, TaskBoardRemoteOperationTrustFence,
    claim_controller_operation_trust_in_tx, consume_controller_operation_trust_in_tx,
};
use crate::daemon::db::CliError;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteCancelRequest, RemoteStatusRequest, RemoteStatusResponse,
};
use crate::task_board::TaskBoardRemoteAssignmentState;

pub(super) async fn claim_pending_cancel_status_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteStatusRequest,
    trust: Option<&TaskBoardRemoteOperationTrustFence>,
) -> Result<Option<RemoteCancelRequest>, CliError> {
    let Some(cancel) = pending_cancel_request_for_record(assignment)? else {
        return Ok(None);
    };
    if cancel.binding != request.binding
        || cancel.lease_id != request.lease_id
        || cancel.offer_request_sha256 != request.offer_request_sha256
    {
        return Err(concurrent(
            "pending remote cancel status changed its exact request generation",
        ));
    }
    claim_controller_operation_trust_in_tx(
        transaction,
        assignment,
        TaskBoardRemoteOperationKind::Cancel,
        &cancel.request_sha256,
        trust,
    )
    .await?;
    require_authority_parent(
        transaction,
        assignment,
        TaskBoardRemoteIoAuthorityKind::Cancel,
        &cancel.request_sha256,
    )
    .await?;
    Ok(Some(cancel))
}

pub(super) fn exact_cancel_status_evidence(
    assignment: &TaskBoardRemoteAssignmentRecord,
    cancel: &RemoteCancelRequest,
    response: &RemoteStatusResponse,
) -> bool {
    terminal(response.state)
        && response.binding == cancel.binding
        && response.offer_request_sha256 == cancel.offer_request_sha256
        && response.lease.as_ref().is_some_and(|lease| {
            lease.lease_id == cancel.lease_id
                && assignment.lease_expires_at.as_deref() == Some(lease.expires_at.as_str())
        })
        && response.claimed_at == assignment.claimed_at
        && response.started_at == assignment.started_at
        && response.workspace_ref == assignment.workspace_ref
        && cancel_reason_matches(cancel, response)
}

// A reconciling cancelled status must echo the journaled cancellation reason so an
// executor cannot rewrite the controller's immutable cancel evidence.
fn cancel_reason_matches(cancel: &RemoteCancelRequest, response: &RemoteStatusResponse) -> bool {
    response.state != RemoteAssignmentWireState::Cancelled
        || response.error_code.as_deref() == Some(cancel.reason.as_str())
}

pub(super) async fn reconcile_pending_cancel_status_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteStatusRequest,
    response: &RemoteStatusResponse,
) -> Result<Option<bool>, CliError> {
    let Some(cancel) =
        claim_pending_cancel_status_in_tx(transaction, assignment, request, None).await?
    else {
        return Ok(None);
    };
    if !exact_cancel_status_evidence(assignment, &cancel, response)
        || !status_update_allowed(assignment, response)?
    {
        return Ok(Some(false));
    }
    consume_controller_operation_trust_in_tx(
        transaction,
        assignment,
        TaskBoardRemoteOperationKind::Cancel,
        &cancel.request_sha256,
    )
    .await?;
    persist_status(transaction, assignment, request, response).await?;
    settle_cancel_io_authority_in_tx(
        transaction,
        assignment,
        &cancel,
        durable_state(response.state),
        &response.observed_at,
    )
    .await?;
    Ok(Some(true))
}

const fn terminal(state: RemoteAssignmentWireState) -> bool {
    matches!(
        state,
        RemoteAssignmentWireState::Completed
            | RemoteAssignmentWireState::Failed
            | RemoteAssignmentWireState::Cancelled
    )
}

const fn durable_state(state: RemoteAssignmentWireState) -> TaskBoardRemoteAssignmentState {
    match state {
        RemoteAssignmentWireState::Completed => TaskBoardRemoteAssignmentState::Completed,
        RemoteAssignmentWireState::Failed => TaskBoardRemoteAssignmentState::Failed,
        RemoteAssignmentWireState::Cancelled => TaskBoardRemoteAssignmentState::Cancelled,
        _ => TaskBoardRemoteAssignmentState::Unknown,
    }
}
