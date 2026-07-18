#[cfg(test)]
use std::collections::BTreeMap;

use chrono::{DateTime, SecondsFormat, Utc};

use crate::daemon::db::AsyncDaemonDb;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionAttemptCas, TaskBoardExecutionAttemptCasOutcome,
    TaskBoardExecutionAttemptCreateOutcome, TaskBoardExecutionAttemptRecord,
    TaskBoardExecutionDiagnostic, TaskBoardExecutionPhase, TaskBoardExecutionState,
    TaskBoardPullRequestIdentity, TaskBoardRetrySchedule, TaskBoardTerminalOutcome,
    TaskBoardTerminalOutcomeKind, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionCasOutcome, TaskBoardWorkflowExecutionRecord,
    TaskBoardWorkflowRevisionGuard, advance_task_board_workflow,
};
#[cfg(test)]
use crate::task_board::{
    TaskBoardExecutionOwnership, TaskBoardWorkflowExecutionArtifacts,
    TaskBoardWorkflowExecutionCreateOutcome, TaskBoardWorkflowKind, TaskBoardWorkflowSnapshot,
    start_task_board_workflow,
};

#[cfg(test)]
pub(crate) struct TaskBoardWorkflowExecutionCreateRequest {
    pub execution_id: String,
    pub item_id: String,
    pub snapshot: TaskBoardWorkflowSnapshot,
    pub pull_request: Option<TaskBoardPullRequestIdentity>,
    pub exact_head_revision: Option<String>,
    pub created_at: String,
}

#[cfg(test)]
pub(crate) async fn create_or_load_workflow_execution(
    db: &AsyncDaemonDb,
    request: &TaskBoardWorkflowExecutionCreateRequest,
) -> Result<TaskBoardWorkflowExecutionCreateOutcome, CliError> {
    let created_at = canonical_time(&request.created_at)?;
    if !matches!(
        request.snapshot.workflow_kind,
        TaskBoardWorkflowKind::PrReview | TaskBoardWorkflowKind::Review
    ) {
        return Err(invalid_transition(
            "read-only workflow execution requires Review or PrReview",
        ));
    }
    let transition = start_task_board_workflow(
        request.snapshot.workflow_kind,
        request.pull_request.as_ref(),
        request.exact_head_revision.as_deref(),
    )
    .map_err(workflow_error)?;
    let record = TaskBoardWorkflowExecutionRecord {
        execution_id: required(&request.execution_id, "execution id")?,
        item_id: required(&request.item_id, "item id")?,
        snapshot: request.snapshot.clone(),
        resolved_reviewers: request.snapshot.reviewer.clone(),
        transition,
        artifacts: TaskBoardWorkflowExecutionArtifacts::default(),
        ownership: TaskBoardExecutionOwnership {
            host_id: None,
            fencing_epoch: 0,
            resources: BTreeMap::default(),
        },
        available_at: None,
        blocked_reason: None,
        created_at: created_at.clone(),
        updated_at: created_at,
        completed_at: None,
        attempts: Vec::new(),
    };
    db.create_or_load_task_board_workflow_execution(&record)
        .await
}

pub(crate) async fn advance_workflow_execution(
    db: &AsyncDaemonDb,
    expected: &TaskBoardWorkflowExecutionCas,
    current_revisions: &TaskBoardWorkflowRevisionGuard,
    observed_pull_request: Option<&TaskBoardPullRequestIdentity>,
    observed_head_revision: Option<&str>,
    updated_at: &str,
) -> Result<TaskBoardWorkflowExecutionCasOutcome, CliError> {
    let Some(mut record) = guarded_execution(db, expected).await? else {
        return stale_outcome(db, expected).await;
    };
    if is_stopped(&record) {
        return Ok(TaskBoardWorkflowExecutionCasOutcome::Unchanged(record));
    }
    let updated_at = canonical_time(updated_at)?;
    if current_revisions != &TaskBoardWorkflowRevisionGuard::from(&record.snapshot) {
        invalidate_for_revision_change(&mut record, current_revisions, &updated_at);
        return db
            .compare_and_set_task_board_workflow_execution(expected, &record)
            .await;
    }
    if record
        .attempts
        .iter()
        .any(|attempt| attempt.state == TaskBoardAttemptState::Unknown)
    {
        require_human_for_unknown_outcome(&mut record, &updated_at);
        return db
            .compare_and_set_task_board_workflow_execution(expected, &record)
            .await;
    }
    if !phase_evidence_allows_advance(&mut record, &updated_at) {
        return db
            .compare_and_set_task_board_workflow_execution(expected, &record)
            .await;
    }
    record.transition = advance_task_board_workflow(
        &record.transition,
        observed_pull_request,
        observed_head_revision,
    )
    .map_err(workflow_error)?;
    record.available_at = None;
    record.blocked_reason = None;
    record.artifacts.retry = None;
    record.updated_at = updated_at.clone();
    if record.transition.execution_state == TaskBoardExecutionState::Completed {
        record.completed_at = Some(updated_at.clone());
        record.artifacts.terminal_outcome = Some(TaskBoardTerminalOutcome {
            kind: TaskBoardTerminalOutcomeKind::Succeeded,
            summary: "workflow completed with durable evidence".into(),
            recorded_at: updated_at,
        });
    }
    db.compare_and_set_task_board_workflow_execution(expected, &record)
        .await
}

