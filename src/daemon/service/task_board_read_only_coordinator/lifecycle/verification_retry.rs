use chrono::{DateTime, Utc};

use crate::daemon::db::AsyncDaemonDb;
use crate::errors::CliError;
use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardAttemptRetryDecision, TaskBoardAttemptState,
    TaskBoardExecutionAttemptCas, TaskBoardExecutionAttemptRecord, TaskBoardExecutionDiagnostic,
    TaskBoardExecutionPhase, TaskBoardExecutionState, TaskBoardFailureClass,
    TaskBoardLifecycleOutcome, TaskBoardTerminalOutcomeKind, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionRecord, task_board_attempt_retry_decision,
};

use super::invalid_transition;

pub(super) async fn schedule_publish_verification_retry(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    detail: &str,
    provisional: Option<&crate::task_board::TaskBoardLifecycleOutcome>,
    now: &str,
) -> Result<(), CliError> {
    let current = db
        .task_board_workflow_execution(&execution.execution_id)
        .await?
        .ok_or_else(|| invalid_transition("workflow execution disappeared during verification"))?;
    let current_attempt = current
        .attempts
        .iter()
        .find(|candidate| same_attempt(candidate, attempt))
        .ok_or_else(|| invalid_transition("publish attempt disappeared during verification"))?;
    if current_attempt.state != TaskBoardAttemptState::Running {
        return Ok(());
    }
    if current.transition.phase != Some(TaskBoardExecutionPhase::Publish)
        || !matches!(
            current.transition.execution_state,
            TaskBoardExecutionState::Starting | TaskBoardExecutionState::Running
        )
    {
        return Ok(());
    }
    let failed_attempt = verification_failure_count(&current);
    let settings = db.task_board_orchestrator_settings_snapshot().await?;
    let timestamp = DateTime::parse_from_rfc3339(now)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| invalid_transition(format!("invalid verification timestamp: {error}")))?;
    let decision = task_board_attempt_retry_decision(
        &settings.settings.retry,
        &format!("{}:publish:verification", execution.execution_id),
        "publish",
        failed_attempt,
        TaskBoardFailureClass::Transient,
        timestamp,
    );
    let TaskBoardAttemptRetryDecision::Retry(retry) = decision else {
        return mark_publish_unknown(db, &current, current_attempt, detail, provisional, now).await;
    };
    let mut updated = current.clone();
    updated.transition.execution_state = TaskBoardExecutionState::Running;
    updated.available_at = None;
    updated.blocked_reason = None;
    updated
        .artifacts
        .diagnostics
        .push(TaskBoardExecutionDiagnostic {
            code: "publish_verification_failed".into(),
            message: detail.into(),
            recorded_at: now.into(),
        });
    updated.updated_at = now.into();
    let mut updated_attempt = current_attempt.clone();
    updated_attempt.failure_class = Some(TaskBoardFailureClass::Transient);
    updated_attempt.error = Some(detail.to_string());
    updated_attempt.available_at = Some(retry.available_at);
    updated_attempt.updated_at = now.to_string();
    if let Some(outcome) = provisional {
        updated_attempt.artifact =
            Some(crate::task_board::TaskBoardAttemptResultArtifact::Lifecycle(outcome.clone()));
    }
    let outcome = db
        .compare_and_set_task_board_workflow_execution_and_attempt(
            &TaskBoardWorkflowExecutionCas::from(&current),
            &updated,
            &TaskBoardExecutionAttemptCas::from(current_attempt),
            &updated_attempt,
        )
        .await?;
    if outcome.is_none() {
        return Ok(());
    }
    Ok(())
}

pub(super) async fn mark_publish_unknown(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    detail: &str,
    immediate: Option<&TaskBoardLifecycleOutcome>,
    now: &str,
) -> Result<(), CliError> {
    if !store_publish_unknown(db, execution, attempt, detail, immediate, now).await? {
        return Ok(());
    }
    super::super::attempts::require_human(
        db,
        &execution.execution_id,
        "publish_outcome_unknown",
        "workflow publication outcome could not be verified authoritatively",
        TaskBoardTerminalOutcomeKind::Unknown,
        now,
    )
    .await
}

async fn store_publish_unknown(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    detail: &str,
    immediate: Option<&TaskBoardLifecycleOutcome>,
    now: &str,
) -> Result<bool, CliError> {
    loop {
        let current = db
            .task_board_workflow_execution(&execution.execution_id)
            .await?
            .ok_or_else(|| {
                invalid_transition("workflow execution disappeared during verification")
            })?;
        let current_attempt = current
            .attempts
            .iter()
            .find(|candidate| same_attempt(candidate, attempt))
            .ok_or_else(|| invalid_transition("publish attempt disappeared during verification"))?;
        if !matches!(
            current_attempt.state,
            TaskBoardAttemptState::Running | TaskBoardAttemptState::Unknown
        ) {
            return Ok(false);
        }
        let evidence = provisional_publication(immediate, current_attempt)?;
        if let (Some(stored), Some(evidence)) = (
            current.artifacts.provisional_publication.as_ref(),
            evidence.as_ref(),
        ) && stored != evidence
        {
            return Err(invalid_transition(
                "provisional publication evidence conflicts with durable state",
            ));
        }
        if current_attempt.state == TaskBoardAttemptState::Unknown
            && evidence.as_ref() == current.artifacts.provisional_publication.as_ref()
        {
            return Ok(true);
        }
        let mut updated = current.clone();
        if let Some(evidence) = evidence {
            updated.artifacts.provisional_publication = Some(evidence);
        }
        updated.updated_at = now.to_string();
        let mut updated_attempt = current_attempt.clone();
        if current_attempt.state == TaskBoardAttemptState::Running {
            updated_attempt.state = TaskBoardAttemptState::Unknown;
            updated_attempt.failure_class = Some(TaskBoardFailureClass::UnknownOutcome);
            updated_attempt.available_at = None;
            updated_attempt.error = Some(detail.to_string());
            updated_attempt.artifact = None;
            updated_attempt.updated_at = now.to_string();
        }
        let stored = db
            .compare_and_set_task_board_workflow_execution_and_attempt(
                &TaskBoardWorkflowExecutionCas::from(&current),
                &updated,
                &TaskBoardExecutionAttemptCas::from(current_attempt),
                &updated_attempt,
            )
            .await?;
        if stored.is_some() {
            return Ok(true);
        }
    }
}

fn provisional_publication(
    immediate: Option<&TaskBoardLifecycleOutcome>,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> Result<Option<TaskBoardLifecycleOutcome>, CliError> {
    let durable = match attempt.artifact.as_ref() {
        Some(TaskBoardAttemptResultArtifact::Lifecycle(outcome)) => Some(outcome.clone()),
        _ => None,
    };
    match (immediate, durable) {
        (Some(immediate), Some(durable)) if *immediate != durable => Err(invalid_transition(
            "immediate publication evidence conflicts with the durable attempt",
        )),
        (Some(immediate), _) => Ok(Some(immediate.clone())),
        (None, durable) => Ok(durable),
    }
}

fn verification_failure_count(execution: &TaskBoardWorkflowExecutionRecord) -> u32 {
    let count = execution
        .artifacts
        .diagnostics
        .iter()
        .filter(|diagnostic| diagnostic.code == "publish_verification_failed")
        .count()
        .saturating_add(1);
    u32::try_from(count).unwrap_or(u32::MAX)
}

fn same_attempt(
    candidate: &TaskBoardExecutionAttemptRecord,
    expected: &TaskBoardExecutionAttemptRecord,
) -> bool {
    candidate.action_key == expected.action_key && candidate.attempt == expected.attempt
}
