use crate::daemon::db::AsyncDaemonDb;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionAttemptRecord, TaskBoardExecutionPhase,
    TaskBoardExecutionState, TaskBoardItem, TaskBoardTerminalOutcome, TaskBoardTerminalOutcomeKind,
    TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionCasOutcome,
    TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowRevisionGuard,
};
use sha2::{Digest, Sha256};

use super::super::task_board_read_only_runtime::TaskBoardReadOnlyRuntime;
use super::{attempt_recovery, ingestion, lifecycle, reports, requests};

pub(super) async fn reconcile_execution<R>(
    db: &AsyncDaemonDb,
    runtime: &R,
    execution: TaskBoardWorkflowExecutionRecord,
    now: &str,
) -> Result<(), CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    if is_stopped(&execution) {
        return Ok(());
    }
    if let Err(error) = requests::run_context(&execution) {
        require_human(
            db,
            &execution.execution_id,
            "read_only_run_context_missing",
            &error.to_string(),
            TaskBoardTerminalOutcomeKind::HumanRequired,
            now,
        )
        .await?;
        return Ok(());
    }
    if execution.transition.execution_state == TaskBoardExecutionState::RetryWait {
        super::super::task_board_workflow_execution::resume_workflow_retry(
            db,
            &TaskBoardWorkflowExecutionCas::from(&execution),
            now,
        )
        .await?;
        return Ok(());
    }
    let active_attempt = one_active_attempt(&execution)?.cloned();
    if let Some(attempt) = active_attempt.as_ref().filter(|attempt| {
        matches!(
            execution.transition.phase,
            Some(TaskBoardExecutionPhase::Review | TaskBoardExecutionPhase::Evaluate)
        ) && matches!(
            attempt.state,
            TaskBoardAttemptState::Starting | TaskBoardAttemptState::Running
        )
    }) && reports::reconcile_report_attempt(db, runtime, &execution, attempt, false, now).await?
    {
        return Ok(());
    }
    if let Some(attempt) = active_attempt.as_ref().filter(|attempt| {
        execution.transition.phase == Some(TaskBoardExecutionPhase::Publish)
            && attempt.state == TaskBoardAttemptState::Running
    }) {
        lifecycle::reconcile_lifecycle_attempt(db, runtime, &execution, attempt, now).await?;
        return Ok(());
    }
    let snapshot = db.task_board_item_snapshot(&execution.item_id).await?;
    if !item_identity_matches(&execution, &snapshot.item) {
        require_human(
            db,
            &execution.execution_id,
            "item_identity_changed",
            "Task Board item was deleted or detached from its read-only workflow",
            TaskBoardTerminalOutcomeKind::HumanRequired,
            now,
        )
        .await?;
        return Ok(());
    }
    let revisions = current_revisions(db, snapshot.item_revision, &execution).await?;
    if revisions != TaskBoardWorkflowRevisionGuard::from(&execution.snapshot) {
        invalidate_revisions(db, &execution, &revisions, now).await?;
        return Ok(());
    }
    if let Some(attempt) = active_attempt.as_ref() {
        return reconcile_active_attempt(db, runtime, &execution, attempt, now).await;
    }
    if attempt_recovery::recover_terminal_attempt_state(db, &execution, now).await? {
        return Ok(());
    }
    if let Some(attempt) = ingestion::unapplied_completed_attempt(&execution) {
        return ingestion::ingest_completed_attempt(
            db, runtime, &execution, attempt, &revisions, now,
        )
        .await;
    }
    if execution.transition.phase == Some(TaskBoardExecutionPhase::Publish)
        && !lifecycle::preflight_publish(db, runtime, &execution, now).await?
    {
        return Ok(());
    }
    schedule_next_attempt(db, &execution, now).await
}

async fn reconcile_active_attempt<R>(
    db: &AsyncDaemonDb,
    runtime: &R,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    now: &str,
) -> Result<(), CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    match execution.transition.phase {
        Some(TaskBoardExecutionPhase::Review | TaskBoardExecutionPhase::Evaluate) => {
            reports::reconcile_report_attempt(db, runtime, execution, attempt, true, now)
                .await
                .map(|_| ())
        }
        Some(TaskBoardExecutionPhase::Publish | TaskBoardExecutionPhase::Cleanup) => {
            lifecycle::reconcile_lifecycle_attempt(db, runtime, execution, attempt, now).await
        }
        phase => Err(invalid_transition(format!(
            "active read-only attempt cannot run in phase {phase:?}"
        ))),
    }
}

