use crate::agents::turn::{
    AgentTurnPullRequest, AgentTurnPullRequestContext, AgentTurnReadOnlyContent,
};
use crate::daemon::agent_acp::dependency_triage_prompt;
use crate::daemon::db::{AgentTurnRunSnapshot, AgentTurnRunStatus, AsyncDaemonDb};
use crate::task_board::{
    TASK_BOARD_DEPENDENCY_TRIAGE_MODEL, TaskBoardAttemptResultArtifact, TaskBoardAttemptState,
    TaskBoardExecutionAttemptRecord, TaskBoardExecutionState, TaskBoardWorkflowExecutionRecord,
    compile_task_board_dependency_route, parse_task_board_dependency_triage_result,
};
use harness_kernel::errors::{CliError, CliErrorKind};

use super::super::task_board_read_only_runtime::{AgentTurnReportStart, TaskBoardReadOnlyRuntime};
use super::attempts::{require_human, set_execution_state, settlement_is_current};
use super::report_starts::claim_report_side_effect;
use super::reports::{
    current_attempt, mark_unknown, record_retry_or_human, report_claim_verification_due,
    transition_attempt,
};
use super::requests::run_context;
use crate::daemon::db::task_board::prelude::*;

pub(super) const DEPENDENCY_TRIAGE_ACTION: &str = "dependency_triage";

pub(super) async fn reconcile<R>(
    db: &AsyncDaemonDb,
    runtime: &R,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    allow_start: bool,
    now: &str,
) -> Result<(), CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    let run = runtime
        .load_agent_turn_report_run(&attempt.idempotency_key)
        .await?;
    match run {
        Some(run) if run.status.is_active() => mark_running(db, execution, attempt, now).await,
        Some(run) => settle_terminal(db, execution, attempt, &run, now).await,
        None if attempt.state == TaskBoardAttemptState::Running => {
            if !report_claim_verification_due(attempt, now)? {
                return Ok(());
            }
            mark_unknown(
                db,
                execution,
                attempt,
                now,
                "durable dependency triage run is missing",
            )
            .await
        }
        None if !allow_start => Ok(()),
        None => start(db, runtime, execution, attempt, now).await,
    }
}

async fn start<R>(
    db: &AsyncDaemonDb,
    runtime: &R,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    now: &str,
) -> Result<(), CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    let Some(claimed) = claim_report_side_effect(db, attempt, now).await? else {
        return Ok(());
    };
    let context = run_context(execution)?;
    let pull_request = pull_request_context(execution)?;
    let start = AgentTurnReportStart {
        runtime: "openrouter",
        session_id: &context.session_id,
        project_dir: Some(context.worktree.clone()),
        prompt: dependency_triage_prompt(),
        requested_model: Some(TASK_BOARD_DEPENDENCY_TRIAGE_MODEL.into()),
        pull_request: Some(pull_request),
        run_id: &claimed.idempotency_key,
        board_item_id: &execution.item_id,
        workflow_execution_id: &execution.execution_id,
    };
    if let Err(error) = runtime.start_agent_turn_report_run(start).await {
        match runtime
            .load_agent_turn_report_run(&claimed.idempotency_key)
            .await
        {
            Ok(Some(_)) => {}
            Ok(None) => {
                if settlement_is_current(db, &execution.execution_id, now).await? {
                    record_retry_or_human(db, execution, &claimed, &error.to_string(), now).await?;
                }
                return Ok(());
            }
            Err(probe_error) => {
                tracing::warn!(
                    execution_id = %execution.execution_id,
                    idempotency_key = %claimed.idempotency_key,
                    error = %error,
                    probe_error = %probe_error,
                    "failed to start and re-probe dependency triage; retaining the claim for grace recovery"
                );
                return Ok(());
            }
        }
    }
    db.complete_task_board_workflow_dispatch_start(&execution.execution_id)
        .await?;
    set_execution_state(
        db,
        &execution.execution_id,
        TaskBoardExecutionState::Running,
        now,
    )
    .await
}

