use sqlx::{Sqlite, Transaction, query};

use super::remote_assignment_io_authority::monotonic_time;
use super::remote_assignment_lease::require_assignment;
use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, canonical_time, concurrent, nonblank, to_i64,
};
use super::remote_assignment_terminal_handoff::settlement_handoff_exists_in_tx;
use super::remote_operation_trust::{
    TaskBoardRemoteOperationKind, TaskBoardRemoteOperationTrustFence,
    claim_controller_operation_trust_in_tx, consume_controller_operation_trust_in_tx,
};
use super::remote_settlement_receipts::{
    TaskBoardRemoteSettlementReceipt, insert_settlement_in_tx, load_settlement_collisions_in_tx,
    load_settlement_in_tx, require_current_settlement_window, require_exact_terminal_assignment,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteSettledRequest, RemoteSettledResponse,
};

impl AsyncDaemonDb {
    /// Claim one exact terminal assignment generation before settlement I/O.
    ///
    /// An adopted response is returned directly. Otherwise the exact request
    /// owns the durable `settle` marker and may be sent or replayed.
    #[cfg(test)]
    pub(crate) async fn claim_task_board_remote_settlement_io_authority(
        &self,
        request: &RemoteSettledRequest,
        authenticated_principal: &str,
        authority_at: &str,
    ) -> Result<Option<RemoteSettledResponse>, CliError> {
        self.claim_settlement_io_authority(request, authenticated_principal, authority_at, None)
            .await
    }

    pub(crate) async fn claim_task_board_remote_settlement_io_authority_fenced(
        &self,
        request: &RemoteSettledRequest,
        authenticated_principal: &str,
        authority_at: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<Option<RemoteSettledResponse>, CliError> {
        self.claim_settlement_io_authority(
            request,
            authenticated_principal,
            authority_at,
            Some(trust),
        )
        .await
    }

    async fn claim_settlement_io_authority(
        &self,
        request: &RemoteSettledRequest,
        authenticated_principal: &str,
        authority_at: &str,
        trust: Option<&TaskBoardRemoteOperationTrustFence>,
    ) -> Result<Option<RemoteSettledResponse>, CliError> {
        validate_inputs(request, authenticated_principal, authority_at)?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote settlement I/O authority")
            .await?;
        let assignment =
            require_assignment(&mut transaction, &request.binding.assignment_id).await?;
        require_settlement_handoff(&mut transaction, &assignment, request).await?;
        if let Some(response) =
            exact_receipt_or_conflict(&mut transaction, request, authenticated_principal, None)
                .await?
        {
            commit_replay(transaction, "settlement authority").await?;
            return Ok(Some(response));
        }
        require_current_settlement_window(&assignment, authority_at)?;
        require_exact_terminal_assignment(&assignment, request, authenticated_principal)?;
        claim_controller_operation_trust_in_tx(
            &mut transaction,
            &assignment,
            TaskBoardRemoteOperationKind::Settle,
            &request.request_sha256,
            trust,
        )
        .await?;
        if exact_pending_authority(&assignment, request) {
            commit_replay(transaction, "settlement authority").await?;
            return Ok(None);
        }
        if assignment.last_mutation_kind.as_deref() == Some("settle") {
            return Err(concurrent(
                "remote settlement conflicts with durable I/O authority",
            ));
        }
        persist_authority_in_tx(
            &mut transaction,
            &assignment,
            request,
            authenticated_principal,
            authority_at,
        )
        .await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit remote settlement I/O authority: {error}"))
        })?;
        Ok(None)
    }

    pub(crate) async fn record_task_board_remote_settlement_response(
        &self,
        request: &RemoteSettledRequest,
        response: &RemoteSettledResponse,
        authenticated_principal: &str,
    ) -> Result<TaskBoardRemoteSettlementReceipt, CliError> {
        validate_response_inputs(request, response, authenticated_principal)?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote settlement response")
            .await?;
        let assignment =
            require_assignment(&mut transaction, &request.binding.assignment_id).await?;
        require_settlement_handoff(&mut transaction, &assignment, request).await?;
        if exact_receipt_or_conflict(
            &mut transaction,
            request,
            authenticated_principal,
            Some(response),
        )
        .await?
        .is_some()
        {
            let receipt = require_receipt(&mut transaction, request).await?;
            commit_replay(transaction, "settlement response").await?;
            return Ok(receipt);
        }
        require_exact_terminal_assignment(&assignment, request, authenticated_principal)?;
        if !exact_pending_authority(&assignment, request) {
            return Err(concurrent(
                "remote settlement response lost its durable I/O authority",
            ));
        }
        consume_controller_operation_trust_in_tx(
            &mut transaction,
            &assignment,
            TaskBoardRemoteOperationKind::Settle,
            &request.request_sha256,
        )
        .await?;
        insert_settlement_in_tx(&mut transaction, request, authenticated_principal, response)
            .await?;
        clear_authority_in_tx(&mut transaction, &assignment, request, response).await?;
        let receipt = require_receipt(&mut transaction, request).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote settlement response: {error}")))?;
        Ok(receipt)
    }
}

