use sqlx::{Sqlite, Transaction, query};

use super::remote_assignment_authority_settlement::clear_offer_io_authority_in_tx;
use super::remote_assignment_lease::{
    commit_noop, exact_mutation_replay, finish_mutation, mutation_binding_matches,
    require_assignment,
};
use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome, canonical_time, concurrent,
    nonblank, to_i64,
};
use super::remote_assignment_rejection::{apply_rejected_offer, apply_unclaimable_offer};
use super::remote_offer_receipts::{
    ensure_accepted_offer_receipt_in_tx, load_offer_receipt_collisions_in_tx,
};
use super::remote_operation_trust::{
    TaskBoardRemoteOperationKind, TaskBoardRemoteOperationTrustFence,
    consume_controller_operation_trust_in_tx, consume_successor_recovery_operation_trust_in_tx,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAttemptBinding, RemoteCancelRequest, RemoteOfferDisposition, RemoteOfferResponse,
};
use crate::task_board::TaskBoardRemoteAssignmentState;

impl AsyncDaemonDb {
    pub(crate) async fn record_task_board_remote_offer_response(
        &self,
        response: &RemoteOfferResponse,
        authenticated_principal: &str,
        observed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        nonblank(
            authenticated_principal,
            "remote assignment authenticated principal",
        )?;
        canonical_time(observed_at, "remote offer response time")?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote offer response")
            .await?;
        let record = require_assignment(&mut transaction, &response.binding.assignment_id).await?;
        response
            .validate(record.require_offer()?)
            .map_err(|error| db_error(format!("validate remote offer response: {error}")))?;
        if super::remote_source_bundle_abandonment::source_offer_is_abandoned_in_tx(
            &mut transaction,
            record.require_offer()?,
        )
        .await?
        {
            commit_noop(transaction, "stale abandoned offer response").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        let receipts =
            load_offer_receipt_collisions_in_tx(&mut transaction, record.require_offer()?).await?;
        if !receipts.is_empty() {
            if receipts.len() == 1
                && receipts[0].is_exact_replay(record.require_offer()?, authenticated_principal)
                && receipts[0].response()? == *response
            {
                commit_noop(transaction, "replayed immutable remote offer response").await?;
                return Ok(TaskBoardRemoteMutationOutcome::Replayed(record));
            }
            return Err(concurrent(
                "remote offer response conflicts with immutable receipt evidence",
            ));
        }
        if !response_binding_matches(&record, &response.binding, authenticated_principal) {
            commit_noop(transaction, "stale offer response").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        consume_controller_operation_trust_in_tx(
            &mut transaction,
            &record,
            TaskBoardRemoteOperationKind::Offer,
            &response.offer_request_sha256,
        )
        .await?;
        match response.disposition {
            RemoteOfferDisposition::Accepted => {
                apply_accepted_offer(transaction, record, response, observed_at).await
            }
            RemoteOfferDisposition::Rejected => {
                apply_rejected_offer(transaction, record, response, observed_at).await
            }
        }
    }

    pub(crate) async fn record_task_board_remote_predecessor_offer_acceptance(
        &self,
        response: &RemoteOfferResponse,
        authenticated_principal: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
        observed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        nonblank(
            authenticated_principal,
            "recovered remote offer authenticated principal",
        )?;
        canonical_time(observed_at, "recovered remote offer response time")?;
        if response.disposition != RemoteOfferDisposition::Accepted {
            return Err(db_error(
                "predecessor offer acceptance recovery requires an accepted response",
            ));
        }
        let mut transaction = self
            .begin_immediate_transaction("task board predecessor offer acceptance")
            .await?;
        let record = require_assignment(&mut transaction, &response.binding.assignment_id).await?;
        response
            .validate(record.require_offer()?)
            .map_err(|error| db_error(format!("validate recovered offer response: {error}")))?;
        if super::remote_source_bundle_abandonment::source_offer_is_abandoned_in_tx(
            &mut transaction,
            record.require_offer()?,
        )
        .await?
        {
            commit_noop(transaction, "stale recovered abandoned offer").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        let receipts =
            load_offer_receipt_collisions_in_tx(&mut transaction, record.require_offer()?).await?;
        if !receipts.is_empty() {
            if receipts.len() == 1
                && receipts[0].is_exact_replay(record.require_offer()?, authenticated_principal)
                && receipts[0].response()? == *response
            {
                commit_noop(transaction, "replayed recovered offer acceptance").await?;
                return Ok(TaskBoardRemoteMutationOutcome::Replayed(record));
            }
            return Err(concurrent(
                "recovered offer acceptance conflicts with immutable receipt evidence",
            ));
        }
        if !response_binding_matches(&record, &response.binding, authenticated_principal)
            || record.target_host_instance_id.as_deref()
                == Some(trust.observed_host_instance_id.as_str())
        {
            commit_noop(transaction, "stale recovered offer acceptance").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        consume_successor_recovery_operation_trust_in_tx(
            &mut transaction,
            &record,
            TaskBoardRemoteOperationKind::Offer,
            &response.offer_request_sha256,
            trust,
        )
        .await?;
        apply_accepted_offer(transaction, record, response, observed_at).await
    }

    pub(crate) async fn cancel_task_board_remote_assignment(
        &self,
        request: &RemoteCancelRequest,
        authenticated_principal: &str,
        cancelled_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        request
            .validate()
            .map_err(|error| db_error(format!("validate remote assignment cancel: {error}")))?;
        nonblank(
            authenticated_principal,
            "remote assignment authenticated principal",
        )?;
        canonical_time(cancelled_at, "remote assignment cancellation time")?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote assignment cancel")
            .await?;
        let record = require_assignment(&mut transaction, &request.binding.assignment_id).await?;
        if exact_mutation_replay(&record, "cancel", &request.request_sha256)
            && record.state == TaskBoardRemoteAssignmentState::Cancelled
        {
            commit_noop(transaction, "replayed cancellation").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Replayed(record));
        }
        let cancellable = matches!(
            record.state,
            TaskBoardRemoteAssignmentState::Offered
                | TaskBoardRemoteAssignmentState::Claimed
                | TaskBoardRemoteAssignmentState::Started
                | TaskBoardRemoteAssignmentState::Running
        );
        if record.executor_start_authority_sha256.is_some()
            || record.executor_stop_pending.is_some()
            || !cancellable
            || !mutation_binding_matches(
                &record,
                &request.binding,
                authenticated_principal,
                &request.lease_id,
            )
        {
            commit_noop(transaction, "stale cancellation").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        let rows = query(
            "UPDATE task_board_remote_assignments SET state = 'cancelled',
             cancel_requested_at = ?2, heartbeat_at = ?2, completed_at = ?2,
             last_mutation_kind = 'cancel', last_mutation_sha256 = ?3,
             error = ?4, updated_at = ?2
             WHERE assignment_id = ?1 AND fencing_epoch = ?5 AND lease_id = ?6
             AND state IN ('offered', 'claimed', 'started', 'running')
             AND executor_start_authority_sha256 IS NULL
             AND executor_stop_pending_sha256 IS NULL",
        )
        .bind(&record.assignment_id)
        .bind(cancelled_at)
        .bind(&request.request_sha256)
        .bind(&request.reason)
        .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
        .bind(&request.lease_id)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("cancel remote assignment: {error}")))?
        .rows_affected();
        if rows != 1 {
            return Err(concurrent("remote assignment cancellation lost its fence"));
        }
        finish_mutation(transaction, &record.assignment_id, "cancellation").await
    }

    pub(crate) async fn mark_task_board_remote_assignment_unknown(
        &self,
        binding: &RemoteAttemptBinding,
        reason: &str,
        observed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        binding
            .validate()
            .map_err(|error| db_error(format!("validate unknown assignment binding: {error}")))?;
        nonblank(reason, "remote assignment unknown reason")?;
        canonical_time(observed_at, "remote assignment unknown time")?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote assignment unknown")
            .await?;
        let record = require_assignment(&mut transaction, &binding.assignment_id).await?;
        if record.state == TaskBoardRemoteAssignmentState::Unknown
            && record.error.as_deref() == Some(reason)
        {
            commit_noop(transaction, "replayed unknown outcome").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Replayed(record));
        }
        let active = matches!(
            record.state,
            TaskBoardRemoteAssignmentState::Offered
                | TaskBoardRemoteAssignmentState::Claimed
                | TaskBoardRemoteAssignmentState::Started
                | TaskBoardRemoteAssignmentState::Running
        );
        if record.executor_start_authority_sha256.is_some()
            || record.executor_stop_pending.is_some()
            || !active
            || !record_binding_matches(&record, binding)
        {
            commit_noop(transaction, "stale unknown outcome").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        update_terminal_state(
            &mut transaction,
            &record,
            "unknown",
            reason,
            observed_at,
            false,
        )
        .await?;
        finish_mutation(transaction, &record.assignment_id, "unknown outcome").await
    }

    pub(crate) async fn supersede_unclaimed_task_board_remote_assignment(
        &self,
        binding: &RemoteAttemptBinding,
        reason: &str,
        superseded_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        binding
            .validate()
            .map_err(|error| db_error(format!("validate supersede binding: {error}")))?;
        nonblank(reason, "remote assignment supersede reason")?;
        canonical_time(superseded_at, "remote assignment supersede time")?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote assignment supersede")
            .await?;
        let record = require_assignment(&mut transaction, &binding.assignment_id).await?;
        if record.state == TaskBoardRemoteAssignmentState::Superseded
            && record.claimed_at.is_none()
            && record.error.as_deref() == Some(reason)
        {
            commit_noop(transaction, "replayed supersede").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Replayed(record));
        }
        if record.state != TaskBoardRemoteAssignmentState::Offered
            || record.claimed_at.is_some()
            || !record_binding_matches(&record, binding)
        {
            commit_noop(transaction, "stale supersede").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        update_terminal_state(
            &mut transaction,
            &record,
            "superseded",
            reason,
            superseded_at,
            true,
        )
        .await?;
        finish_mutation(transaction, &record.assignment_id, "supersede").await
    }
}

async fn apply_accepted_offer(
    mut transaction: Transaction<'_, Sqlite>,
    record: TaskBoardRemoteAssignmentRecord,
    response: &RemoteOfferResponse,
    observed_at: &str,
) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
    let lease = response
        .lease
        .as_ref()
        .ok_or_else(|| db_error("accepted remote offer response has no lease"))?;
    if record.lease_id.as_deref() == Some(lease.lease_id.as_str())
        && record.lease_expires_at.as_deref() == Some(lease.expires_at.as_str())
    {
        commit_noop(transaction, "replayed accepted offer").await?;
        return Ok(TaskBoardRemoteMutationOutcome::Replayed(record));
    }
    let expires = canonical_time(&lease.expires_at, "remote assignment lease expiry")?;
    let deadline = record
        .deadline_at
        .as_deref()
        .ok_or_else(|| db_error("remote assignment deadline is missing"))?;
    if expires > canonical_time(deadline, "remote assignment deadline")? {
        return Err(db_error(
            "accepted remote offer lease is outside its deadline",
        ));
    }
    if record.state == TaskBoardRemoteAssignmentState::Superseded
        && record.claimed_at.is_none()
        && record.lease_id.is_none()
    {
        return retain_late_accepted_offer(transaction, record, response, observed_at).await;
    }
    if record.state != TaskBoardRemoteAssignmentState::Offered
        || record.claimed_at.is_some()
        || record.lease_id.is_some()
    {
        commit_noop(transaction, "stale accepted offer").await?;
        return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
    }
    ensure_accepted_offer_receipt_in_tx(
        &mut transaction,
        record.require_offer()?,
        record
            .authenticated_principal
            .as_deref()
            .ok_or_else(|| db_error("remote assignment principal is missing"))?,
        &lease.lease_id,
        &lease.expires_at,
        observed_at,
    )
    .await?;
    clear_offer_io_authority_in_tx(&mut transaction, &record, observed_at).await?;
    let rows = query(
        "UPDATE task_board_remote_assignments SET lease_id = ?2, lease_expires_at = ?3,
         heartbeat_at = ?4, updated_at = ?4
         WHERE assignment_id = ?1 AND fencing_epoch = ?5 AND state = 'offered'
           AND claimed_at IS NULL AND lease_id IS NULL",
    )
    .bind(&record.assignment_id)
    .bind(&lease.lease_id)
    .bind(&lease.expires_at)
    .bind(observed_at)
    .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("record accepted remote offer: {error}")))?
    .rows_affected();
    if rows != 1 {
        return Err(concurrent("accepted remote offer lost its fence"));
    }
    if expires <= canonical_time(observed_at, "remote offer response time")? {
        let accepted = TaskBoardRemoteAssignmentRecord {
            lease_id: Some(lease.lease_id.clone()),
            lease_expires_at: Some(lease.expires_at.clone()),
            heartbeat_at: Some(observed_at.into()),
            updated_at: observed_at.into(),
            ..record
        };
        return apply_unclaimable_offer(
            transaction,
            accepted,
            "remote offer acceptance arrived after lease expiry",
            observed_at,
        )
        .await;
    }
    finish_mutation(transaction, &record.assignment_id, "accepted offer").await
}

