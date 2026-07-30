use async_trait::async_trait;

use crate::daemon::db::{AgentTurnRunSnapshot, AsyncDaemonDb};
use crate::daemon::http::{DaemonHttpState, run_codex_agent_blocking};
use crate::daemon::protocol::{CodexRunMode, CodexRunRequest, CodexRunSnapshot};
use crate::reviews::{
    ReviewActionKind, ReviewActionOutcome, ReviewItem, ReviewPullRequestState,
    ReviewsActionResponse, ReviewsApproveRequest, ReviewsApproveRequestSource,
};
use crate::task_board::{
    TaskBoardImplementationResult, TaskBoardLifecycleOutcome, TaskBoardPullRequestIdentity,
    TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind,
};
use harness_kernel::errors::{CliError, CliErrorKind};

#[path = "task_board_read_only_runtime/git_evidence.rs"]
mod git_evidence;
#[path = "task_board_read_only_runtime/agent_turn_report.rs"]
pub(crate) mod agent_turn_report;

pub(crate) use agent_turn_report::AgentTurnReportStart;

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

    async fn load_codex_workspace_run(
        &self,
        _run_id: &str,
    ) -> Result<Option<CodexRunSnapshot>, CliError> {
        Err(invalid_transition(
            "write workflow runtime does not support durable Codex run loading",
        ))
    }

    async fn start_codex_workspace_run(
        &self,
        _session_id: &str,
        _request: &CodexRunRequest,
        _run_id: &str,
    ) -> Result<CodexRunSnapshot, CliError> {
        Err(invalid_transition(
            "write workflow runtime does not support WorkspaceWrite starts",
        ))
    }

    async fn start_agent_turn_report_run(
        &self,
        _start: AgentTurnReportStart<'_>,
    ) -> Result<(), CliError> {
        Err(invalid_transition(
            "runtime does not support agent-turn report runs",
        ))
    }

    async fn load_agent_turn_report_run(
        &self,
        _run_id: &str,
    ) -> Result<Option<AgentTurnRunSnapshot>, CliError> {
        Err(invalid_transition(
            "runtime does not support agent-turn report run loading",
        ))
    }

    async fn resolve_exact_head(
        &self,
        execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<String, CliError>;

    async fn implementation_result_descends_from_base(
        &self,
        execution: &TaskBoardWorkflowExecutionRecord,
        result: &TaskBoardImplementationResult,
    ) -> Result<bool, CliError>;

    async fn publish_pr_review(
        &self,
        execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<TaskBoardLifecycleOutcome, CliError>;

    async fn verify_pr_review_approval(
        &self,
        execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<TaskBoardPublishVerification, CliError>;

    async fn publish_write_workflow(
        &self,
        _execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<TaskBoardLifecycleOutcome, CliError> {
        Err(invalid_transition(
            "runtime does not support write workflow publication",
        ))
    }

    async fn verify_write_workflow_publication(
        &self,
        _execution: &TaskBoardWorkflowExecutionRecord,
        _known_external_url: Option<&str>,
    ) -> Result<TaskBoardPublishVerification, CliError> {
        Err(invalid_transition(
            "runtime does not support write workflow publication verification",
        ))
    }
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

    async fn load_codex_workspace_run(
        &self,
        run_id: &str,
    ) -> Result<Option<CodexRunSnapshot>, CliError> {
        self.load_codex_report_run(run_id).await
    }

    async fn start_codex_workspace_run(
        &self,
        session_id: &str,
        request: &CodexRunRequest,
        run_id: &str,
    ) -> Result<CodexRunSnapshot, CliError> {
        if request.mode != CodexRunMode::WorkspaceWrite {
            return Err(invalid_transition(
                "write workflow runtime only starts Codex WorkspaceWrite runs",
            ));
        }
        let session_id = session_id.to_owned();
        let request = request.clone();
        let run_id = run_id.to_owned();
        run_codex_agent_blocking(
            self.state,
            "task-board write workspace start",
            move |handle| handle.start_run_with_id(&session_id, &request, run_id),
        )
        .await
    }

    async fn start_agent_turn_report_run(
        &self,
        start: AgentTurnReportStart<'_>,
    ) -> Result<(), CliError> {
        agent_turn_report::start_agent_turn_report_run(self.state, start).await
    }

    async fn load_agent_turn_report_run(
        &self,
        run_id: &str,
    ) -> Result<Option<AgentTurnRunSnapshot>, CliError> {
        agent_turn_report::load_agent_turn_report_run(self.state, self.db, run_id).await
    }

    async fn resolve_exact_head(
        &self,
        execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<String, CliError> {
        // A dependency-update pull request resolves its worktree head like a
        // default task; a pure review request uses the frozen PR head.
        match execution.snapshot.workflow_kind {
            TaskBoardWorkflowKind::DefaultTask
            | TaskBoardWorkflowKind::PrFix
            | TaskBoardWorkflowKind::PrFixReview
            | TaskBoardWorkflowKind::Review => {
                git_evidence::resolve_local_workflow_head(execution).await
            }
            TaskBoardWorkflowKind::PrReview => {
                let review = resolve_pr_review(execution).await?;
                required_head(&review.head_sha)
            }
            TaskBoardWorkflowKind::Unknown => Err(invalid_transition(
                "workflow runtime requires a known execution",
            )),
        }
    }

    async fn implementation_result_descends_from_base(
        &self,
        execution: &TaskBoardWorkflowExecutionRecord,
        result: &TaskBoardImplementationResult,
    ) -> Result<bool, CliError> {
        git_evidence::implementation_result_descends_from_base(execution, result).await
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
        let response = crate::daemon::service::reviews_source_port::approve_pull_requests(
            &ReviewsApproveRequest {
                targets: vec![review.target()],
                source: ReviewsApproveRequestSource::Direct,
            },
        )
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

    async fn publish_write_workflow(
        &self,
        execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<TaskBoardLifecycleOutcome, CliError> {
        crate::daemon::service::task_board_github::publish_task_board_write_execution(
            self.db, execution,
        )
        .await
    }

    async fn verify_write_workflow_publication(
        &self,
        execution: &TaskBoardWorkflowExecutionRecord,
        known_external_url: Option<&str>,
    ) -> Result<TaskBoardPublishVerification, CliError> {
        crate::daemon::service::task_board_github::verify_task_board_write_execution_publication(
            self.db,
            execution,
            known_external_url,
        )
        .await
        .map(TaskBoardPublishVerification::Applied)
    }
}

async fn resolve_pr_review(
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

fn pr_review_identity(
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
#[path = "task_board_read_only_runtime/tests.rs"]
mod tests;
