use sqlx::query;

use super::remote_assignment_authority_settlement::settle_claim_io_authority_in_tx;
use super::remote_assignment_controller_recovery::recover_controller_remote_assignment_in_tx;
use super::remote_assignment_lease::{
    commit_noop, finish_mutation, mutation_binding_matches, require_assignment,
};
use super::remote_assignment_model::{
    TaskBoardRemoteMutationOutcome, canonical_time, concurrent, nonblank, to_i64,
};
use super::remote_claim_receipts::{claim_receipt_values, exact_claim_response};
use super::remote_operation_trust::{
    TaskBoardRemoteOperationKind, consume_controller_operation_trust_in_tx,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{RemoteClaimRequest, RemoteClaimResponse};
use crate::task_board::TaskBoardRemoteAssignmentState;

impl AsyncDaemonDb {
    pub(crate) async fn record_task_board_remote_assignment_claim(
        &self,
        request: &RemoteClaimRequest,
        response: &RemoteClaimResponse,
        authenticated_principal: &str,
        observed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        request
            .validate()
            .map_err(|error| db_error(format!("validate remote claim request: {error}")))?;
        response
            .validate(request)
            .map_err(|error| db_error(format!("validate remote claim response: {error}")))?;
        nonblank(
            authenticated_principal,
            "remote assignment authenticated principal",
        )?;
        let claimed = canonical_time(&response.claimed_at, "remote claim response time")?;
        let observed = canonical_time(observed_at, "remote claim observation time")?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote claim response")
            .await?;
        let record = require_assignment(&mut transaction, &request.binding.assignment_id).await?;
        if exact_claim_response(&record, request, authenticated_principal).as_ref()
            == Some(response)
        {
            commit_noop(transaction, "replayed remote claim response").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Replayed(record));
        }
        if record.claim_receipt.is_some() {
            commit_noop(transaction, "conflicting remote claim receipt").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        let lease_expiry = record
            .lease_expires_at
            .as_deref()
            .map(|value| canonical_time(value, "remote assignment lease expiry"))
            .transpose()?;
        let deadline = record
            .deadline_at
            .as_deref()
            .map(|value| canonical_time(value, "remote assignment deadline"))
            .transpose()?;
        let exact_lease = record.lease_id.as_deref() == Some(response.lease.lease_id.as_str())
            && record.lease_expires_at.as_deref() == Some(response.lease.expires_at.as_str());
        let within_fence = lease_expiry.is_some_and(|expiry| claimed <= expiry)
            && deadline.is_some_and(|deadline| claimed <= deadline);
        if record.state != TaskBoardRemoteAssignmentState::Offered
            || !exact_lease
            || !within_fence
            || !mutation_binding_matches(
                &record,
                &request.binding,
                authenticated_principal,
                &request.lease_id,
            )
        {
            commit_noop(transaction, "stale remote claim response").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        consume_controller_operation_trust_in_tx(
            &mut transaction,
            &record,
            TaskBoardRemoteOperationKind::Claim,
            &request.request_sha256,
        )
        .await?;
        let observed_after_fence = lease_expiry.is_some_and(|expiry| observed >= expiry)
            || deadline.is_some_and(|deadline| observed >= deadline);
        if observed_after_fence {
            persist_claim_response(&mut transaction, &record, request, response).await?;
            let claimed_record =
                require_assignment(&mut transaction, &record.assignment_id).await?;
            Box::pin(recover_controller_remote_assignment_in_tx(
                &mut transaction,
                &claimed_record,
                observed_at,
            ))
            .await?;
            return finish_mutation(transaction, &record.assignment_id, "late claim response")
                .await;
        }
        settle_claim_io_authority_in_tx(&mut transaction, &record, request, &response.claimed_at)
            .await?;
        persist_claim_response(&mut transaction, &record, request, response).await?;
        finish_mutation(transaction, &record.assignment_id, "claim response").await
    }
}

async fn persist_claim_response(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    record: &super::TaskBoardRemoteAssignmentRecord,
    request: &RemoteClaimRequest,
    response: &RemoteClaimResponse,
) -> Result<(), CliError> {
    let principal = record
        .authenticated_principal
        .as_deref()
        .ok_or_else(|| db_error("remote claim response has no authenticated principal"))?;
    let (response_json, receipt_sha256) =
        claim_receipt_values(record, request, response, principal)?;
    let rows = query(
        "UPDATE task_board_remote_assignments SET state = 'claimed',
         claimed_host_instance_id = ?2, claimed_at = ?3, heartbeat_at = ?3,
         claim_request_sha256 = ?4, claim_response_json = ?5,
         claim_receipt_sha256 = ?6, last_mutation_kind = 'claim_response',
         last_mutation_sha256 = ?4, updated_at = ?3
         WHERE assignment_id = ?1 AND fencing_epoch = ?7
         AND state = 'offered' AND lease_id = ?8 AND lease_expires_at = ?9
         AND claim_receipt_sha256 IS NULL",
    )
    .bind(&record.assignment_id)
    .bind(&request.binding.host_instance_id)
    .bind(&response.claimed_at)
    .bind(&request.request_sha256)
    .bind(response_json)
    .bind(receipt_sha256)
    .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
    .bind(&request.lease_id)
    .bind(&response.lease.expires_at)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("persist remote claim response: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(())
    } else {
        Err(concurrent("remote claim response lost its lease fence"))
    }
}
