use super::{persist_renewal_response, renewal_response_replayed};
use crate::daemon::db::task_board::remote_assignment_authority_settlement::clear_renew_io_authority_in_tx;
use crate::daemon::db::task_board::remote_assignment_controller_recovery::recover_controller_remote_assignment_in_tx;
use crate::daemon::db::task_board::remote_assignment_lease::{
    commit_noop, finish_mutation, mutation_binding_matches, renew_request_for_record,
    require_assignment,
};
use crate::daemon::db::task_board::remote_assignment_model::{
    TaskBoardRemoteMutationOutcome, canonical_time, concurrent, nonblank,
};
use crate::daemon::db::task_board::remote_operation_trust::{
    TaskBoardRemoteOperationKind, consume_pending_operation_replay_trust_in_tx,
    require_generation_replay_trust_in_tx,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, TaskBoardRemoteHostTrustFence, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteLeaseRenewRequest, RemoteLeaseRenewResponse,
};
use crate::task_board::TaskBoardRemoteAssignmentState;

impl AsyncDaemonDb {
    pub(crate) async fn record_pending_task_board_remote_assignment_lease_renewal_replay(
        &self,
        request: &RemoteLeaseRenewRequest,
        response: &RemoteLeaseRenewResponse,
        authenticated_principal: &str,
        recorded_at: &str,
        trust: &TaskBoardRemoteHostTrustFence,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        validate_exchange(request, response, authenticated_principal)?;
        let recorded = canonical_time(recorded_at, "remote renewal replay response time")?;
        let renewed_expiry = canonical_time(&response.lease.expires_at, "renewed lease expiry")?;
        let mut transaction = self
            .begin_immediate_transaction("pending remote renewal replay response")
            .await?;
        let record = require_assignment(&mut transaction, &request.binding.assignment_id).await?;
        if renewal_response_replayed(&record, request, response, authenticated_principal) {
            require_generation_replay_trust_in_tx(&mut transaction, &record, trust).await?;
            commit_noop(transaction, "replayed pending remote renewal response").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Replayed(record));
        }
        let window = replay_window(&record, request, response, authenticated_principal)?;
        consume_pending_operation_replay_trust_in_tx(
            &mut transaction,
            &record,
            TaskBoardRemoteOperationKind::Renew,
            &request.request_sha256,
            trust,
        )
        .await?;
        persist_renewal_response(&mut transaction, &record, request, response, recorded_at).await?;
        if window.settlement_only {
            return finish_mutation(transaction, &record.assignment_id, "late renewal replay").await;
        }
        if recorded >= window.current_expiry
            || recorded >= renewed_expiry
            || recorded >= window.deadline
        {
            recover_controller_remote_assignment_in_tx(&mut transaction, &record, recorded_at)
                .await?;
        } else {
            clear_renew_io_authority_in_tx(
                &mut transaction,
                &record,
                &request.request_sha256,
                recorded_at,
            )
            .await?;
        }
        finish_mutation(transaction, &record.assignment_id, "pending renewal replay").await
    }
}

struct ReplayWindow {
    current_expiry: chrono::DateTime<chrono::Utc>,
    deadline: chrono::DateTime<chrono::Utc>,
    settlement_only: bool,
}

fn replay_window(
    record: &crate::daemon::db::TaskBoardRemoteAssignmentRecord,
    request: &RemoteLeaseRenewRequest,
    response: &RemoteLeaseRenewResponse,
    principal: &str,
) -> Result<ReplayWindow, CliError> {
    let active = matches!(
        record.state,
        TaskBoardRemoteAssignmentState::Claimed
            | TaskBoardRemoteAssignmentState::Started
            | TaskBoardRemoteAssignmentState::Running
    );
    let settlement_only = record.state == TaskBoardRemoteAssignmentState::Unknown;
    if settlement_only && renew_request_for_record(record)? != *request {
        return Err(concurrent(
            "late remote renewal replay differs from durable evidence",
        ));
    }
    let current_expiry = canonical_time(
        record
            .lease_expires_at
            .as_deref()
            .ok_or_else(|| db_error("remote renewal replay lease expiry is missing"))?,
        "current lease expiry",
    )?;
    let deadline = canonical_time(
        record
            .deadline_at
            .as_deref()
            .ok_or_else(|| db_error("remote renewal replay deadline is missing"))?,
        "remote assignment deadline",
    )?;
    let renewed_expiry = canonical_time(&response.lease.expires_at, "renewed lease expiry")?;
    let exact = (active || settlement_only)
        && response.lease.lease_id != request.lease_id
        && renewed_expiry > current_expiry
        && renewed_expiry <= deadline
        && mutation_binding_matches(
            record,
            &request.binding,
            principal,
            &request.lease_id,
        );
    if !exact {
        return Err(concurrent(
            "pending remote renewal replay response is stale",
        ));
    }
    Ok(ReplayWindow {
        current_expiry,
        deadline,
        settlement_only,
    })
}

fn validate_exchange(
    request: &RemoteLeaseRenewRequest,
    response: &RemoteLeaseRenewResponse,
    principal: &str,
) -> Result<(), CliError> {
    request
        .validate()
        .map_err(|error| db_error(format!("validate remote renewal replay request: {error}")))?;
    response
        .validate(request)
        .map_err(|error| db_error(format!("validate remote renewal replay response: {error}")))?;
    nonblank(principal, "remote renewal replay principal")
}
