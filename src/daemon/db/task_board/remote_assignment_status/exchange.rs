use sqlx::{Sqlite, Transaction};

use super::super::remote_assignment_active_fence::{
    TaskBoardRemoteControllerHandoffKind, controller_handoff_matches_in_tx,
    record_controller_handoff_in_tx,
};
use super::super::remote_assignment_cancel_status::reconcile_pending_cancel_status_in_tx;
use super::super::remote_assignment_controller_recovery::recover_ambiguous_remote_start_in_tx;
use super::super::remote_assignment_lease::{commit_noop, finish_mutation};
use super::super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome, concurrent,
};
use super::super::remote_assignment_start_authority::EXECUTOR_RESTARTED_BEFORE_START;
use super::super::remote_assignment_status_persistence::{
    persist_status, status_non_state_evidence_allowed, status_update_allowed,
};
use super::super::remote_assignment_status_settlement::{
    StatusParentResolution, settle_running_status_in_tx, status_parent_for_response_in_tx,
};
use super::super::remote_assignment_terminal_handoff::terminal_handoff_digest_in_tx;
use super::super::remote_operation_trust::{
    TaskBoardRemoteOperationKind, consume_controller_operation_trust_in_tx,
};
use super::super::workflow_executions::load_execution_in_tx;
use super::persist_lost_claim_receipt_in_tx;
use crate::daemon::db::CliError;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteStatusRequest, RemoteStatusResponse,
};
use crate::task_board::TaskBoardRemoteAssignmentState;

/// Why a status exchange never reaches the write path. Collapsing the four
/// refusals into one value lets the recorder settle every one of them at a
/// single `commit_noop`.
#[derive(Clone, Copy)]
pub(super) enum StatusRefusal {
    StaleGeneration,
    StalePendingCancel,
    Replayed,
    LostParentAuthority,
}

impl StatusRefusal {
    const fn reason(self) -> &'static str {
        match self {
            Self::StaleGeneration => "stale status request generation",
            Self::StalePendingCancel => "stale pending remote cancel status",
            Self::Replayed => "replayed assignment status",
            Self::LostParentAuthority => "remote status lost exact parent authority",
        }
    }

    const fn outcome(
        self,
        record: TaskBoardRemoteAssignmentRecord,
    ) -> TaskBoardRemoteMutationOutcome {
        match self {
            Self::Replayed => TaskBoardRemoteMutationOutcome::Replayed(record),
            Self::StaleGeneration | Self::StalePendingCancel | Self::LostParentAuthority => {
                TaskBoardRemoteMutationOutcome::Stale(record)
            }
        }
    }
}

/// How a status exchange settles its transaction, whichever screen or write
/// step decided it. The recorder holds the transaction across all of them and
/// settles exactly once.
pub(super) enum StatusSettlement {
    Refused(StatusRefusal),
    Mutated(&'static str),
    /// The stored evidence forbids this update. Which outcome that earns is
    /// decided inside the rejection path, which has to read the record again.
    Rejected,
}

/// The gates a status exchange passes before anything is written, in the order
/// the recorder has always run them: a cheap generation match, then the pending
/// cancel reconciliation, then the replay digest, then the pre-Start restart
/// recovery. `None` means the exchange has earned the write path.
pub(super) async fn screen_status_exchange_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteStatusRequest,
    response: &RemoteStatusResponse,
    authenticated_principal: &str,
) -> Result<Option<StatusSettlement>, CliError> {
    if !status_generation_matches(record, request, response, authenticated_principal)? {
        return Ok(Some(StatusSettlement::Refused(
            StatusRefusal::StaleGeneration,
        )));
    }
    if let Some(updated) =
        reconcile_pending_cancel_status_in_tx(transaction, record, request, response).await?
    {
        return Ok(Some(if updated {
            StatusSettlement::Mutated("cancel status")
        } else {
            StatusSettlement::Refused(StatusRefusal::StalePendingCancel)
        }));
    }
    if record.status_sha256.as_deref() == Some(response.status_sha256.as_str())
        && record.status_response.as_ref() == Some(response)
    {
        consume_controller_operation_trust_in_tx(
            transaction,
            record,
            TaskBoardRemoteOperationKind::Status,
            &request.request_sha256,
        )
        .await?;
        return Ok(Some(StatusSettlement::Refused(StatusRefusal::Replayed)));
    }
    if reconcile_prestart_restart_unknown_in_tx(transaction, record, request, response).await? {
        return Ok(Some(StatusSettlement::Mutated("restart status")));
    }
    if status_update_allowed(record, response)? {
        Ok(None)
    } else {
        Ok(Some(StatusSettlement::Rejected))
    }
}

/// The write path a screened status exchange earns: spend the controller's
/// operation trust, resolve the parent execution, then persist the evidence.
/// Losing the parent's exact authority is a refusal rather than an error, so it
/// comes back as a settlement like every other exit.
pub(super) async fn apply_status_update_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteStatusRequest,
    response: &RemoteStatusResponse,
    authenticated_principal: &str,
) -> Result<StatusSettlement, CliError> {
    consume_controller_operation_trust_in_tx(
        transaction,
        record,
        TaskBoardRemoteOperationKind::Status,
        &request.request_sha256,
    )
    .await?;
    let Some(resolution) = status_parent_for_response_in_tx(transaction, record, response).await?
    else {
        return Ok(StatusSettlement::Refused(
            StatusRefusal::LostParentAuthority,
        ));
    };
    persist_lost_claim_receipt_in_tx(
        transaction,
        record,
        response,
        authenticated_principal,
        resolution.pending_claim.as_ref(),
    )
    .await?;
    persist_status(transaction, record, request, response).await?;
    record_evidence_only_handoff_in_tx(transaction, record, response, &resolution).await?;
    settle_running_status_in_tx(transaction, &resolution.parent, response).await?;
    Ok(StatusSettlement::Mutated("status"))
}

