use crate::daemon::db::task_board::prelude::AutomationKillSwitchQueries;
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::daemon::http::{DaemonHttpState, run_codex_agent_blocking};
use crate::daemon::protocol::CodexRunSnapshot;
use crate::reviews::{
    ReviewActionKind, ReviewActionOutcome, ReviewItem, ReviewPullRequestState,
    ReviewsActionResponse,
};
use crate::task_board::{
    TaskBoardLifecycleOutcome, TaskBoardPullRequestIdentity, TaskBoardWorkflowExecutionRecord,
};
use harness_kernel::errors::{CliError, CliErrorKind};

pub(super) async fn ensure_automation_kill_switch_clear(
    db: &AsyncDaemonDbHandle,
) -> Result<(), CliError> {
    if db.automation_kill_switch_engaged().await? {
        return Err(invalid_transition("automation kill switch is engaged"));
    }
    Ok(())
}

pub(super) async fn stop_codex_run_if_killed(
    state: &DaemonHttpState,
    db: &AsyncDaemonDbHandle,
    snapshot: CodexRunSnapshot,
) -> Result<CodexRunSnapshot, CliError> {
    if !db.automation_kill_switch_engaged().await? {
        return Ok(snapshot);
    }
    let run_id = snapshot.run_id.clone();
    let target = run_id.clone();
    run_codex_agent_blocking(state, "automation kill switch", move |controller| {
        controller.stop(&target)
    })
    .await?;
    Err(invalid_transition(format!(
        "automation kill switch engaged while starting run '{run_id}'"
    )))
}

pub(super) async fn resolve_pr_review(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<ReviewItem, CliError> {
    let identity = pr_review_identity(execution)?;
    let review = crate::daemon::service::reviews_source_port::resolve_exact_pull_request(
        &identity.repository,
        identity.number,
    )
    .await?;
    if review.state != ReviewPullRequestState::Open {
        return Err(invalid_transition(format!(
            "pull request '{}#{}' is not open",
            identity.repository, identity.number
        )));
    }
    Ok(review)
}

pub(super) fn pr_review_identity(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<TaskBoardPullRequestIdentity, CliError> {
    if !execution.snapshot.workflow_kind.is_read_only_review()
        || !execution.transition.workflow_kind.is_read_only_review()
    {
        return Err(invalid_transition(
            "publish requires a PrReview execution and Task Board item",
        ));
    }
    let frozen = execution
        .transition
        .pull_request
        .as_ref()
        .ok_or_else(|| invalid_transition("PrReview execution has no frozen pull request"))?;
    Ok(frozen.clone())
}

pub(super) fn lifecycle_outcome(
    execution: &TaskBoardWorkflowExecutionRecord,
    review: &ReviewItem,
    mutated: bool,
) -> TaskBoardLifecycleOutcome {
    TaskBoardLifecycleOutcome {
        mutated,
        terminal: false,
        provider_revision: execution.snapshot.provider_revision.clone(),
        external_url: Some(review.url.clone()),
    }
}

pub(super) fn require_applied_approval(
    response: &ReviewsActionResponse,
    review: &ReviewItem,
) -> Result<(), CliError> {
    let [result] = response.results.as_slice() else {
        return Err(invalid_transition(format!(
            "PrReview approval returned {} action results instead of one",
            response.results.len()
        )));
    };
    if result.repository != review.repository
        || result.number != review.number
        || result.action != ReviewActionKind::Approve
    {
        return Err(invalid_transition(format!(
            "PrReview approval result identity did not match '{}#{}'",
            review.repository, review.number
        )));
    }
    match result.outcome {
        ReviewActionOutcome::Applied => Ok(()),
        ReviewActionOutcome::Failed => Err(CliErrorKind::workflow_io(format!(
            "PrReview approval failed for '{}#{}': {}",
            review.repository,
            review.number,
            result.message.as_deref().unwrap_or("no action detail")
        ))
        .into()),
        ReviewActionOutcome::Skipped => Err(invalid_transition(format!(
            "PrReview approval was skipped for '{}#{}': {}",
            review.repository,
            review.number,
            result.message.as_deref().unwrap_or("no action detail")
        ))),
    }
}

pub(super) fn required_head(head: &str) -> Result<String, CliError> {
    let head = head.trim();
    if head.is_empty() {
        Err(invalid_transition("workflow exact head is empty"))
    } else {
        Ok(head.to_owned())
    }
}

pub(super) fn invalid_transition(detail: impl Into<String>) -> CliError {
    CliErrorKind::invalid_transition(detail.into()).into()
}
