use super::chronology;
use super::controller_operation;
use super::decode::{
    decode_offer, decode_status, positive_u32, positive_u64, validate_offer_copies,
};
use super::failure_receipt::apply_start_failure_receipt;
use super::{RemoteAssignmentRow, TaskBoardRemoteAssignmentRecord};
use crate::daemon::db::{CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest;
use crate::task_board::{TaskBoardExecutionPhase, TaskBoardRemoteAssignmentState};

struct DecodedRow {
    phase: TaskBoardExecutionPhase,
    state: TaskBoardRemoteAssignmentState,
    fencing_epoch: u64,
    attempt: Option<u32>,
    configuration_revision: Option<u64>,
    executor_configuration_revision: Option<u64>,
    offer: Option<RemoteOfferRequest>,
    claim_receipt: Option<super::super::remote_claim_receipts::TaskBoardRemoteClaimReceipt>,
    controller_operation: Option<super::TaskBoardRemoteControllerOperationToken>,
}

struct EvidenceBlobs {
    start_receipt_json: Option<String>,
    start_receipt_sha256: Option<String>,
    owner_instance_id: Option<String>,
    owner_epoch: Option<i64>,
    owner_acquired_at: Option<String>,
    owner_expires_at: Option<String>,
    owner_sha256: Option<String>,
    stop_pending_json: Option<String>,
    stop_pending_sha256: Option<String>,
}

pub(super) fn into_record(
    row: RemoteAssignmentRow,
) -> Result<TaskBoardRemoteAssignmentRecord, CliError> {
    let mut decoded = decode_row(&row)?;
    decode_control_evidence(&row, &mut decoded)?;
    let evidence = EvidenceBlobs::from_row(&row);
    let record = into_base_record(row, decoded)?;
    attach_evidence(record, evidence)
}

fn decode_row(row: &RemoteAssignmentRow) -> Result<DecodedRow, CliError> {
    if row.legacy_migrated {
        return Err(db_error(
            "legacy-migrated remote assignment is archival only",
        ));
    }
    let executor_configuration_revision = row
        .executor_configuration_revision
        .map(|value| positive_u64(value, "executor configuration revision"))
        .transpose()?;
    if executor_configuration_revision.is_some() != row.executor_checkout_path.is_some() {
        return Err(db_error(
            "executor assignment settings evidence is incomplete",
        ));
    }
    chronology::validate_persisted_chronology(row)?;
    let offer = row.request_json.as_deref().map(decode_offer).transpose()?;
    validate_offer_copies(row, offer.as_ref())?;
    Ok(DecodedRow {
        phase: super::decode::decode_phase(&row.phase)?,
        state: TaskBoardRemoteAssignmentState::decode(&row.state)?,
        fencing_epoch: positive_u64(row.fencing_epoch, "assignment fencing epoch")?,
        attempt: row
            .attempt
            .map(|value| positive_u32(value, "assignment attempt"))
            .transpose()?,
        configuration_revision: row
            .configuration_revision
            .map(|value| positive_u64(value, "assignment configuration revision"))
            .transpose()?,
        executor_configuration_revision,
        offer,
        claim_receipt: None,
        controller_operation: None,
    })
}

fn decode_control_evidence(
    row: &RemoteAssignmentRow,
    decoded: &mut DecodedRow,
) -> Result<(), CliError> {
    decoded.claim_receipt = super::super::remote_claim_receipts::decode_claim_receipt(
        &row.assignment_id,
        decoded.fencing_epoch,
        decoded.offer.as_ref(),
        row.authenticated_principal.as_deref(),
        row.claimed_at.as_deref(),
        row.claim_request_sha256.clone(),
        row.claim_response_json.clone(),
        row.claim_receipt_sha256.clone(),
    )?;
    let lifecycle_trust = super::super::remote_lifecycle_trust::decode_lifecycle_trust(
        row.controller_lifecycle_trust_json.clone(),
        row.controller_lifecycle_trust_sha256.clone(),
    )?;
    if let Some(generation) = lifecycle_trust.as_ref() {
        generation.require_generation_binding(
            &row.host_id,
            decoded.configuration_revision,
            row.target_host_instance_id.as_deref(),
        )?;
    }
    decoded.controller_operation = controller_operation::decode(
        row.controller_operation_kind.clone(),
        row.controller_operation_request_sha256.clone(),
        row.controller_operation_trust_sha256.clone(),
        row.controller_operation_fence_json.clone(),
        row.controller_operation_fence_sha256.clone(),
    )?;
    if let Some(operation) = decoded.controller_operation.as_ref()
        && let Some(fence) = operation.fence.as_ref()
    {
        let generation = lifecycle_trust.as_ref().ok_or_else(|| {
            db_error("controller operation has no frozen generation lifecycle trust")
        })?;
        fence.require_operation_binding(
            generation,
            &row.host_id,
            decoded.configuration_revision,
            row.target_host_instance_id.as_deref(),
            controller_operation::requires_exact_generation(&operation.kind),
        )?;
    }
    super::super::remote_assignment_cleanup::validate_cleanup_marker(
        row.legacy_migrated,
        &row.state,
        row.cleanup_settlement_request_sha256.as_deref(),
        row.cleanup_completed_at.as_deref(),
    )
}

fn into_base_record(
    row: RemoteAssignmentRow,
    decoded: DecodedRow,
) -> Result<TaskBoardRemoteAssignmentRecord, CliError> {
    let status_response = row
        .result_json
        .as_deref()
        .map(|json| {
            decode_status(
                json,
                decoded.offer.as_ref(),
                row.lease_id.as_deref(),
                row.lease_expires_at.as_deref(),
            )
        })
        .transpose()?;
    Ok(TaskBoardRemoteAssignmentRecord {
        assignment_id: row.assignment_id,
        execution_id: row.execution_id,
        phase: decoded.phase,
        action_key: row.action_key,
        attempt: decoded.attempt,
        idempotency_key: row.idempotency_key,
        host_id: row.host_id,
        target_host_instance_id: row.target_host_instance_id,
        claimed_host_instance_id: row.claimed_host_instance_id,
        fencing_epoch: decoded.fencing_epoch,
        configuration_revision: decoded.configuration_revision,
        executor_configuration_revision: decoded.executor_configuration_revision,
        executor_checkout_path: row.executor_checkout_path,
        executor_start_authority_sha256: row.executor_start_authority_sha256,
        executor_start_authority_at: row.executor_start_authority_at,
        executor_start_io_permit_sha256: row.executor_start_io_permit_sha256,
        executor_start_io_permit_at: row.executor_start_io_permit_at,
        executor_start_failure_receipt_json: row.executor_start_failure_receipt_json,
        executor_start_failure_receipt_sha256: row.executor_start_failure_receipt_sha256,
        start_failure_receipt: None,
        start_receipt: None,
        executor_lifecycle_owner: None,
        executor_stop_pending: None,
        execution_record_sha256: row.execution_record_sha256,
        request_sha256: row.request_sha256,
        offer: decoded.offer,
        authenticated_principal: row.authenticated_principal,
        claim_receipt: decoded.claim_receipt,
        controller_operation: decoded.controller_operation,
        state: decoded.state,
        legacy_migrated: row.legacy_migrated,
        offered_at: row.offered_at,
        claimed_at: row.claimed_at,
        started_at: row.started_at,
        heartbeat_at: row.heartbeat_at,
        lease_id: row.lease_id,
        lease_expires_at: row.lease_expires_at,
        deadline_at: row.deadline_at,
        cancel_requested_at: row.cancel_requested_at,
        completed_at: row.completed_at,
        workspace_ref: row.workspace_ref,
        status_response,
        result_sha256: row.result_sha256,
        status_sha256: row.status_sha256,
        cleanup_settlement_request_sha256: row.cleanup_settlement_request_sha256,
        cleanup_completed_at: row.cleanup_completed_at,
        last_mutation_kind: row.last_mutation_kind,
        last_mutation_sha256: row.last_mutation_sha256,
        error: row.error,
        updated_at: row.updated_at,
    })
}

fn attach_evidence(
    record: TaskBoardRemoteAssignmentRecord,
    evidence: EvidenceBlobs,
) -> Result<TaskBoardRemoteAssignmentRecord, CliError> {
    super::super::remote_assignment_start_authority::validate_executor_start_authority(&record)?;
    let _ = super::super::remote_assignment_start_authority::executor_start_io_permit(&record)?;
    let start_receipt = super::super::remote_start_receipts::decode_start_receipt(
        &record,
        evidence.start_receipt_json,
        evidence.start_receipt_sha256,
    )?;
    let record = TaskBoardRemoteAssignmentRecord {
        start_receipt,
        ..record
    };
    let owner = super::super::remote_assignment_lifecycle_owner::decode_executor_lifecycle_owner(
        &record,
        evidence.owner_instance_id,
        evidence.owner_epoch,
        evidence.owner_acquired_at,
        evidence.owner_expires_at,
        evidence.owner_sha256,
    )?;
    let record = TaskBoardRemoteAssignmentRecord {
        executor_lifecycle_owner: owner,
        ..record
    };
    let executor_stop_pending =
        super::super::remote_assignment_executor_stop::decode_executor_stop_pending(
            &record,
            evidence.stop_pending_json,
            evidence.stop_pending_sha256,
        )?;
    apply_start_failure_receipt(TaskBoardRemoteAssignmentRecord {
        executor_stop_pending,
        ..record
    })
}

impl EvidenceBlobs {
    fn from_row(row: &RemoteAssignmentRow) -> Self {
        Self {
            start_receipt_json: row.executor_start_receipt_json.clone(),
            start_receipt_sha256: row.executor_start_receipt_sha256.clone(),
            owner_instance_id: row.executor_lifecycle_owner_instance_id.clone(),
            owner_epoch: row.executor_lifecycle_owner_epoch,
            owner_acquired_at: row.executor_lifecycle_owner_acquired_at.clone(),
            owner_expires_at: row.executor_lifecycle_owner_expires_at.clone(),
            owner_sha256: row.executor_lifecycle_owner_sha256.clone(),
            stop_pending_json: row.executor_stop_pending_json.clone(),
            stop_pending_sha256: row.executor_stop_pending_sha256.clone(),
        }
    }
}
