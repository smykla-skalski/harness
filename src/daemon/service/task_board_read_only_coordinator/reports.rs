use chrono::{DateTime, Duration, Utc};

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{CodexRunMode, CodexRunRequest, CodexRunSnapshot, CodexRunStatus};
use crate::errors::CliError;
use crate::task_board::{
    TASK_BOARD_SIDE_EFFECT_CLAIM_GRACE_SECONDS, TaskBoardAttemptResultArtifact,
    TaskBoardAttemptRetryDecision, TaskBoardAttemptState, TaskBoardExecutionAttemptCas,
    TaskBoardExecutionAttemptCasOutcome, TaskBoardExecutionAttemptRecord,
    TaskBoardExecutionDiagnostic, TaskBoardExecutionState, TaskBoardFailureClass,
    TaskBoardTerminalOutcomeKind, TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord,
    task_board_attempt_retry_decision,
};

use super::super::task_board_read_only_runtime::TaskBoardReadOnlyRuntime;
use super::attempts::{invalid_transition, require_human, set_execution_state};
use super::requests::codex_attempt_request;

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
    let expected_request = codex_attempt_request(execution, attempt)?;
    let run = load_codex_run(runtime, expected_request.mode, &attempt.idempotency_key).await?;
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
            let starting = transition_attempt(
                db,
                attempt,
                TaskBoardAttemptState::Starting,
                now,
                None,
                None,
                None,
            )
            .await?;
            let Some(claimed) = claim_report_side_effect(db, &starting, now).await? else {
                return Ok(true);
            };
            let session_id = super::requests::run_context(execution)?.session_id.as_str();
            match start_codex_run(
                runtime,
                session_id,
                &expected_request,
                &claimed.idempotency_key,
            )
            .await
            {
                Ok(run) => run,
                Err(error) => {
                    let Some(run) =
                        reconcile_report_start_error(db, runtime, execution, &claimed, &error, now)
                            .await?
                    else {
                        return Ok(true);
                    };
                    run
                }
            }
        }
    };
    let durable_attempt = current_attempt(db, attempt).await?;
    if let Err(error) = super::report_evidence::validate_run_binding(
        &run,
        execution,
        &durable_attempt,
        &expected_request,
    ) {
        mark_unknown(db, execution, &durable_attempt, now, &error.to_string()).await?;
        return Ok(true);
    }
    handle_run_status(db, execution, &durable_attempt, run, now).await?;
    Ok(true)
}

async fn load_codex_run<R>(
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

async fn start_codex_run<R>(
    runtime: &R,
    session_id: &str,
    request: &CodexRunRequest,
    run_id: &str,
) -> Result<CodexRunSnapshot, CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    match request.mode {
        CodexRunMode::Report => {
            runtime
                .start_codex_report_run(session_id, request, run_id)
                .await
        }
        CodexRunMode::WorkspaceWrite => {
            runtime
                .start_codex_workspace_run(session_id, request, run_id)
                .await
        }
        CodexRunMode::Approval => Err(invalid_transition(
            "workflow attempts do not admit Codex Approval mode",
        )),
    }
}

async fn reconcile_report_start_error<R>(
    db: &AsyncDaemonDb,
    runtime: &R,
    execution: &TaskBoardWorkflowExecutionRecord,
    claimed: &TaskBoardExecutionAttemptRecord,
    start_error: &CliError,
    now: &str,
) -> Result<Option<CodexRunSnapshot>, CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    let request = codex_attempt_request(execution, claimed)?;
    match load_codex_run(runtime, request.mode, &claimed.idempotency_key).await {
        Ok(Some(run)) => Ok(Some(run)),
        Ok(None) => {
            if super::attempts::settlement_is_current(db, &execution.execution_id, now).await? {
                record_retry_or_human(db, execution, claimed, &start_error.to_string(), now)
                    .await?;
            }
            Ok(None)
        }
        Err(probe_error) => {
            tracing::warn!(
                execution_id = %execution.execution_id,
                idempotency_key = %claimed.idempotency_key,
                error = %start_error,
                probe_error = %probe_error,
                "failed to start and re-probe durable Codex report run; retaining the claim for grace recovery"
            );
            Ok(None)
        }
    }
}

async fn claim_report_side_effect(
    db: &AsyncDaemonDb,
    starting: &TaskBoardExecutionAttemptRecord,
    now: &str,
) -> Result<Option<TaskBoardExecutionAttemptRecord>, CliError> {
    let execution = db
        .task_board_workflow_execution(&starting.execution_id)
        .await?
        .ok_or_else(|| invalid_transition("workflow execution disappeared before report claim"))?;
    let current = execution
        .attempts
        .iter()
        .find(|attempt| {
            attempt.action_key == starting.action_key && attempt.attempt == starting.attempt
        })
        .ok_or_else(|| invalid_transition("workflow attempt disappeared before report claim"))?;
    let mut claimed = current.clone();
    claimed.state = TaskBoardAttemptState::Running;
    claimed.updated_at = now.to_string();
    claimed.available_at = Some(report_claim_deadline(now)?);
    db.claim_task_board_workflow_side_effect(
        &TaskBoardWorkflowExecutionCas::from(&execution),
        &TaskBoardExecutionAttemptCas::from(current),
        &claimed,
        now,
    )
    .await
}

fn report_claim_deadline(now: &str) -> Result<String, CliError> {
    let now = DateTime::parse_from_rfc3339(now)
        .map_err(|error| invalid_transition(format!("invalid report claim time: {error}")))?;
    now.checked_add_signed(Duration::seconds(
        TASK_BOARD_SIDE_EFFECT_CLAIM_GRACE_SECONDS,
    ))
    .ok_or_else(|| invalid_transition("report claim deadline is out of range"))
    .map(|deadline| deadline.to_rfc3339())
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
        let settings = db.task_board_orchestrator_settings_snapshot().await?;
        let timestamp = DateTime::parse_from_rfc3339(now)
            .map(|value| value.with_timezone(&Utc))
            .map_err(|parse| invalid_transition(format!("invalid retry timestamp: {parse}")))?;
        if let TaskBoardAttemptRetryDecision::Retry(retry) = task_board_attempt_retry_decision(
            &settings.settings.retry,
            &format!("{}:{}", current.execution_id, current.action_key),
            &current.action_key,
            current.attempt,
            failure_class.unwrap_or(TaskBoardFailureClass::Transient),
            timestamp,
        ) {
            updated.available_at = Some(retry.available_at);
        }
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
