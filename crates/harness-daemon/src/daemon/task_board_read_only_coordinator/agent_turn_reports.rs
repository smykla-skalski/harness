//! Reconciles durable agent-turn review attempts and terminal evidence.

use crate::agents::turn::{
    AgentTurnPullRequest, AgentTurnPullRequestContext, AgentTurnReadOnlyContent,
};
use crate::daemon::db::{AgentTurnRunSnapshot, AgentTurnRunStatus, AsyncDaemonDb};
use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardAttemptState, TaskBoardExecutionAttemptRecord,
    TaskBoardExecutionState, TaskBoardFailureClass, TaskBoardPhaseVerdict,
    TaskBoardReportOnlyReviewRequest, TaskBoardReviewResult, TaskBoardReviewerOutcome,
    TaskBoardTerminalOutcomeKind, TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind,
    complete_task_board_report_only_review,
};
use harness_kernel::errors::{CliError, CliErrorKind};
use crate::daemon::db::task_board::prelude::*;

const SUPPORTED_AGENT_TURN_RUNTIMES: [&str; 1] = ["openrouter"];

use super::super::task_board_read_only_runtime::{AgentTurnReportStart, TaskBoardReadOnlyRuntime};
use super::attempts::{require_human, set_execution_state, settlement_is_current};
use super::report_starts::{claim_report_side_effect, refuse_unrenderable_request};
use super::reports::{
    current_attempt, mark_unknown, record_retry_or_human, report_claim_verification_due,
    transition_attempt,
};
use super::requests::{codex_attempt_request, run_context};

