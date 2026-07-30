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

#[cfg(test)]
mod tests {
    use harness_task_board::TaskBoardWorkflowProgressResponse;
    use serde_json::json;

    use super::project_task_board_workflow_progress;

    #[test]
    fn non_viewer_preserves_workflow_progress() {
        let response = workflow_progress();

        assert_eq!(
            project_task_board_workflow_progress(response.clone(), false),
            response
        );
    }

    #[test]
    fn remote_viewer_replaces_all_workflow_prose() {
        let projected = project_task_board_workflow_progress(workflow_progress(), true);
        let progress = projected.progress.expect("workflow progress");
        let triage = progress.triage.expect("dependency triage");

        assert_eq!(progress.blocked_reason.as_deref(), Some("[redacted]"));
        assert_eq!(
            progress
                .terminal_outcome
                .expect("terminal outcome")
                .summary,
            "[redacted]"
        );
        assert_eq!(triage.reason, "[redacted]");
        assert_eq!(triage.source_result.safety_assumption, "[redacted]");
        assert_eq!(triage.source_result.next_steps[0].reason, "[redacted]");
        assert_eq!(progress.attempts[0].report.as_deref(), Some("[redacted]"));
        assert_eq!(
            progress.attempts[0].terminal_reason.as_deref(),
            Some("[redacted]")
        );
    }

    fn workflow_progress() -> TaskBoardWorkflowProgressResponse {
        serde_json::from_value(json!({
            "progress": {
                "execution_id": "execution-1",
                "workflow_kind": "pr_fix",
                "phase": "implementation",
                "state": "blocked",
                "blocked_reason": "private blocked reason",
                "terminal_outcome": {
                    "kind": "human_required",
                    "summary": "private outcome",
                    "recorded_at": "2026-07-30T08:02:00Z"
                },
                "triage": {
                    "route_id": "route-1",
                    "repository": "example/repo",
                    "pull_request_number": 17,
                    "exact_head_revision": "0123456789abcdef0123456789abcdef01234567",
                    "status": { "kind": "fix_requested" },
                    "reason": "private route reason",
                    "source_result": {
                        "schema_version": 1,
                        "repository": "example/repo",
                        "pull_request_number": 17,
                        "exact_head_revision": "0123456789abcdef0123456789abcdef01234567",
                        "dependency": {
                            "name": "serde",
                            "ecosystem": "cargo",
                            "current_version": "1.0.219",
                            "target_version": "1.0.221",
                            "update_class": "patch"
                        },
                        "checks": [],
                        "conflicts": {
                            "state": "clean",
                            "summary": "clean"
                        },
                        "approvals": {
                            "current": 0,
                            "required": 0
                        },
                        "safety_assumption": "private safety assumption",
                        "disposition": "fix_required",
                        "required_tools": ["github.read", "codex.dispatch"],
                        "next_steps": [{
                            "order": 1,
                            "action": "inspect_failed_checks",
                            "reason": "private next step"
                        }]
                    }
                },
                "attempts": [{
                    "action_key": "dependency_triage",
                    "attempt": 1,
                    "state": "failed",
                    "runtime": "openrouter",
                    "model": "deepseek/deepseek-v4-flash",
                    "report": "private report",
                    "terminal_reason": "private terminal reason",
                    "started_at": "2026-07-30T08:00:00Z",
                    "updated_at": "2026-07-30T08:01:00Z",
                    "completed_at": "2026-07-30T08:01:00Z"
                }],
                "created_at": "2026-07-30T08:00:00Z",
                "updated_at": "2026-07-30T08:02:00Z"
            }
        }))
        .expect("workflow progress fixture")
    }
}
