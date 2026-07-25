use chrono::{DateTime, Duration};

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{CodexRunMode, CodexRunRequest, CodexRunSnapshot};
use harness_kernel::errors::CliError;
use crate::task_board::{
    TASK_BOARD_SIDE_EFFECT_CLAIM_GRACE_SECONDS, TaskBoardAttemptState,
    TaskBoardExecutionAttemptCas, TaskBoardExecutionAttemptRecord, TaskBoardFailureClass,
    TaskBoardTerminalOutcomeKind, TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord,
};

use super::super::task_board_read_only_runtime::TaskBoardReadOnlyRuntime;
use super::attempts::{invalid_transition, require_human};
use super::reports::{load_codex_run, record_retry_or_human, transition_attempt};
use super::requests::{attempt_run_identity, codex_attempt_request, run_context};

/// Starts the Codex run backing a fresh attempt. `Ok(None)` means the attempt
/// was already settled here - refused, claimed by another reconciler, or handed
/// to grace recovery - so the caller has nothing left to reconcile this tick.
pub(super) async fn start_new_report_run<R>(
    db: &AsyncDaemonDb,
    runtime: &R,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    now: &str,
) -> Result<Option<CodexRunSnapshot>, CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    // Rendered before the claim so a refusal costs no side effect.
    let request = match codex_attempt_request(execution, attempt) {
        Ok(request) => request,
        Err(error) => {
            refuse_unrenderable_request(db, execution, attempt, now, &error).await?;
            return Ok(None);
        }
    };
    let Some(claimed) = claim_report_side_effect(db, attempt, now).await? else {
        return Ok(None);
    };
    let session_id = run_context(execution)?.session_id.as_str();
    match start_codex_run(runtime, session_id, &request, &claimed.idempotency_key).await {
        Ok(run) => Ok(Some(run)),
        Err(error) => {
            reconcile_report_start_error(db, runtime, execution, &claimed, &error, now).await
        }
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

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
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
    let identity = attempt_run_identity(execution, claimed)?;
    match load_codex_run(runtime, identity.mode, &claimed.idempotency_key).await {
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
    attempt: &TaskBoardExecutionAttemptRecord,
    now: &str,
) -> Result<Option<TaskBoardExecutionAttemptRecord>, CliError> {
    loop {
        let execution = db
            .task_board_workflow_execution(&attempt.execution_id)
            .await?
            .ok_or_else(|| {
                invalid_transition("workflow execution disappeared before report claim")
            })?;
        let current = execution
            .attempts
            .iter()
            .find(|current| {
                current.action_key == attempt.action_key && current.attempt == attempt.attempt
            })
            .ok_or_else(|| {
                invalid_transition("workflow attempt disappeared before report claim")
            })?;
        // The claim needs an execution target; when the remote controller has not selected one,
        // the coordinator selects local itself (a no-op once targeted or fenced by a remote
        // assignment). Selection advances the attempt to Starting, so reload before the claim.
        if current.state == TaskBoardAttemptState::Preparing
            && db
                .select_task_board_local_execution_target(
                    &TaskBoardWorkflowExecutionCas::from(&execution),
                    &TaskBoardExecutionAttemptCas::from(current),
                    now,
                )
                .await?
        {
            continue;
        }
        let mut claimed = current.clone();
        claimed.state = TaskBoardAttemptState::Running;
        claimed.updated_at = now.to_string();
        claimed.available_at = Some(report_claim_deadline(now)?);
        return db
            .claim_task_board_workflow_side_effect(
                &TaskBoardWorkflowExecutionCas::from(&execution),
                &TaskBoardExecutionAttemptCas::from(current),
                &claimed,
                now,
            )
            .await;
    }
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

/// A prompt that cannot render is a configuration mistake, not a transient
/// fault, and nothing was started. Retrying it on a backoff would only repeat
/// the same refusal, so the attempt fails permanently and says what to fix.
async fn refuse_unrenderable_request(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    now: &str,
    error: &CliError,
) -> Result<(), CliError> {
    transition_attempt(
        db,
        attempt,
        TaskBoardAttemptState::Failed,
        now,
        Some(TaskBoardFailureClass::Permanent),
        Some(&error.to_string()),
        None,
    )
    .await?;
    require_human(
        db,
        &execution.execution_id,
        "attempt_prompt_unrenderable",
        "the configured prompt for this attempt cannot be rendered",
        TaskBoardTerminalOutcomeKind::HumanRequired,
        now,
    )
    .await
}
