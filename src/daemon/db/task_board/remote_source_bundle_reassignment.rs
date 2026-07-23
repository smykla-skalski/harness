use chrono::Duration;
use sqlx::{Sqlite, Transaction};

#[path = "remote_source_bundle_reassignment_replay.rs"]
mod replay;
#[path = "remote_source_bundle_reassignment_storage.rs"]
mod storage;

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::remote_assignment_active_fence::record_controller_reassignment_handoff_in_tx;
use super::remote_assignment_archival_fence::require_no_archival_collision_in_tx;
use super::remote_assignment_authority_settlement::clear_offer_io_authority_in_tx;
use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteOfferOutcome, canonical_time, concurrent,
    insert_assignment_in_tx, load_assignment_in_tx, nonblank,
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
use super::workflow_execution_attempts::attempt_cas_matches;
use super::workflow_executions::{cas_mismatch, load_execution_in_tx, update_execution_in_tx};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteOfferRequest, RemoteSourceBundleAbandonRequest, RemoteSourceBundleAbandonResponse,
};
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE, TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE,
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TASK_BOARD_REMOTE_OFFER_IO_AUTHORITY_RESOURCE,
    TaskBoardAttemptState, TaskBoardExecutionAttemptCas, TaskBoardExecutionState,
    TaskBoardRemoteAssignmentState, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionRecord, validate_task_board_remote_target_reassignment,
};
use replay::replayed_replacement_in_tx;
use storage::{require_no_replacement_collision_in_tx, supersede_predecessor_in_tx};

pub(crate) struct TaskBoardRemoteSourceOfferReassignment<'a> {
    pub(crate) expected_execution: &'a TaskBoardWorkflowExecutionCas,
    pub(crate) expected_attempt: &'a TaskBoardExecutionAttemptCas,
    pub(crate) replacement: &'a RemoteOfferRequest,
    pub(crate) authenticated_principal: &'a str,
    pub(crate) trust: &'a TaskBoardRemoteOperationTrustFence,
    pub(crate) offered_at: &'a str,
    pub(crate) lease_expires_at: &'a str,
}

impl AsyncDaemonDb {
    pub(crate) async fn reassign_abandoned_task_board_remote_source_bundle_offer(
        &self,
        reassignment: &TaskBoardRemoteSourceOfferReassignment<'_>,
        abandonment_request: &RemoteSourceBundleAbandonRequest,
        abandonment_response: &RemoteSourceBundleAbandonResponse,
    ) -> Result<TaskBoardRemoteOfferOutcome, CliError> {
        Box::pin(self.reassign_task_board_remote_source_bundle_offer(
            reassignment,
            SourceReassignmentEvidence::Abandonment {
                request: abandonment_request,
                response: abandonment_response,
            },
        ))
        .await
    }

    pub(super) async fn reassign_task_board_remote_source_bundle_offer(
        &self,
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
        let mut transaction = self
            .begin_immediate_transaction("task board remote source offer reassignment")
            .await?;
        require_source_recovery_operation_fence_in_tx(&mut transaction, reassignment.trust).await?;
        // The successor identity must not collide with an archived legacy row
        // before the idempotent replay or a fresh successor is created.
        require_no_archival_collision_in_tx(
            &mut transaction,
            &reassignment.replacement.binding.assignment_id,
            &reassignment.replacement.binding.idempotency_key,
            Some(&reassignment.replacement.request_sha256),
            &reassignment.replacement.binding.execution_id,
            reassignment.replacement.binding.fencing_epoch,
        )
        .await?;
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
        let parent = exact_parent_in_tx(
            &mut transaction,
            reassignment.expected_execution,
            reassignment.expected_attempt,
        )
        .await?;
        let predecessor = exact_predecessor_in_tx(
            &mut transaction,
            evidence,
            reassignment.authenticated_principal,
            reassignment.trust,
        )
        .await?;
        let parent = settle_predecessor_offer_authority_in_tx(
            &mut transaction,
            &predecessor,
            &parent,
            reassignment.offered_at,
        )
        .await?;
        let source_content =
            exact_outbound_source_content_in_tx(&mut transaction, predecessor.require_offer()?)
                .await?;
        validate_replacement(
            &parent,
            &predecessor,
            reassignment.expected_execution,
            reassignment.replacement,
            reassignment.trust,
        )?;
        require_no_replacement_collision_in_tx(
            &mut transaction,
            &predecessor,
            reassignment.replacement,
        )
        .await?;
        let lifecycle_trust =
            capture_lifecycle_trust_for_offer_in_tx(&mut transaction, reassignment.replacement)
                .await?;
        let persistence = PersistReassignedOfferInput {
            predecessor: &predecessor,
            parent: &parent,
            replacement: reassignment.replacement,
            authenticated_principal: reassignment.authenticated_principal,
            source_content: &source_content,
            offered_at: reassignment.offered_at,
            lease_expires_at: reassignment.lease_expires_at,
            lifecycle_trust: &lifecycle_trust,
        };
        let created = persist_reassigned_offer_in_tx(&mut transaction, &persistence).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit remote source offer reassignment: {error}"))
        })?;
        Ok(TaskBoardRemoteOfferOutcome::Created(created))
    }
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
    let created = load_assignment_in_tx(transaction, &input.replacement.binding.assignment_id)
        .await?
        .ok_or_else(|| db_error("replacement remote source offer disappeared"))?;
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
    if cas_mismatch(expected_execution, &parent).is_some()
        || !attempt_cas_matches(expected_attempt, attempt)
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

