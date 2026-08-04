use sqlx::{Sqlite, Transaction};

#[path = "remote_source_bundle_reassignment_replay.rs"]
mod replay;
#[path = "remote_source_bundle_reassignment_storage.rs"]
mod storage;
#[path = "remote_source_bundle_reassignment_validation.rs"]
mod validation;

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::remote_assignment_active_fence::record_controller_reassignment_handoff_in_tx;
use super::remote_assignment_archival_fence::require_no_archival_collision_in_tx;
use super::remote_assignment_authority_settlement::clear_offer_io_authority_in_tx;
use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteOfferOutcome, concurrent,
    insert_assignment_in_tx, load_assignment_in_tx,
};
use super::remote_lifecycle_trust::{
    TaskBoardRemoteLifecycleTrustSnapshot, capture_lifecycle_trust_for_offer_in_tx,
};
use super::remote_operation_trust::{
    TaskBoardRemoteOperationTrustFence, require_source_recovery_operation_fence_in_tx,
};
use super::remote_outbound_sources::{
    exact_outbound_source_content_in_tx, persist_outbound_source_in_tx,
};
use super::remote_source_bundle_reassignment_evidence::{
    SourceReassignmentEvidence, require_reassignment_evidence_in_tx,
};
use super::workflow_execution_fencing::WorkflowExecutionFencing;
use super::workflow_executions::{load_execution_in_tx, update_execution_in_tx};
use crate::daemon::db::prelude::*;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::remote_wire::wire::{
    RemoteOfferRequest, RemoteSourceBundleAbandonRequest, RemoteSourceBundleAbandonResponse,
};
use crate::task_board::{
    TASK_BOARD_REMOTE_OFFER_IO_AUTHORITY_RESOURCE, TaskBoardAttemptState,
    TaskBoardExecutionAttemptCas, TaskBoardExecutionState, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionRecord, validate_task_board_remote_target_reassignment,
};
use replay::replayed_replacement_in_tx;
use storage::{require_no_replacement_collision_in_tx, supersede_predecessor_in_tx};
use validation::{
    replacement_parent, require_preclaim_predecessor, validate_reassignment_input,
    validate_replacement,
};

pub(crate) struct TaskBoardRemoteSourceOfferReassignment<'a> {
    pub(crate) expected_execution: &'a TaskBoardWorkflowExecutionCas,
    pub(crate) expected_attempt: &'a TaskBoardExecutionAttemptCas,
    pub(crate) replacement: &'a RemoteOfferRequest,
    pub(crate) authenticated_principal: &'a str,
    pub(crate) trust: &'a TaskBoardRemoteOperationTrustFence,
    pub(crate) offered_at: &'a str,
    pub(crate) lease_expires_at: &'a str,
}

pub(super) async fn reassign_abandoned_task_board_remote_source_bundle_offer(
    db: &AsyncDaemonDb,
    reassignment: &TaskBoardRemoteSourceOfferReassignment<'_>,
    abandonment_request: &RemoteSourceBundleAbandonRequest,
    abandonment_response: &RemoteSourceBundleAbandonResponse,
) -> Result<TaskBoardRemoteOfferOutcome, CliError> {
    Box::pin(reassign_task_board_remote_source_bundle_offer(
        db,
        reassignment,
        SourceReassignmentEvidence::Abandonment {
            request: abandonment_request,
            response: abandonment_response,
        },
    ))
    .await
}

pub(super) async fn reassign_task_board_remote_source_bundle_offer(
    db: &AsyncDaemonDb,
    reassignment: &TaskBoardRemoteSourceOfferReassignment<'_>,
    evidence: SourceReassignmentEvidence<'_>,
) -> Result<TaskBoardRemoteOfferOutcome, CliError> {
    validate_reassignment_input(
        evidence,
        reassignment.replacement,
        reassignment.authenticated_principal,
        reassignment.trust,
        reassignment.offered_at,
        reassignment.lease_expires_at,
    )?;
    let mut transaction = db
        .begin_immediate_transaction("task board remote source offer reassignment")
        .await?;
    require_reassignment_preconditions_in_tx(&mut transaction, reassignment).await?;
    if let Some(replayed) = Box::pin(replayed_replacement_in_tx(
        &mut transaction,
        evidence,
        reassignment.replacement,
        reassignment.authenticated_principal,
        reassignment.trust,
    ))
    .await?
    {
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit replayed source offer reassignment: {error}"
            ))
        })?;
        return Ok(TaskBoardRemoteOfferOutcome::Replayed(replayed));
    }
    let created = Box::pin(create_reassigned_successor_in_tx(
        &mut transaction,
        reassignment,
        evidence,
    ))
    .await?;
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit remote source offer reassignment: {error}")))?;
    Ok(TaskBoardRemoteOfferOutcome::Created(created))
}

