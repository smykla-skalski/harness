use chrono::{DateTime, Utc};

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{CodexRunMode, CodexRunSnapshot, CodexRunStatus};
use harness_kernel::errors::CliError;
use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardAttemptRetryDecision, TaskBoardAttemptState,
    TaskBoardExecutionAttemptCas, TaskBoardExecutionAttemptCasOutcome,
    TaskBoardExecutionAttemptRecord, TaskBoardExecutionDiagnostic, TaskBoardExecutionState,
    TaskBoardFailureClass, TaskBoardTerminalOutcomeKind, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionRecord, task_board_attempt_retry_decision,
};

use super::super::task_board_read_only_runtime::TaskBoardReadOnlyRuntime;
use super::attempts::{invalid_transition, require_human, set_execution_state};
use super::report_starts::start_new_report_run;
use super::requests::attempt_run_identity;

#[expect(
    clippy::cognitive_complexity,
    reason = "flat match resolving the durable run snapshot; each arm is one terminal attempt outcome"
)]
pub(super) async fn reconcile_report_attempt<R>(
    db: &AsyncDaemonDb,
    runtime: &R,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    allow_start: bool,
    now: &str,
) -> Result<bool, CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    // Only a new run needs the prompt. Finding an existing one and confirming
    // it are structural, so they must not render: an attempt that has already
    // finished has to be harvestable no matter what the prompt file says now.
    let identity = attempt_run_identity(execution, attempt)?;
    let run = load_codex_run(runtime, identity.mode, &attempt.idempotency_key).await?;
    let run = match run {
        Some(run) => run,
        None if attempt.state == TaskBoardAttemptState::Running => {
            if !report_claim_verification_due(attempt, now)? {
                return Ok(false);
            }
            mark_unknown(db, execution, attempt, now, "durable Codex run is missing").await?;
            return Ok(true);
        }
        None if !allow_start => return Ok(false),
        None => {
            let Some(run) =
                Box::pin(start_new_report_run(db, runtime, execution, attempt, now)).await?
            else {
                return Ok(true);
            };
            run
        }
    };
    let durable_attempt = current_attempt(db, attempt).await?;
    if let Err(error) =
        super::report_evidence::validate_run_binding(&run, execution, &durable_attempt, &identity)
    {
        mark_unknown(db, execution, &durable_attempt, now, &error.to_string()).await?;
        return Ok(true);
    }
    db.complete_task_board_workflow_dispatch_start(&execution.execution_id)
        .await?;
    handle_run_status(db, execution, &durable_attempt, run, now).await?;
    Ok(true)
}

pub(super) async fn load_codex_run<R>(
    runtime: &R,
    mode: CodexRunMode,
    run_id: &str,
) -> Result<Option<CodexRunSnapshot>, CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    match mode {
        CodexRunMode::Report => runtime.load_codex_report_run(run_id).await,
        CodexRunMode::WorkspaceWrite => runtime.load_codex_workspace_run(run_id).await,
        CodexRunMode::Approval => Err(invalid_transition(
            "workflow attempts do not admit Codex Approval mode",
        )),
    }
}

fn report_claim_verification_due(
    attempt: &TaskBoardExecutionAttemptRecord,
    now: &str,
) -> Result<bool, CliError> {
    let Some(deadline) = attempt.available_at.as_deref() else {
        return Ok(true);
    };
    let deadline = DateTime::parse_from_rfc3339(deadline)
        .map_err(|error| invalid_transition(format!("invalid report claim deadline: {error}")))?;
    let now = DateTime::parse_from_rfc3339(now)
        .map_err(|error| invalid_transition(format!("invalid report recovery time: {error}")))?;
    Ok(now >= deadline)
}

