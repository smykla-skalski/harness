use sqlx::query;

use super::remote_assignment_active_fence::{
    TaskBoardRemoteControllerHandoffKind, controller_handoff_matches_in_tx,
};
use super::remote_assignment_authority_settlement::settle_cancel_io_authority_in_tx;
use super::remote_assignment_lease::{
    commit_noop, exact_mutation_replay, finish_mutation, mutation_binding_matches,
    require_assignment,
};
use super::remote_assignment_model::{
    TaskBoardRemoteMutationOutcome, canonical_time, concurrent, nonblank, to_i64,
};
use super::remote_claim_receipts::{claim_receipt_values, claim_response_for_record};
use super::remote_operation_trust::{
    TaskBoardRemoteOperationKind, consume_controller_operation_trust_in_tx,
};
use super::workflow_executions::load_execution_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteCancelRequest, RemoteCancelResponse, RemoteClaimRequest,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::TaskBoardRemoteAssignmentState;

/// A claim receipt reconstructed from an authenticated cancel response for an
/// assignment the controller offered but never durably claimed. The executor is
/// the authority on whether it claimed and started, so its sealed cancel evidence
/// backfills the durable claim the assignment requires before it can terminate.
struct AdoptedCancelClaim {
    request_sha256: String,
    response_json: String,
    receipt_sha256: String,
}

