use std::path::{Path, PathBuf};

use async_trait::async_trait;
use tokio::task::spawn_blocking;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::http::{DaemonHttpState, run_codex_agent_blocking};
use crate::daemon::protocol::{CodexRunMode, CodexRunRequest, CodexRunSnapshot};
use crate::errors::{CliError, CliErrorKind};
use crate::git::GitRepository;
use crate::reviews::{
    ReviewActionKind, ReviewActionOutcome, ReviewItem, ReviewPullRequestState,
    ReviewsActionResponse, ReviewsApproveRequest, ReviewsApproveRequestSource,
};
use crate::task_board::{
    TaskBoardLifecycleOutcome, TaskBoardPullRequestIdentity, TaskBoardWorkflowExecutionRecord,
    TaskBoardWorkflowKind, validate_task_board_read_only_run_context,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TaskBoardPublishVerification {
    Applied(TaskBoardLifecycleOutcome),
    Absent,
}

#[async_trait]
pub(crate) trait TaskBoardReadOnlyRuntime: Send + Sync {
    async fn load_codex_report_run(
        &self,
        run_id: &str,
    ) -> Result<Option<CodexRunSnapshot>, CliError>;

    async fn start_codex_report_run(
        &self,
        session_id: &str,
        request: &CodexRunRequest,
        run_id: &str,
    ) -> Result<CodexRunSnapshot, CliError>;

    async fn resolve_exact_head(
        &self,
        execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<String, CliError>;

    async fn publish_pr_review(
        &self,
        execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<TaskBoardLifecycleOutcome, CliError>;

    async fn verify_pr_review_approval(
        &self,
        execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<TaskBoardPublishVerification, CliError>;
}

pub(crate) struct ProductionTaskBoardReadOnlyRuntime<'a> {
    state: &'a DaemonHttpState,
    db: &'a AsyncDaemonDb,
}

impl<'a> ProductionTaskBoardReadOnlyRuntime<'a> {
    pub(crate) const fn new(state: &'a DaemonHttpState, db: &'a AsyncDaemonDb) -> Self {
        Self { state, db }
    }
}

#[async_trait]
impl TaskBoardReadOnlyRuntime for ProductionTaskBoardReadOnlyRuntime<'_> {
    async fn load_codex_report_run(
        &self,
        run_id: &str,
    ) -> Result<Option<CodexRunSnapshot>, CliError> {
        if self.db.codex_run(run_id).await?.is_none() {
            return Ok(None);
        }
        let run_id = run_id.to_owned();
        run_codex_agent_blocking(
            self.state,
            "task-board read-only report load",
            move |handle| handle.run(&run_id),
        )
        .await
        .map(Some)
    }

    async fn start_codex_report_run(
        &self,
        session_id: &str,
        request: &CodexRunRequest,
        run_id: &str,
    ) -> Result<CodexRunSnapshot, CliError> {
        if request.mode != CodexRunMode::Report {
            return Err(invalid_transition(
                "read-only workflow runtime only starts Codex Report runs",
            ));
        }
        let session_id = session_id.to_owned();
        let request = request.clone();
        let run_id = run_id.to_owned();
        run_codex_agent_blocking(
            self.state,
            "task-board read-only report start",
            move |handle| handle.start_run_with_id(&session_id, &request, run_id),
        )
        .await
    }

    async fn resolve_exact_head(
        &self,
        execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<String, CliError> {
        match execution.snapshot.workflow_kind {
            TaskBoardWorkflowKind::Review => resolve_local_review_head(execution).await,
            TaskBoardWorkflowKind::PrReview => {
                let review = resolve_pr_review(execution).await?;
                required_head(&review.head_sha)
            }
            _ => Err(invalid_transition(
                "read-only runtime requires a Review or PrReview execution",
            )),
        }
    }

    async fn publish_pr_review(
        &self,
        execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<TaskBoardLifecycleOutcome, CliError> {
        let review = resolve_pr_review(execution).await?;
        let expected_head = execution
            .transition
            .exact_head_revision
            .as_deref()
            .ok_or_else(|| invalid_transition("PrReview execution has no frozen exact head"))?;
        let current_head = required_head(&review.head_sha)?;
        if current_head != expected_head {
            return Err(invalid_transition(format!(
                "PrReview head changed before publish: expected '{expected_head}', found '{current_head}'"
            )));
        }
        if review.viewer_has_active_approval == Some(true) {
            return Ok(lifecycle_outcome(execution, &review, false));
        }
        let response = super::reviews::approve_reviews(&ReviewsApproveRequest {
            targets: vec![review.target()],
            source: ReviewsApproveRequestSource::Direct,
        })
        .await?;
        require_applied_approval(&response, &review)?;
        Ok(lifecycle_outcome(execution, &review, true))
    }

    async fn verify_pr_review_approval(
        &self,
        execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<TaskBoardPublishVerification, CliError> {
        let review = resolve_pr_review(execution).await?;
        let expected_head = execution
            .transition
            .exact_head_revision
            .as_deref()
            .ok_or_else(|| invalid_transition("PrReview execution has no frozen exact head"))?;
        let current_head = required_head(&review.head_sha)?;
        if current_head != expected_head {
            return Err(invalid_transition(format!(
                "PrReview head changed during approval verification: expected '{expected_head}', found '{current_head}'"
            )));
        }
        if review.viewer_has_active_approval == Some(true) {
            Ok(TaskBoardPublishVerification::Applied(lifecycle_outcome(
                execution, &review, false,
            )))
        } else {
            Ok(TaskBoardPublishVerification::Absent)
        }
    }
}

async fn resolve_local_review_head(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<String, CliError> {
    if execution.transition.workflow_kind != TaskBoardWorkflowKind::Review
        || execution.transition.pull_request.is_some()
    {
        return Err(invalid_transition(
            "Review execution and Task Board item identities do not agree",
        ));
    }
    let context = execution
        .snapshot
        .read_only_run_context
        .as_ref()
        .ok_or_else(|| invalid_transition("Review workflow has no immutable run context"))?;
    validate_task_board_read_only_run_context(context)
        .map_err(|error| invalid_transition(error.to_string()))?;
    let worktree = PathBuf::from(&context.worktree);
    spawn_blocking(move || local_head(&worktree))
        .await
        .map_err(|error| invalid_transition(format!("join local head resolver: {error}")))?
}

async fn resolve_pr_review(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<ReviewItem, CliError> {
    let identity = pr_review_identity(execution)?;
    let review =
        super::reviews::resolve_exact_pull_request(&identity.repository, identity.number).await?;
    if review.state != ReviewPullRequestState::Open {
        return Err(invalid_transition(format!(
            "pull request '{}#{}' is not open",
            identity.repository, identity.number
        )));
    }
    Ok(review)
}

fn pr_review_identity(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<TaskBoardPullRequestIdentity, CliError> {
    if execution.snapshot.workflow_kind != TaskBoardWorkflowKind::PrReview
        || execution.transition.workflow_kind != TaskBoardWorkflowKind::PrReview
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

fn local_head(worktree: &Path) -> Result<String, CliError> {
    let repository = GitRepository::discover(worktree)
        .map_err(|error| invalid_transition(format!("discover review repository: {error}")))?;
    let repository = repository
        .open_gix()
        .map_err(|error| invalid_transition(format!("open review repository: {error}")))?;
    repository
        .head_commit()
        .map(|commit| commit.id.to_hex().to_string())
        .map_err(|error| invalid_transition(format!("resolve review HEAD: {error}")))
}

fn lifecycle_outcome(
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

fn require_applied_approval(
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

fn required_head(head: &str) -> Result<String, CliError> {
    let head = head.trim();
    if head.is_empty() {
        Err(invalid_transition("workflow exact head is empty"))
    } else {
        Ok(head.to_owned())
    }
}

fn invalid_transition(detail: impl Into<String>) -> CliError {
    CliErrorKind::invalid_transition(detail.into()).into()
}

#[cfg(test)]
#[path = "task_board_read_only_runtime/recovery_tests.rs"]
mod recovery_tests;

#[cfg(test)]
mod tests {
    use chrono::{TimeZone, Utc};
    use tempfile::tempdir;

    use super::*;
    use crate::reviews::{
        ReviewActionResult, ReviewCheckStatus, ReviewItemFlags, ReviewMergeableState,
        ReviewReviewStatus,
    };

    #[test]
    fn local_head_resolves_full_commit_oid() {
        let temp = tempdir().expect("tempdir");
        harness_testkit::init_git_repo_with_seed(temp.path());

        let head = local_head(temp.path()).expect("resolve local head");

        assert_eq!(head.len(), 40);
        assert!(head.bytes().all(|byte| byte.is_ascii_hexdigit()));
    }

    #[test]
    fn publish_mapping_requires_one_applied_approval() {
        let review = review_item();
        let applied = ReviewsActionResponse {
            summary: "approved".into(),
            results: vec![action_result(ReviewActionOutcome::Applied, None)],
        };
        require_applied_approval(&applied, &review).expect("applied approval");

        let skipped = ReviewsActionResponse {
            summary: "skipped".into(),
            results: vec![action_result(
                ReviewActionOutcome::Skipped,
                Some("policy declined"),
            )],
        };
        let error = require_applied_approval(&skipped, &review).expect_err("skipped approval");
        assert!(error.message().contains("policy declined"));
    }

    #[test]
    fn production_adapter_satisfies_runtime_contract() {
        fn assert_runtime<T: TaskBoardReadOnlyRuntime>() {}
        assert_runtime::<ProductionTaskBoardReadOnlyRuntime<'static>>();
        let constructor = ProductionTaskBoardReadOnlyRuntime::new;
        let load = ProductionTaskBoardReadOnlyRuntime::load_codex_report_run;
        let start = ProductionTaskBoardReadOnlyRuntime::start_codex_report_run;
        let resolve = ProductionTaskBoardReadOnlyRuntime::resolve_exact_head;
        let publish = ProductionTaskBoardReadOnlyRuntime::publish_pr_review;
        let verify = ProductionTaskBoardReadOnlyRuntime::verify_pr_review_approval;
        let _ = (constructor, load, start, resolve, publish, verify);
    }

    fn action_result(outcome: ReviewActionOutcome, message: Option<&str>) -> ReviewActionResult {
        ReviewActionResult {
            repository: "example/compass".into(),
            number: 17,
            action: ReviewActionKind::Approve,
            outcome,
            message: message.map(str::to_owned),
            timeline_entry: None,
        }
    }

    fn review_item() -> ReviewItem {
        let timestamp = Utc
            .with_ymd_and_hms(2026, 7, 17, 10, 0, 0)
            .single()
            .expect("timestamp");
        ReviewItem {
            pull_request_id: "pr-node-17".into(),
            repository_id: "repo-node".into(),
            repository: "example/compass".into(),
            number: 17,
            title: "Review me".into(),
            url: "https://github.com/example/compass/pull/17".into(),
            base_ref_name: Some("main".into()),
            default_branch_name: Some("main".into()),
            backport_source: None,
            author_login: "author".into(),
            author_avatar_url: None,
            author_association: Default::default(),
            state: ReviewPullRequestState::Open,
            mergeable: ReviewMergeableState::Mergeable,
            review_status: ReviewReviewStatus::ReviewRequired,
            check_status: ReviewCheckStatus::Success,
            flags: ReviewItemFlags::default(),
            viewer_can_merge_as_admin: true,
            head_sha: "head-amber".into(),
            labels: Vec::new(),
            checks: Vec::new(),
            reviews: Vec::new(),
            additions: 3,
            deletions: 1,
            created_at: timestamp,
            updated_at: timestamp,
            required_failed_check_names: Vec::new(),
            required_approving_review_count: None,
            has_conflict_markers: None,
            viewer_has_active_approval: Some(false),
            auto_merge_enabled: None,
            approval_requirement_satisfied_after_viewer_approval: None,
        }
    }
}
