use chrono::{DateTime, SecondsFormat, Utc};
use sqlx::{Sqlite, Transaction, query_as};

use super::remote_claim_receipts::TaskBoardRemoteClaimReceipt;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteOfferRequest, RemoteStatusResponse,
};
use crate::errors::CliErrorKind;
use crate::task_board::{TaskBoardExecutionPhase, TaskBoardRemoteAssignmentState};

mod chronology;
mod controller_operation;
mod decode;
mod failure_receipt;
mod outcomes;
mod persistence;
mod record;

pub(crate) use controller_operation::TaskBoardRemoteControllerOperationToken;
pub(super) use decode::phase_label;
pub(crate) use outcomes::{TaskBoardRemoteMutationOutcome, TaskBoardRemoteOfferOutcome};
pub(super) use persistence::{RemoteAssignmentInsertInput, insert_assignment_in_tx};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteAssignmentRecord {
    pub(crate) assignment_id: String,
    pub(crate) execution_id: String,
    pub(crate) phase: TaskBoardExecutionPhase,
    pub(crate) action_key: Option<String>,
    pub(crate) attempt: Option<u32>,
    pub(crate) idempotency_key: String,
    pub(crate) host_id: String,
    pub(crate) target_host_instance_id: Option<String>,
    pub(crate) claimed_host_instance_id: Option<String>,
    pub(crate) fencing_epoch: u64,
    pub(crate) configuration_revision: Option<u64>,
    pub(crate) executor_configuration_revision: Option<u64>,
    pub(crate) executor_checkout_path: Option<String>,
    pub(crate) executor_start_authority_sha256: Option<String>,
    pub(crate) executor_start_authority_at: Option<String>,
    pub(crate) executor_start_io_permit_sha256: Option<String>,
    pub(crate) executor_start_io_permit_at: Option<String>,
    pub(crate) executor_start_failure_receipt_json: Option<String>,
    pub(crate) executor_start_failure_receipt_sha256: Option<String>,
    pub(crate) start_failure_receipt:
        Option<super::remote_start_failure_receipts::TaskBoardRemoteExecutorStartFailureReceipt>,
    pub(crate) start_receipt:
        Option<super::remote_start_receipts::TaskBoardRemoteExecutorStartReceipt>,
    pub(crate) executor_lifecycle_owner:
        Option<super::remote_assignment_lifecycle_owner::TaskBoardRemoteExecutorLifecycleOwner>,
    pub(crate) executor_stop_pending:
        Option<super::remote_assignment_executor_stop::TaskBoardRemoteExecutorStopPending>,
    pub(crate) execution_record_sha256: Option<String>,
    pub(crate) request_sha256: Option<String>,
    pub(crate) offer: Option<RemoteOfferRequest>,
    pub(crate) authenticated_principal: Option<String>,
    pub(crate) claim_receipt: Option<TaskBoardRemoteClaimReceipt>,
    pub(crate) controller_operation: Option<TaskBoardRemoteControllerOperationToken>,
    pub(crate) state: TaskBoardRemoteAssignmentState,
    pub(crate) legacy_migrated: bool,
    pub(crate) offered_at: String,
    pub(crate) claimed_at: Option<String>,
    pub(crate) started_at: Option<String>,
    pub(crate) heartbeat_at: Option<String>,
    pub(crate) lease_id: Option<String>,
    pub(crate) lease_expires_at: Option<String>,
    pub(crate) deadline_at: Option<String>,
    pub(crate) cancel_requested_at: Option<String>,
    pub(crate) completed_at: Option<String>,
    pub(crate) workspace_ref: Option<String>,
    pub(crate) status_response: Option<RemoteStatusResponse>,
    pub(crate) status_sha256: Option<String>,
    pub(crate) result_sha256: Option<String>,
    pub(crate) cleanup_settlement_request_sha256: Option<String>,
    pub(crate) cleanup_completed_at: Option<String>,
    pub(crate) last_mutation_kind: Option<String>,
    pub(crate) last_mutation_sha256: Option<String>,
    pub(crate) error: Option<String>,
    pub(crate) updated_at: String,
}