async fn require_reassignment_preconditions_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    reassignment: &TaskBoardRemoteSourceOfferReassignment<'_>,
) -> Result<(), CliError> {
    require_source_recovery_operation_fence_in_tx(transaction, reassignment.trust).await?;
    // The successor identity must not collide with an archived legacy row
    // before the idempotent replay or a fresh successor is created.
    require_no_archival_collision_in_tx(
        transaction,
        &reassignment.replacement.binding.assignment_id,
        &reassignment.replacement.binding.idempotency_key,
        Some(&reassignment.replacement.request_sha256),
        &reassignment.replacement.binding.execution_id,
        reassignment.replacement.binding.fencing_epoch,
    )
    .await
}

struct ReassignmentParties {
    parent: TaskBoardWorkflowExecutionRecord,
    predecessor: TaskBoardRemoteAssignmentRecord,
    source_content: Vec<u8>,
}

async fn create_reassigned_successor_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    reassignment: &TaskBoardRemoteSourceOfferReassignment<'_>,
    evidence: SourceReassignmentEvidence<'_>,
) -> Result<TaskBoardRemoteAssignmentRecord, CliError> {
    let parties = resolve_reassignment_parties_in_tx(transaction, reassignment, evidence).await?;
    validate_replacement(
        &parties.parent,
        &parties.predecessor,
        reassignment.expected_execution,
        reassignment.replacement,
        reassignment.trust,
    )?;
    require_no_replacement_collision_in_tx(
        transaction,
        &parties.predecessor,
        reassignment.replacement,
    )
    .await?;
    let lifecycle_trust =
        capture_lifecycle_trust_for_offer_in_tx(transaction, reassignment.replacement).await?;
    let persistence = PersistReassignedOfferInput {
        predecessor: &parties.predecessor,
        parent: &parties.parent,
        replacement: reassignment.replacement,
        authenticated_principal: reassignment.authenticated_principal,
        source_content: &parties.source_content,
        offered_at: reassignment.offered_at,
        lease_expires_at: reassignment.lease_expires_at,
        lifecycle_trust: &lifecycle_trust,
    };
    persist_reassigned_offer_in_tx(transaction, &persistence).await
}

async fn resolve_reassignment_parties_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    reassignment: &TaskBoardRemoteSourceOfferReassignment<'_>,
    evidence: SourceReassignmentEvidence<'_>,
) -> Result<ReassignmentParties, CliError> {
    let parent = exact_parent_in_tx(
        transaction,
        reassignment.expected_execution,
        reassignment.expected_attempt,
    )
    .await?;
    let predecessor = exact_predecessor_in_tx(
        transaction,
        evidence,
        reassignment.authenticated_principal,
        reassignment.trust,
    )
    .await?;
    let parent = settle_predecessor_offer_authority_in_tx(
        transaction,
        &predecessor,
        &parent,
        reassignment.offered_at,
    )
    .await?;
    let source_content =
        exact_outbound_source_content_in_tx(transaction, predecessor.require_offer()?).await?;
    Ok(ReassignmentParties {
        parent,
        predecessor,
        source_content,
    })
}

struct PersistReassignedOfferInput<'a> {
    predecessor: &'a TaskBoardRemoteAssignmentRecord,
    parent: &'a TaskBoardWorkflowExecutionRecord,
    replacement: &'a RemoteOfferRequest,
    authenticated_principal: &'a str,
    source_content: &'a [u8],
    offered_at: &'a str,
    lease_expires_at: &'a str,
    lifecycle_trust: &'a TaskBoardRemoteLifecycleTrustSnapshot,
}

