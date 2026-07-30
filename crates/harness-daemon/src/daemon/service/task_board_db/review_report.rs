use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{
    TaskBoardAiReviewReportResponse, TaskBoardAiReviewUnavailableExecution, TaskBoardAttemptState,
    TaskBoardExecutionAttemptRecord, TaskBoardExecutionState, TaskBoardWorkflowExecutionRecord,
    TaskBoardWorkflowKind,
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
        && let Some(attempt) = active_review_attempt(execution)?
    {
        return running_review_response(db, execution, attempt).await;
    }

    let latest = db.task_board_latest_ai_review_report(&request.id).await?;
    if let Some(report) = latest {
        return Ok(TaskBoardAiReviewReportResponse::from_terminal_report(
            report,
        ));
    }
    let Some(execution) = execution.as_ref().filter(|execution| {
        is_review_execution(execution.snapshot.workflow_kind)
            && is_terminal(execution.transition.execution_state)
    }) else {
        return Ok(TaskBoardAiReviewReportResponse::NotStarted { terminal: None });
    };
    terminal_review_response(db, execution).await
}

async fn running_review_response(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> Result<TaskBoardAiReviewReportResponse, CliError> {
    let provenance = review_runtime_provenance(db, execution).await?;
    Ok(TaskBoardAiReviewReportResponse::Running {
        execution_id: execution.execution_id.clone(),
        runtime: provenance.requested_runtime.clone(),
        requested_runtime: provenance.requested_runtime,
        actual_runtime: provenance.actual_runtime,
        requested_model: provenance.requested_model,
        head_revision: execution.transition.exact_head_revision.clone(),
        started_at: attempt.started_at.clone(),
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
    Ok(TaskBoardAiReviewReportResponse::NotStarted {
        terminal: Some(TaskBoardAiReviewUnavailableExecution {
            execution_id: execution.execution_id.clone(),
            execution_state: execution.transition.execution_state,
            runtime: provenance.requested_runtime.clone(),
            requested_runtime: provenance.requested_runtime,
            actual_runtime: provenance.actual_runtime,
            requested_model: provenance.requested_model,
            head_revision: execution.transition.exact_head_revision.clone(),
            started_at: execution.created_at.clone(),
            finished_at,
        }),
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
    let attempt = latest_review_attempt(execution)?;
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
) -> Result<Option<&TaskBoardExecutionAttemptRecord>, CliError> {
    select_latest_review_attempt(&execution.attempts)
}

fn select_latest_review_attempt(
    attempts: &[TaskBoardExecutionAttemptRecord],
) -> Result<Option<&TaskBoardExecutionAttemptRecord>, CliError> {
    let review_attempts = attempts
        .iter()
        .filter(|attempt| attempt.action_key.starts_with("review:"));
    let mut active = review_attempts.clone().filter(|attempt| {
        matches!(
            attempt.state,
            TaskBoardAttemptState::Preparing
                | TaskBoardAttemptState::Starting
                | TaskBoardAttemptState::Running
        )
    });
    let current = active.next();
    if active.next().is_some() {
        return Err(CliErrorKind::invalid_transition(
            "task-board review execution has multiple active reviewer attempts",
        )
        .into());
    }
    Ok(current.or_else(|| {
        review_attempts.max_by(|left, right| {
            left.updated_at
                .cmp(&right.updated_at)
                .then_with(|| left.attempt.cmp(&right.attempt))
        })
    }))
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

fn active_review_attempt(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<Option<&TaskBoardExecutionAttemptRecord>, CliError> {
    if !is_review_execution(execution.snapshot.workflow_kind) {
        return Ok(None);
    }
    let Some(attempt) = execution
        .attempts
        .iter()
        .find(|attempt| is_active(attempt.state) && attempt.action_key.starts_with("review:"))
    else {
        return Ok(None);
    };
    attempt_profile(execution, attempt)?;
    Ok(Some(attempt))
}

const fn is_active(state: TaskBoardAttemptState) -> bool {
    matches!(
        state,
        TaskBoardAttemptState::Preparing
            | TaskBoardAttemptState::Starting
            | TaskBoardAttemptState::Running
    )
}

#[cfg(test)]
mod tests {
    use super::{is_active, is_terminal, select_latest_review_attempt};
    use crate::task_board::{
        TaskBoardAttemptState, TaskBoardExecutionAttemptRecord, TaskBoardExecutionState,
    };

    #[test]
    fn only_live_attempt_states_are_active() {
        assert!(is_active(TaskBoardAttemptState::Preparing));
        assert!(is_active(TaskBoardAttemptState::Starting));
        assert!(is_active(TaskBoardAttemptState::Running));
        assert!(!is_active(TaskBoardAttemptState::RetryWait));
        assert!(!is_active(TaskBoardAttemptState::Completed));
        assert!(!is_active(TaskBoardAttemptState::Failed));
        assert!(!is_active(TaskBoardAttemptState::Cancelled));
        assert!(!is_active(TaskBoardAttemptState::Unknown));
    }

    #[test]
    fn only_finished_execution_states_are_terminal() {
        assert!(!is_terminal(TaskBoardExecutionState::HumanRequired));
        assert!(is_terminal(TaskBoardExecutionState::Completed));
        assert!(is_terminal(TaskBoardExecutionState::Failed));
        assert!(is_terminal(TaskBoardExecutionState::Cancelled));
    }

    #[test]
    fn active_reviewer_wins_over_lexicographically_later_completed_reviewer() {
        let attempts = [
            review_attempt("review:zeta", TaskBoardAttemptState::Completed, "10:00"),
            review_attempt("review:alpha", TaskBoardAttemptState::Running, "10:01"),
        ];

        let selected = select_latest_review_attempt(&attempts)
            .expect("select attempt")
            .expect("active attempt");

        assert_eq!(selected.action_key, "review:alpha");
    }

    fn review_attempt(
        action_key: &str,
        state: TaskBoardAttemptState,
        updated_at: &str,
    ) -> TaskBoardExecutionAttemptRecord {
        TaskBoardExecutionAttemptRecord {
            execution_id: "execution-1".into(),
            action_key: action_key.into(),
            attempt: 1,
            idempotency_key: format!("{action_key}:1"),
            state,
            failure_class: None,
            available_at: None,
            error: None,
            artifact: None,
            started_at: "09:59".into(),
            updated_at: updated_at.into(),
            completed_at: None,
        }
    }
}
