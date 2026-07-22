use sha2::{Digest, Sha256};
use sqlx::{Sqlite, Transaction, query};

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::remote_assignment_active_fence::{
    TaskBoardRemoteControllerHandoffKind, controller_handoff_matches_in_tx,
    record_controller_handoff_in_tx,
};
use super::remote_assignment_authority_settlement::clear_offer_io_authority_in_tx;
use super::remote_assignment_lease::commit_noop;
use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome, canonical_time, concurrent,
    to_i64,
};
use super::remote_offer_receipts::ensure_rejected_offer_receipt_in_tx;
use super::workflow_execution_attempts::{
    insert_attempt_in_tx, update_attempt_in_tx, validate_attempt_phase,
};
use super::workflow_executions::{load_execution_in_tx, update_execution_in_tx};
use crate::daemon::db::{CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::RemoteOfferResponse;
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE, TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE,
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TaskBoardAttemptState, TaskBoardExecutionAttemptCas,
    TaskBoardExecutionAttemptRecord, TaskBoardExecutionState, TaskBoardFailureClass,
    TaskBoardRemoteAssignmentState, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionRecord, validate_task_board_attempt_update,
    validate_task_board_execution_attempt, validate_task_board_execution_target_update,
    validate_task_board_workflow_execution,
};

pub(super) async fn apply_rejected_offer(
    mut transaction: Transaction<'_, Sqlite>,
    record: TaskBoardRemoteAssignmentRecord,
    response: &RemoteOfferResponse,
    observed_at: &str,
) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
    let reason = response
        .rejection_code
        .as_deref()
        .ok_or_else(|| db_error("rejected remote offer response has no reason"))?;
    if record.state == TaskBoardRemoteAssignmentState::Superseded
        && record.claimed_at.is_none()
        && record.error.as_deref() == Some(local_fallback_error(reason).as_str())
    {
        let parent = load_execution_in_tx(&mut transaction, &record.execution_id).await?;
        let replayed = if let Some(parent) = parent.as_ref() {
            controller_handoff_matches_in_tx(
                &mut transaction,
                &record,
                TaskBoardRemoteControllerHandoffKind::LocalFallback,
                parent,
            )
            .await?
        } else {
            false
        };
        commit_noop(transaction, "replayed rejected offer").await?;
        return Ok(if replayed {
            TaskBoardRemoteMutationOutcome::Replayed(record)
        } else {
            TaskBoardRemoteMutationOutcome::Stale(record)
        });
    }
    if record.state != TaskBoardRemoteAssignmentState::Offered || record.claimed_at.is_some() {
        commit_noop(transaction, "stale rejected offer").await?;
        return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
    }
    ensure_rejected_offer_receipt_in_tx(
        &mut transaction,
        record.require_offer()?,
        record
            .authenticated_principal
            .as_deref()
            .ok_or_else(|| db_error("remote assignment principal is missing"))?,
        reason,
        observed_at,
    )
    .await?;
    clear_offer_io_authority_in_tx(&mut transaction, &record, observed_at).await?;
    apply_unclaimable_offer(transaction, record, reason, observed_at).await
}

pub(super) async fn apply_unclaimable_offer(
    mut transaction: Transaction<'_, Sqlite>,
    record: TaskBoardRemoteAssignmentRecord,
    reason: &str,
    observed_at: &str,
) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
    let Some(updated) =
        apply_unclaimable_offer_in_tx(&mut transaction, &record, reason, observed_at).await?
    else {
        commit_noop(transaction, "stale unclaimable remote offer").await?;
        return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
    };
    bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    transaction.commit().await.map_err(|error| {
        db_error(format!(
            "commit rejected remote assignment fallback: {error}"
        ))
    })?;
    Ok(TaskBoardRemoteMutationOutcome::Updated(updated))
}