async fn persist_reassigned_offer_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    input: &PersistReassignedOfferInput<'_>,
) -> Result<TaskBoardRemoteAssignmentRecord, CliError> {
    let updated = retarget_parent_execution_in_tx(transaction, input).await?;
    let created = insert_successor_offer_in_tx(transaction, input).await?;
    record_controller_reassignment_handoff_in_tx(
        transaction,
        input.predecessor,
        &created,
        &updated,
        input.offered_at,
    )
    .await?;
    bump_change_in_tx(transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    Ok(created)
}

async fn retarget_parent_execution_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    input: &PersistReassignedOfferInput<'_>,
) -> Result<TaskBoardWorkflowExecutionRecord, CliError> {
    let updated = replacement_parent(input.parent, input.replacement, input.offered_at)?;
    validate_task_board_remote_target_reassignment(input.parent, &updated)
        .map_err(|error| db_error(format!("validate remote source reassignment: {error}")))?;
    supersede_predecessor_in_tx(transaction, input.predecessor, input.offered_at).await?;
    update_execution_in_tx(
        transaction,
        &TaskBoardWorkflowExecutionCas::from(input.parent),
        &updated,
    )
    .await?;
    Ok(updated)
}

async fn insert_successor_offer_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    input: &PersistReassignedOfferInput<'_>,
) -> Result<TaskBoardRemoteAssignmentRecord, CliError> {
    let assignment = super::remote_assignment_model::RemoteAssignmentInsertInput {
        request: input.replacement,
        principal: input.authenticated_principal,
        offered_at: input.offered_at,
        lease_id: None,
        lease_expires_at: input.lease_expires_at,
        deadline_at: &input.replacement.deadline_at,
        executor_configuration_revision: None,
        executor_checkout_path: None,
        lifecycle_trust: Some(input.lifecycle_trust),
    };
    insert_assignment_in_tx(transaction, &assignment).await?;
    persist_outbound_source_in_tx(
        transaction,
        input.replacement,
        Some(input.source_content),
        input.offered_at,
    )
    .await?;
    load_assignment_in_tx(transaction, &input.replacement.binding.assignment_id)
        .await?
        .ok_or_else(|| db_error("replacement remote source offer disappeared"))
}

async fn exact_parent_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected_execution: &TaskBoardWorkflowExecutionCas,
    expected_attempt: &TaskBoardExecutionAttemptCas,
) -> Result<TaskBoardWorkflowExecutionRecord, CliError> {
    let parent = load_execution_in_tx(transaction, &expected_execution.execution_id)
        .await?
        .ok_or_else(|| concurrent("source reassignment execution disappeared"))?;
    let attempt = parent
        .attempts
        .iter()
        .find(|attempt| {
            attempt.action_key == expected_attempt.action_key
                && attempt.attempt == expected_attempt.attempt
        })
        .ok_or_else(|| concurrent("source reassignment attempt disappeared"))?;
    if AsyncDaemonDb::cas_mismatch(expected_execution, &parent).is_some()
        || !AsyncDaemonDb::attempt_cas_matches(expected_attempt, attempt)
        || parent.transition.execution_state != TaskBoardExecutionState::Starting
        || attempt.state != TaskBoardAttemptState::Starting
    {
        return Err(concurrent(
            "source reassignment lost its exact Starting execution and attempt",
        ));
    }
    Ok(parent)
}

async fn exact_predecessor_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    evidence: SourceReassignmentEvidence<'_>,
    principal: &str,
    trust: &TaskBoardRemoteOperationTrustFence,
) -> Result<TaskBoardRemoteAssignmentRecord, CliError> {
    let offer = evidence.offer();
    let predecessor = load_assignment_in_tx(transaction, &offer.binding.assignment_id)
        .await?
        .ok_or_else(|| concurrent("source reassignment predecessor disappeared"))?;
    require_preclaim_predecessor(&predecessor, offer, principal)?;
    require_reassignment_evidence_in_tx(transaction, &predecessor, evidence, principal, trust)
        .await?;
    Ok(predecessor)
}

/// Release the rejected predecessor's offer I/O authority before reassigning.
///
/// The local-fallback rejection path settles this authority, so the source-recovery
/// reassignment must do the same and hand the target validator an authority-free
/// parent. Abandonment evidence never carries a pending offer authority, so this
/// returns the parent unchanged there.
async fn settle_predecessor_offer_authority_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    predecessor: &TaskBoardRemoteAssignmentRecord,
    parent: &TaskBoardWorkflowExecutionRecord,
    observed_at: &str,
) -> Result<TaskBoardWorkflowExecutionRecord, CliError> {
    if !parent
        .ownership
        .resources
        .contains_key(TASK_BOARD_REMOTE_OFFER_IO_AUTHORITY_RESOURCE)
    {
        return Ok(parent.clone());
    }
    clear_offer_io_authority_in_tx(transaction, predecessor, observed_at).await?;
    load_execution_in_tx(transaction, &predecessor.execution_id)
        .await?
        .ok_or_else(|| {
            concurrent("source reassignment execution disappeared after offer settlement")
        })
}