fn require_preclaim_predecessor(
    record: &TaskBoardRemoteAssignmentRecord,
    offer: &RemoteOfferRequest,
    principal: &str,
) -> Result<(), CliError> {
    let exact = record.state == TaskBoardRemoteAssignmentState::Offered
        && record.offer.as_ref() == Some(offer)
        && record.authenticated_principal.as_deref() == Some(principal)
        && record.claim_receipt.is_none()
        && record.lease_id.is_none()
        && record.claimed_at.is_none()
        && record.started_at.is_none()
        && record.workspace_ref.is_none()
        && record.start_receipt.is_none()
        && record.executor_start_authority_sha256.is_none()
        && record.executor_lifecycle_owner.is_none()
        && record.executor_stop_pending.is_none()
        && record.status_response.is_none()
        && record.result_sha256.is_none()
        && record.cleanup_completed_at.is_none();
    if exact {
        Ok(())
    } else {
        Err(concurrent(
            "source reassignment predecessor has accepted or running evidence",
        ))
    }
}

fn validate_replacement(
    parent: &TaskBoardWorkflowExecutionRecord,
    predecessor: &TaskBoardRemoteAssignmentRecord,
    expected_execution: &TaskBoardWorkflowExecutionCas,
    replacement: &RemoteOfferRequest,
    trust: &TaskBoardRemoteOperationTrustFence,
) -> Result<(), CliError> {
    let old = predecessor.require_offer()?;
    let mut expected_binding = old.binding.clone();
    expected_binding
        .assignment_id
        .clone_from(&replacement.binding.assignment_id);
    expected_binding
        .host_instance_id
        .clone_from(&trust.observed_host_instance_id);
    expected_binding.fencing_epoch = old
        .binding
        .fencing_epoch
        .checked_add(1)
        .ok_or_else(|| db_error("remote source reassignment epoch overflow"))?;
    expected_binding
        .execution_record_sha256
        .clone_from(&expected_execution.record_sha256);
    let exact = replacement.binding == expected_binding
        && replacement.binding.assignment_id != old.binding.assignment_id
        && replacement.lease_seconds == old.lease_seconds
        && replacement.deadline_at == old.deadline_at
        && replacement.launch == old.launch
        && replacement.source == old.source
        && replacement.artifacts == old.artifacts
        && predecessor.host_id == trust.host.config.host_id
        && parent.ownership.fencing_epoch == predecessor.fencing_epoch
        && active_target_matches(parent, predecessor);
    if exact {
        Ok(())
    } else {
        Err(concurrent(
            "replacement offer changed the frozen source, launch, attempt, or host contract",
        ))
    }
}

fn active_target_matches(
    parent: &TaskBoardWorkflowExecutionRecord,
    predecessor: &TaskBoardRemoteAssignmentRecord,
) -> bool {
    let attempt = predecessor.attempt.map(|value| value.to_string());
    parent.ownership.host_id.as_deref() == Some(predecessor.host_id.as_str())
        && parent
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            .is_some_and(|target| target == &format!("remote:{}", predecessor.assignment_id))
        && parent
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE)
            == predecessor.action_key.as_ref()
        && parent
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE)
            .map(String::as_str)
            == attempt.as_deref()
}

fn replacement_parent(
    parent: &TaskBoardWorkflowExecutionRecord,
    replacement: &RemoteOfferRequest,
    offered_at: &str,
) -> Result<TaskBoardWorkflowExecutionRecord, CliError> {
    if canonical_time(offered_at, "source reassignment offer time")?
        < canonical_time(&parent.updated_at, "source reassignment parent time")?
    {
        return Err(concurrent("source reassignment time precedes parent state"));
    }
    let mut updated = parent.clone();
    updated.ownership.fencing_epoch = replacement.binding.fencing_epoch;
    updated.ownership.resources.insert(
        TASK_BOARD_EXECUTION_TARGET_RESOURCE.into(),
        format!("remote:{}", replacement.binding.assignment_id),
    );
    updated.updated_at = offered_at.into();
    Ok(updated)
}

fn validate_reassignment_input(
    evidence: SourceReassignmentEvidence<'_>,
    replacement: &RemoteOfferRequest,
    principal: &str,
    trust: &TaskBoardRemoteOperationTrustFence,
    offered_at: &str,
    lease_expires_at: &str,
) -> Result<(), CliError> {
    evidence.validate()?;
    replacement
        .validate()
        .map_err(|error| db_error(format!("validate replacement source offer: {error}")))?;
    nonblank(principal, "replacement source offer principal")?;
    let offered = canonical_time(offered_at, "replacement source offer time")?;
    let lease = canonical_time(lease_expires_at, "replacement source lease expiry")?;
    let deadline = canonical_time(&replacement.deadline_at, "replacement source deadline")?;
    let expected_lease = offered + Duration::seconds(i64::from(replacement.lease_seconds));
    let exact = lease == expected_lease
        && lease <= deadline
        && principal == replacement.binding.host_id
        && replacement.binding.host_id == trust.host.config.host_id
        && replacement.binding.host_instance_id == trust.observed_host_instance_id;
    if exact {
        Ok(())
    } else {
        Err(concurrent(
            "replacement source offer time, lease, principal, or trust mismatched",
        ))
    }
}