async fn require_settlement_handoff(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteSettledRequest,
) -> Result<(), CliError> {
    if assignment.fencing_epoch == request.binding.fencing_epoch
        && settlement_handoff_exists_in_tx(transaction, assignment).await?
    {
        Ok(())
    } else {
        Err(concurrent(
            "remote settlement requires a durable controller handoff",
        ))
    }
}

fn validate_inputs(
    request: &RemoteSettledRequest,
    principal: &str,
    authority_at: &str,
) -> Result<(), CliError> {
    request
        .validate()
        .map_err(|error| db_error(format!("validate remote settlement request: {error}")))?;
    nonblank(principal, "remote settlement principal")?;
    canonical_time(authority_at, "remote settlement authority time")?;
    Ok(())
}

fn validate_response_inputs(
    request: &RemoteSettledRequest,
    response: &RemoteSettledResponse,
    principal: &str,
) -> Result<(), CliError> {
    request
        .validate()
        .map_err(|error| db_error(format!("validate remote settlement request: {error}")))?;
    response
        .validate(request)
        .map_err(|error| db_error(format!("validate remote settlement response: {error}")))?;
    nonblank(principal, "remote settlement principal")
}

async fn exact_receipt_or_conflict(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteSettledRequest,
    principal: &str,
    expected_response: Option<&RemoteSettledResponse>,
) -> Result<Option<RemoteSettledResponse>, CliError> {
    let receipts = load_settlement_collisions_in_tx(transaction, request).await?;
    match receipts.as_slice() {
        [] => Ok(None),
        [receipt]
            if receipt.is_exact_replay(request, principal)
                && expected_response.is_none_or(|response| receipt.response == *response) =>
        {
            Ok(Some(receipt.response.clone()))
        }
        _ => Err(concurrent(
            "remote settlement conflicts with immutable receipt evidence",
        )),
    }
}

fn exact_pending_authority(
    assignment: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteSettledRequest,
) -> bool {
    assignment.last_mutation_kind.as_deref() == Some("settle")
        && assignment.last_mutation_sha256.as_deref() == Some(&request.request_sha256)
}

async fn persist_authority_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteSettledRequest,
    principal: &str,
    authority_at: &str,
) -> Result<(), CliError> {
    let updated_at = monotonic_time(&assignment.updated_at, authority_at)?;
    let rows = query(
        "UPDATE task_board_remote_assignments
         SET last_mutation_kind = 'settle', last_mutation_sha256 = ?2, updated_at = ?3
         WHERE assignment_id = ?1 AND fencing_epoch = ?4 AND state = ?5
           AND lease_id = ?6 AND request_sha256 = ?7 AND authenticated_principal = ?8",
    )
    .bind(&assignment.assignment_id)
    .bind(&request.request_sha256)
    .bind(updated_at)
    .bind(to_i64(
        assignment.fencing_epoch,
        "settlement fencing epoch",
    )?)
    .bind(assignment.state.as_str())
    .bind(&request.lease_id)
    .bind(&request.offer_request_sha256)
    .bind(principal)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("persist remote settlement authority: {error}")))?
    .rows_affected();
    exact_row(
        rows,
        "remote settlement authority lost its assignment fence",
    )
}

async fn clear_authority_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteSettledRequest,
    response: &RemoteSettledResponse,
) -> Result<(), CliError> {
    let updated_at = monotonic_time(&assignment.updated_at, &response.settled_at)?;
    let rows = query(
        "UPDATE task_board_remote_assignments
         SET last_mutation_kind = NULL, last_mutation_sha256 = NULL, updated_at = ?3
         WHERE assignment_id = ?1 AND last_mutation_kind = 'settle'
           AND last_mutation_sha256 = ?2 AND fencing_epoch = ?4
           AND state = ?5 AND lease_id = ?6",
    )
    .bind(&assignment.assignment_id)
    .bind(&request.request_sha256)
    .bind(updated_at)
    .bind(to_i64(
        assignment.fencing_epoch,
        "settlement fencing epoch",
    )?)
    .bind(assignment.state.as_str())
    .bind(&request.lease_id)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("clear remote settlement authority: {error}")))?
    .rows_affected();
    exact_row(rows, "remote settlement response lost its assignment fence")
}

async fn require_receipt(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteSettledRequest,
) -> Result<TaskBoardRemoteSettlementReceipt, CliError> {
    load_settlement_in_tx(transaction, &request.binding.assignment_id)
        .await?
        .ok_or_else(|| db_error("persisted remote settlement receipt disappeared"))
}

async fn commit_replay(
    transaction: Transaction<'_, Sqlite>,
    operation: &str,
) -> Result<(), CliError> {
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit replayed remote {operation}: {error}")))
}

fn exact_row(rows: u64, message: &'static str) -> Result<(), CliError> {
    if rows == 1 {
        Ok(())
    } else {
        Err(concurrent(message))
    }
}