pub(super) async fn apply_unclaimable_offer_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    reason: &str,
    observed_at: &str,
) -> Result<Option<TaskBoardRemoteAssignmentRecord>, CliError> {
    let Some(parent) = load_execution_in_tx(transaction, &record.execution_id).await? else {
        return Ok(None);
    };
    let offer = record.require_offer()?;
    let Some((attempt_index, current_attempt)) = parent
        .attempts
        .iter()
        .enumerate()
        .find(|(_, attempt)| {
            attempt.action_key == offer.binding.action_key
                && attempt.attempt == offer.binding.attempt
        })
        .map(|(index, attempt)| (index, attempt.clone()))
    else {
        return Ok(None);
    };
    if !active_remote_target_matches(&parent, record)
        || current_attempt.state != TaskBoardAttemptState::Starting
    {
        return Ok(None);
    }
    let (updated_parent, failed_attempt, fallback_attempt, combined) = build_fallback(
        &parent,
        &current_attempt,
        attempt_index,
        reason,
        observed_at,
    )?;
    let expected_parent = TaskBoardWorkflowExecutionCas::from(&parent);
    let expected_attempt = TaskBoardExecutionAttemptCas::from(&current_attempt);
    update_execution_in_tx(transaction, &expected_parent, &updated_parent).await?;
    update_attempt_in_tx(transaction, &expected_attempt, &failed_attempt).await?;
    insert_attempt_in_tx(transaction, &fallback_attempt).await?;
    terminalize_rejected_assignment(transaction, record, reason, observed_at).await?;
    record_controller_handoff_in_tx(
        transaction,
        record,
        TaskBoardRemoteAssignmentState::Superseded,
        TaskBoardRemoteControllerHandoffKind::LocalFallback,
        &combined,
        observed_at,
    )
    .await?;
    debug_assert_eq!(combined.attempts[attempt_index], failed_attempt);
    let updated_at = monotonic_time(&record.updated_at, observed_at)?;
    Ok(Some(TaskBoardRemoteAssignmentRecord {
        state: TaskBoardRemoteAssignmentState::Superseded,
        completed_at: Some(updated_at.clone()),
        heartbeat_at: Some(updated_at.clone()),
        error: Some(local_fallback_error(reason)),
        updated_at,
        ..record.clone()
    }))
}

fn active_remote_target_matches(
    parent: &TaskBoardWorkflowExecutionRecord,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> bool {
    let offer = assignment.offer.as_ref().expect("strict assignment offer");
    parent.ownership.host_id.as_deref() == Some(assignment.host_id.as_str())
        && parent.ownership.fencing_epoch == assignment.fencing_epoch
        && parent
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            .is_some_and(|target| target == &format!("remote:{}", assignment.assignment_id))
        && parent
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE)
            == Some(&offer.binding.action_key)
        && parent
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE)
            .is_some_and(|attempt| attempt == &offer.binding.attempt.to_string())
}

fn build_fallback(
    parent: &TaskBoardWorkflowExecutionRecord,
    current_attempt: &TaskBoardExecutionAttemptRecord,
    attempt_index: usize,
    reason: &str,
    now: &str,
) -> Result<
    (
        TaskBoardWorkflowExecutionRecord,
        TaskBoardExecutionAttemptRecord,
        TaskBoardExecutionAttemptRecord,
        TaskBoardWorkflowExecutionRecord,
    ),
    CliError,
