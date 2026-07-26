use sqlx::query;

use super::remote_assignment_authority_settlement::clear_renew_io_authority_in_tx;
use super::remote_assignment_controller_recovery::recover_controller_remote_assignment_in_tx;
use super::remote_assignment_lease::{
    commit_noop, exact_mutation_replay, finish_mutation, mutation_binding_matches,
    renew_request_for_record, require_assignment,
};
use super::remote_assignment_model::{
    TaskBoardRemoteMutationOutcome, canonical_time, concurrent, nonblank, to_i64,
};
use super::remote_operation_trust::{
    TaskBoardRemoteOperationKind, consume_controller_operation_trust_in_tx,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteLeaseRenewRequest, RemoteLeaseRenewResponse,
};
use crate::task_board::TaskBoardRemoteAssignmentState;

#[path = "remote_assignment_lease_response/replay.rs"]
mod replay;

impl AsyncDaemonDb {
    pub(crate) async fn record_task_board_remote_assignment_lease_renewal(
        &self,
        request: &RemoteLeaseRenewRequest,
        response: &RemoteLeaseRenewResponse,
        authenticated_principal: &str,
        recorded_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        request
            .validate()
            .map_err(|error| db_error(format!("validate remote renewal request: {error}")))?;
        response
            .validate(request)
            .map_err(|error| db_error(format!("validate remote renewal response: {error}")))?;
        nonblank(
            authenticated_principal,
            "remote assignment authenticated principal",
        )?;
        let recorded = canonical_time(recorded_at, "remote renewal response time")?;
        let renewed_expiry = canonical_time(&response.lease.expires_at, "renewed lease expiry")?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote renewal response")
            .await?;
        let record = require_assignment(&mut transaction, &request.binding.assignment_id).await?;
        if renewal_response_replayed(&record, request, response, authenticated_principal) {
            commit_noop(transaction, "replayed remote renewal response").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Replayed(record));
        }
        let window = renewal_window(
            &record,
            request,
            response,
            renewed_expiry,
            authenticated_principal,
        )?;
        if !window.acceptable {
            commit_noop(transaction, "stale remote renewal response").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        let RenewalWindow {
            current_expiry,
            deadline,
            settlement_only,
            ..
        } = window;
        consume_controller_operation_trust_in_tx(
            &mut transaction,
            &record,
            TaskBoardRemoteOperationKind::Renew,
            &request.request_sha256,
        )
        .await?;
        settle_renewal_response_in_tx(
            transaction,
            &record,
            request,
            response,
            recorded_at,
            &RenewalFence {
                recorded,
                renewed_expiry,
                current_expiry,
                deadline,
                settlement_only,
            },
            &RenewalLabels {
                late: "late renewal response",
                settled: "renewal response",
            },
        )
        .await
    }
}

/// The live renewal path's counterpart to the replay path's `ReplayWindow`:
/// the record's own fence values, whether it is only being settled after the
/// fact, and whether the rotation is acceptable at all. The two paths differ
/// in that a live record need not carry an expiry or a deadline, and reports
/// an unacceptable rotation as a stale no-op rather than an error.
struct RenewalWindow {
    current_expiry: Option<chrono::DateTime<chrono::Utc>>,
    deadline: Option<chrono::DateTime<chrono::Utc>>,
    settlement_only: bool,
    acceptable: bool,
}

fn renewal_window(
    record: &super::TaskBoardRemoteAssignmentRecord,
    request: &RemoteLeaseRenewRequest,
    response: &RemoteLeaseRenewResponse,
    renewed_expiry: chrono::DateTime<chrono::Utc>,
    principal: &str,
) -> Result<RenewalWindow, CliError> {
    let active = matches!(
        record.state,
        TaskBoardRemoteAssignmentState::Claimed
            | TaskBoardRemoteAssignmentState::Started
            | TaskBoardRemoteAssignmentState::Running
    );
    let settlement_only = record.state == TaskBoardRemoteAssignmentState::Unknown;
    if settlement_only && renew_request_for_record(record)? != *request {
        return Err(concurrent(
            "late remote renewal request differs from deterministic durable evidence",
        ));
    }
    let current_expiry = record
        .lease_expires_at
        .as_deref()
        .map(|value| canonical_time(value, "current lease expiry"))
        .transpose()?;
    let deadline = record
        .deadline_at
        .as_deref()
        .map(|value| canonical_time(value, "remote assignment deadline"))
        .transpose()?;
    let valid_rotation = response.lease.lease_id != request.lease_id
        && current_expiry.is_some_and(|current| renewed_expiry > current)
        && deadline.is_some_and(|deadline| renewed_expiry <= deadline);
    let acceptable = (active || settlement_only)
        && valid_rotation
        && mutation_binding_matches(record, &request.binding, principal, &request.lease_id);
    Ok(RenewalWindow {
        current_expiry,
        deadline,
        settlement_only,
        acceptable,
    })
}

