use async_trait::async_trait;

use crate::daemon::db::AgentTurnRunSnapshot;
use crate::daemon::db::prelude::*;
use crate::daemon::db::task_board::prelude::AutomationKillSwitchQueries;
use crate::daemon::db_handle::AsyncDaemonDbHandle;
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

#[path = "task_board_read_only_runtime/agent_turn_report.rs"]
pub(crate) mod agent_turn_report;
#[path = "task_board_read_only_runtime/git_evidence.rs"]
mod git_evidence;
#[path = "task_board_read_only_runtime/support.rs"]
mod support;

pub(crate) use agent_turn_report::AgentTurnReportStart;
// `git_evidence` reaches `invalid_transition` through `super::`, so the binding
// has to stay in this module rather than being called through `support::`.
use support::{
    ensure_automation_kill_switch_clear, invalid_transition, lifecycle_outcome, pr_review_identity,
    require_applied_approval, required_head, resolve_pr_review, stop_codex_run_if_killed,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TaskBoardPublishVerification {
    Applied(TaskBoardLifecycleOutcome),
    Absent,
}

/// Who owns a workflow attempt's Codex run, and where it runs.
///
/// A legacy attempt names the Session its dispatch was linked to and the run
/// binds to it. A workspace-owned attempt has no Session, so the run names
/// itself and takes the checkout directly.
#[derive(Debug, Clone, Copy)]
pub(crate) struct WorkflowRunOwner<'a> {
    pub owner_id: &'a str,
    pub worktree: &'a str,
}

#[async_trait]
pub(crate) trait TaskBoardReadOnlyRuntime: Send + Sync {
    async fn load_codex_report_run(
        &self,
        run_id: &str,
    ) -> Result<Option<CodexRunSnapshot>, CliError>;

    async fn start_report_run(
        &self,
        owner: WorkflowRunOwner<'_>,
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
        _owner: WorkflowRunOwner<'_>,
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

    async fn immutable_pull_request_content(
        &self,
        _repository: &str,
        _number: u64,
        _expected_head: &str,
    ) -> Result<String, CliError> {
        Err(invalid_transition(
            "runtime does not support immutable pull request content",
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
    db: &'a AsyncDaemonDbHandle,
}

impl<'a> ProductionTaskBoardReadOnlyRuntime<'a> {
    pub(crate) const fn new(state: &'a DaemonHttpState, db: &'a AsyncDaemonDbHandle) -> Self {
        Self { state, db }
    }

    /// Start an attempt's Codex run under whichever owner the dispatch left it.
    ///
    /// A Session-bound run derives its directory from the Session's worktree, so
    /// only a Session owner can take that path. Everything else is
    /// workspace-owned: the run names itself and takes the checkout the attempt
    /// already records. The id shape decides, because a Session id is a
    /// canonical lowercase UUID and a workspace id never is - looking the owner
    /// up instead would fail on the very ids this has to route.
    async fn start_owned_run(
        &self,
        owner: WorkflowRunOwner<'_>,
        request: &CodexRunRequest,
        run_id: &str,
        label: &'static str,
    ) -> Result<CodexRunSnapshot, CliError> {
        let session_bound = harness_workspace::workspace::ids::validate(owner.owner_id).is_ok();
        let owner_id = owner.owner_id.to_owned();
        let worktree = owner.worktree.to_owned();
        let request = request.clone();
        let run_id = run_id.to_owned();
        let snapshot = run_codex_agent_blocking(self.state, label, move |handle| {
            if session_bound {
                handle.start_run_with_id(&owner_id, &request, run_id)
            } else {
                handle.start_standalone_run_with_id(&worktree, &request, run_id)
            }
        })
        .await?;
        stop_codex_run_if_killed(self.state, self.db, snapshot).await
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

    async fn start_report_run(
        &self,
        owner: WorkflowRunOwner<'_>,
        request: &CodexRunRequest,
        run_id: &str,
    ) -> Result<CodexRunSnapshot, CliError> {
        ensure_automation_kill_switch_clear(self.db).await?;
        if request.mode != CodexRunMode::Report {
            return Err(invalid_transition(
                "read-only workflow runtime only starts Codex Report runs",
            ));
        }
        self.start_owned_run(owner, request, run_id, "task-board read-only report start")
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
        owner: WorkflowRunOwner<'_>,
        request: &CodexRunRequest,
        run_id: &str,
    ) -> Result<CodexRunSnapshot, CliError> {
        ensure_automation_kill_switch_clear(self.db).await?;
        if request.mode != CodexRunMode::WorkspaceWrite {
            return Err(invalid_transition(
                "write workflow runtime only starts Codex WorkspaceWrite runs",
            ));
        }
        self.start_owned_run(owner, request, run_id, "task-board write workspace start")
            .await
    }

    async fn start_agent_turn_report_run(
        &self,
        start: AgentTurnReportStart<'_>,
    ) -> Result<(), CliError> {
        ensure_automation_kill_switch_clear(self.db).await?;
        agent_turn_report::start_agent_turn_report_run(self.state, start).await
    }

    async fn load_agent_turn_report_run(
        &self,
        run_id: &str,
    ) -> Result<Option<AgentTurnRunSnapshot>, CliError> {
        agent_turn_report::load_agent_turn_report_run(self.state, self.db, run_id).await
    }

    async fn immutable_pull_request_content(
        &self,
        repository: &str,
        number: u64,
        expected_head: &str,
    ) -> Result<String, CliError> {
        crate::daemon::service::reviews_source_port::immutable_pull_request_content(
            repository,
            number,
            expected_head,
        )
        .await
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


#[cfg(test)]
#[path = "task_board_read_only_runtime/detached_turn_tests.rs"]
mod detached_turn_tests;

#[cfg(test)]
#[path = "task_board_read_only_runtime/recovery_tests.rs"]
mod recovery_tests;

#[cfg(test)]
#[path = "task_board_read_only_runtime/tests.rs"]
mod tests;