impl TaskBoardRemoteAssignmentRecord {
    pub(crate) fn require_offer(&self) -> Result<&RemoteOfferRequest, CliError> {
        self.offer.as_ref().ok_or_else(|| {
            db_error("legacy remote assignment cannot be used as executable evidence")
        })
    }

    pub(crate) fn wire_state(&self) -> RemoteAssignmentWireState {
        match self.state {
            TaskBoardRemoteAssignmentState::Offered => RemoteAssignmentWireState::Offered,
            TaskBoardRemoteAssignmentState::Claimed => RemoteAssignmentWireState::Claimed,
            TaskBoardRemoteAssignmentState::Started | TaskBoardRemoteAssignmentState::Running => {
                RemoteAssignmentWireState::Running
            }
            TaskBoardRemoteAssignmentState::Completed => RemoteAssignmentWireState::Completed,
            TaskBoardRemoteAssignmentState::Failed => RemoteAssignmentWireState::Failed,
            TaskBoardRemoteAssignmentState::Cancelled => RemoteAssignmentWireState::Cancelled,
            TaskBoardRemoteAssignmentState::Unknown => RemoteAssignmentWireState::Unknown,
            TaskBoardRemoteAssignmentState::Superseded => RemoteAssignmentWireState::Superseded,
        }
    }
}

impl AsyncDaemonDb {
    pub(crate) async fn task_board_remote_assignment(
        &self,
        assignment_id: &str,
    ) -> Result<Option<TaskBoardRemoteAssignmentRecord>, CliError> {
        nonblank(assignment_id, "remote assignment id")?;
        let mut transaction = self
            .pool()
            .begin()
            .await
            .map_err(|error| db_error(format!("begin remote assignment read: {error}")))?;
        let assignment = load_assignment_in_tx(&mut transaction, assignment_id).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote assignment read: {error}")))?;
        Ok(assignment)
    }
}

#[derive(sqlx::FromRow)]
pub(super) struct RemoteAssignmentRow {
    assignment_id: String,
    execution_id: String,
    phase: String,
    action_key: Option<String>,
    attempt: Option<i64>,
    idempotency_key: String,
    host_id: String,
    target_host_instance_id: Option<String>,
    claimed_host_instance_id: Option<String>,
    fencing_epoch: i64,
    configuration_revision: Option<i64>,
    executor_configuration_revision: Option<i64>,
    executor_checkout_path: Option<String>,
    executor_start_authority_sha256: Option<String>,
    executor_start_authority_at: Option<String>,
    executor_start_io_permit_sha256: Option<String>,
    executor_start_io_permit_at: Option<String>,
    executor_start_receipt_json: Option<String>,
    executor_start_receipt_sha256: Option<String>,
    executor_start_failure_receipt_json: Option<String>,
    executor_start_failure_receipt_sha256: Option<String>,
    executor_lifecycle_owner_instance_id: Option<String>,
    executor_lifecycle_owner_epoch: Option<i64>,
    executor_lifecycle_owner_acquired_at: Option<String>,
    executor_lifecycle_owner_expires_at: Option<String>,
    executor_lifecycle_owner_sha256: Option<String>,
    executor_stop_pending_json: Option<String>,
    executor_stop_pending_sha256: Option<String>,
    execution_record_sha256: Option<String>,
    request_sha256: Option<String>,
    request_json: Option<String>,
    authenticated_principal: Option<String>,
    claim_request_sha256: Option<String>,
    claim_response_json: Option<String>,
    claim_receipt_sha256: Option<String>,
    controller_lifecycle_trust_json: Option<String>,
    controller_lifecycle_trust_sha256: Option<String>,
    controller_operation_kind: Option<String>,
    controller_operation_request_sha256: Option<String>,
    controller_operation_trust_sha256: Option<String>,
    controller_operation_fence_json: Option<String>,
    controller_operation_fence_sha256: Option<String>,
    state: String,
    legacy_migrated: bool,
    offered_at: String,
    claimed_at: Option<String>,
    started_at: Option<String>,
    heartbeat_at: Option<String>,
    lease_id: Option<String>,
    lease_expires_at: Option<String>,
    deadline_at: Option<String>,
    cancel_requested_at: Option<String>,
    completed_at: Option<String>,
    workspace_ref: Option<String>,
    result_json: Option<String>,
    result_sha256: Option<String>,
    status_sha256: Option<String>,
    cleanup_settlement_request_sha256: Option<String>,
    cleanup_completed_at: Option<String>,
    last_mutation_kind: Option<String>,
    last_mutation_sha256: Option<String>,
    error: Option<String>,
    updated_at: String,
}

