//! Controller adoption of authenticated executor cleanup evidence.

use sqlx::Transaction;

use super::remote_assignment_cleanup::persist_cleanup_completion_in_tx;
use super::remote_assignment_lease::{commit_noop, finish_mutation, require_assignment};
use super::remote_assignment_model::{TaskBoardRemoteMutationOutcome, concurrent, nonblank};
use super::remote_assignment_terminal_handoff::{
    exact_active_remote_target, terminal_handoff_digest_in_tx,
};
use super::remote_operation_trust::{
    claim_cleanup_observation_trust_in_tx, consume_cleanup_observation_trust_in_tx,
};
use super::remote_settlement_receipts::{
    TaskBoardRemoteSettlementReceipt, load_settlement_in_tx, require_exact_terminal_assignment,
};
use super::workflow_executions::load_execution_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, TaskBoardRemoteHostTrustFence, db_error};
use crate::daemon::task_board_remote_transport::wire_cleanup::{
    RemoteCleanupObservationRequest, RemoteCleanupObservationResponse,
};
use crate::task_board::TaskBoardWorkflowExecutionCas;

impl AsyncDaemonDb {
    pub(crate) async fn claim_task_board_remote_cleanup_observation_fenced(
        &self,
        request: &RemoteCleanupObservationRequest,
        principal: &str,
        trust: &TaskBoardRemoteHostTrustFence,
    ) -> Result<Option<RemoteCleanupObservationResponse>, CliError> {
        validate_request(request, principal)?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote cleanup observation")
            .await?;
        let assignment = match screen_cleanup_observation_claim_in_tx(
            &mut transaction,
            request,
            principal,
        )
        .await?
        {
            CleanupObservationClaimScreen::Replayed(response) => {
                commit_noop(transaction, "replayed remote cleanup observation").await?;
                return Ok(Some(*response));
            }
            CleanupObservationClaimScreen::Ready(assignment) => assignment,
        };
        claim_cleanup_observation_authority_in_tx(&mut transaction, &assignment, request, trust)
            .await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit remote cleanup observation authority: {error}"
            ))
        })?;
        Ok(None)
    }

    pub(crate) async fn record_task_board_remote_cleanup_observation(
        &self,
        request: &RemoteCleanupObservationRequest,
        response: &RemoteCleanupObservationResponse,
        principal: &str,
        trust: &TaskBoardRemoteHostTrustFence,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        validate_response(request, response, principal)?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote cleanup response")
            .await?;
        let assignment =
            require_assignment(&mut transaction, &request.binding.assignment_id).await?;
        let (receipt, replayed) = screen_cleanup_observation_record_in_tx(
            &mut transaction,
            &assignment,
            request,
            response,
            principal,
        )
        .await?;
        if replayed {
            commit_noop(transaction, "replayed remote cleanup response").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Replayed(assignment));
        }
        settle_cleanup_observation_in_tx(
            &mut transaction,
            &assignment,
            request,
            &receipt,
            principal,
            &response.cleanup_completed_at,
            trust,
        )
        .await?;
        finish_mutation(
            transaction,
            &assignment.assignment_id,
            "cleanup observation",
        )
        .await
    }
}

/// Either this exact claim already has a recorded response, or the
/// generation is ready for a fresh claim.
enum CleanupObservationClaimScreen {
    Replayed(Box<RemoteCleanupObservationResponse>),
    Ready(Box<super::TaskBoardRemoteAssignmentRecord>),
}

async fn screen_cleanup_observation_claim_in_tx(
    transaction: &mut Transaction<'_, sqlx::Sqlite>,
    request: &RemoteCleanupObservationRequest,
    principal: &str,
) -> Result<CleanupObservationClaimScreen, CliError> {
    let assignment = require_assignment(transaction, &request.binding.assignment_id).await?;
    let receipt = exact_settlement(transaction, request, principal).await?;
    require_exact_terminal_assignment(&assignment, &receipt.request, principal)?;
    if let Some(response) = replay_cleanup_claim_in_tx(transaction, &assignment, request).await? {
        return Ok(CleanupObservationClaimScreen::Replayed(Box::new(response)));
    }
    Ok(CleanupObservationClaimScreen::Ready(Box::new(assignment)))
}

/// Claims cleanup-observation trust once the terminal handoff this claim
/// needs is durably on file.
async fn claim_cleanup_observation_authority_in_tx(
    transaction: &mut Transaction<'_, sqlx::Sqlite>,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    request: &RemoteCleanupObservationRequest,
    trust: &TaskBoardRemoteHostTrustFence,
) -> Result<(), CliError> {
    let (parent_sha256, handoff_recorded) = cleanup_parent_in_tx(transaction, assignment).await?;
    if !handoff_recorded {
        return Err(concurrent(
            "remote cleanup cannot claim without a durable terminal handoff",
        ));
    }
    claim_cleanup_observation_trust_in_tx(
        transaction,
        assignment,
        &request.request_sha256,
        &parent_sha256,
        trust,
    )
    .await
}

/// The settlement receipt this response answers, and whether that exact
/// response was already recorded.
async fn screen_cleanup_observation_record_in_tx(
    transaction: &mut Transaction<'_, sqlx::Sqlite>,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    request: &RemoteCleanupObservationRequest,
    response: &RemoteCleanupObservationResponse,
    principal: &str,
) -> Result<(TaskBoardRemoteSettlementReceipt, bool), CliError> {
    let receipt = exact_settlement(transaction, request, principal).await?;
    require_exact_terminal_assignment(assignment, &receipt.request, principal)?;
    let replayed = replay_cleanup_response_in_tx(transaction, assignment, request, response).await?;
    Ok((receipt, replayed))
}

