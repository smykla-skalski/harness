use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{
    TaskBoardAiReviewReportResponse, TaskBoardExecutionState, TaskBoardWorkflowKind,
};
use harness_kernel::errors::{CliError, CliErrorKind};

use super::TaskBoardGetItemRequest;

pub(crate) async fn get_task_board_ai_review_report_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardGetItemRequest,
) -> Result<TaskBoardAiReviewReportResponse, CliError> {
    let item = db.task_board_item(&request.id).await?;
    let execution = match item.workflow.execution_id.as_deref() {
        Some(execution_id) => Some(
            db.task_board_workflow_execution(execution_id)
                .await?
                .ok_or_else(|| {
                    CliError::from(CliErrorKind::workflow_io(format!(
                        "task-board item '{}' references missing workflow execution '{execution_id}'",
                        request.id
                    )))
                })?,
        ),
        None => None,
    };

    if let Some(execution) = execution.as_ref()
        && is_review_execution(execution.snapshot.workflow_kind)
        && !is_terminal(execution.transition.execution_state)
    {
        let reviewer = execution
            .resolved_reviewers
            .profiles
            .first()
            .ok_or_else(|| {
                CliError::from(CliErrorKind::workflow_io(format!(
                    "task-board review execution '{}' has no resolved reviewer",
                    execution.execution_id
                )))
            })?;
        return Ok(TaskBoardAiReviewReportResponse::Running {
            execution_id: execution.execution_id.clone(),
            runtime: reviewer.runtime.clone(),
            requested_model: reviewer.model.clone(),
            head_revision: execution.transition.exact_head_revision.clone(),
            started_at: execution.created_at.clone(),
        });
    }

    let latest = db.task_board_latest_ai_review_report(&request.id).await?;
    Ok(
        latest.map_or(TaskBoardAiReviewReportResponse::NotStarted, |report| {
            TaskBoardAiReviewReportResponse::from_terminal_report(report)
        }),
    )
}

const fn is_review_execution(workflow_kind: TaskBoardWorkflowKind) -> bool {
    matches!(
        workflow_kind,
        TaskBoardWorkflowKind::PrReview | TaskBoardWorkflowKind::Review
    )
}

const fn is_terminal(state: TaskBoardExecutionState) -> bool {
    matches!(
        state,
        TaskBoardExecutionState::Completed
            | TaskBoardExecutionState::Failed
            | TaskBoardExecutionState::Cancelled
            | TaskBoardExecutionState::HumanRequired
    )
}
