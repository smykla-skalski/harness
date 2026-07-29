use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::CodexRunSnapshot;
use crate::task_board::{
    TaskBoardAiReviewReportRecord, TaskBoardAiReviewReportStatus, TaskBoardExecutionAttemptRecord,
    TaskBoardReviewResult, TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind,
};
use harness_kernel::errors::CliError;

use super::attempts::invalid_transition;

pub(super) async fn retain_completed_review_run(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    run: &CodexRunSnapshot,
    result: &TaskBoardReviewResult,
) -> Result<(), CliError> {
    let Some(mut report) = review_report(
        execution,
        attempt,
        run,
        TaskBoardAiReviewReportStatus::Completed,
    )?
    else {
        return Ok(());
    };
    report.summary = Some(result.summary.clone());
    report.findings.clone_from(&result.structured_findings);
    if !result.findings.is_empty() {
        report.partial_output = Some(serde_json::to_string(&result.findings).map_err(|error| {
            invalid_transition(format!("serialize legacy AI review findings: {error}"))
        })?);
    }
    db.append_task_board_ai_review_report(&report).await?;
    Ok(())
}

pub(super) async fn retain_failed_review_run(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    run: &CodexRunSnapshot,
    reason: &str,
) -> Result<(), CliError> {
    retain_unsuccessful_review_run(
        db,
        execution,
        attempt,
        run,
        TaskBoardAiReviewReportStatus::Failed,
        reason,
    )
    .await
}

pub(super) async fn retain_cancelled_review_run(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    run: &CodexRunSnapshot,
    reason: &str,
) -> Result<(), CliError> {
    retain_unsuccessful_review_run(
        db,
        execution,
        attempt,
        run,
        TaskBoardAiReviewReportStatus::Cancelled,
        reason,
    )
    .await
}

async fn retain_unsuccessful_review_run(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    run: &CodexRunSnapshot,
    status: TaskBoardAiReviewReportStatus,
    reason: &str,
) -> Result<(), CliError> {
    let Some(mut report) = review_report(execution, attempt, run, status)? else {
        return Ok(());
    };
    report.partial_output = run
        .final_message
        .clone()
        .or_else(|| run.latest_summary.clone());
    report.terminal_reason = Some(reason.to_owned());
    db.append_task_board_ai_review_report(&report).await?;
    Ok(())
}

fn review_report(
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    run: &CodexRunSnapshot,
    status: TaskBoardAiReviewReportStatus,
) -> Result<Option<TaskBoardAiReviewReportRecord>, CliError> {
    if execution.snapshot.workflow_kind != TaskBoardWorkflowKind::PrReview
        || !attempt.action_key.starts_with("review:")
    {
        return Ok(None);
    }
    let Some(pull_request) = execution.transition.pull_request.as_ref() else {
        return Ok(None);
    };
    let profile = crate::daemon::task_board_codex_requests::attempt_profile(execution, attempt)?;
    let requested_model = profile
        .model
        .clone()
        .ok_or_else(|| invalid_transition("AI review report requires a frozen requested model"))?;
    let head_revision = execution
        .transition
        .exact_head_revision
        .clone()
        .ok_or_else(|| invalid_transition("AI review report requires a frozen exact head"))?;
    Ok(Some(TaskBoardAiReviewReportRecord {
        report_id: format!("review-report:{}", attempt.idempotency_key),
        item_id: execution.item_id.clone(),
        correlation_id: run.run_id.clone(),
        repository: pull_request.repository.clone(),
        pull_request_number: pull_request.number,
        head_revision,
        runtime: profile.runtime.clone(),
        requested_model,
        effective_model: run.model.clone(),
        status,
        summary: None,
        findings: Vec::new(),
        partial_output: None,
        terminal_reason: None,
        started_at: run.created_at.clone(),
        finished_at: run.updated_at.clone(),
    }))
}
