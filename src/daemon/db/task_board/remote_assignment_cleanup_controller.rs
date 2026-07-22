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
        let assignment =
            require_assignment(&mut transaction, &request.binding.assignment_id).await?;
        let receipt = exact_settlement(&mut transaction, request, principal).await?;
        require_exact_terminal_assignment(&assignment, &receipt.request, principal)?;
        if let Some(response) = replayed_response(&assignment, request)? {
            require_recorded_handoff(&mut transaction, &assignment).await?;
            commit_noop(transaction, "replayed remote cleanup observation").await?;
            return Ok(Some(response));
        }
        let (parent_sha256, handoff_recorded) =
            cleanup_parent_in_tx(&mut transaction, &assignment).await?;
        if !handoff_recorded {
            return Err(concurrent(
                "remote cleanup cannot claim without a durable terminal handoff",
            ));
        }
        claim_cleanup_observation_trust_in_tx(
            &mut transaction,
            &assignment,
            &request.request_sha256,
            &parent_sha256,
            trust,
        )
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
        let receipt = exact_settlement(&mut transaction, request, principal).await?;
        require_exact_terminal_assignment(&assignment, &receipt.request, principal)?;
        if let Some(stored) = replayed_response(&assignment, request)? {
            if stored != *response {
                return Err(concurrent(
                    "remote cleanup response conflicts with durable completion evidence",
                ));
            }
            require_recorded_handoff(&mut transaction, &assignment).await?;
            commit_noop(transaction, "replayed remote cleanup response").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Replayed(assignment));
        }
        let (parent_sha256, handoff_recorded) =
            cleanup_parent_in_tx(&mut transaction, &assignment).await?;
        if !handoff_recorded {
            return Err(concurrent(
                "remote cleanup cannot manufacture a missing terminal handoff",
            ));
        }
        consume_cleanup_observation_trust_in_tx(
            &mut transaction,
            &assignment,
            &request.request_sha256,
            &parent_sha256,
            trust,
        )
        .await?;
        persist_cleanup_completion_in_tx(
            &mut transaction,
            &assignment,
            &receipt.request,
            principal,
            &response.cleanup_completed_at,
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