impl RemoteAssignmentRow {
    const SELECT_BY_ID: &'static str = "SELECT assignment_id, execution_id, phase,
        action_key, attempt, idempotency_key, host_id, target_host_instance_id,
        claimed_host_instance_id, fencing_epoch, configuration_revision,
        executor_configuration_revision, executor_checkout_path,
        executor_start_authority_sha256, executor_start_authority_at,
        executor_start_io_permit_sha256, executor_start_io_permit_at,
        executor_start_receipt_json, executor_start_receipt_sha256,
        executor_start_failure_receipt_json, executor_start_failure_receipt_sha256,
        executor_lifecycle_owner_instance_id, executor_lifecycle_owner_epoch,
        executor_lifecycle_owner_acquired_at, executor_lifecycle_owner_expires_at,
        executor_lifecycle_owner_sha256, executor_stop_pending_json,
        executor_stop_pending_sha256,
        execution_record_sha256, request_sha256, request_json, authenticated_principal,
        claim_request_sha256, claim_response_json, claim_receipt_sha256,
        controller_lifecycle_trust_json, controller_lifecycle_trust_sha256,
        controller_operation_kind, controller_operation_request_sha256,
        controller_operation_trust_sha256, controller_operation_fence_json,
        controller_operation_fence_sha256,
        state, legacy_migrated, offered_at, claimed_at, started_at, heartbeat_at,
        lease_id, lease_expires_at, deadline_at, cancel_requested_at, completed_at,
        workspace_ref, result_json, result_sha256, status_sha256,
        cleanup_settlement_request_sha256, cleanup_completed_at, last_mutation_kind,
        last_mutation_sha256, error, updated_at FROM task_board_remote_assignments
        WHERE assignment_id = ?1 AND legacy_migrated = 0";
    const SELECT_COLLISION: &'static str = "SELECT assignment_id, execution_id, phase,
        action_key, attempt, idempotency_key, host_id, target_host_instance_id,
        claimed_host_instance_id, fencing_epoch, configuration_revision,
        executor_configuration_revision, executor_checkout_path,
        executor_start_authority_sha256, executor_start_authority_at,
        executor_start_io_permit_sha256, executor_start_io_permit_at,
        executor_start_receipt_json, executor_start_receipt_sha256,
        executor_start_failure_receipt_json, executor_start_failure_receipt_sha256,
        executor_lifecycle_owner_instance_id, executor_lifecycle_owner_epoch,
        executor_lifecycle_owner_acquired_at, executor_lifecycle_owner_expires_at,
        executor_lifecycle_owner_sha256, executor_stop_pending_json,
        executor_stop_pending_sha256,
        execution_record_sha256, request_sha256, request_json, authenticated_principal,
        claim_request_sha256, claim_response_json, claim_receipt_sha256,
        controller_lifecycle_trust_json, controller_lifecycle_trust_sha256,
        controller_operation_kind, controller_operation_request_sha256,
        controller_operation_trust_sha256, controller_operation_fence_json,
        controller_operation_fence_sha256,
        state, legacy_migrated, offered_at, claimed_at, started_at, heartbeat_at,
        lease_id, lease_expires_at, deadline_at, cancel_requested_at, completed_at,
        workspace_ref, result_json, result_sha256, status_sha256,
        cleanup_settlement_request_sha256, cleanup_completed_at, last_mutation_kind,
        last_mutation_sha256, error, updated_at FROM task_board_remote_assignments
        WHERE legacy_migrated = 0 AND (
              assignment_id = ?1 OR idempotency_key = ?2 OR request_sha256 = ?3
              OR (execution_id = ?4 AND action_key = ?5 AND attempt = ?6)
              OR (execution_id = ?4 AND fencing_epoch = ?7)
        )
        ORDER BY assignment_id";

