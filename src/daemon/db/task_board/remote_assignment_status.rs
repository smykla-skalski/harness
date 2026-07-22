use sqlx::query;

use super::remote_assignment_active_fence::{
    TaskBoardRemoteControllerHandoffKind, controller_handoff_matches_in_tx,
    record_controller_handoff_in_tx,
};
use super::remote_assignment_cancel_status::{
    claim_pending_cancel_status_in_tx, reconcile_pending_cancel_status_in_tx,
};
use super::remote_assignment_io_authority::active_target_matches;
use super::remote_assignment_lease::{
    claim_request_for_record, commit_noop, finish_mutation, require_assignment,
};
use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome, concurrent, nonblank, to_i64,
};
use super::remote_assignment_status_persistence::{
    persist_status, status_non_state_evidence_allowed, status_update_allowed,
};
use super::remote_assignment_status_settlement::{
    settle_running_status_in_tx, status_parent_for_response_in_tx,
};
use super::remote_assignment_terminal_handoff::terminal_handoff_digest_in_tx;
use super::remote_claim_receipts::{claim_receipt_values, claim_response_for_record};
use super::remote_operation_trust::{
    TaskBoardRemoteOperationKind, TaskBoardRemoteOperationTrustFence,
    claim_controller_operation_trust_in_tx, consume_controller_operation_trust_in_tx,
};
use super::workflow_executions::load_execution_in_tx;
use super::{ORCHESTRATOR_CHANGE_SCOPE, items::bump_change_in_tx};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteStatusRequest, RemoteStatusResponse,
};
use crate::task_board::{
    TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE, TaskBoardExecutionState,
    TaskBoardRemoteAssignmentState,
};

impl AsyncDaemonDb {
    #[cfg(test)]
    pub(crate) async fn claim_task_board_remote_status_io_authority(
        &self,
        request: &RemoteStatusRequest,
        authenticated_principal: &str,
    ) -> Result<bool, CliError> {
        self.claim_status_io_authority(request, authenticated_principal, None)
            .await
    }

    pub(crate) async fn claim_task_board_remote_status_io_authority_fenced(
        &self,
        request: &RemoteStatusRequest,
        authenticated_principal: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<bool, CliError> {
        self.claim_status_io_authority(request, authenticated_principal, Some(trust))
            .await
    }

    async fn claim_status_io_authority(
        &self,
        request: &RemoteStatusRequest,
        authenticated_principal: &str,
        trust: Option<&TaskBoardRemoteOperationTrustFence>,
    ) -> Result<bool, CliError> {
        request
            .validate()
            .map_err(|error| db_error(format!("validate remote status I/O authority: {error}")))?;
        nonblank(authenticated_principal, "remote status I/O principal")?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote status I/O authority")
            .await?;
        let record = require_assignment(&mut transaction, &request.binding.assignment_id).await?;
        let offer = record.require_offer()?;
        let exact = offer.binding == request.binding
            && offer.request_sha256 == request.offer_request_sha256
            && record.lease_id.as_deref() == Some(request.lease_id.as_str())
            && record.authenticated_principal.as_deref() == Some(authenticated_principal)
            && matches!(
                record.state,
                TaskBoardRemoteAssignmentState::Offered
                    | TaskBoardRemoteAssignmentState::Claimed
                    | TaskBoardRemoteAssignmentState::Started
                    | TaskBoardRemoteAssignmentState::Running
                    | TaskBoardRemoteAssignmentState::Unknown
            );
        if !exact {
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit stale remote status authority: {error}"))
            })?;
            return Ok(false);
        }
        let record = handoff_pending_claim_trust_to_status_in_tx(&mut transaction, record).await?;
        if claim_pending_cancel_status_in_tx(&mut transaction, &record, request, trust)
            .await?
            .is_some()
        {
            commit_noop(
                transaction,
                "verified pending remote cancel status authority",
            )
            .await?;
            return Ok(true);
        }
        claim_controller_operation_trust_in_tx(
            &mut transaction,
            &record,
            TaskBoardRemoteOperationKind::Status,
            &request.request_sha256,
            trust,
        )
        .await?;
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote status authority: {error}")))?;
        Ok(true)
    }

    pub(crate) async fn record_task_board_remote_assignment_status(
        &self,
        request: &RemoteStatusRequest,
        response: &RemoteStatusResponse,
        authenticated_principal: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        request.validate().map_err(|error| {
            db_error(format!(
                "validate remote assignment status request: {error}"
            ))
        })?;
        nonblank(
            authenticated_principal,
            "remote assignment authenticated principal",
        )?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote assignment status")
            .await?;
        let record = status_record_in_tx(&mut transaction, request).await?;
        response
            .validate(request)
            .map_err(|error| db_error(format!("validate remote assignment status: {error}")))?;
        if !status_generation_matches(&record, request, response, authenticated_principal)? {
            commit_noop(transaction, "stale status request generation").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        if let Some(updated) =
            reconcile_pending_cancel_status_in_tx(&mut transaction, &record, request, response)
                .await?
        {
            if !updated {
                commit_noop(transaction, "stale pending remote cancel status").await?;
                return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
            }
            return finish_mutation(transaction, &record.assignment_id, "cancel status").await;
        }
        if record.status_sha256.as_deref() == Some(response.status_sha256.as_str())
            && record.status_response.as_ref() == Some(response)
        {
            consume_controller_operation_trust_in_tx(
                &mut transaction,
                &record,
                TaskBoardRemoteOperationKind::Status,
                &request.request_sha256,
            )
            .await?;
            commit_noop(transaction, "replayed assignment status").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Replayed(record));
        }
        if !status_update_allowed(&record, response)? {
            return rejected_status_outcome(transaction, record, request, response).await;
        }
        consume_controller_operation_trust_in_tx(
            &mut transaction,
            &record,
            TaskBoardRemoteOperationKind::Status,
            &request.request_sha256,
        )
        .await?;
        let Some(resolution) =
            status_parent_for_response_in_tx(&mut transaction, &record, response).await?
        else {
            commit_noop(transaction, "remote status lost exact parent authority").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        };
        persist_lost_claim_receipt_in_tx(
            &mut transaction,
            &record,
            response,
            authenticated_principal,
            resolution.pending_claim.as_ref(),
        )
        .await?;
        persist_status(&mut transaction, &record, request, response).await?;
        if resolution.evidence_only
            && !controller_handoff_matches_in_tx(
                &mut transaction,
                &record,
                TaskBoardRemoteControllerHandoffKind::EvidenceOnly,
                &resolution.parent,
            )
            .await?
        {
            record_controller_handoff_in_tx(
                &mut transaction,
                &record,
                evidence_only_terminal_state(response.state)?,
                TaskBoardRemoteControllerHandoffKind::EvidenceOnly,
                &resolution.parent,
                &response.observed_at,
            )
            .await?;
        }
        settle_running_status_in_tx(&mut transaction, &resolution.parent, response).await?;
        finish_mutation(transaction, &record.assignment_id, "status").await
    }
}

