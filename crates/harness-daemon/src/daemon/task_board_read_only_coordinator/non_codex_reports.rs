//! Reconciles a report attempt whose reviewer profile names a non-Codex
//! runtime. Codex report runs live in `codex_runs`; a non-Codex runtime
//! (`openrouter` today) runs the shared turn through the `agent_turn_runs`
//! store instead, keyed to the attempt's managed run id.
//!
//! Slice A of #1001 wires selection and a durable start: the turn starts, is
//! recorded from the moment it starts, and a restart-settled failure resumes
//! the review exactly once. Harvesting a completed run's summary, findings, and
//! verdict is #895, so a completed run is left for that ingest rather than
//! settled here.

use crate::daemon::db::{AgentTurnRunStatus, AsyncDaemonDb};
use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionAttemptRecord, TaskBoardExecutionState,
    TaskBoardFailureClass, TaskBoardTerminalOutcomeKind, TaskBoardWorkflowExecutionRecord,
};
use harness_kernel::errors::CliError;

/// Non-Codex reviewer runtimes the coordinator can drive. Codex is handled by
/// its own path; anything outside this set is refused by name before any side
/// effect, so a stray or hand-edited profile never silently runs as Codex.
const SUPPORTED_NON_CODEX_RUNTIMES: [&str; 1] = ["openrouter"];

use super::super::task_board_read_only_runtime::{NonCodexReportStart, TaskBoardReadOnlyRuntime};
use super::attempts::{require_human, set_execution_state, settlement_is_current};
use super::report_starts::{claim_report_side_effect, refuse_unrenderable_request};
use super::reports::{
    current_attempt, mark_unknown, record_retry_or_human, report_claim_verification_due,
    transition_attempt,
};
use super::requests::{codex_attempt_request, run_context};

/// Reconcile one report attempt on a non-Codex runtime. `Ok(true)` means this
/// attempt was handled this tick; `Ok(false)` leaves it for the caller.
pub(super) async fn reconcile_non_codex_report_attempt<R>(
    db: &AsyncDaemonDb,
    runtime: &R,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    runtime_name: &str,
    allow_start: bool,
    now: &str,
) -> Result<bool, CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    if !SUPPORTED_NON_CODEX_RUNTIMES.contains(&runtime_name) {
        refuse_unsupported_runtime(db, execution, attempt, runtime_name, now).await?;
        return Ok(true);
    }
    match db.agent_turn_run(&attempt.idempotency_key).await? {
        Some(run) if run.status.is_active() => {
            mark_running(db, execution, attempt, now).await?;
            Ok(true)
        }
        Some(run) => {
            settle_terminal_run(db, execution, attempt, run.status, run.error.as_deref(), now)
                .await?;
            Ok(true)
        }
        None if attempt.state == TaskBoardAttemptState::Running => {
            if !report_claim_verification_due(attempt, now)? {
                return Ok(false);
            }
            mark_unknown(db, execution, attempt, now, "durable non-Codex run is missing").await?;
            Ok(true)
        }
        None if !allow_start => Ok(false),
        None => {
            if start_new_run(db, runtime, execution, attempt, runtime_name, now).await? {
                mark_running(db, execution, attempt, now).await?;
            }
            Ok(true)
        }
    }
}

/// An unsupported reviewer runtime is a configuration mistake, not a transient
/// fault, and nothing has been started. Fail the attempt permanently, naming the
/// runtime, so it is refused visibly instead of retried or run as Codex.
async fn refuse_unsupported_runtime(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    runtime_name: &str,
    now: &str,
) -> Result<(), CliError> {
    let detail = format!("reviewer runtime '{runtime_name}' is not a supported reviewer runtime");
    transition_attempt(
        db,
        attempt,
        TaskBoardAttemptState::Failed,
        now,
        Some(TaskBoardFailureClass::Permanent),
        Some(&detail),
        None,
    )
    .await?;
    require_human(
        db,
        &execution.execution_id,
        "reviewer_runtime_unsupported",
        &detail,
        TaskBoardTerminalOutcomeKind::HumanRequired,
        now,
    )
    .await
}