async fn retain_late_accepted_offer(
    mut transaction: Transaction<'_, Sqlite>,
    record: TaskBoardRemoteAssignmentRecord,
    response: &RemoteOfferResponse,
    observed_at: &str,
) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
    let lease = response
        .lease
        .as_ref()
        .ok_or_else(|| db_error("accepted remote offer response has no lease"))?;
    ensure_accepted_offer_receipt_in_tx(
        &mut transaction,
        record.require_offer()?,
        record
            .authenticated_principal
            .as_deref()
            .ok_or_else(|| db_error("remote assignment principal is missing"))?,
        &lease.lease_id,
        &lease.expires_at,
        observed_at,
    )
    .await?;
    let rows = query(
        "UPDATE task_board_remote_assignments SET lease_id = ?2,
         lease_expires_at = ?3, heartbeat_at = ?4, updated_at = ?4
         WHERE assignment_id = ?1 AND fencing_epoch = ?5
           AND state = 'superseded' AND claimed_at IS NULL AND lease_id IS NULL",
    )
    .bind(&record.assignment_id)
    .bind(&lease.lease_id)
    .bind(&lease.expires_at)
    .bind(observed_at)
    .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("retain late accepted remote offer: {error}")))?
    .rows_affected();
    if rows != 1 {
        return Err(concurrent("late accepted remote offer lost its fence"));
    }
    finish_mutation(transaction, &record.assignment_id, "late accepted offer").await
}