pub(crate) async fn schedule_workflow_retry(
    db: &AsyncDaemonDb,
    expected: &TaskBoardWorkflowExecutionCas,
    retry: TaskBoardRetrySchedule,
    diagnostic: TaskBoardExecutionDiagnostic,
    updated_at: &str,
) -> Result<TaskBoardWorkflowExecutionCasOutcome, CliError> {
    let Some(mut record) = guarded_execution(db, expected).await? else {
        return stale_outcome(db, expected).await;
    };
    canonical_time(&retry.available_at)?;
    canonical_time(&diagnostic.recorded_at)?;
    if record.transition.execution_state == TaskBoardExecutionState::RetryWait
        && record.artifacts.retry.as_ref() == Some(&retry)
        && record.artifacts.diagnostics.last() == Some(&diagnostic)
    {
        return db
            .compare_and_set_task_board_workflow_execution(expected, &record)
            .await;
    }
    record.transition.execution_state = TaskBoardExecutionState::RetryWait;
    record.available_at = Some(retry.available_at.clone());
    record.artifacts.retry = Some(retry);
    record.artifacts.diagnostics.push(diagnostic);
    record.updated_at = canonical_time(updated_at)?;
    db.compare_and_set_task_board_workflow_execution(expected, &record)
        .await
}

pub(crate) async fn resume_workflow_retry(
    db: &AsyncDaemonDb,
    expected: &TaskBoardWorkflowExecutionCas,
    resumed_at: &str,
) -> Result<TaskBoardWorkflowExecutionCasOutcome, CliError> {
    let Some(mut record) = guarded_execution(db, expected).await? else {
        return stale_outcome(db, expected).await;
    };
    let resumed_at = canonical_time(resumed_at)?;
    if record.transition.execution_state != TaskBoardExecutionState::RetryWait {
        return Ok(TaskBoardWorkflowExecutionCasOutcome::Unchanged(record));
    }
    let available_at = record
        .available_at
        .as_deref()
        .ok_or_else(|| invalid_transition("retry execution has no availability time"))?;
    if parse_time(&resumed_at)? < parse_time(available_at)? {
        return Ok(TaskBoardWorkflowExecutionCasOutcome::Unchanged(record));
    }
    record.transition.execution_state = TaskBoardExecutionState::Pending;
    record.available_at = None;
    record.artifacts.retry = None;
    record.updated_at = resumed_at;
    db.compare_and_set_task_board_workflow_execution(expected, &record)
        .await
}

