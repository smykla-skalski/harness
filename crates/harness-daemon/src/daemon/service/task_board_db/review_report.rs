use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{
    TaskBoardAiReviewReportResponse, TaskBoardExecutionAttemptRecord, TaskBoardExecutionState,
    TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind,
};
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_task_board_codex_requests::attempt_profile;

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
        return running_review_response(db, execution).await;
    }

    let latest = db.task_board_latest_ai_review_report(&request.id).await?;
    if let Some(report) = latest {
        return Ok(TaskBoardAiReviewReportResponse::from_terminal_report(report));
    }
    let Some(execution) = execution.as_ref().filter(|execution| {
        is_review_execution(execution.snapshot.workflow_kind)
            && is_terminal(execution.transition.execution_state)
    }) else {
        return Ok(TaskBoardAiReviewReportResponse::NotStarted);
    };
    terminal_review_response(db, execution).await
}

async fn running_review_response(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<TaskBoardAiReviewReportResponse, CliError> {
    let provenance = review_runtime_provenance(db, execution).await?;
    Ok(TaskBoardAiReviewReportResponse::Running {
        execution_id: execution.execution_id.clone(),
        runtime: provenance.requested_runtime.clone(),
        requested_runtime: provenance.requested_runtime,
        actual_runtime: provenance.actual_runtime,
        requested_model: provenance.requested_model,
        head_revision: execution.transition.exact_head_revision.clone(),
        started_at: execution.created_at.clone(),
    })
}

async fn terminal_review_response(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<TaskBoardAiReviewReportResponse, CliError> {
    let provenance = review_runtime_provenance(db, execution).await?;
    let finished_at = execution.completed_at.clone().ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "terminal task-board review execution '{}' has no completion time",
            execution.execution_id
        )))
    })?;
    Ok(TaskBoardAiReviewReportResponse::Terminal {
        execution_id: execution.execution_id.clone(),
        execution_state: execution.transition.execution_state,
        runtime: provenance.requested_runtime.clone(),
        requested_runtime: provenance.requested_runtime,
        actual_runtime: provenance.actual_runtime,
        requested_model: provenance.requested_model,
        head_revision: execution.transition.exact_head_revision.clone(),
        started_at: execution.created_at.clone(),
        finished_at,
    })
}

struct ReviewRuntimeProvenance {
    requested_runtime: String,
    actual_runtime: Option<String>,
    requested_model: Option<String>,
}

async fn review_runtime_provenance(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<ReviewRuntimeProvenance, CliError> {
    let attempt = latest_review_attempt(execution);
    let reviewer = match attempt {
        Some(attempt) => attempt_profile(execution, attempt)?,
        None => execution
            .resolved_reviewers
            .profiles
            .first()
            .ok_or_else(|| {
                CliError::from(CliErrorKind::workflow_io(format!(
                    "task-board review execution '{}' has no resolved reviewer",
                    execution.execution_id
                )))
            })?,
    };
    let fallback = ReviewRuntimeProvenance {
        requested_runtime: reviewer.runtime.clone(),
        actual_runtime: None,
        requested_model: reviewer.model.clone(),
    };
    let Some(attempt) = attempt else {
        return Ok(fallback);
    };
    if let Some(remote) = db
        .task_board_remote_runtime_provenance(&execution.execution_id, &attempt.idempotency_key)
        .await?
    {
        return Ok(ReviewRuntimeProvenance {
            requested_runtime: remote.requested_runtime,
            actual_runtime: remote.actual_runtime,
            requested_model: remote.requested_model.or(reviewer.model.clone()),
        });
    }
    match reviewer.runtime.as_str() {
        "codex" => {
            let Some(run) = db.codex_run(&attempt.idempotency_key).await? else {
                return Ok(fallback);
            };
            Ok(ReviewRuntimeProvenance {
                requested_runtime: "codex".into(),
                actual_runtime: Some("codex".into()),
                requested_model: run.model.or(reviewer.model.clone()),
            })
        }
        "openrouter" => {
            let Some(run) = db.agent_turn_run(&attempt.idempotency_key).await? else {
                return Ok(fallback);
            };
            Ok(ReviewRuntimeProvenance {
                requested_runtime: run.requested_runtime,
                actual_runtime: run.actual_runtime,
                requested_model: run.requested_model.or(reviewer.model.clone()),
            })
        }
        _ => Ok(fallback),
    }
}

fn latest_review_attempt(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Option<&TaskBoardExecutionAttemptRecord> {
    execution
        .attempts
        .iter()
        .rev()
        .find(|attempt| attempt.action_key.starts_with("review:"))
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
    )
}

#[cfg(test)]
mod tests {
    use super::is_terminal;
    use crate::task_board::TaskBoardExecutionState;

    #[test]
    fn human_required_review_remains_observable_as_running() {
        assert!(!is_terminal(TaskBoardExecutionState::HumanRequired));
        assert!(is_terminal(TaskBoardExecutionState::Completed));
        assert!(is_terminal(TaskBoardExecutionState::Failed));
        assert!(is_terminal(TaskBoardExecutionState::Cancelled));
    }
}
