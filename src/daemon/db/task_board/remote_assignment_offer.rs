use chrono::{DateTime, Duration, Utc};
use sqlx::{Sqlite, Transaction, query_scalar};

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::remote_assignment_archival_fence::require_no_archival_collision_in_tx;
use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteOfferOutcome, canonical_time, concurrent,
    exact_offer_replay, insert_assignment_in_tx, load_assignment_in_tx, load_offer_collision_in_tx,
    nonblank, to_i64,
};
use super::remote_assignment_source::source_binding_matches_in_tx;
use super::remote_lifecycle_trust::{
    TaskBoardRemoteLifecycleTrustSnapshot, capture_lifecycle_trust_for_offer_in_tx,
};
use super::remote_outbound_sources::{
    persist_outbound_source_in_tx, require_outbound_source_in_tx,
};
use super::workflow_execution_attempts::{
    attempt_cas_matches, update_attempt_in_tx, validate_attempt_phase,
};
use super::workflow_execution_revisions::live_execution_revision_mismatch_in_tx;
use super::workflow_executions::{cas_mismatch, load_execution_in_tx, update_execution_in_tx};
use super::workflow_first_start_admission::{
    TaskBoardFirstStartAdmission, revalidate_first_start_admission_in_tx,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::service::task_board_read_only_coordinator::requests::remote_codex_attempt_request;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteCodexLaunchEnvelope, RemoteOfferRequest,
};
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE, TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE,
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TaskBoardAttemptState, TaskBoardExecutionAttemptCas,
    TaskBoardExecutionAttemptRecord, TaskBoardExecutionState, TaskBoardOrchestratorSettings,
    TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind,
    remote_capability_for_phase, validate_task_board_attempt_update,
    validate_task_board_execution_target_update, validate_task_board_workflow_execution,
};

#[path = "remote_assignment_offer/capacity.rs"]
mod capacity;
use capacity::host_has_capacity;

impl AsyncDaemonDb {
    pub(crate) async fn offer_task_board_remote_assignment(
        &self,
        expected_execution: &TaskBoardWorkflowExecutionCas,
        expected_attempt: &TaskBoardExecutionAttemptCas,
        request: &RemoteOfferRequest,
        authenticated_principal: &str,
        offered_at: &str,
        lease_expires_at: &str,
        deadline_at: &str,
    ) -> Result<TaskBoardRemoteOfferOutcome, CliError> {
        Box::pin(self.offer_task_board_remote_assignment_with_source(
            expected_execution,
            expected_attempt,
            request,
            None,
            authenticated_principal,
            offered_at,
            lease_expires_at,
            deadline_at,
        ))
        .await
    }

    pub(crate) async fn offer_task_board_remote_assignment_with_source(
        &self,
        expected_execution: &TaskBoardWorkflowExecutionCas,
        expected_attempt: &TaskBoardExecutionAttemptCas,
        request: &RemoteOfferRequest,
        source_content: Option<&[u8]>,
        authenticated_principal: &str,
        offered_at: &str,
        lease_expires_at: &str,
        deadline_at: &str,
    ) -> Result<TaskBoardRemoteOfferOutcome, CliError> {
        let times = validate_offer_input(
            request,
            authenticated_principal,
            offered_at,
            lease_expires_at,
            deadline_at,
        )?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote assignment offer")
            .await?;
        // An identity colliding with an archived legacy row is a deterministic
        // conflict; exact replay is only ever honoured with the archive empty.
        require_no_archival_collision_in_tx(
            &mut transaction,
            &request.binding.assignment_id,
            &request.binding.idempotency_key,
            Some(&request.request_sha256),
            &request.binding.execution_id,
            request.binding.fencing_epoch,
        )
        .await?;
        let collisions = load_offer_collision_in_tx(&mut transaction, request).await?;
        if !collisions.is_empty() {
            return resolve_offer_collision(
                transaction,
                collisions,
                request,
                authenticated_principal,
                source_content,
            )
            .await;
        }
        let prepared = match prepare_remote_offer_in_tx(
            &mut transaction,
            expected_execution,
            expected_attempt,
            request,
            offered_at,
            times,
        )
        .await?
        {
            OfferPreparation::Stale(reason) => {
                commit_noop(transaction, reason).await?;
                return Ok(TaskBoardRemoteOfferOutcome::Stale);
            }
            OfferPreparation::Unavailable(reason) => {
                commit_noop(transaction, reason).await?;
                return Ok(TaskBoardRemoteOfferOutcome::Unavailable);
            }
            OfferPreparation::Ready(prepared) => prepared,
        };
        let lifecycle_trust =
            capture_lifecycle_trust_for_offer_in_tx(&mut transaction, request).await?;
        let assignment = persist_remote_offer_in_tx(
            &mut transaction,
            expected_execution,
            expected_attempt,
            request,
            source_content,
            authenticated_principal,
            &prepared.parent,
            &prepared.attempt,
            prepared.attempt_index,
            offered_at,
            lease_expires_at,
            deadline_at,
            &lifecycle_trust,
        )
        .await?;
        commit_created_offer(transaction, assignment).await
    }
}