#[expect(
    clippy::cognitive_complexity,
    reason = "flat match over codex run status; each arm handles one status variant"
)]
async fn handle_run_status(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    run: CodexRunSnapshot,
    now: &str,
) -> Result<(), CliError> {
    match run.status {
        CodexRunStatus::Queued | CodexRunStatus::Running | CodexRunStatus::WaitingApproval => {
            transition_attempt(
                db,
                attempt,
                TaskBoardAttemptState::Running,
                now,
                None,
                None,
                None,
            )
            .await?;
            set_execution_state(
                db,
                &execution.execution_id,
                TaskBoardExecutionState::Running,
                now,
            )
            .await
        }
        CodexRunStatus::Completed => {
            super::report_evidence::accept_completed_run(db, execution, attempt, &run, now).await?;
            super::attempts::settlement_is_current(db, &execution.execution_id, now).await?;
            Ok(())
        }
        CodexRunStatus::Failed => {
            if !super::attempts::settlement_is_current(db, &execution.execution_id, now).await? {
                return Ok(());
            }
            let detail = run.error.as_deref().unwrap_or("Codex Report run failed");
            record_retry_or_human(db, execution, attempt, detail, now).await
        }
        CodexRunStatus::Cancelled => {
            transition_attempt(
                db,
                attempt,
                TaskBoardAttemptState::Cancelled,
                now,
                None,
                Some("Codex Report run was cancelled"),
                None,
            )
            .await?;
            if !super::attempts::settlement_is_current(db, &execution.execution_id, now).await? {
                return Ok(());
            }
            require_human(
                db,
                &execution.execution_id,
                "report_attempt_cancelled",
                "read-only report attempt was cancelled without result evidence",
                TaskBoardTerminalOutcomeKind::HumanRequired,
                now,
            )
            .await
        }
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "two-arm match over retry decision; each arm is a short transition-then-notify sequence"
)]
pub(super) async fn record_retry_or_human(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    detail: &str,
    now: &str,
) -> Result<(), CliError> {
    let settings = db.task_board_orchestrator_settings_snapshot().await?;
    let timestamp = DateTime::parse_from_rfc3339(now)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| invalid_transition(format!("invalid retry timestamp: {error}")))?;
    let decision = task_board_attempt_retry_decision(
        &settings.settings.retry,
        &format!("{}:{}", execution.execution_id, attempt.action_key),
        &attempt.action_key,
        attempt.attempt,
        TaskBoardFailureClass::Transient,
        timestamp,
    );
    match decision {
        TaskBoardAttemptRetryDecision::Retry(retry) => {
            transition_attempt(
                db,
                attempt,
                TaskBoardAttemptState::RetryWait,
                now,
                Some(TaskBoardFailureClass::Transient),
                Some(detail),
                None,
            )
            .await?;
            let current = db
                .task_board_workflow_execution(&execution.execution_id)
                .await?
                .ok_or_else(|| invalid_transition("workflow execution disappeared"))?;
            super::super::task_board_workflow_execution::schedule_workflow_retry(
                db,
                &TaskBoardWorkflowExecutionCas::from(&current),
                retry,
                TaskBoardExecutionDiagnostic {
                    code: "report_attempt_failed".into(),
                    message: detail.to_string(),
                    recorded_at: now.to_string(),
                },
                now,
            )
            .await?;
            Ok(())
        }
        TaskBoardAttemptRetryDecision::HumanRequired => {
            transition_attempt(
                db,
                attempt,
                TaskBoardAttemptState::Failed,
                now,
                Some(TaskBoardFailureClass::Transient),
                Some(detail),
                None,
            )
            .await?;
            require_human(
                db,
                &execution.execution_id,
                "report_attempts_exhausted",
                "read-only report attempts exhausted the deterministic retry policy",
                TaskBoardTerminalOutcomeKind::HumanRequired,
                now,
            )
            .await
        }
    }
}

async fn mark_unknown(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    now: &str,
    detail: &str,
) -> Result<(), CliError> {
    transition_attempt(
        db,
        attempt,
        TaskBoardAttemptState::Unknown,
        now,
        Some(TaskBoardFailureClass::UnknownOutcome),
        Some(detail),
        None,
    )
    .await?;
    require_human(
        db,
        &execution.execution_id,
        "attempt_outcome_unknown",
        "attempt result is unknown; success was not recorded",
        TaskBoardTerminalOutcomeKind::Unknown,
        now,
    )
    .await
}

