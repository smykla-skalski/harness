//! Durable task-board workflow-execution transitions over a narrow storage port.

use std::future::Future;

use harness_kernel::errors::CliError;
use harness_task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardAttemptState, TaskBoardExecutionAttemptCas,
    TaskBoardExecutionAttemptCasOutcome, TaskBoardExecutionAttemptCreateOutcome,
    TaskBoardExecutionAttemptRecord, TaskBoardExecutionDiagnostic, TaskBoardExecutionPhase,
    TaskBoardExecutionState, TaskBoardPhaseVerdict, TaskBoardPullRequestIdentity,
    TaskBoardRetrySchedule, TaskBoardReviewRoundDecision, TaskBoardTerminalOutcome,
    TaskBoardTerminalOutcomeKind, TaskBoardWorkflowCasMismatch, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionCasOutcome, TaskBoardWorkflowExecutionRecord,
    TaskBoardWorkflowRevisionGuard, advance_task_board_workflow,
};

mod attempt_validation;
mod support;

use attempt_validation::attempt_replay_matches;
pub use attempt_validation::validate_attempt_phase;
pub use support::canonical_time;
use support::{invalid_transition, parse_time, workflow_error};

/// Persistence operations required by workflow-execution transitions.
pub trait WorkflowExecutionStore: Send + Sync {
    /// Loads one execution by its durable identity.
    fn workflow_execution(
        &self,
        execution_id: &str,
    ) -> impl Future<Output = Result<Option<TaskBoardWorkflowExecutionRecord>, CliError>> + Send;

    /// Persists an execution when its compare-and-set fence still matches.
    fn compare_and_set_workflow_execution(
        &self,
        expected: &TaskBoardWorkflowExecutionCas,
        updated: &TaskBoardWorkflowExecutionRecord,
    ) -> impl Future<Output = Result<TaskBoardWorkflowExecutionCasOutcome, CliError>> + Send;

    /// Creates an attempt under an existing execution.
    fn create_execution_attempt(
        &self,
        proposed: &TaskBoardExecutionAttemptRecord,
    ) -> impl Future<Output = Result<TaskBoardExecutionAttemptCreateOutcome, CliError>> + Send;

    /// Persists an attempt when its compare-and-set fence still matches.
    fn compare_and_set_execution_attempt(
        &self,
        expected: &TaskBoardExecutionAttemptCas,
        updated: &TaskBoardExecutionAttemptRecord,
    ) -> impl Future<Output = Result<TaskBoardExecutionAttemptCasOutcome, CliError>> + Send;
}

/// Advances an execution after checking its frozen revisions and phase evidence.
///
/// # Errors
/// Returns [`CliError`] when timestamps, transitions, or persistence are invalid.
pub async fn advance_workflow_execution(
    db: &impl WorkflowExecutionStore,
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
            .compare_and_set_workflow_execution(expected, &record)
            .await;
    }
    if record
        .attempts
        .iter()
        .any(|attempt| attempt.state == TaskBoardAttemptState::Unknown)
    {
        require_human_for_unknown_outcome(&mut record, &updated_at);
        return db
            .compare_and_set_workflow_execution(expected, &record)
            .await;
    }
    if !phase_evidence_allows_advance(&mut record, &updated_at) {
        return db
            .compare_and_set_workflow_execution(expected, &record)
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
    db.compare_and_set_workflow_execution(expected, &record)
        .await
}

/// Moves an execution into retry wait with durable diagnostic evidence.
///
/// # Errors
/// Returns [`CliError`] when timestamps are invalid or persistence fails.
pub async fn schedule_workflow_retry(
    db: &impl WorkflowExecutionStore,
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
            .compare_and_set_workflow_execution(expected, &record)
            .await;
    }
    record.transition.execution_state = TaskBoardExecutionState::RetryWait;
    record.available_at = Some(retry.available_at.clone());
    record.artifacts.retry = Some(retry);
    record.artifacts.diagnostics.push(diagnostic);
    record.updated_at = canonical_time(updated_at)?;
    db.compare_and_set_workflow_execution(expected, &record)
        .await
}

/// Resumes a retry-wait execution once its availability time has arrived.
///
/// # Errors
/// Returns [`CliError`] when timestamps are invalid or persistence fails.
pub async fn resume_workflow_retry(
    db: &impl WorkflowExecutionStore,
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
    db.compare_and_set_workflow_execution(expected, &record)
        .await
}