/// Claim the attempt's side effect, then start the runtime turn. `Ok(true)`
/// means the turn is durably recorded; `Ok(false)` means the attempt was
/// settled here (refused, claimed elsewhere, or handed to retry) with nothing
/// left to mark running this tick.
async fn start_new_run<R>(
    db: &AsyncDaemonDb,
    runtime: &R,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    runtime_name: &str,
    now: &str,
) -> Result<bool, CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    // Rendered before the claim so a refusal costs no side effect.
    let request = match codex_attempt_request(execution, attempt) {
        Ok(request) => request,
        Err(error) => {
            refuse_unrenderable_request(db, execution, attempt, now, &error).await?;
            return Ok(false);
        }
    };
    let Some(claimed) = claim_report_side_effect(db, attempt, now).await? else {
        return Ok(false);
    };
    let context = run_context(execution)?;
    let start = NonCodexReportStart {
        runtime: runtime_name,
        session_id: context.session_id.as_str(),
        project_dir: Some(context.worktree.clone()),
        prompt: request.prompt,
        requested_model: request.model,
        pull_request: None,
        run_id: &claimed.idempotency_key,
        board_item_id: &execution.item_id,
        workflow_execution_id: &execution.execution_id,
    };
    match runtime.start_non_codex_report_run(start).await {
        Ok(()) => Ok(true),
        Err(error) => reconcile_start_error(db, execution, &claimed, &error, now).await,
    }
}

/// A start error might still have recorded the run before it surfaced. Probe
/// the store: a recorded run is already tracked, otherwise fail the attempt
/// through the deterministic retry policy when the settlement is still current.
async fn reconcile_start_error(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    claimed: &TaskBoardExecutionAttemptRecord,
    start_error: &CliError,
    now: &str,
) -> Result<bool, CliError> {
    if db.agent_turn_run(&claimed.idempotency_key).await?.is_some() {
        return Ok(true);
    }
    if settlement_is_current(db, &execution.execution_id, now).await? {
        record_retry_or_human(db, execution, claimed, &start_error.to_string(), now).await?;
    }
    Ok(false)
}

async fn mark_running(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    now: &str,
) -> Result<(), CliError> {
    let durable_attempt = current_attempt(db, attempt).await?;
    transition_attempt(
        db,
        &durable_attempt,
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
    .await?;
    db.complete_task_board_workflow_dispatch_start(&execution.execution_id)
        .await
        .map(|_| ())
}

async fn settle_terminal_run(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    status: AgentTurnRunStatus,
    error: Option<&str>,
    now: &str,
) -> Result<(), CliError> {
    // Settle against the current attempt record, not the snapshot the tick was
    // seeded with, so a transition here does not fail its CAS against a row a
    // concurrent reconciler already moved. This mirrors the Codex report path.
    let attempt = &current_attempt(db, attempt).await?;
    match status {
        AgentTurnRunStatus::Failed => {
            if !settlement_is_current(db, &execution.execution_id, now).await? {
                return Ok(());
            }
            let detail = error.unwrap_or("non-Codex report run failed");
            record_retry_or_human(db, execution, attempt, detail, now).await
        }
        AgentTurnRunStatus::Cancelled => {
            transition_attempt(
                db,
                attempt,
                TaskBoardAttemptState::Cancelled,
                now,
                None,
                Some("non-Codex report run was cancelled"),
                None,
            )
            .await?;
            if !settlement_is_current(db, &execution.execution_id, now).await? {
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
        // A completed run is harvested by #895; slice A leaves it in place.
        // Queued/Running never reach here (the active branch handles them).
        AgentTurnRunStatus::Completed
        | AgentTurnRunStatus::Queued
        | AgentTurnRunStatus::Running => Ok(()),
    }
}