    pub(super) fn into_record(self) -> Result<TaskBoardRemoteAssignmentRecord, CliError> {
        record::into_record(self)
    }
}

pub(super) async fn load_assignment_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment_id: &str,
) -> Result<Option<TaskBoardRemoteAssignmentRecord>, CliError> {
    query_as::<_, RemoteAssignmentRow>(RemoteAssignmentRow::SELECT_BY_ID)
        .bind(assignment_id)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load remote assignment: {error}")))?
        .map(RemoteAssignmentRow::into_record)
        .transpose()
}

pub(super) async fn load_offer_collision_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteOfferRequest,
) -> Result<Vec<TaskBoardRemoteAssignmentRecord>, CliError> {
    query_as::<_, RemoteAssignmentRow>(RemoteAssignmentRow::SELECT_COLLISION)
        .bind(&request.binding.assignment_id)
        .bind(&request.binding.idempotency_key)
        .bind(&request.request_sha256)
        .bind(&request.binding.execution_id)
        .bind(&request.binding.action_key)
        .bind(i64::from(request.binding.attempt))
        .bind(to_i64(
            request.binding.fencing_epoch,
            "offer collision fencing epoch",
        )?)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load remote assignment offer collision: {error}")))?
        .into_iter()
        .map(RemoteAssignmentRow::into_record)
        .collect()
}

pub(super) fn exact_offer_replay(
    record: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteOfferRequest,
    principal: &str,
) -> bool {
    !record.legacy_migrated
        && record.offer.as_ref() == Some(request)
        && record.request_sha256.as_deref() == Some(request.request_sha256.as_str())
        && record.authenticated_principal.as_deref() == Some(principal)
}

pub(super) fn canonical_time(value: &str, field: &str) -> Result<DateTime<Utc>, CliError> {
    let parsed = DateTime::parse_from_rfc3339(value)
        .map(DateTime::<Utc>::from)
        .map_err(|error| parse_error(format!("invalid {field}: {error}")))?;
    if parsed.to_rfc3339_opts(SecondsFormat::AutoSi, true) == value {
        Ok(parsed)
    } else {
        Err(parse_error(format!(
            "{field} must be canonical UTC RFC 3339"
        )))
    }
}

pub(super) fn nonblank(value: &str, field: &str) -> Result<(), CliError> {
    if value.trim() == value && !value.is_empty() && value.len() <= 512 {
        Ok(())
    } else {
        Err(parse_error(format!(
            "{field} must be nonblank and canonical"
        )))
    }
}

pub(super) fn concurrent(message: impl Into<String>) -> CliError {
    CliErrorKind::concurrent_modification(message.into()).into()
}

pub(super) fn to_i64(value: u64, field: &str) -> Result<i64, CliError> {
    i64::try_from(value).map_err(|_| db_error(format!("{field} is out of range")))
}

fn parse_error(message: impl Into<String>) -> CliError {
    CliErrorKind::workflow_parse(message.into()).into()
}

#[cfg(test)]
#[path = "remote_assignment_model_archival_tests.rs"]
mod archival_tests;