async fn schedule_next_attempt(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    now: &str,
) -> Result<(), CliError> {
    let action_key = next_action_key(execution)?;
    let attempt_number = execution
        .attempts
        .iter()
        .filter(|attempt| attempt.action_key == action_key)
        .map(|attempt| attempt.attempt)
        .max()
        .unwrap_or(0)
        .saturating_add(1);
    let attempt = TaskBoardExecutionAttemptRecord {
        execution_id: execution.execution_id.clone(),
        action_key: action_key.clone(),
        attempt: attempt_number,
        idempotency_key: deterministic_attempt_id(
            &execution.execution_id,
            &action_key,
            attempt_number,
        ),
        state: TaskBoardAttemptState::Preparing,
        failure_class: None,
        available_at: None,
        error: None,
        artifact: None,
        started_at: now.to_string(),
        updated_at: now.to_string(),
        completed_at: None,
    };
    super::super::task_board_workflow_execution::create_workflow_execution_attempt(db, &attempt)
        .await?;
    set_execution_state(
        db,
        &execution.execution_id,
        TaskBoardExecutionState::Preparing,
        now,
    )
    .await?;
    Ok(())
}

fn next_action_key(execution: &TaskBoardWorkflowExecutionRecord) -> Result<String, CliError> {
    match execution.transition.phase {
        Some(TaskBoardExecutionPhase::Review) => {
            let completed = execution
                .artifacts
                .review_cycles
                .last()
                .map(|cycle| cycle.outcomes.as_slice())
                .unwrap_or_default();
            execution
                .resolved_reviewers
                .profiles
                .iter()
                .find(|profile| {
                    !completed
                        .iter()
                        .any(|outcome| outcome.profile_id == profile.id)
                })
                .map(|profile| format!("review:{}", profile.id))
                .ok_or_else(|| invalid_transition("review phase has no remaining reviewer action"))
        }
        Some(TaskBoardExecutionPhase::Evaluate) => Ok("evaluate".into()),
        Some(TaskBoardExecutionPhase::Publish) => Ok("publish".into()),
        Some(TaskBoardExecutionPhase::Cleanup) => Ok("cleanup".into()),
        phase => Err(invalid_transition(format!(
            "read-only execution has no schedulable action in phase {phase:?}"
        ))),
    }
}

