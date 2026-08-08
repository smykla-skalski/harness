use harness_kernel::remote_redaction::REDACTION_PLACEHOLDER;
use harness_task_board::wire::TaskBoardWorkItemProgressResponse;

/// Strips the worker's free-form prose for a remote viewer.
///
/// A worker writes whatever it likes into its summaries, so the checkpoint log
/// is the most quotable thing this record carries. Identity and counters stay:
/// a viewer needs to see that work is moving and how far along it claims to be,
/// which is the same line `project_task_board_workflow_progress` draws for the
/// dependency workflow.
#[must_use]
pub fn project_task_board_work_item_progress(
    mut response: TaskBoardWorkItemProgressResponse,
    viewer: bool,
) -> TaskBoardWorkItemProgressResponse {
    if !viewer {
        return response;
    }
    let Some(progress) = response.progress.as_mut() else {
        return response;
    };
    progress.summary = progress
        .summary
        .as_ref()
        .map(|_| REDACTION_PLACEHOLDER.to_string());
    progress.blocked_reason = progress
        .blocked_reason
        .as_ref()
        .map(|_| REDACTION_PLACEHOLDER.to_string());
    for checkpoint in &mut progress.checkpoints {
        checkpoint.summary = REDACTION_PLACEHOLDER.to_string();
    }
    response
}

#[cfg(test)]
mod tests {
    use harness_task_board::wire::TaskBoardWorkItemProgressResponse;
    use harness_task_board::{
        TaskBoardWorkItemCheckpoint, TaskBoardWorkItemProgress, TaskBoardWorkItemState,
    };

    use super::project_task_board_work_item_progress;

    #[test]
    fn non_viewer_preserves_work_item_progress() {
        let response = work_item_progress();

        assert_eq!(
            project_task_board_work_item_progress(response.clone(), false),
            response
        );
    }

    #[test]
    fn remote_viewer_replaces_all_work_item_prose() {
        let projected = project_task_board_work_item_progress(work_item_progress(), true);
        let progress = projected.progress.expect("work item progress");

        assert_eq!(progress.summary.as_deref(), Some("[redacted]"));
        assert_eq!(progress.blocked_reason.as_deref(), Some("[redacted]"));
        assert_eq!(progress.checkpoints[0].summary, "[redacted]");
        assert_eq!(progress.checkpoints[1].summary, "[redacted]");
    }

    #[test]
    fn remote_viewer_keeps_identity_and_counters() {
        let projected = project_task_board_work_item_progress(work_item_progress(), true);
        let progress = projected.progress.expect("work item progress");

        assert_eq!(progress.board_item_id, "board-1");
        assert_eq!(progress.work_item_id, "task-board-1");
        assert_eq!(progress.execution_id.as_deref(), Some("workflow-1"));
        assert_eq!(progress.state, TaskBoardWorkItemState::Blocked);
        assert_eq!(progress.progress_percent, Some(60));
        assert_eq!(progress.report_sequence, 3);
        assert_eq!(progress.checkpoints[0].actor, "codex-worker");
        assert_eq!(progress.checkpoints[0].progress_percent, Some(20));
    }

    #[test]
    fn an_undispatched_response_projects_unchanged() {
        let response = TaskBoardWorkItemProgressResponse::default();

        assert_eq!(
            project_task_board_work_item_progress(response, true).progress,
            None
        );
    }

    fn work_item_progress() -> TaskBoardWorkItemProgressResponse {
        TaskBoardWorkItemProgressResponse {
            progress: Some(TaskBoardWorkItemProgress {
                board_item_id: "board-1".into(),
                work_item_id: "task-board-1".into(),
                execution_id: Some("workflow-1".into()),
                state: TaskBoardWorkItemState::Blocked,
                progress_percent: Some(60),
                summary: Some("private worker summary".into()),
                blocked_reason: Some("private blocked reason".into()),
                attempt_id: Some("codex-dispatch-intent-1".into()),
                item_revision: Some(7),
                report_sequence: 3,
                checkpoints: vec![
                    TaskBoardWorkItemCheckpoint {
                        checkpoint_id: "checkpoint-1".into(),
                        sequence: 1,
                        actor: "codex-worker".into(),
                        summary: "private first checkpoint".into(),
                        progress_percent: Some(20),
                        attempt_id: Some("codex-dispatch-intent-1".into()),
                        recorded_at: "2026-08-08T09:04:10Z".into(),
                    },
                    TaskBoardWorkItemCheckpoint {
                        checkpoint_id: "checkpoint-2".into(),
                        sequence: 2,
                        actor: "codex-worker".into(),
                        summary: "private second checkpoint".into(),
                        progress_percent: Some(60),
                        attempt_id: Some("codex-dispatch-intent-1".into()),
                        recorded_at: "2026-08-08T09:14:30Z".into(),
                    },
                ],
                created_at: "2026-08-08T09:00:00Z".into(),
                updated_at: "2026-08-08T09:14:30Z".into(),
                completed_at: Some("2026-08-08T09:14:30Z".into()),
            }),
        }
    }
}