/// The three deadlines a renewal is measured against, plus whether the record
/// is only being settled after the fact. `current_expiry` and `deadline` are
/// optional because the live path reads them straight off a record that need
/// not carry either, while the replay path has already proved both present.
pub(super) struct RenewalFence {
    pub(super) recorded: chrono::DateTime<chrono::Utc>,
    pub(super) renewed_expiry: chrono::DateTime<chrono::Utc>,
    pub(super) current_expiry: Option<chrono::DateTime<chrono::Utc>>,
    pub(super) deadline: Option<chrono::DateTime<chrono::Utc>>,
    pub(super) settlement_only: bool,
}

impl RenewalFence {
    /// A renewal observed at or past any one of the three fences means the
    /// controller has to re-derive the assignment rather than simply release
    /// its renew authority.
    fn observed_after_fence(&self) -> bool {
        self.current_expiry
            .is_some_and(|expiry| self.recorded >= expiry)
            || self.recorded >= self.renewed_expiry
            || self
                .deadline
                .is_some_and(|deadline| self.recorded >= deadline)
    }
}

/// The commit labels that distinguish a live renewal from its pending replay;
/// everything else about settling the two is identical.
pub(super) struct RenewalLabels {
    pub(super) late: &'static str,
    pub(super) settled: &'static str,
}

/// Persist a renewal response and settle its transaction: a settlement-only
/// record finishes immediately, anything observed past the fence hands the
/// assignment back to controller recovery, and everything else just releases
/// the renew I/O authority. The live renewal path and its pending-replay twin
/// share this verbatim -- they differ only in these labels and in whether
/// their fence values were optional at the point they were read.
pub(super) async fn settle_renewal_response_in_tx(
    mut transaction: sqlx::Transaction<'_, sqlx::Sqlite>,
    record: &super::TaskBoardRemoteAssignmentRecord,
    request: &RemoteLeaseRenewRequest,
    response: &RemoteLeaseRenewResponse,
    recorded_at: &str,
    fence: &RenewalFence,
    labels: &RenewalLabels,
) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
    persist_renewal_response(&mut transaction, record, request, response, recorded_at).await?;
    if fence.settlement_only {
        return finish_mutation(transaction, &record.assignment_id, labels.late).await;
    }
    if fence.observed_after_fence() {
        Box::pin(recover_controller_remote_assignment_in_tx(
            &mut transaction,
            record,
            recorded_at,
        ))
        .await?;
    } else {
        clear_renew_io_authority_in_tx(
            &mut transaction,
            record,
            &request.request_sha256,
            recorded_at,
        )
        .await?;
    }
    finish_mutation(transaction, &record.assignment_id, labels.settled).await
}

pub(super) fn renewal_response_replayed(
    record: &super::TaskBoardRemoteAssignmentRecord,
    request: &RemoteLeaseRenewRequest,
    response: &RemoteLeaseRenewResponse,
    principal: &str,
) -> bool {
    record.authenticated_principal.as_deref() == Some(principal)
        && record.offer.as_ref().map(|offer| &offer.binding) == Some(&request.binding)
        && record.request_sha256.as_deref() == Some(request.offer_request_sha256.as_str())
        && record.lease_id.as_deref() == Some(response.lease.lease_id.as_str())
        && record.lease_expires_at.as_deref() == Some(response.lease.expires_at.as_str())
        && exact_mutation_replay(record, "renew_response", &request.request_sha256)
}

pub(super) async fn persist_renewal_response(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    record: &super::TaskBoardRemoteAssignmentRecord,
    request: &RemoteLeaseRenewRequest,
    response: &RemoteLeaseRenewResponse,
    recorded_at: &str,
) -> Result<(), CliError> {
    let rows = query(
        "UPDATE task_board_remote_assignments SET lease_id = ?2,
         lease_expires_at = ?3, heartbeat_at = ?4,
         last_mutation_kind = 'renew_response', last_mutation_sha256 = ?5,
         result_json = NULL, status_sha256 = NULL, result_sha256 = NULL,
         updated_at = ?4 WHERE assignment_id = ?1 AND fencing_epoch = ?6
         AND lease_id = ?7 AND state IN ('claimed', 'started', 'running', 'unknown')",
    )
    .bind(&record.assignment_id)
    .bind(&response.lease.lease_id)
    .bind(&response.lease.expires_at)
    .bind(recorded_at)
    .bind(&request.request_sha256)
    .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
    .bind(&request.lease_id)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("persist remote renewal response: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(())
    } else {
        Err(concurrent("remote renewal response lost its lease fence"))
    }
}