/// Consumes cleanup-observation trust and persists completion once the
/// terminal handoff this settlement needs is durably on file.
async fn settle_cleanup_observation_in_tx(
    transaction: &mut Transaction<'_, sqlx::Sqlite>,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    request: &RemoteCleanupObservationRequest,
    receipt: &TaskBoardRemoteSettlementReceipt,
    principal: &str,
    completed_at: &str,
    trust: &TaskBoardRemoteHostTrustFence,
) -> Result<(), CliError> {
    let (parent_sha256, handoff_recorded) = cleanup_parent_in_tx(transaction, assignment).await?;
    if !handoff_recorded {
        return Err(concurrent(
            "remote cleanup cannot manufacture a missing terminal handoff",
        ));
    }
    consume_cleanup_observation_trust_in_tx(
        transaction,
        assignment,
        &request.request_sha256,
        &parent_sha256,
        trust,
    )
    .await?;
    persist_cleanup_completion_in_tx(transaction, assignment, &receipt.request, principal, completed_at)
        .await?;
    Ok(())
}

async fn cleanup_parent_in_tx(
    transaction: &mut Transaction<'_, sqlx::Sqlite>,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
) -> Result<(String, bool), CliError> {
    if let Some(handoff_digest) = terminal_handoff_digest_in_tx(transaction, assignment).await? {
        return Ok((handoff_digest, true));
    }
    let Some(parent) = load_execution_in_tx(transaction, &assignment.execution_id).await? else {
        return Err(concurrent(
            "remote cleanup parent disappeared without durable controller handoff",
        ));
    };
    if exact_active_remote_target(&parent, assignment) {
        return Err(concurrent(
            "remote cleanup cannot detach an active workflow target",
        ));
    }
    Ok((
        TaskBoardWorkflowExecutionCas::from(&parent).record_sha256,
        false,
    ))
}

async fn require_recorded_handoff(
    transaction: &mut Transaction<'_, sqlx::Sqlite>,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
) -> Result<(), CliError> {
    if terminal_handoff_digest_in_tx(transaction, assignment)
        .await?
        .is_some()
    {
        Ok(())
    } else {
        Err(concurrent(
            "remote cleanup completion is missing its controller handoff",
        ))
    }
}

async fn exact_settlement(
    transaction: &mut Transaction<'_, sqlx::Sqlite>,
    request: &RemoteCleanupObservationRequest,
    principal: &str,
) -> Result<TaskBoardRemoteSettlementReceipt, CliError> {
    let receipt = load_settlement_in_tx(transaction, &request.binding.assignment_id)
        .await?
        .ok_or_else(|| concurrent("remote cleanup observation has no settlement receipt"))?;
    let expected = RemoteCleanupObservationRequest::for_settlement(&receipt.request)
        .map_err(|error| db_error(format!("seal cleanup observation request: {error}")))?;
    if expected == *request && receipt.authenticated_principal == principal {
        Ok(receipt)
    } else {
        Err(concurrent(
            "remote cleanup observation mismatched immutable settlement evidence",
        ))
    }
}

/// `Some` when this exact claim request already has a durable cleanup
/// response recorded, after checking that response also has its controller
/// handoff on file.
async fn replay_cleanup_claim_in_tx(
    transaction: &mut Transaction<'_, sqlx::Sqlite>,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    request: &RemoteCleanupObservationRequest,
) -> Result<Option<RemoteCleanupObservationResponse>, CliError> {
    let Some(response) = replayed_response(assignment, request)? else {
        return Ok(None);
    };
    require_recorded_handoff(transaction, assignment).await?;
    Ok(Some(response))
}

/// `true` when this exact response was already recorded and its controller
/// handoff is on file; refuses a response that conflicts with the one durably
/// recorded instead of silently accepting the caller's version.
async fn replay_cleanup_response_in_tx(
    transaction: &mut Transaction<'_, sqlx::Sqlite>,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    request: &RemoteCleanupObservationRequest,
    response: &RemoteCleanupObservationResponse,
) -> Result<bool, CliError> {
    let Some(stored) = replayed_response(assignment, request)? else {
        return Ok(false);
    };
    if stored != *response {
        return Err(concurrent(
            "remote cleanup response conflicts with durable completion evidence",
        ));
    }
    require_recorded_handoff(transaction, assignment).await?;
    Ok(true)
}

fn replayed_response(
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    request: &RemoteCleanupObservationRequest,
) -> Result<Option<RemoteCleanupObservationResponse>, CliError> {
    match (
        assignment.cleanup_settlement_request_sha256.as_deref(),
        assignment.cleanup_completed_at.as_deref(),
    ) {
        (None, None) => Ok(None),
        (Some(digest), Some(completed_at)) if digest == request.settlement_request_sha256 => {
            RemoteCleanupObservationResponse::for_completed(request, completed_at.to_owned())
                .map(Some)
                .map_err(|error| db_error(format!("rebuild cleanup observation response: {error}")))
        }
        _ => Err(concurrent(
            "remote cleanup observation conflicts with durable cleanup evidence",
        )),
    }
}

fn validate_request(
    request: &RemoteCleanupObservationRequest,
    principal: &str,
) -> Result<(), CliError> {
    request
        .validate()
        .map_err(|error| db_error(format!("validate cleanup observation request: {error}")))?;
    nonblank(principal, "remote cleanup observation principal")
}

fn validate_response(
    request: &RemoteCleanupObservationRequest,
    response: &RemoteCleanupObservationResponse,
    principal: &str,
) -> Result<(), CliError> {
    validate_request(request, principal)?;
    response
        .validate(request)
        .map_err(|error| db_error(format!("validate cleanup observation response: {error}")))
}