pub(super) async fn reconcile_agent_turn_report_attempt<R>(
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
    if !SUPPORTED_AGENT_TURN_RUNTIMES.contains(&runtime_name) {
        refuse_unsupported_runtime(db, execution, attempt, runtime_name, now).await?;
        return Ok(true);
    }
    match runtime
        .load_agent_turn_report_run(&attempt.idempotency_key)
        .await?
    {
        Some(run) => {
            reconcile_loaded_run(db, execution, attempt, run, runtime_name, now).await?;
            Ok(true)
        }
        None if attempt.state == TaskBoardAttemptState::Running => {
            if !report_claim_verification_due(attempt, now)? {
                return Ok(false);
            }
            mark_unknown(
                db,
                execution,
                attempt,
                now,
                "durable agent-turn run is missing",
            )
            .await?;
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
    let request = match codex_attempt_request(execution, attempt) {
        Ok(request) => request,
        Err(error) => {
            refuse_unrenderable_request(db, execution, attempt, now, &error).await?;
            return Ok(false);
        }
    };
    let context = match run_context(execution) {
        Ok(context) => context,
        Err(error) => {
            settle_preflight_error(db, execution, attempt, &error, now).await?;
            return Ok(false);
        }
    };
    let (prompt, pull_request) = match prepare_prompt(runtime, execution, request.prompt).await {
        Ok(prepared) => prepared,
        Err(error) => {
            settle_preflight_error(db, execution, attempt, &error, now).await?;
            return Ok(false);
        }
    };
    let Some(claimed) = claim_report_side_effect(db, attempt, now).await? else {
        return Ok(false);
    };
    let start = AgentTurnReportStart {
        runtime: runtime_name,
        session_id: context.session_id.as_str(),
        project_dir: Some(context.worktree.clone()),
        prompt,
        requested_model: request.model,
        pull_request,
        run_id: &claimed.idempotency_key,
        board_item_id: &execution.item_id,
        workflow_execution_id: &execution.execution_id,
    };
    match runtime.start_agent_turn_report_run(start).await {
        Ok(()) => Ok(true),
        Err(error) => reconcile_start_error(db, execution, &claimed, &error, now).await,
    }
}

async fn prepare_prompt<R>(
    runtime: &R,
    execution: &TaskBoardWorkflowExecutionRecord,
    configured_prompt: String,
) -> Result<(String, Option<AgentTurnPullRequestContext>), CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    if execution.snapshot.workflow_kind != TaskBoardWorkflowKind::PrReview {
        return Ok((configured_prompt, None));
    }
    let pull_request = freeze_pull_request(runtime, execution).await?;
    let prompt = TaskBoardReportOnlyReviewRequest::task_prompt_for_head(
        pull_request.pull_request.head_revision.clone(),
    )
    .map_err(|error| CliErrorKind::invalid_transition(error.to_string()))?;
    Ok((prompt, Some(pull_request)))
}

async fn settle_preflight_error(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    error: &CliError,
    now: &str,
) -> Result<(), CliError> {
    if settlement_is_current(db, &execution.execution_id, now).await? {
        let attempt = current_attempt(db, attempt).await?;
        record_retry_or_human(db, execution, &attempt, &error.to_string(), now).await?;
    }
    Ok(())
}

async fn freeze_pull_request<R>(
    runtime: &R,
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<AgentTurnPullRequestContext, CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    let pull_request = execution.transition.pull_request.as_ref().ok_or_else(|| {
        CliErrorKind::invalid_transition("requested-review attempt has no frozen pull request")
    })?;
    let head_revision = execution
        .transition
        .exact_head_revision
        .as_deref()
        .ok_or_else(|| {
            CliErrorKind::invalid_transition("requested-review attempt has no exact head")
        })?
        .to_string();
    let identity = AgentTurnPullRequest {
        repository: pull_request.repository.clone(),
        number: pull_request.number,
        head_revision: head_revision.clone(),
    };
    let body = runtime
        .immutable_pull_request_content(&identity.repository, identity.number, &head_revision)
        .await?;
    Ok(AgentTurnPullRequestContext {
        pull_request: identity.clone(),
        content: AgentTurnReadOnlyContent {
            pull_request: identity,
            body,
        },
    })
}

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

async fn reconcile_loaded_run(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    mut run: AgentTurnRunSnapshot,
    runtime_name: &str,
    now: &str,
) -> Result<(), CliError> {
    if let Err(error) = validate_run_binding(&run, execution, attempt, runtime_name) {
        let detail = error.to_string();
        if run.status.is_active() {
            run.status = AgentTurnRunStatus::Failed;
            run.error = Some(detail.clone());
            run.updated_at = now.to_owned();
            db.save_agent_turn_run(&run).await?;
        }
        settle_invalid_run(db, execution, attempt, &run, &detail, now).await?;
        return Ok(());
    }
    if run.status.is_active() {
        return mark_running(db, execution, attempt, now).await;
    }
    settle_terminal_run(db, execution, attempt, &run, runtime_name, now).await
}

fn validate_run_binding(
    run: &AgentTurnRunSnapshot,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    runtime_name: &str,
) -> Result<(), CliError> {
    let context = run_context(execution)?;
    let profile = harness_task_board_codex_requests::attempt_profile(execution, attempt)?;
    let source_matches = execution.snapshot.workflow_kind != TaskBoardWorkflowKind::PrReview
        || run.source_revision.as_deref() == execution.transition.exact_head_revision.as_deref();
    let valid = run.run_id == attempt.idempotency_key
        && run.session_id.as_deref() == Some(context.session_id.as_str())
        && run.task_id.is_none()
        && run.board_item_id.as_deref() == Some(execution.item_id.as_str())
        && run.workflow_execution_id.as_deref() == Some(execution.execution_id.as_str())
        && run.project_dir.as_deref() == Some(context.worktree.as_str())
        && run.requested_runtime == runtime_name
        && run.actual_runtime.as_deref() == Some(runtime_name)
        && run.requested_model == profile.model
        && source_matches;
    if valid {
        Ok(())
    } else {
        Err(super::attempts::invalid_transition(
            "durable agent-turn run does not match the frozen workflow attempt binding",
        ))
    }
}

async fn settle_terminal_run(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    run: &AgentTurnRunSnapshot,
    runtime_name: &str,
    now: &str,
) -> Result<(), CliError> {
    let attempt = &current_attempt(db, attempt).await?;
    match run.status {
        AgentTurnRunStatus::Completed => {
            settle_completed_run(db, execution, attempt, run, runtime_name, now).await
        }
        AgentTurnRunStatus::Failed => {
            let detail = run
                .error
                .as_deref()
                .unwrap_or("agent-turn report run failed");
            super::review_report_retention::retain_failed_agent_turn_review_run(
                db, execution, attempt, run, detail,
            )
            .await?;
            if !settlement_is_current(db, &execution.execution_id, now).await? {
                return Ok(());
            }
            record_retry_or_human(db, execution, attempt, detail, now).await
        }
        AgentTurnRunStatus::Cancelled => {
            let reason = run
                .stop_reason
                .as_deref()
                .or(run.error.as_deref())
                .unwrap_or("agent-turn report run was cancelled");
            super::review_report_retention::retain_cancelled_agent_turn_review_run(
                db, execution, attempt, run, reason,
            )
            .await?;
            transition_attempt(
                db,
                attempt,
                TaskBoardAttemptState::Cancelled,
                now,
                None,
                Some(reason),
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
        AgentTurnRunStatus::Queued | AgentTurnRunStatus::Running => Ok(()),
    }
}

async fn settle_completed_run(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    run: &AgentTurnRunSnapshot,
    runtime_name: &str,
    now: &str,
) -> Result<(), CliError> {
    let result = completed_run_result(execution, attempt, run, runtime_name);
    let result = match result {
        Ok(result) => result,
        Err(error) => {
            settle_invalid_run(db, execution, attempt, run, &error.to_string(), now).await?;
            return Ok(());
        }
    };
    super::review_report_retention::retain_completed_agent_turn_review_run(
        db, execution, attempt, run, &result.0,
    )
    .await?;
    transition_attempt(
        db,
        attempt,
        TaskBoardAttemptState::Completed,
        now,
        None,
        None,
        Some(result.1),
    )
    .await
    .map(|_| ())
}

fn completed_run_result(
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    run: &AgentTurnRunSnapshot,
    runtime_name: &str,
) -> Result<
    (
        crate::task_board::TaskBoardReportOnlyReviewReport,
        TaskBoardAttemptResultArtifact,
    ),
    CliError,
> {
    let profile = harness_task_board_codex_requests::attempt_profile(execution, attempt)?;
    let effective_model = run.actual_model.as_deref().ok_or_else(|| {
        super::attempts::invalid_transition("completed review run has no effective model")
    })?;
    if profile
        .model
        .as_deref()
        .is_some_and(|requested| requested != effective_model)
    {
        return Err(super::attempts::invalid_transition(
            "completed review run used a different effective model",
        ));
    }
    let requested_model = profile.model.as_deref().unwrap_or("provider-default");
    let head_revision = execution
        .transition
        .exact_head_revision
        .as_deref()
        .ok_or_else(|| {
            super::attempts::invalid_transition("completed review has no frozen head")
        })?;
    let output = run.report.as_deref().ok_or_else(|| {
        super::attempts::invalid_transition("completed agent-turn run has no report output")
    })?;
    let report = complete_task_board_report_only_review(
        head_revision,
        runtime_name,
        requested_model,
        effective_model,
        output.trim(),
    )
    .map_err(|error| super::attempts::invalid_transition(error.to_string()))?;
    let verdict = if report.findings.is_empty() {
        TaskBoardPhaseVerdict::Pass
    } else {
        TaskBoardPhaseVerdict::ChangesRequired
    };
    let profile_id = attempt
        .action_key
        .strip_prefix("review:")
        .ok_or_else(|| super::attempts::invalid_transition("review attempt has no profile"))?;
    let artifact = TaskBoardAttemptResultArtifact::Review(TaskBoardReviewerOutcome {
        profile_id: profile_id.to_owned(),
        result: TaskBoardReviewResult {
            verdict,
            head_revision: report.head_revision.clone(),
            summary: report.summary.clone(),
            findings: Vec::new(),
            structured_findings: report.findings.clone(),
        },
    });
    Ok((report, artifact))
}

async fn settle_invalid_run(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    run: &AgentTurnRunSnapshot,
    detail: &str,
    now: &str,
) -> Result<(), CliError> {
    super::review_report_retention::retain_failed_agent_turn_review_run(
        db, execution, attempt, run, detail,
    )
    .await?;
    let attempt = &current_attempt(db, attempt).await?;
    transition_attempt(
        db,
        attempt,
        TaskBoardAttemptState::Failed,
        now,
        Some(TaskBoardFailureClass::Permanent),
        Some(detail),
        None,
    )
    .await?;
    require_human(
        db,
        &execution.execution_id,
        "invalid_attempt_result",
        "agent-turn runtime returned invalid or mismatched workflow result evidence",
        TaskBoardTerminalOutcomeKind::HumanRequired,
        now,
    )
    .await
}
