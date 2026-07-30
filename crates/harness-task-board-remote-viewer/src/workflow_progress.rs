use harness_kernel::remote_redaction::REDACTION_PLACEHOLDER;
use harness_task_board::TaskBoardWorkflowProgressResponse;

#[must_use]
pub fn project_task_board_workflow_progress(
    mut response: TaskBoardWorkflowProgressResponse,
    viewer: bool,
) -> TaskBoardWorkflowProgressResponse {
    if !viewer {
        return response;
    }
    let Some(progress) = response.progress.as_mut() else {
        return response;
    };
    progress.blocked_reason = progress
        .blocked_reason
        .as_ref()
        .map(|_| REDACTION_PLACEHOLDER.to_string());
    if let Some(outcome) = progress.terminal_outcome.as_mut() {
        outcome.summary = REDACTION_PLACEHOLDER.to_string();
    }
    if let Some(triage) = progress.triage.as_mut() {
        triage.reason = REDACTION_PLACEHOLDER.to_string();
        triage.source_result.safety_assumption = REDACTION_PLACEHOLDER.to_string();
        for step in &mut triage.source_result.next_steps {
            step.reason = REDACTION_PLACEHOLDER.to_string();
        }
    }
    for attempt in &mut progress.attempts {
        attempt.report = attempt
            .report
            .as_ref()
            .map(|_| REDACTION_PLACEHOLDER.to_string());
        attempt.terminal_reason = attempt
            .terminal_reason
            .as_ref()
            .map(|_| REDACTION_PLACEHOLDER.to_string());
    }
    response
}