async fn rejected_status_outcome(
    mut transaction: sqlx::Transaction<'_, sqlx::Sqlite>,
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

async fn status_record_in_tx(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    request: &RemoteStatusRequest,
) -> Result<TaskBoardRemoteAssignmentRecord, CliError> {
    let record = require_assignment(transaction, &request.binding.assignment_id).await?;
    #[cfg(test)]
    if record.controller_operation.is_none() {
        claim_controller_operation_trust_in_tx(
            transaction,
            &record,
            TaskBoardRemoteOperationKind::Status,
            &request.request_sha256,
            None,
        )
        .await?;
        return require_assignment(transaction, &request.binding.assignment_id).await;
    }
    Ok(record)
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
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
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

async fn handoff_pending_claim_trust_to_status_in_tx(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    record: TaskBoardRemoteAssignmentRecord,
) -> Result<TaskBoardRemoteAssignmentRecord, CliError> {
    let Some(operation) = record.controller_operation.as_ref() else {
        return Ok(record);
    };
    if operation.kind != TaskBoardRemoteOperationKind::Claim.as_str() {
        return Ok(record);
    }
    if record.state != TaskBoardRemoteAssignmentState::Offered || record.claim_receipt.is_some() {
        return Err(concurrent(
            "remote claim-to-status handoff has incompatible assignment evidence",
        ));
    }
    let claim = claim_request_for_record(&record)?;
    if operation.request_sha256 != claim.request_sha256 {
        return Err(concurrent(
            "remote claim-to-status handoff changed its request digest",
        ));
    }
    let parent = load_execution_in_tx(transaction, &record.execution_id)
        .await?
        .ok_or_else(|| concurrent("remote claim-to-status execution disappeared"))?;
    if parent.transition.execution_state != TaskBoardExecutionState::Starting
        || !active_target_matches(&parent, &record)
        || parent
            .ownership
            .resources
            .get(TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE)
            != Some(&claim.request_sha256)
    {
        return Err(concurrent(
            "remote claim-to-status handoff lost exact workflow authority",
        ));
    }
    consume_controller_operation_trust_in_tx(
        transaction,
        &record,
        TaskBoardRemoteOperationKind::Claim,
        &claim.request_sha256,
    )
    .await?;
    require_assignment(transaction, &record.assignment_id).await
}

async fn persist_lost_claim_receipt_in_tx(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    response: &RemoteStatusResponse,
    principal: &str,
    pending_claim: Option<&crate::daemon::task_board_remote_transport::wire::RemoteClaimRequest>,
) -> Result<(), CliError> {
    let Some(claimed_at) = response.claimed_at.as_deref() else {
        return Ok(());
    };
    if record.claim_receipt.is_some() {
        return Ok(());
    }
    let request = pending_claim.ok_or_else(|| {
        concurrent("lost remote claim receipt has no exact pending claim authority")
    })?;
    let Some(status_lease) = response.lease.as_ref() else {
        return Err(concurrent(
            "lost remote claim evidence omitted its exact lease",
        ));
    };
    if status_lease.lease_id != request.lease_id
        || record.lease_expires_at.as_deref() != Some(status_lease.expires_at.as_str())
    {
        return Err(concurrent(
            "lost remote claim evidence changed its exact lease",
        ));
    }
    let claim_response = claim_response_for_record(record, request, claimed_at)?;
    let (response_json, receipt_sha256) =
        claim_receipt_values(record, request, &claim_response, principal)?;
    let rows = query(
        "UPDATE task_board_remote_assignments
         SET claimed_host_instance_id = ?2, claimed_at = ?3,
             claim_request_sha256 = ?4, claim_response_json = ?5,
             claim_receipt_sha256 = ?6
         WHERE assignment_id = ?1 AND fencing_epoch = ?7 AND state = 'offered'
           AND lease_id = ?8 AND lease_expires_at = ?9
           AND claim_request_sha256 IS NULL AND claim_response_json IS NULL
           AND claim_receipt_sha256 IS NULL",
    )
    .bind(&record.assignment_id)
    .bind(&request.binding.host_instance_id)
    .bind(claimed_at)
    .bind(&request.request_sha256)
    .bind(response_json)
    .bind(receipt_sha256)
    .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
    .bind(&request.lease_id)
    .bind(&record.lease_expires_at)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("persist lost remote claim receipt: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(())
    } else {
        Err(concurrent("lost remote claim receipt lost its fence"))
    }
}
