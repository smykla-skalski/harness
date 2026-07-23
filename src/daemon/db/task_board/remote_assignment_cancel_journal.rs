//! Durable controller-side evidence for an in-flight remote cancellation.

use sqlx::{Sqlite, Transaction, query};

use super::remote_assignment_io_authority::active_target_matches;
use super::remote_assignment_io_authority::monotonic_time;
use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, canonical_time, concurrent, to_i64,
};
use super::remote_operation_trust::TaskBoardRemoteOperationKind;
use super::workflow_executions::load_execution_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteCancelRequest, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::TaskBoardRemoteAssignmentState;
use crate::task_board::{
    TASK_BOARD_REMOTE_CANCEL_INTENT_AT_RESOURCE, TASK_BOARD_REMOTE_CANCEL_INTENT_REASON_RESOURCE,
    TASK_BOARD_REMOTE_CANCEL_INTENT_RESOURCE, TaskBoardWorkflowExecutionRecord,
};

impl AsyncDaemonDb {
    pub(crate) async fn task_board_remote_cancel_intent(
        &self,
        assignment_id: &str,
    ) -> Result<Option<RemoteCancelRequest>, CliError> {
        let mut transaction = self
            .pool()
            .begin()
            .await
            .map_err(|error| db_error(format!("begin remote cancel intent read: {error}")))?;
        let Some(assignment) =
            super::remote_assignment_model::load_assignment_in_tx(&mut transaction, assignment_id)
                .await?
        else {
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit missing remote cancel intent read: {error}"))
            })?;
            return Ok(None);
        };
        let parent = load_execution_in_tx(&mut transaction, &assignment.execution_id)
            .await?
            .ok_or_else(|| concurrent("remote cancel intent parent disappeared"))?;
        let request = cancel_intent_request_for_record(&parent, &assignment)?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote cancel intent read: {error}")))?;
        Ok(request)
    }
}

pub(super) fn cancel_intent_request_for_record(
    parent: &TaskBoardWorkflowExecutionRecord,
    record: &TaskBoardRemoteAssignmentRecord,
) -> Result<Option<RemoteCancelRequest>, CliError> {
    let resources = &parent.ownership.resources;
    let digest = resources
        .get(TASK_BOARD_REMOTE_CANCEL_INTENT_RESOURCE)
        .map(String::as_str);
    let reason = resources
        .get(TASK_BOARD_REMOTE_CANCEL_INTENT_REASON_RESOURCE)
        .map(String::as_str);
    let requested_at = resources
        .get(TASK_BOARD_REMOTE_CANCEL_INTENT_AT_RESOURCE)
        .map(String::as_str);
    let (digest, reason, requested_at) = match (digest, reason, requested_at) {
        (None, None, None) => return Ok(None),
        (Some(digest), Some(reason), Some(requested_at)) => (digest, reason, requested_at),
        _ => return Err(concurrent("remote cancel intent evidence is incomplete")),
    };
    canonical_time(requested_at, "remote cancel intent time")?;
    if !active_target_matches(parent, record)
        || !matches!(
            record.state,
            TaskBoardRemoteAssignmentState::Claimed
                | TaskBoardRemoteAssignmentState::Started
                | TaskBoardRemoteAssignmentState::Running
        )
    {
        return Err(concurrent(
            "remote cancel intent is not attached to its exact active generation",
        ));
    }
    let request = cancel_request(record, reason)?;
    if request.request_sha256 != digest {
        return Err(concurrent(
            "remote cancel intent changed its exact request digest",
        ));
    }
    Ok(Some(request))
}

pub(super) fn cancel_request(
    record: &TaskBoardRemoteAssignmentRecord,
    reason: &str,
) -> Result<RemoteCancelRequest, CliError> {
    let offer = record.require_offer()?;
    RemoteCancelRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: record
            .lease_id
            .clone()
            .ok_or_else(|| concurrent("remote cancel intent has no exact lease"))?,
        offer_request_sha256: offer.request_sha256.clone(),
        reason: reason.into(),
        request_sha256: String::new(),
    }
    .seal()
    .map_err(|error| db_error(format!("seal remote cancel intent: {error}")))
}