#[expect(
    clippy::cognitive_complexity,
    reason = "sequential attempt-record builder followed by one flat match over the CAS outcome"
)]
pub(super) async fn transition_attempt(
    db: &AsyncDaemonDb,
    current: &TaskBoardExecutionAttemptRecord,
    state: TaskBoardAttemptState,
    now: &str,
    failure_class: Option<TaskBoardFailureClass>,
    error: Option<&str>,
    artifact: Option<TaskBoardAttemptResultArtifact>,
) -> Result<TaskBoardExecutionAttemptRecord, CliError> {
    if current.state == state
        && current.failure_class == failure_class
        && current.error.as_deref() == error
        && current.artifact == artifact
    {
        return Ok(current.clone());
    }
    let mut updated = current.clone();
    updated.state = state;
    updated.failure_class = failure_class;
    updated.error = error.map(str::to_owned);
    updated.artifact = artifact;
    updated.updated_at = now.to_string();
    updated.available_at = None;
    if state == TaskBoardAttemptState::RetryWait {
        updated.available_at = retry_wait_available_at(db, current, failure_class, now).await?;
    }
    if matches!(
        state,
        TaskBoardAttemptState::Completed
            | TaskBoardAttemptState::Failed
            | TaskBoardAttemptState::Cancelled
    ) {
        updated.completed_at = Some(now.to_string());
    }
    let outcome = super::super::task_board_workflow_execution::record_workflow_execution_attempt(
        db,
        &TaskBoardExecutionAttemptCas::from(current),
        &updated,
    )
    .await?;
    match outcome {
        TaskBoardExecutionAttemptCasOutcome::Updated(record)
        | TaskBoardExecutionAttemptCasOutcome::Unchanged(record) => Ok(record),
        TaskBoardExecutionAttemptCasOutcome::Stale(Some(record)) if record == updated => Ok(record),
        TaskBoardExecutionAttemptCasOutcome::Stale(_) => {
            Err(invalid_transition("workflow attempt CAS became stale"))
        }
    }
}

/// The retry policy decides when a `RetryWait` attempt becomes eligible again.
/// `Ok(None)` leaves the attempt without a deadline, which is what a policy that
/// declines to retry means here.
async fn retry_wait_available_at(
    db: &AsyncDaemonDb,
    current: &TaskBoardExecutionAttemptRecord,
    failure_class: Option<TaskBoardFailureClass>,
    now: &str,
) -> Result<Option<String>, CliError> {
    let settings = db.task_board_orchestrator_settings_snapshot().await?;
    let timestamp = DateTime::parse_from_rfc3339(now)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|parse| invalid_transition(format!("invalid retry timestamp: {parse}")))?;
    let decision = task_board_attempt_retry_decision(
        &settings.settings.retry,
        &format!("{}:{}", current.execution_id, current.action_key),
        &current.action_key,
        current.attempt,
        failure_class.unwrap_or(TaskBoardFailureClass::Transient),
        timestamp,
    );
    match decision {
        TaskBoardAttemptRetryDecision::Retry(retry) => Ok(Some(retry.available_at)),
        TaskBoardAttemptRetryDecision::HumanRequired => Ok(None),
    }
}

async fn current_attempt(
    db: &AsyncDaemonDb,
    expected: &TaskBoardExecutionAttemptRecord,
) -> Result<TaskBoardExecutionAttemptRecord, CliError> {
    db.task_board_workflow_execution(&expected.execution_id)
        .await?
        .and_then(|execution| {
            execution.attempts.into_iter().find(|attempt| {
                attempt.action_key == expected.action_key && attempt.attempt == expected.attempt
            })
        })
        .ok_or_else(|| invalid_transition("workflow attempt disappeared"))
}