/// Settle the transaction the way the exchange decided. This is the one place
/// the recorder gives the transaction up.
pub(super) async fn settle_status_exchange(
    transaction: Transaction<'_, Sqlite>,
    record: TaskBoardRemoteAssignmentRecord,
    request: &RemoteStatusRequest,
    response: &RemoteStatusResponse,
    settlement: StatusSettlement,
) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
    match settlement {
        StatusSettlement::Refused(refusal) => {
            commit_noop(transaction, refusal.reason()).await?;
            Ok(refusal.outcome(record))
        }
        StatusSettlement::Mutated(context) => {
            finish_mutation(transaction, &record.assignment_id, context).await
        }
        StatusSettlement::Rejected => {
            rejected_status_outcome(transaction, record, request, response).await
        }
    }
}

/// An evidence-only resolution records the controller handoff once. The match
/// check is awaited only when the resolution is evidence-only, so a normal
/// status exchange still runs no extra query.
async fn record_evidence_only_handoff_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    response: &RemoteStatusResponse,
    resolution: &StatusParentResolution,
) -> Result<(), CliError> {
    if !resolution.evidence_only
        || controller_handoff_matches_in_tx(
            transaction,
            record,
            TaskBoardRemoteControllerHandoffKind::EvidenceOnly,
            &resolution.parent,
        )
        .await?
    {
        return Ok(());
    }
    record_controller_handoff_in_tx(
        transaction,
        record,
        evidence_only_terminal_state(response.state)?,
        TaskBoardRemoteControllerHandoffKind::EvidenceOnly,
        &resolution.parent,
        &response.observed_at,
    )
    .await
}

async fn reconcile_prestart_restart_unknown_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteStatusRequest,
    response: &RemoteStatusResponse,
) -> Result<bool, CliError> {
    let exact = record.state == TaskBoardRemoteAssignmentState::Claimed
        && response.state == RemoteAssignmentWireState::Unknown
        && response.error_code.as_deref() == Some(EXECUTOR_RESTARTED_BEFORE_START)
        && response.failure_class.is_none()
        && response.started_at.is_none()
        && response.workspace_ref.is_none()
        && response.result.is_none()
        && response.output_artifacts.entries.is_empty()
        && record.start_receipt.is_none()
        && record.started_at.is_none()
        && record.workspace_ref.is_none()
        && status_non_state_evidence_allowed(record, response)?;
    if !exact {
        return Ok(false);
    }
    let parent = load_execution_in_tx(transaction, &record.execution_id)
        .await?
        .ok_or_else(|| concurrent("pre-Start restart execution disappeared"))?;
    consume_controller_operation_trust_in_tx(
        transaction,
        record,
        TaskBoardRemoteOperationKind::Status,
        &request.request_sha256,
    )
    .await?;
    if !recover_ambiguous_remote_start_in_tx(transaction, record, &parent, &response.observed_at)
        .await?
    {
        return Err(concurrent(
            "pre-Start restart status did not advance its exact generation",
        ));
    }
    Ok(true)
}

async fn rejected_status_outcome(
    mut transaction: Transaction<'_, Sqlite>,
    record: TaskBoardRemoteAssignmentRecord,
    request: &RemoteStatusRequest,
    response: &RemoteStatusResponse,
) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
    if preserved_unknown_observation_replays_in_tx(&mut transaction, &record, response).await? {
        consume_controller_operation_trust_in_tx(
            &mut transaction,
            &record,
            TaskBoardRemoteOperationKind::Status,
            &request.request_sha256,
        )
        .await?;
        commit_noop(transaction, "replayed recovered unknown status").await?;
        return Ok(TaskBoardRemoteMutationOutcome::Replayed(record));
    }
    commit_noop(transaction, "stale assignment status").await?;
    Ok(TaskBoardRemoteMutationOutcome::Stale(record))
}

fn status_generation_matches(
    record: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteStatusRequest,
    response: &RemoteStatusResponse,
    principal: &str,
) -> Result<bool, CliError> {
    let offer = record.require_offer()?;
    Ok(record.authenticated_principal.as_deref() == Some(principal)
        && offer.binding == request.binding
        && offer.request_sha256 == request.offer_request_sha256
        && record.lease_id.as_deref() == Some(request.lease_id.as_str())
        && response.lease.as_ref().is_none_or(|lease| {
            record.lease_id.as_deref() == Some(lease.lease_id.as_str())
                && record.lease_expires_at.as_deref() == Some(lease.expires_at.as_str())
        }))
}

fn evidence_only_terminal_state(
    state: RemoteAssignmentWireState,
) -> Result<TaskBoardRemoteAssignmentState, CliError> {
    match state {
        RemoteAssignmentWireState::Completed => Ok(TaskBoardRemoteAssignmentState::Completed),
        RemoteAssignmentWireState::Failed => Ok(TaskBoardRemoteAssignmentState::Failed),
        RemoteAssignmentWireState::Cancelled => Ok(TaskBoardRemoteAssignmentState::Cancelled),
        _ => Err(concurrent(
            "remote evidence-only handoff requires definitive terminal status",
        )),
    }
}

async fn preserved_unknown_observation_replays_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    response: &RemoteStatusResponse,
) -> Result<bool, CliError> {
    if record.state != TaskBoardRemoteAssignmentState::Unknown
        || !matches!(
            response.state,
            RemoteAssignmentWireState::Unknown | RemoteAssignmentWireState::Running
        )
        || !status_non_state_evidence_allowed(record, response)?
    {
        return Ok(false);
    }
    Ok(terminal_handoff_digest_in_tx(transaction, record)
        .await?
        .is_some())
}