impl AsyncDaemonDb {
    pub(crate) async fn record_task_board_remote_assignment_cancel(
        &self,
        request: &RemoteCancelRequest,
        response: &RemoteCancelResponse,
        authenticated_principal: &str,
        recorded_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        request
            .validate()
            .map_err(|error| db_error(format!("validate remote cancel request: {error}")))?;
        response
            .validate(request)
            .map_err(|error| db_error(format!("validate remote cancel response: {error}")))?;
        nonblank(
            authenticated_principal,
            "remote assignment authenticated principal",
        )?;
        canonical_time(recorded_at, "remote cancel response receipt time")?;
        if response.state != RemoteAssignmentWireState::Cancelled {
            return Err(db_error(
                "remote cancel response did not confirm cancellation",
            ));
        }
        let mut transaction = self
            .begin_immediate_transaction("task board remote cancel response")
            .await?;
        let record = require_assignment(&mut transaction, &request.binding.assignment_id).await?;
        if cancel_response_replayed(&record, request, response, authenticated_principal) {
            let parent = load_execution_in_tx(&mut transaction, &record.execution_id).await?;
            let handoff_matches = if let Some(parent) = parent.as_ref() {
                controller_handoff_matches_in_tx(
                    &mut transaction,
                    &record,
                    TaskBoardRemoteControllerHandoffKind::TerminalProjection,
                    parent,
                )
                .await?
            } else {
                false
            };
            commit_noop(transaction, "replayed remote cancel response").await?;
            return Ok(if handoff_matches {
                TaskBoardRemoteMutationOutcome::Replayed(record)
            } else {
                TaskBoardRemoteMutationOutcome::Stale(record)
            });
        }
        let cancellable = matches!(
            record.state,
            TaskBoardRemoteAssignmentState::Offered
                | TaskBoardRemoteAssignmentState::Claimed
                | TaskBoardRemoteAssignmentState::Started
                | TaskBoardRemoteAssignmentState::Running
        );
        if !cancellable
            || !mutation_binding_matches(
                &record,
                &request.binding,
                authenticated_principal,
                &request.lease_id,
            )
            || !cancel_evidence_matches(&record, response)
        {
            commit_noop(transaction, "stale remote cancel response").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        let adopted = reconstruct_adopted_claim(&record, response)?;
        consume_controller_operation_trust_in_tx(
            &mut transaction,
            &record,
            TaskBoardRemoteOperationKind::Cancel,
            &request.request_sha256,
        )
        .await?;
        persist_cancel_response(
            &mut transaction,
            &record,
            request,
            response,
            adopted.as_ref(),
            recorded_at,
        )
        .await?;
        settle_cancel_io_authority_in_tx(
            &mut transaction,
            &record,
            request,
            TaskBoardRemoteAssignmentState::Cancelled,
            recorded_at,
        )
        .await?;
        finish_mutation(transaction, &record.assignment_id, "cancel response").await
    }
}

fn cancel_response_replayed(
    record: &super::TaskBoardRemoteAssignmentRecord,
    request: &RemoteCancelRequest,
    response: &RemoteCancelResponse,
    principal: &str,
) -> bool {
    record.state == TaskBoardRemoteAssignmentState::Cancelled
        && record.authenticated_principal.as_deref() == Some(principal)
        && record.offer.as_ref().map(|offer| &offer.binding) == Some(&request.binding)
        && record.request_sha256.as_deref() == Some(request.offer_request_sha256.as_str())
        && record.lease_id.as_deref() == Some(request.lease_id.as_str())
        && record.completed_at.as_deref() == Some(response.observed_at.as_str())
        && cancel_evidence_matches(record, response)
        && record.error.as_deref() == Some(request.reason.as_str())
        && exact_mutation_replay(record, "cancel_response", &response.cancel_response_sha256)
}

fn cancel_evidence_matches(
    record: &super::TaskBoardRemoteAssignmentRecord,
    response: &RemoteCancelResponse,
) -> bool {
    let observed = (
        response.claimed_at.as_deref(),
        response.started_at.as_deref(),
        response.workspace_ref.as_deref(),
    );
    if record.claim_receipt.is_none() {
        // The controller holds no durable run evidence, so the authenticated response
        // is the first authority: accept an empty cancel (nothing happened) or a fully
        // reported claim+start (adopt the unreported run). A bare claim with no start
        // has no run to account for and is not adoptable through the cancel channel.
        return matches!(observed, (None, None, None) | (Some(_), Some(_), Some(_)));
    }
    // A durable claim receipt is authoritative: the response may echo it or stay
    // silent, but must never contradict it or extend it with run evidence the
    // controller never recorded through the claim or start channel.
    consistent_without_extending(record.claimed_at.as_deref(), observed.0)
        && consistent_without_extending(record.started_at.as_deref(), observed.1)
        && consistent_without_extending(record.workspace_ref.as_deref(), observed.2)
}

fn consistent_without_extending(durable: Option<&str>, observed: Option<&str>) -> bool {
    observed.is_none() || durable == observed
}

/// Backfills the durable claim receipt for a cancel that adopts start evidence the
/// controller never recorded (an offered assignment whose executor reports it
/// claimed). Returns `None` when the response carries no claim, or the assignment
/// already holds an authoritative claim receipt that must not be rewritten.
fn reconstruct_adopted_claim(
    record: &super::TaskBoardRemoteAssignmentRecord,
    response: &RemoteCancelResponse,
) -> Result<Option<AdoptedCancelClaim>, CliError> {
    let Some(claimed_at) = response.claimed_at.as_deref() else {
        return Ok(None);
    };
    if record.claim_receipt.is_some() {
        return Ok(None);
    }
    let offer = record.require_offer()?;
    let lease_id = record
        .lease_id
        .as_deref()
        .ok_or_else(|| concurrent("adopted cancel claim has no lease"))?;
    let claim_request = RemoteClaimRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: lease_id.to_owned(),
        offer_request_sha256: offer.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .map_err(|error| db_error(format!("seal adopted cancel claim request: {error}")))?;
    let claim_response = claim_response_for_record(record, &claim_request, claimed_at)?;
    let principal = record
        .authenticated_principal
        .as_deref()
        .ok_or_else(|| concurrent("adopted cancel claim has no authenticated principal"))?;
    let (response_json, receipt_sha256) =
        claim_receipt_values(record, &claim_request, &claim_response, principal)?;
    Ok(Some(AdoptedCancelClaim {
        request_sha256: claim_request.request_sha256,
        response_json,
        receipt_sha256,
    }))
}

async fn persist_cancel_response(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    record: &super::TaskBoardRemoteAssignmentRecord,
    request: &RemoteCancelRequest,
    response: &RemoteCancelResponse,
    adopted: Option<&AdoptedCancelClaim>,
    recorded_at: &str,
) -> Result<(), CliError> {
    let rows = query(
        "UPDATE task_board_remote_assignments SET state = 'cancelled',
         cancel_requested_at = ?2, completed_at = ?2, heartbeat_at = ?3,
         claimed_host_instance_id = COALESCE(?10, claimed_host_instance_id),
         claimed_at = COALESCE(?11, claimed_at),
         started_at = COALESCE(?12, started_at),
         workspace_ref = COALESCE(?13, workspace_ref),
         claim_request_sha256 = COALESCE(?14, claim_request_sha256),
         claim_response_json = COALESCE(?15, claim_response_json),
         claim_receipt_sha256 = COALESCE(?16, claim_receipt_sha256),
         result_json = NULL, status_sha256 = NULL, result_sha256 = NULL,
         last_mutation_kind = 'cancel_response', last_mutation_sha256 = ?4,
         error = ?5, updated_at = ?3 WHERE assignment_id = ?1
         AND fencing_epoch = ?6 AND state = ?7 AND lease_id = ?8
         AND lease_expires_at = ?9",
    )
    .bind(&record.assignment_id)
    .bind(&response.observed_at)
    .bind(recorded_at)
    .bind(&response.cancel_response_sha256)
    .bind(&request.reason)
    .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
    .bind(record.state.as_str())
    .bind(&request.lease_id)
    .bind(&record.lease_expires_at)
    .bind(
        response
            .claimed_at
            .as_ref()
            .map(|_| response.binding.host_instance_id.as_str()),
    )
    .bind(&response.claimed_at)
    .bind(&response.started_at)
    .bind(&response.workspace_ref)
    .bind(adopted.map(|claim| claim.request_sha256.as_str()))
    .bind(adopted.map(|claim| claim.response_json.as_str()))
    .bind(adopted.map(|claim| claim.receipt_sha256.as_str()))
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("persist remote cancel response: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(())
    } else {
        Err(concurrent("remote cancel response lost its lease fence"))
    }
}