/// Validates and creates one execution attempt.
///
/// # Errors
/// Returns [`CliError`] when the parent is absent, the phase is invalid, or persistence fails.
pub async fn create_workflow_execution_attempt(
    db: &impl WorkflowExecutionStore,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> Result<TaskBoardExecutionAttemptCreateOutcome, CliError> {
    let execution = db
        .workflow_execution(&attempt.execution_id)
        .await?
        .ok_or_else(|| invalid_transition("workflow execution does not exist"))?;
    validate_attempt_phase(&execution, attempt)?;
    db.create_execution_attempt(attempt).await
}

/// Validates and compare-and-sets one execution attempt.
///
/// # Errors
/// Returns [`CliError`] when the parent is absent, the phase is invalid, or persistence fails.
pub async fn record_workflow_execution_attempt(
    db: &impl WorkflowExecutionStore,
    expected: &TaskBoardExecutionAttemptCas,
    updated: &TaskBoardExecutionAttemptRecord,
) -> Result<TaskBoardExecutionAttemptCasOutcome, CliError> {
    let execution = db
        .workflow_execution(&expected.execution_id)
        .await?
        .ok_or_else(|| invalid_transition("workflow execution does not exist"))?;
    if execution
        .attempts
        .iter()
        .any(|current| attempt_replay_matches(expected, current, updated))
    {
        return db
            .compare_and_set_execution_attempt(expected, updated)
            .await;
    }
    validate_attempt_phase(&execution, updated)?;
    db.compare_and_set_execution_attempt(expected, updated)
        .await
}

/// Loads an execution only when its compare-and-set fence still matches.
///
/// # Errors
/// Returns [`CliError`] when persistence cannot load the execution.
pub async fn guarded_execution(
    db: &impl WorkflowExecutionStore,
    expected: &TaskBoardWorkflowExecutionCas,
) -> Result<Option<TaskBoardWorkflowExecutionRecord>, CliError> {
    let current = db.workflow_execution(&expected.execution_id).await?;
    Ok(current.filter(|record| cas_matches(expected, record)))
}

/// Produces the durable stale outcome for a failed compare-and-set fence.
///
/// # Errors
/// Returns [`CliError`] when persistence cannot load or screen the execution.
pub async fn stale_outcome(
    db: &impl WorkflowExecutionStore,
    expected: &TaskBoardWorkflowExecutionCas,
) -> Result<TaskBoardWorkflowExecutionCasOutcome, CliError> {
    let current = db.workflow_execution(&expected.execution_id).await?;
    let Some(current) = current else {
        return Ok(TaskBoardWorkflowExecutionCasOutcome::Stale {
            mismatch: TaskBoardWorkflowCasMismatch::ExecutionId,
            current: None,
        });
    };
    db.compare_and_set_workflow_execution(expected, &current)
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
                cycle.decision == Some(TaskBoardReviewRoundDecision::Approved)
            });
            evidence_or_wait(record, approved, "review_evidence_pending", updated_at)
        }
        Some(TaskBoardExecutionPhase::Implementation) => {
            let action = format!("implementation:{}", record.artifacts.current_revision_cycle);
            let triage_continues =
                record
                    .artifacts
                    .dependency_triage
                    .as_ref()
                    .is_some_and(|route| {
                        route.status
                            == harness_task_board::TaskBoardDependencyRouteStatus::ReadyToContinue
                    });
            let present = triage_continues
                || completed_attempt(record, &action, ArtifactKind::Implementation);
            evidence_or_wait(
                record,
                present,
                "implementation_evidence_pending",
                updated_at,
            )
        }
        Some(TaskBoardExecutionPhase::Evaluate) => {
            let action = if record.snapshot.workflow_kind.is_write() {
                format!("evaluate:{}", record.artifacts.current_revision_cycle)
            } else {
                "evaluate".into()
            };
            let present = completed_attempt(record, &action, ArtifactKind::Evaluation);
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
        Some(TaskBoardExecutionPhase::Planning | TaskBoardExecutionPhase::AwaitingApproval) => {
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
    Implementation,
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
    use TaskBoardAttemptResultArtifact::{Evaluation, Implementation, Lifecycle};
    match (attempt.artifact.as_ref(), kind) {
        (Some(Implementation(_)), ArtifactKind::Implementation)
        | (Some(Lifecycle(_)), ArtifactKind::Lifecycle) => true,
        (Some(Evaluation(result)), ArtifactKind::Evaluation) => {
            result.verdict == TaskBoardPhaseVerdict::Pass
        }
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

pub fn require_human(
    record: &mut TaskBoardWorkflowExecutionRecord,
    reason: &str,
    updated_at: &str,
) {
    record.transition.execution_state = TaskBoardExecutionState::HumanRequired;
    record.blocked_reason = Some(reason.to_owned());
    record.available_at = None;
    updated_at.clone_into(&mut record.updated_at);
}