pub(crate) async fn create_workflow_execution_attempt(
    db: &AsyncDaemonDb,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> Result<TaskBoardExecutionAttemptCreateOutcome, CliError> {
    let execution = db
        .task_board_workflow_execution(&attempt.execution_id)
        .await?
        .ok_or_else(|| invalid_transition("workflow execution does not exist"))?;
    validate_attempt_phase(&execution, attempt)?;
    db.create_task_board_execution_attempt(attempt).await
}

pub(crate) async fn record_workflow_execution_attempt(
    db: &AsyncDaemonDb,
    expected: &TaskBoardExecutionAttemptCas,
    updated: &TaskBoardExecutionAttemptRecord,
) -> Result<TaskBoardExecutionAttemptCasOutcome, CliError> {
    let execution = db
        .task_board_workflow_execution(&expected.execution_id)
        .await?
        .ok_or_else(|| invalid_transition("workflow execution does not exist"))?;
    if execution
        .attempts
        .iter()
        .any(|current| attempt_replay_matches(expected, current, updated))
    {
        return db
            .compare_and_set_task_board_execution_attempt(expected, updated)
            .await;
    }
    validate_attempt_phase(&execution, updated)?;
    db.compare_and_set_task_board_execution_attempt(expected, updated)
        .await
}

fn attempt_replay_matches(
    expected: &TaskBoardExecutionAttemptCas,
    current: &TaskBoardExecutionAttemptRecord,
    updated: &TaskBoardExecutionAttemptRecord,
) -> bool {
    current == updated
        && expected.execution_id == current.execution_id
        && expected.action_key == current.action_key
        && expected.attempt == current.attempt
        && expected.idempotency_key == current.idempotency_key
}

fn validate_attempt_phase(
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> Result<(), CliError> {
    if attempt.execution_id != execution.execution_id {
        return Err(invalid_transition(
            "workflow attempt does not belong to its execution",
        ));
    }
    let phase = execution
        .transition
        .phase
        .ok_or_else(|| invalid_transition("workflow execution has no active phase"))?;
    let valid_action = match phase {
        TaskBoardExecutionPhase::Review => attempt.action_key.starts_with("review:"),
        TaskBoardExecutionPhase::Evaluate => attempt.action_key == "evaluate",
        TaskBoardExecutionPhase::Publish => attempt.action_key == "publish",
        TaskBoardExecutionPhase::Cleanup => attempt.action_key == "cleanup",
        TaskBoardExecutionPhase::Planning
        | TaskBoardExecutionPhase::AwaitingApproval
        | TaskBoardExecutionPhase::Implementation
        | TaskBoardExecutionPhase::Terminal => false,
    };
    if !valid_action {
        return Err(invalid_transition(format!(
            "workflow attempt action '{}' does not belong to phase {phase:?}",
            attempt.action_key
        )));
    }
    if attempt.state != TaskBoardAttemptState::Completed {
        return Ok(());
    }
    let valid_artifact = match (phase, attempt.artifact.as_ref()) {
        (
            TaskBoardExecutionPhase::Review,
            Some(crate::task_board::TaskBoardAttemptResultArtifact::Review(outcome)),
        ) => attempt.action_key == format!("review:{}", outcome.profile_id),
        (
            TaskBoardExecutionPhase::Evaluate,
            Some(crate::task_board::TaskBoardAttemptResultArtifact::Evaluation(_)),
        )
        | (
            TaskBoardExecutionPhase::Publish | TaskBoardExecutionPhase::Cleanup,
            Some(crate::task_board::TaskBoardAttemptResultArtifact::Lifecycle(_)),
        ) => true,
        _ => false,
    };
    if valid_artifact {
        Ok(())
    } else {
        Err(invalid_transition(
            "workflow attempt result artifact contradicts its frozen phase",
        ))
    }
}

pub(super) async fn guarded_execution(
    db: &AsyncDaemonDb,
    expected: &TaskBoardWorkflowExecutionCas,
) -> Result<Option<TaskBoardWorkflowExecutionRecord>, CliError> {
    let current = db
        .task_board_workflow_execution(&expected.execution_id)
        .await?;
    Ok(current.filter(|record| cas_matches(expected, record)))
}

pub(super) async fn stale_outcome(
    db: &AsyncDaemonDb,
    expected: &TaskBoardWorkflowExecutionCas,
) -> Result<TaskBoardWorkflowExecutionCasOutcome, CliError> {
    let current = db
        .task_board_workflow_execution(&expected.execution_id)
        .await?;
    let Some(current) = current else {
        return Ok(TaskBoardWorkflowExecutionCasOutcome::Stale {
            mismatch: crate::task_board::TaskBoardWorkflowCasMismatch::ExecutionId,
            current: None,
        });
    };
    db.compare_and_set_task_board_workflow_execution(expected, &current)
        .await
}

fn cas_matches(
    expected: &TaskBoardWorkflowExecutionCas,
    record: &TaskBoardWorkflowExecutionRecord,
) -> bool {
    *expected == TaskBoardWorkflowExecutionCas::from(record)
}

fn is_stopped(record: &TaskBoardWorkflowExecutionRecord) -> bool {
    matches!(
        record.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
            | TaskBoardExecutionState::Completed
            | TaskBoardExecutionState::Failed
            | TaskBoardExecutionState::Cancelled
    ) || record.transition.phase.is_none()
}

fn phase_evidence_allows_advance(
    record: &mut TaskBoardWorkflowExecutionRecord,
    updated_at: &str,
) -> bool {
    match record.transition.phase {
        Some(TaskBoardExecutionPhase::Review) => {
            let approved = record.artifacts.review_cycles.last().is_some_and(|cycle| {
                cycle.decision == Some(crate::task_board::TaskBoardReviewRoundDecision::Approved)
            });
            evidence_or_wait(record, approved, "review_evidence_pending", updated_at)
        }
        Some(TaskBoardExecutionPhase::Evaluate) => {
            let present = completed_attempt(record, "evaluate", ArtifactKind::Evaluation);
            evidence_or_wait(record, present, "evaluation_evidence_pending", updated_at)
        }
        Some(TaskBoardExecutionPhase::Publish) => {
            let present = completed_attempt(record, "publish", ArtifactKind::Lifecycle);
            evidence_or_wait(record, present, "publish_evidence_pending", updated_at)
        }
        Some(TaskBoardExecutionPhase::Cleanup) => {
            let present = completed_attempt(record, "cleanup", ArtifactKind::TerminalLifecycle);
            evidence_or_wait(record, present, "cleanup_evidence_pending", updated_at)
        }
        Some(TaskBoardExecutionPhase::Terminal) | None => true,
        Some(
            TaskBoardExecutionPhase::Planning
            | TaskBoardExecutionPhase::AwaitingApproval
            | TaskBoardExecutionPhase::Implementation,
        ) => {
            require_human(record, "write_phase_not_supported", updated_at);
            false
        }
    }
}

fn evidence_or_wait(
    record: &mut TaskBoardWorkflowExecutionRecord,
    present: bool,
    reason: &str,
    updated_at: &str,
) -> bool {
    if !present {
        record.blocked_reason = Some(reason.to_owned());
        updated_at.clone_into(&mut record.updated_at);
    }
    present
}

fn invalidate_for_revision_change(
    record: &mut TaskBoardWorkflowExecutionRecord,
    _revisions: &TaskBoardWorkflowRevisionGuard,
    updated_at: &str,
) {
    require_human(record, "frozen_revision_changed", updated_at);
}

#[derive(Clone, Copy)]
enum ArtifactKind {
    Evaluation,
    Lifecycle,
    TerminalLifecycle,
}

fn completed_attempt(
    record: &TaskBoardWorkflowExecutionRecord,
    action_key: &str,
    kind: ArtifactKind,
) -> bool {
    record.attempts.iter().any(|attempt| {
        attempt.action_key == action_key
            && attempt.state == TaskBoardAttemptState::Completed
            && artifact_matches(attempt, kind)
    })
}

fn artifact_matches(attempt: &TaskBoardExecutionAttemptRecord, kind: ArtifactKind) -> bool {
    use crate::task_board::TaskBoardAttemptResultArtifact::{Evaluation, Lifecycle};
    match (attempt.artifact.as_ref(), kind) {
        (Some(Evaluation(result)), ArtifactKind::Evaluation) => {
            result.verdict == crate::task_board::TaskBoardPhaseVerdict::Pass
        }
        (Some(Lifecycle(_)), ArtifactKind::Lifecycle) => true,
        (Some(Lifecycle(result)), ArtifactKind::TerminalLifecycle) => result.terminal,
        _ => false,
    }
}

fn require_human_for_unknown_outcome(
    record: &mut TaskBoardWorkflowExecutionRecord,
    updated_at: &str,
) {
    require_human(record, "attempt_outcome_unknown", updated_at);
    record.artifacts.terminal_outcome = Some(TaskBoardTerminalOutcome {
        kind: TaskBoardTerminalOutcomeKind::Unknown,
        summary: "attempt result is unknown; success was not recorded".into(),
        recorded_at: updated_at.to_owned(),
    });
}

pub(super) fn require_human(
    record: &mut TaskBoardWorkflowExecutionRecord,
    reason: &str,
    updated_at: &str,
) {
    record.transition.execution_state = TaskBoardExecutionState::HumanRequired;
    record.blocked_reason = Some(reason.to_owned());
    record.available_at = None;
    updated_at.clone_into(&mut record.updated_at);
}

pub(super) fn canonical_time(value: &str) -> Result<String, CliError> {
    parse_time(value).map(|value| value.to_rfc3339_opts(SecondsFormat::AutoSi, true))
}

fn parse_time(value: &str) -> Result<DateTime<Utc>, CliError> {
    DateTime::parse_from_rfc3339(value.trim())
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| invalid_transition(format!("invalid workflow timestamp: {error}")))
}

#[cfg(test)]
fn required(value: &str, field: &str) -> Result<String, CliError> {
    let value = value.trim();
    if value.is_empty() {
        Err(invalid_transition(format!("{field} is empty")))
    } else {
        Ok(value.to_owned())
    }
}

fn workflow_error(error: impl std::fmt::Display) -> CliError {
    invalid_transition(error.to_string())
}

fn invalid_transition(detail: impl Into<String>) -> CliError {
    CliErrorKind::invalid_transition(detail.into()).into()
}