> {
    let mut failed = current_attempt.clone();
    failed.state = TaskBoardAttemptState::Failed;
    failed.failure_class = Some(TaskBoardFailureClass::Transient);
    failed.error = Some(local_fallback_error(reason));
    failed.updated_at = now.into();
    failed.completed_at = Some(now.into());
    validate_task_board_attempt_update(current_attempt, &failed)
        .map_err(|error| db_error(format!("validate rejected remote attempt: {error}")))?;
    let next_attempt = parent
        .attempts
        .iter()
        .filter(|attempt| attempt.action_key == current_attempt.action_key)
        .map(|attempt| attempt.attempt)
        .max()
        .unwrap_or(0)
        .checked_add(1)
        .ok_or_else(|| db_error("remote fallback attempt number overflow"))?;
    let fallback = TaskBoardExecutionAttemptRecord {
        execution_id: parent.execution_id.clone(),
        action_key: current_attempt.action_key.clone(),
        attempt: next_attempt,
        idempotency_key: deterministic_attempt_id(
            &parent.execution_id,
            &current_attempt.action_key,
            next_attempt,
        ),
        state: TaskBoardAttemptState::Starting,
        failure_class: None,
        available_at: None,
        error: None,
        artifact: None,
        started_at: now.into(),
        updated_at: now.into(),
        completed_at: None,
    };
    validate_task_board_execution_attempt(&fallback)
        .map_err(|error| db_error(format!("validate local fallback attempt: {error}")))?;
    validate_attempt_phase(parent, &failed)?;
    validate_attempt_phase(parent, &fallback)?;
    let mut updated_parent = parent.clone();
    updated_parent.transition.execution_state = TaskBoardExecutionState::Starting;
    updated_parent.ownership.host_id = None;
    updated_parent
        .ownership
        .resources
        .insert(TASK_BOARD_EXECUTION_TARGET_RESOURCE.into(), "local".into());
    updated_parent.ownership.resources.insert(
        TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE.into(),
        fallback.action_key.clone(),
    );
    updated_parent.ownership.resources.insert(
        TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE.into(),
        fallback.attempt.to_string(),
    );
    updated_parent.available_at = None;
    updated_parent.blocked_reason = None;
    updated_parent.updated_at = monotonic_time(&parent.updated_at, now)?;
    let mut combined = updated_parent.clone();
    combined.attempts[attempt_index] = failed.clone();
    combined.attempts.push(fallback.clone());
    validate_task_board_execution_target_update(parent, &combined)
        .map_err(|error| db_error(format!("validate remote fallback parent: {error}")))?;
    validate_task_board_workflow_execution(&combined)
        .map_err(|error| db_error(format!("validate remote fallback execution: {error}")))?;
    Ok((updated_parent, failed, fallback, combined))
}

/// Descriptive terminal error for an assignment superseded by local fallback.
///
/// The schema forbids storing the bare `executor_unavailable` wire code as an
/// assignment error, so the assignment records the same prefixed description the
/// fallback attempt carries.
fn local_fallback_error(reason: &str) -> String {
    format!("remote offer rejected: {reason}")
}

fn monotonic_time(current: &str, candidate: &str) -> Result<String, CliError> {
    let current_time = canonical_time(current, "current workflow update time")?;
    let candidate_time = canonical_time(candidate, "remote fallback time")?;
    Ok(if candidate_time > current_time {
        candidate.into()
    } else {
        current.into()
    })
}

async fn terminalize_rejected_assignment(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    reason: &str,
    now: &str,
) -> Result<(), CliError> {
    let updated_at = monotonic_time(&record.updated_at, now)?;
    let rows = query(
        "UPDATE task_board_remote_assignments SET state = 'superseded',
         heartbeat_at = ?2, completed_at = ?2, error = ?3, updated_at = ?2
         WHERE assignment_id = ?1 AND fencing_epoch = ?4 AND state = 'offered'
           AND claimed_at IS NULL",
    )
    .bind(&record.assignment_id)
    .bind(updated_at)
    .bind(local_fallback_error(reason))
    .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("terminalize rejected remote assignment: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(())
    } else {
        Err(concurrent("remote assignment rejection lost its fence"))
    }
}

fn deterministic_attempt_id(execution_id: &str, action_key: &str, attempt: u32) -> String {
    let mut digest = Sha256::new();
    digest.update(b"harness:task-board:read-only-attempt:v1\0");
    for component in [execution_id.as_bytes(), action_key.as_bytes()] {
        digest.update((component.len() as u64).to_be_bytes());
        digest.update(component);
    }
    digest.update(attempt.to_be_bytes());
    format!("codex-workflow-{}", hex::encode(digest.finalize()))
}