pub(super) fn pending_cancel_request_for_record(
    record: &TaskBoardRemoteAssignmentRecord,
) -> Result<Option<RemoteCancelRequest>, CliError> {
    let Some(operation) = record.controller_operation.as_ref() else {
        return Ok(None);
    };
    if operation.kind != TaskBoardRemoteOperationKind::Cancel.as_str() {
        return Ok(None);
    }
    if !active(record.state) {
        return Err(concurrent(
            "pending remote cancel journal is not attached to an active assignment",
        ));
    }
    canonical_time(
        record
            .cancel_requested_at
            .as_deref()
            .ok_or_else(|| concurrent("pending remote cancel journal has no request time"))?,
        "pending remote cancel request time",
    )?;
    let reason = record
        .error
        .as_deref()
        .ok_or_else(|| concurrent("pending remote cancel journal has no reason"))?;
    let (Some("cancel"), Some(journal_sha256)) = (
        record.last_mutation_kind.as_deref(),
        record.last_mutation_sha256.as_deref(),
    ) else {
        return Err(concurrent(
            "pending remote cancel journal has incomplete request evidence",
        ));
    };
    let request = cancel_request(record, reason)?;
    if request.request_sha256 != operation.request_sha256
        || request.request_sha256 != journal_sha256
    {
        return Err(concurrent(
            "pending remote cancel journal changed its exact request digest",
        ));
    }
    Ok(Some(request))
}

pub(super) async fn journal_pending_cancel_request_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteCancelRequest,
    requested_at: &str,
) -> Result<(), CliError> {
    request
        .validate()
        .map_err(|error| db_error(format!("validate pending remote cancel journal: {error}")))?;
    canonical_time(requested_at, "pending remote cancel request time")?;
    if record.cancel_requested_at.is_some() || record.error.is_some() {
        let current = pending_cancel_request_for_record(record)?.ok_or_else(|| {
            concurrent("pending remote cancel journal lost its controller operation")
        })?;
        return if current == *request {
            Ok(())
        } else {
            Err(concurrent(
                "pending remote cancel journal conflicts with its exact request",
            ))
        };
    }
    let operation = record
        .controller_operation
        .as_ref()
        .ok_or_else(|| concurrent("pending remote cancel journal has no controller operation"))?;
    if operation.kind != TaskBoardRemoteOperationKind::Cancel.as_str()
        || operation.request_sha256 != request.request_sha256
        || record.cancel_requested_at.is_some()
        || record.error.is_some()
    {
        return Err(concurrent(
            "pending remote cancel journal conflicts with durable assignment evidence",
        ));
    }
    let updated_at = monotonic_time(&record.updated_at, requested_at)?;
    let rows = query(
        "UPDATE task_board_remote_assignments SET
         cancel_requested_at = ?2, last_mutation_kind = 'cancel',
         last_mutation_sha256 = ?3, error = ?4, updated_at = ?5
         WHERE assignment_id = ?1 AND fencing_epoch = ?6 AND state = ?7
           AND request_sha256 = ?8 AND lease_id = ?9
           AND authenticated_principal = ?10 AND updated_at = ?11
           AND controller_operation_kind = 'cancel'
           AND controller_operation_request_sha256 = ?3
           AND controller_operation_trust_sha256 = ?12
           AND cancel_requested_at IS NULL AND error IS NULL",
    )
    .bind(&record.assignment_id)
    .bind(requested_at)
    .bind(&request.request_sha256)
    .bind(&request.reason)
    .bind(updated_at)
    .bind(to_i64(
        record.fencing_epoch,
        "pending cancel fencing epoch",
    )?)
    .bind(record.state.as_str())
    .bind(&request.offer_request_sha256)
    .bind(&request.lease_id)
    .bind(&record.authenticated_principal)
    .bind(&record.updated_at)
    .bind(&operation.trust_sha256)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("journal pending remote cancel request: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(())
    } else {
        Err(concurrent(
            "pending remote cancel journal lost its exact assignment fence",
        ))
    }
}

pub(super) async fn journal_cancel_claim_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment_id: &str,
    request: Option<&RemoteCancelRequest>,
    requested_at: &str,
) -> Result<(), CliError> {
    let Some(request) = request else {
        return Ok(());
    };
    let record = super::remote_assignment_model::load_assignment_in_tx(transaction, assignment_id)
        .await?
        .ok_or_else(|| concurrent("pending remote cancel assignment disappeared"))?;
    journal_pending_cancel_request_in_tx(transaction, &record, request, requested_at).await
}

const fn active(state: TaskBoardRemoteAssignmentState) -> bool {
    matches!(
        state,
        TaskBoardRemoteAssignmentState::Offered
            | TaskBoardRemoteAssignmentState::Claimed
            | TaskBoardRemoteAssignmentState::Started
            | TaskBoardRemoteAssignmentState::Running
    )
}