fn response_binding_matches(
    record: &TaskBoardRemoteAssignmentRecord,
    binding: &RemoteAttemptBinding,
    principal: &str,
) -> bool {
    record_binding_matches(record, binding)
        && record.authenticated_principal.as_deref() == Some(principal)
}

fn record_binding_matches(
    record: &TaskBoardRemoteAssignmentRecord,
    binding: &RemoteAttemptBinding,
) -> bool {
    record
        .offer
        .as_ref()
        .is_some_and(|offer| offer.binding == *binding)
        && record.fencing_epoch == binding.fencing_epoch
        && record.target_host_instance_id.as_deref() == Some(binding.host_instance_id.as_str())
}

async fn update_terminal_state(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    state: &str,
    reason: &str,
    now: &str,
    completed: bool,
) -> Result<(), CliError> {
    let completed_at = completed.then_some(now);
    let rows = query(
        "UPDATE task_board_remote_assignments SET state = ?2, heartbeat_at = ?3,
         completed_at = ?4, error = ?5, updated_at = ?3,
         result_json = NULL, status_sha256 = NULL, result_sha256 = NULL
         WHERE assignment_id = ?1 AND fencing_epoch = ?6
           AND state IN ('offered', 'claimed', 'started', 'running')
           AND executor_start_authority_sha256 IS NULL
           AND executor_stop_pending_sha256 IS NULL",
    )
    .bind(&record.assignment_id)
    .bind(state)
    .bind(now)
    .bind(completed_at)
    .bind(reason)
    .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("record remote assignment terminal state: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(())
    } else {
        Err(concurrent(
            "remote assignment terminal update lost its fence",
        ))
    }
}