enum OfferPreparation {
    Stale(&'static str),
    Unavailable(&'static str),
    Ready(PreparedRemoteOffer),
}

struct PreparedRemoteOffer {
    parent: TaskBoardWorkflowExecutionRecord,
    attempt: TaskBoardExecutionAttemptRecord,
    attempt_index: usize,
}

async fn prepare_remote_offer_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected_execution: &TaskBoardWorkflowExecutionCas,
    expected_attempt: &TaskBoardExecutionAttemptCas,
    request: &RemoteOfferRequest,
    offered_at: &str,
    times: OfferTimes,
) -> Result<OfferPreparation, CliError> {
    let Some(parent) = load_execution_in_tx(transaction, &expected_execution.execution_id).await?
    else {
        return Ok(OfferPreparation::Stale("missing execution"));
    };
    let Some((attempt_index, current_attempt)) = find_attempt(&parent, expected_attempt) else {
        return Ok(OfferPreparation::Stale("missing attempt"));
    };
    if cas_mismatch(expected_execution, &parent).is_some()
        || !attempt_cas_matches(expected_attempt, current_attempt)
    {
        return Ok(OfferPreparation::Stale("stale execution or attempt"));
    }
    validate_binding(
        transaction,
        request,
        &parent,
        current_attempt,
        expected_execution,
    )
    .await?;
    ensure_live_execution(transaction, &parent).await?;
    if !host_has_capacity(transaction, request, times.offered_at).await? {
        return Ok(OfferPreparation::Unavailable("unavailable host"));
    }
    if revalidate_first_start_admission_in_tx(transaction, &parent, current_attempt, offered_at)
        .await?
        == TaskBoardFirstStartAdmission::Settled
    {
        return Ok(OfferPreparation::Unavailable("settled blocked admission"));
    }
    let attempt = current_attempt.clone();
    Ok(OfferPreparation::Ready(PreparedRemoteOffer {
        parent,
        attempt,
        attempt_index,
    }))
}

async fn persist_remote_offer_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected_execution: &TaskBoardWorkflowExecutionCas,
    expected_attempt: &TaskBoardExecutionAttemptCas,
    request: &RemoteOfferRequest,
    source_content: Option<&[u8]>,
    authenticated_principal: &str,
    parent: &TaskBoardWorkflowExecutionRecord,
    current_attempt: &TaskBoardExecutionAttemptRecord,
    attempt_index: usize,
    offered_at: &str,
    lease_expires_at: &str,
    deadline_at: &str,
    lifecycle_trust: &TaskBoardRemoteLifecycleTrustSnapshot,
) -> Result<TaskBoardRemoteAssignmentRecord, CliError> {
    let (updated_parent, updated_attempt, combined) =
        build_remote_claim(parent, current_attempt, attempt_index, request, offered_at)?;
    update_execution_in_tx(transaction, expected_execution, &updated_parent).await?;
    update_attempt_in_tx(transaction, expected_attempt, &updated_attempt).await?;
    insert_assignment_in_tx(
        transaction,
        request,
        authenticated_principal,
        offered_at,
        None,
        lease_expires_at,
        deadline_at,
        None,
        None,
        Some(lifecycle_trust),
    )
    .await?;
    persist_outbound_source_in_tx(transaction, request, source_content, offered_at).await?;
    bump_change_in_tx(transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    let assignment = load_assignment_in_tx(transaction, &request.binding.assignment_id)
        .await?
        .ok_or_else(|| db_error("inserted remote assignment disappeared"))?;
    debug_assert_eq!(combined.attempts[attempt_index], updated_attempt);
    Ok(assignment)
}

async fn commit_created_offer(
    transaction: Transaction<'_, Sqlite>,
    assignment: TaskBoardRemoteAssignmentRecord,
) -> Result<TaskBoardRemoteOfferOutcome, CliError> {
    transaction.commit().await.map_err(|error| {
        db_error(format!(
            "commit task board remote assignment offer: {error}"
        ))
    })?;
    Ok(TaskBoardRemoteOfferOutcome::Created(assignment))
}

struct OfferTimes {
    offered_at: DateTime<Utc>,
}

fn validate_offer_input(
    request: &RemoteOfferRequest,
    principal: &str,
    offered_at: &str,
    lease_expires_at: &str,
    deadline_at: &str,
) -> Result<OfferTimes, CliError> {
    request
        .validate()
        .map_err(|error| db_error(format!("validate remote assignment offer: {error}")))?;
    if deadline_at != request.deadline_at {
        return Err(db_error(
            "remote assignment deadline does not match the sealed offer",
        ));
    }
    nonblank(principal, "remote assignment authenticated principal")?;
    let offered_at = canonical_time(offered_at, "remote assignment offer time")?;
    let lease = canonical_time(lease_expires_at, "remote assignment lease expiry")?;
    let deadline = canonical_time(deadline_at, "remote assignment deadline")?;
    let expected_lease = offered_at + Duration::seconds(i64::from(request.lease_seconds));
    if lease != expected_lease || deadline < expected_lease {
        return Err(db_error(
            "remote assignment lease must exactly match the sealed duration and deadline",
        ));
    }
    Ok(OfferTimes { offered_at })
}

async fn resolve_offer_collision(
    mut transaction: Transaction<'_, Sqlite>,
    collisions: Vec<TaskBoardRemoteAssignmentRecord>,
    request: &RemoteOfferRequest,
    principal: &str,
    source_content: Option<&[u8]>,
) -> Result<TaskBoardRemoteOfferOutcome, CliError> {
    if collisions.len() == 1 && exact_offer_replay(&collisions[0], request, principal) {
        require_outbound_source_in_tx(&mut transaction, request, source_content).await?;
        let assignment = collisions.into_iter().next().expect("one collision");
        commit_noop(transaction, "replayed offer").await?;
        return Ok(TaskBoardRemoteOfferOutcome::Replayed(assignment));
    }
    commit_noop(transaction, "conflicting offer").await?;
    Err(concurrent(
        "remote assignment identity, attempt, idempotency key, or request digest conflicts",
    ))
}

fn find_attempt<'a>(
    parent: &'a TaskBoardWorkflowExecutionRecord,
    expected: &TaskBoardExecutionAttemptCas,
) -> Option<(usize, &'a TaskBoardExecutionAttemptRecord)> {
    parent.attempts.iter().enumerate().find(|(_, attempt)| {
        attempt.action_key == expected.action_key && attempt.attempt == expected.attempt
    })
}

