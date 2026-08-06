use crate::daemon::db::AgentTurnRunSnapshot;
use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardExecutionAttemptRecord, TaskBoardPhaseVerdict,
    TaskBoardReviewResult, TaskBoardReviewerOutcome, TaskBoardWorkflowExecutionRecord,
    complete_task_board_report_only_review,
};
use harness_kernel::errors::CliError;

pub(super) fn completed_run_result(
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
        super::super::attempts::invalid_transition("completed review run has no effective model")
    })?;
    if profile
        .model
        .as_deref()
        .is_some_and(|requested| requested != effective_model)
    {
        return Err(super::super::attempts::invalid_transition(
            "completed review run used a different effective model",
        ));
    }
    let requested_model = profile.model.as_deref().unwrap_or("provider-default");
    let head_revision = execution
        .transition
        .exact_head_revision
        .as_deref()
        .ok_or_else(|| {
            super::super::attempts::invalid_transition("completed review has no frozen head")
        })?;
    let output = run.report.as_deref().ok_or_else(|| {
        super::super::attempts::invalid_transition("completed agent-turn run has no report output")
    })?;
    let report = complete_task_board_report_only_review(
        head_revision,
        runtime_name,
        requested_model,
        effective_model,
        output.trim(),
    )
    .map_err(|error| super::super::attempts::invalid_transition(error.to_string()))?;
    let verdict = if report.findings.is_empty() {
        TaskBoardPhaseVerdict::Pass
    } else {
        TaskBoardPhaseVerdict::ChangesRequired
    };
    let profile_id = attempt.action_key.strip_prefix("review:").ok_or_else(|| {
        super::super::attempts::invalid_transition("review attempt has no profile")
    })?;
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