fn pull_request_context(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<AgentTurnPullRequestContext, CliError> {
    let pull_request = execution.transition.pull_request.as_ref().ok_or_else(|| {
        CliErrorKind::invalid_transition("dependency triage has no frozen pull request")
    })?;
    let head_revision = execution
        .transition
        .exact_head_revision
        .clone()
        .ok_or_else(|| CliErrorKind::invalid_transition("dependency triage has no exact head"))?;
    let identity = AgentTurnPullRequest {
        repository: pull_request.repository.clone(),
        number: pull_request.number,
        head_revision,
    };
    let body = run_context(execution)?.body.clone();
    Ok(AgentTurnPullRequestContext {
        pull_request: identity.clone(),
        content: AgentTurnReadOnlyContent {
            pull_request: identity,
            body,
        },
    })
}

async fn mark_running(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    now: &str,
) -> Result<(), CliError> {
    let current = current_attempt(db, attempt).await?;
    transition_attempt(
        db,
        &current,
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

async fn settle_terminal(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    run: &AgentTurnRunSnapshot,
    now: &str,
) -> Result<(), CliError> {
    let current = current_attempt(db, attempt).await?;
    match run.status {
        AgentTurnRunStatus::Completed => {
            let route = match parse_route(execution, run) {
                Ok(route) => route,
                Err(error) => {
                    mark_unknown(
                        db,
                        execution,
                        &current,
                        now,
                        &format!("invalid dependency triage result: {error}"),
                    )
                    .await?;
                    return Ok(());
                }
            };
            transition_attempt(
                db,
                &current,
                TaskBoardAttemptState::Completed,
                now,
                None,
                None,
                Some(TaskBoardAttemptResultArtifact::DependencyTriage(Box::new(
                    route,
                ))),
            )
            .await?;
            set_execution_state(
                db,
                &execution.execution_id,
                TaskBoardExecutionState::Pending,
                now,
            )
            .await
        }
        AgentTurnRunStatus::Failed => {
            record_retry_or_human(
                db,
                execution,
                &current,
                run.error.as_deref().unwrap_or("dependency triage failed"),
                now,
            )
            .await
        }
        AgentTurnRunStatus::Cancelled => {
            transition_attempt(
                db,
                &current,
                TaskBoardAttemptState::Cancelled,
                now,
                None,
                Some("dependency triage was cancelled"),
                None,
            )
            .await?;
            if !settlement_is_current(db, &execution.execution_id, now).await? {
                return Ok(());
            }
            require_human(
                db,
                &execution.execution_id,
                "dependency_triage_cancelled",
                "dependency triage was cancelled without route evidence",
                crate::task_board::TaskBoardTerminalOutcomeKind::HumanRequired,
                now,
            )
            .await
        }
        AgentTurnRunStatus::Queued | AgentTurnRunStatus::Running => Ok(()),
    }
}

fn parse_route(
    execution: &TaskBoardWorkflowExecutionRecord,
    run: &AgentTurnRunSnapshot,
) -> Result<crate::task_board::TaskBoardDependencyRouteRecord, CliError> {
    let pull_request = execution.transition.pull_request.as_ref().ok_or_else(|| {
        CliErrorKind::invalid_transition("dependency triage has no frozen pull request")
    })?;
    let head = execution
        .transition
        .exact_head_revision
        .as_deref()
        .ok_or_else(|| CliErrorKind::invalid_transition("dependency triage has no exact head"))?;
    if run.requested_model.as_deref() != Some(TASK_BOARD_DEPENDENCY_TRIAGE_MODEL)
        || run.actual_model.as_deref() != Some(TASK_BOARD_DEPENDENCY_TRIAGE_MODEL)
        || run.source_revision.as_deref() != Some(head)
        || run.stop_reason.as_deref() != Some("end_turn")
    {
        return Err(CliErrorKind::workflow_parse(
            "dependency triage result is not bound to the requested model and exact head",
        )
        .into());
    }
    let result = parse_task_board_dependency_triage_result(
        run.report.as_deref().unwrap_or_default(),
        &pull_request.repository,
        pull_request.number,
        head,
    )
    .map_err(|error| CliErrorKind::workflow_parse(error.to_string()))?;
    compile_task_board_dependency_route(
        &result,
        &pull_request.repository,
        pull_request.number,
        head,
    )
}