async fn validate_binding(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteOfferRequest,
    parent: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    expected: &TaskBoardWorkflowExecutionCas,
) -> Result<(), CliError> {
    let binding = &request.binding;
    let expected_request = remote_codex_attempt_request(parent, attempt)?;
    let expected_launch = RemoteCodexLaunchEnvelope::from_codex_request("codex", &expected_request)
        .map_err(|error| db_error(format!("build frozen remote launch contract: {error}")))?;
    let expected_epoch = parent
        .ownership
        .fencing_epoch
        .checked_add(1)
        .ok_or_else(|| db_error("remote assignment fencing epoch overflow"))?;
    let exact = binding.execution_id == parent.execution_id
        && parent.transition.phase == Some(binding.phase)
        && binding.workflow_kind == parent.snapshot.workflow_kind
        && binding.action_key == attempt.action_key
        && binding.attempt == attempt.attempt
        && binding.idempotency_key == attempt.idempotency_key
        && binding.fencing_epoch == expected_epoch
        && binding.configuration_revision == parent.snapshot.configuration_revision
        && binding.configuration_revision == expected.revisions.configuration_revision
        && binding.execution_record_sha256 == expected.record_sha256
        && request.launch == expected_launch
        && binding.repository == request.source.repository()
        && source_binding_matches_in_tx(transaction, request, parent).await?
        && revision_binding_matches(
            parent,
            binding.base_revision.as_str(),
            binding.expected_head_revision.as_deref(),
        );
    if !exact {
        return Err(concurrent(
            "remote assignment offer does not match the frozen execution and exact attempt",
        ));
    }
    if attempt.state != TaskBoardAttemptState::Preparing
        || matches!(
            parent.transition.execution_state,
            TaskBoardExecutionState::Starting
                | TaskBoardExecutionState::Running
                | TaskBoardExecutionState::HumanRequired
                | TaskBoardExecutionState::Completed
                | TaskBoardExecutionState::Failed
                | TaskBoardExecutionState::Cancelled
        )
    {
        return Err(concurrent(
            "workflow attempt is no longer eligible for a remote offer",
        ));
    }
    remote_capability_for_phase(binding.phase)?;
    Ok(())
}

