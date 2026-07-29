use sqlx::{Sqlite, Transaction, query};

use super::remote_assignment_cancel_status::claim_pending_cancel_status_in_tx;
use super::remote_assignment_io_authority::active_target_matches;
use super::remote_assignment_lease::{claim_request_for_record, commit_noop, require_assignment};
use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome, concurrent, nonblank, to_i64,
};
use super::remote_claim_receipts::{claim_receipt_values, claim_response_for_record};
use super::remote_operation_trust::{
    TaskBoardRemoteOperationKind, TaskBoardRemoteOperationTrustFence,
    claim_controller_operation_trust_in_tx, consume_controller_operation_trust_in_tx,
};
use super::workflow_executions::load_execution_in_tx;
use super::{ORCHESTRATOR_CHANGE_SCOPE, items::bump_change_in_tx};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::RemoteClaimRequest;
use crate::daemon::task_board_remote_transport::wire::{RemoteStatusRequest, RemoteStatusResponse};
use crate::task_board::{
    TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE, TaskBoardExecutionState,
    TaskBoardRemoteAssignmentState,
};

mod exchange;
use exchange::{apply_status_update_in_tx, screen_status_exchange_in_tx, settle_status_exchange};

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
        Box::pin(self.claim_status_io_authority(request, authenticated_principal, Some(trust)))
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
        if !status_authority_generation_matches(&record, request, authenticated_principal)? {
            commit_noop(transaction, "stale remote status authority").await?;
            return Ok(false);
        }
        // Awaiting this inline makes the future 25304 bytes, past the
        // 16384-byte threshold of `clippy::large_futures`, which is denied
        // here. `cargo check` will not tell you, because the limit is a lint
        // rather than a compile error.
        Box::pin(claim_verified_status_authority(
            transaction,
            record,
            request,
            trust,
        ))
        .await
    }

    pub(crate) async fn record_task_board_remote_assignment_status(
        &self,
        request: &RemoteStatusRequest,
        response: &RemoteStatusResponse,
        authenticated_principal: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        validate_status_exchange(request, response, authenticated_principal)?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote assignment status")
            .await?;
        let record = status_record_in_tx(&mut transaction, request).await?;
        let settlement = match screen_status_exchange_in_tx(
            &mut transaction,
            &record,
            request,
            response,
            authenticated_principal,
        )
        .await?
        {
            Some(settlement) => settlement,
            None => {
                apply_status_update_in_tx(
                    &mut transaction,
                    &record,
                    request,
                    response,
                    authenticated_principal,
                )
                .await?
            }
        };
        // Same 16384-byte `clippy::large_futures` threshold: awaited inline this
        // settlement is 23648 bytes, because every arm carries the record and
        // the whole exchange by value.
        Box::pin(settle_status_exchange(
            transaction,
            record,
            request,
            response,
            settlement,
        ))
        .await
    }
}

/// The status request must echo the exact offer, lease and principal the record
/// holds, and the assignment must still be in a state that can report status.
fn status_authority_generation_matches(
    record: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteStatusRequest,
    authenticated_principal: &str,
) -> Result<bool, CliError> {
    let offer = record.require_offer()?;
    Ok(offer.binding == request.binding
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
        ))
}

/// The record has proven it holds this request's exact generation. A pending
/// cancel is already a verified authority of its own, so that path commits
/// without claiming a second one.
async fn claim_verified_status_authority(
    mut transaction: Transaction<'_, Sqlite>,
    record: TaskBoardRemoteAssignmentRecord,
    request: &RemoteStatusRequest,
    trust: Option<&TaskBoardRemoteOperationTrustFence>,
) -> Result<bool, CliError> {
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
    grant_status_operation_trust(transaction, &record, request, trust).await?;
    Ok(true)
}

async fn grant_status_operation_trust(
    mut transaction: Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteStatusRequest,
    trust: Option<&TaskBoardRemoteOperationTrustFence>,
) -> Result<(), CliError> {
    claim_controller_operation_trust_in_tx(
        &mut transaction,
        record,
        TaskBoardRemoteOperationKind::Status,
        &request.request_sha256,
        trust,
    )
    .await?;
    bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    commit_noop(transaction, "remote status authority").await
}

fn validate_status_exchange(
    request: &RemoteStatusRequest,
    response: &RemoteStatusResponse,
    authenticated_principal: &str,
) -> Result<(), CliError> {
    request.validate().map_err(|error| {
        db_error(format!(
            "validate remote assignment status request: {error}"
        ))
    })?;
    nonblank(
        authenticated_principal,
        "remote assignment authenticated principal",
    )?;
    response
        .validate(request)
        .map_err(|error| db_error(format!("validate remote assignment status: {error}")))
}

async fn status_record_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
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

async fn handoff_pending_claim_trust_to_status_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
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
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    response: &RemoteStatusResponse,
    principal: &str,
    pending_claim: Option<&RemoteClaimRequest>,
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