fn one_active_attempt(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<Option<&TaskBoardExecutionAttemptRecord>, CliError> {
    let mut active = execution.attempts.iter().filter(|attempt| {
        matches!(
            attempt.state,
            TaskBoardAttemptState::Preparing
                | TaskBoardAttemptState::Starting
                | TaskBoardAttemptState::Running
        )
    });
    let first = active.next();
    if active.next().is_some() {
        Err(invalid_transition(
            "workflow execution has multiple active attempts",
        ))
    } else {
        Ok(first)
    }
}

async fn current_revisions(
    db: &AsyncDaemonDb,
    item_revision: i64,
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<TaskBoardWorkflowRevisionGuard, CliError> {
    Ok(TaskBoardWorkflowRevisionGuard {
        item_revision,
        configuration_revision: db.task_board_configuration_revision().await?,
        provider_revision: execution.snapshot.provider_revision.clone(),
    })
}

pub(super) async fn settlement_is_current(
    db: &AsyncDaemonDb,
    execution_id: &str,
    now: &str,
) -> Result<bool, CliError> {
    let Some(current) = db.task_board_workflow_execution(execution_id).await? else {
        return Err(invalid_transition("workflow execution disappeared"));
    };
    if is_stopped(&current) {
        return Ok(false);
    }
    let snapshot = db.task_board_item_snapshot(&current.item_id).await?;
    if !item_identity_matches(&current, &snapshot.item) {
        require_human(
            db,
            execution_id,
            "item_identity_changed_after_attempt",
            "Task Board item changed identity while a read-only attempt was settling",
            TaskBoardTerminalOutcomeKind::HumanRequired,
            now,
        )
        .await?;
        return Ok(false);
    }
    let revisions = current_revisions(db, snapshot.item_revision, &current).await?;
    if revisions != TaskBoardWorkflowRevisionGuard::from(&current.snapshot) {
        invalidate_revisions(db, &current, &revisions, now).await?;
        return Ok(false);
    }
    Ok(true)
}

async fn invalidate_revisions(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    revisions: &TaskBoardWorkflowRevisionGuard,
    now: &str,
) -> Result<(), CliError> {
    super::super::task_board_workflow_execution::advance_workflow_execution(
        db,
        &TaskBoardWorkflowExecutionCas::from(execution),
        revisions,
        execution.transition.pull_request.as_ref(),
        execution.transition.exact_head_revision.as_deref(),
        now,
    )
    .await?;
    Ok(())
}

pub(super) async fn set_execution_state(
    db: &AsyncDaemonDb,
    execution_id: &str,
    state: TaskBoardExecutionState,
    now: &str,
) -> Result<(), CliError> {
    set_execution_state_guarded(db, execution_id, state, None, now).await
}

pub(super) async fn settle_execution_running_in_phase(
    db: &AsyncDaemonDb,
    execution_id: &str,
    expected_phase: TaskBoardExecutionPhase,
    now: &str,
) -> Result<(), CliError> {
    set_execution_state_guarded(
        db,
        execution_id,
        TaskBoardExecutionState::Running,
        Some(expected_phase),
        now,
    )
    .await
}

async fn set_execution_state_guarded(
    db: &AsyncDaemonDb,
    execution_id: &str,
    state: TaskBoardExecutionState,
    expected_phase: Option<TaskBoardExecutionPhase>,
    now: &str,
) -> Result<(), CliError> {
    let Some(current) = db.task_board_workflow_execution(execution_id).await? else {
        return Err(invalid_transition("workflow execution disappeared"));
    };
    if expected_phase.is_some() && current.transition.phase != expected_phase {
        return Ok(());
    }
    if is_stopped(&current) {
        return Err(CliErrorKind::concurrent_modification(
            "workflow execution stopped before its active state claim",
        )
        .into());
    }
    if current.transition.execution_state == state {
        return Ok(());
    }
    if !active_state_claim_allowed(current.transition.execution_state) {
        return Err(CliErrorKind::concurrent_modification(
            "workflow execution state changed before its active state claim",
        )
        .into());
    }
    let mut updated = current.clone();
    updated.transition.execution_state = state;
    updated.available_at = None;
    updated.blocked_reason = None;
    updated.updated_at = now.to_string();
    let outcome = db
        .compare_and_set_task_board_workflow_execution(
            &TaskBoardWorkflowExecutionCas::from(&current),
            &updated,
        )
        .await?;
    match outcome {
        TaskBoardWorkflowExecutionCasOutcome::Updated(_)
        | TaskBoardWorkflowExecutionCasOutcome::Unchanged(_) => Ok(()),
        TaskBoardWorkflowExecutionCasOutcome::Stale {
            current: Some(latest),
            ..
        } if latest.transition.execution_state == state
            || (expected_phase.is_some() && latest.transition.phase != expected_phase) =>
        {
            Ok(())
        }
        TaskBoardWorkflowExecutionCasOutcome::Stale { .. } => {
            Err(CliErrorKind::concurrent_modification(
                "workflow execution changed before its active state claim",
            )
            .into())
        }
    }
}

const fn active_state_claim_allowed(current: TaskBoardExecutionState) -> bool {
    matches!(
        current,
        TaskBoardExecutionState::Pending
            | TaskBoardExecutionState::Preparing
            | TaskBoardExecutionState::Starting
            | TaskBoardExecutionState::Running
    )
}

pub(super) async fn require_human(
    db: &AsyncDaemonDb,
    execution_id: &str,
    reason: &str,
    summary: &str,
    kind: TaskBoardTerminalOutcomeKind,
    now: &str,
) -> Result<(), CliError> {
    let Some(current) = db.task_board_workflow_execution(execution_id).await? else {
        return Err(invalid_transition("workflow execution disappeared"));
    };
    if is_stopped(&current) {
        return Ok(());
    }
    let mut updated = current.clone();
    super::super::task_board_workflow_execution::require_human(&mut updated, reason, now);
    updated.artifacts.terminal_outcome = Some(TaskBoardTerminalOutcome {
        kind,
        summary: summary.to_string(),
        recorded_at: now.to_string(),
    });
    db.compare_and_set_task_board_workflow_execution(
        &TaskBoardWorkflowExecutionCas::from(&current),
        &updated,
    )
    .await?;
    Ok(())
}

pub(super) fn deterministic_attempt_id(
    execution_id: &str,
    action_key: &str,
    attempt: u32,
) -> String {
    let mut digest = Sha256::new();
    digest.update(b"harness:task-board:read-only-attempt:v1\0");
    for component in [execution_id.as_bytes(), action_key.as_bytes()] {
        digest.update((component.len() as u64).to_be_bytes());
        digest.update(component);
    }
    digest.update(attempt.to_be_bytes());
    format!("codex-workflow-{}", hex::encode(digest.finalize()))
}

fn item_identity_matches(
    execution: &TaskBoardWorkflowExecutionRecord,
    item: &TaskBoardItem,
) -> bool {
    !item.is_deleted()
        && item.id == execution.item_id
        && item.workflow_kind == execution.snapshot.workflow_kind
        && item.workflow.execution_id.as_deref() == Some(execution.execution_id.as_str())
}

fn is_stopped(execution: &TaskBoardWorkflowExecutionRecord) -> bool {
    matches!(
        execution.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
            | TaskBoardExecutionState::Completed
            | TaskBoardExecutionState::Failed
            | TaskBoardExecutionState::Cancelled
    )
}

pub(super) fn invalid_transition(detail: impl Into<String>) -> CliError {
    CliErrorKind::invalid_transition(detail.into()).into()
}

#[cfg(test)]
mod tests {
    use super::deterministic_attempt_id;

    #[test]
    fn deterministic_attempt_ids_preserve_raw_action_identity() {
        let dotted = deterministic_attempt_id("execution", "review:rev.1", 1);
        let dash = deterministic_attempt_id("execution", "review:rev-1", 1);

        assert_ne!(dotted, dash);
        assert_eq!(
            dotted,
            deterministic_attempt_id("execution", "review:rev.1", 1)
        );
        assert_ne!(
            dotted,
            deterministic_attempt_id("execution", "review:rev.1", 2)
        );
    }
}