fn revision_binding_matches(
    parent: &TaskBoardWorkflowExecutionRecord,
    base: &str,
    expected_head: Option<&str>,
) -> bool {
    match parent.transition.phase {
        Some(crate::task_board::TaskBoardExecutionPhase::Implementation) => {
            expected_head.is_none() && implementation_base(parent) == Some(base)
        }
        Some(
            crate::task_board::TaskBoardExecutionPhase::Review
            | crate::task_board::TaskBoardExecutionPhase::Evaluate,
        ) => {
            parent.transition.exact_head_revision.as_deref() == Some(base)
                && expected_head == Some(base)
        }
        _ => false,
    }
}

fn implementation_base(parent: &TaskBoardWorkflowExecutionRecord) -> Option<&str> {
    let cycle = parent.artifacts.current_revision_cycle;
    if cycle > 1 {
        return parent
            .artifacts
            .review_cycles
            .iter()
            .find(|review| review.revision_cycle == cycle - 1)
            .map(|review| review.head_revision.as_str());
    }
    if parent.snapshot.workflow_kind == TaskBoardWorkflowKind::PrFix {
        return parent
            .transition
            .pull_request
            .as_ref()?
            .head
            .as_ref()
            .map(|head| head.revision.as_str());
    }
    parent.transition.exact_head_revision.as_deref()
}

fn build_remote_claim(
    parent: &TaskBoardWorkflowExecutionRecord,
    current_attempt: &TaskBoardExecutionAttemptRecord,
    attempt_index: usize,
    request: &RemoteOfferRequest,
    now: &str,
) -> Result<
    (
        TaskBoardWorkflowExecutionRecord,
        TaskBoardExecutionAttemptRecord,
        TaskBoardWorkflowExecutionRecord,
    ),
    CliError,
> {
    let mut updated_attempt = current_attempt.clone();
    updated_attempt.state = TaskBoardAttemptState::Starting;
    updated_attempt.failure_class = None;
    updated_attempt.available_at = None;
    updated_attempt.error = None;
    updated_attempt.artifact = None;
    updated_attempt.updated_at = now.to_owned();
    updated_attempt.completed_at = None;
    validate_task_board_attempt_update(current_attempt, &updated_attempt)
        .map_err(|error| db_error(format!("validate remote offer attempt: {error}")))?;
    validate_attempt_phase(parent, &updated_attempt)?;
    let mut updated_parent = parent.clone();
    updated_parent.transition.execution_state = TaskBoardExecutionState::Starting;
    updated_parent.ownership.host_id = Some(request.binding.host_id.clone());
    updated_parent.ownership.fencing_epoch = request.binding.fencing_epoch;
    updated_parent.ownership.resources.insert(
        TASK_BOARD_EXECUTION_TARGET_RESOURCE.into(),
        format!("remote:{}", request.binding.assignment_id),
    );
    updated_parent.ownership.resources.insert(
        TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE.into(),
        request.binding.action_key.clone(),
    );
    updated_parent.ownership.resources.insert(
        TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE.into(),
        request.binding.attempt.to_string(),
    );
    updated_parent.available_at = None;
    updated_parent.blocked_reason = None;
    updated_parent.updated_at = now.to_owned();
    let mut combined = updated_parent.clone();
    combined.attempts[attempt_index] = updated_attempt.clone();
    validate_task_board_execution_target_update(parent, &combined)
        .map_err(|error| db_error(format!("validate remote offer parent: {error}")))?;
    validate_task_board_workflow_execution(&combined)
        .map_err(|error| db_error(format!("validate remote offer execution: {error}")))?;
    Ok((updated_parent, updated_attempt, combined))
}

async fn ensure_live_execution(
    transaction: &mut Transaction<'_, Sqlite>,
    parent: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), CliError> {
    if matches!(
        parent.snapshot.workflow_kind,
        TaskBoardWorkflowKind::DefaultTask | TaskBoardWorkflowKind::PrFix
    ) {
        let settings_json = query_scalar::<_, String>(
            "SELECT settings_json FROM task_board_orchestrator_settings WHERE singleton = 1",
        )
        .fetch_one(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load remote offer policy version: {error}")))?;
        let settings = serde_json::from_str::<TaskBoardOrchestratorSettings>(&settings_json)
            .map_err(|error| db_error(format!("decode remote offer policy version: {error}")))?;
        if settings.policy_version != parent.snapshot.policy_version {
            return Err(concurrent(
                "workflow policy version changed before remote assignment offer",
            ));
        }
    }
    if live_execution_revision_mismatch_in_tx(transaction, parent)
        .await?
        .is_some()
    {
        return Err(concurrent(
            "workflow revision changed before remote assignment offer",
        ));
    }
    Ok(())
}

async fn commit_noop(transaction: Transaction<'_, Sqlite>, reason: &str) -> Result<(), CliError> {
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit {reason} remote assignment offer: {error}")))
}
