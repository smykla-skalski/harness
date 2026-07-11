use std::collections::{BTreeMap, BTreeSet};
use std::future::Future;
use std::path::Path;

use tokio::runtime::Builder as TokioRuntimeBuilder;
use uuid::Uuid;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::service::{session_detail_core, session_detail_core_async};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::github::{
    GitHubAutomation, GitHubAutomationClient, GitHubCreatePullRequest, GitHubProjectConfig,
    GitHubPullRequestHandle,
};
use crate::task_board::policy_graph::{
    RecordedPolicyDecision, record_policy_decision, resolve_gate_policy,
};
use crate::task_board::{
    BuiltInPolicyGate, ExternalProvider, ExternalRefProvider, PolicyAction, PolicyDecision,
    PolicyGate, PolicyInput, PolicyPipelineMode, PolicySubject, TaskBoardItem,
    TaskBoardOrchestratorSettings, TaskBoardWorkflowState,
};

use super::super::task_board_runtime::external_sync_config_for_repository;

#[path = "git_ops.rs"]
mod git_ops;

pub(super) use git_ops::{branch_publication_async, push_branch_async};

pub(super) const STEP_POLICY_BLOCKED: &str = "github_policy_blocked";
pub(super) const STEP_PUSH_FAILED: &str = "github_push_failed";
pub(super) const STEP_PR_FAILED: &str = "github_pr_failed";
pub(super) const STEP_REVIEW_FAILED: &str = "github_review_failed";
pub(super) const STEP_EVIDENCE_FAILED: &str = "github_evidence_failed";
pub(super) const STEP_MISSING_WORKTREE: &str = "github_missing_worktree";
pub(super) const STEP_WAITING_FOR_COMMITS: &str = "github_waiting_for_commits";
pub(super) const STEP_BRANCH_PUSHED: &str = "github_branch_pushed";
pub(super) const STEP_PR_OPENED: &str = "github_pr_opened";
pub(super) const STEP_REVIEW_REQUESTED: &str = "github_review_requested";
pub(super) const STEP_WAITING_FOR_CHECKS: &str = "github_waiting_for_checks";
pub(super) const STEP_WAITING_FOR_REVIEW: &str = "github_waiting_for_review";
pub(super) const STEP_WAITING_FOR_HUMAN: &str = "github_waiting_for_human";
pub(super) const STEP_WAITING_FOR_CONSENSUS: &str = "github_waiting_for_consensus";
pub(super) const STEP_MERGED: &str = "github_merged";
pub(super) const STEP_READY: &str = "github_ready";

pub(super) async fn sync_labels(
    config: &GitHubProjectConfig,
    client: &dyn GitHubAutomationClient,
    pr_number: u64,
    desired_labels: BTreeSet<String>,
    workflow: &mut TaskBoardWorkflowState,
) -> TaskBoardWorkflowState {
    let managed_labels = vec![
        config.labels.managed.clone(),
        config.labels.auto_merge.clone(),
        config.labels.needs_human.clone(),
        config.labels.protected_path.clone(),
    ];
    if let Err(error) = client
        .sync_pull_request_labels(
            config,
            pr_number,
            &managed_labels,
            &desired_labels.into_iter().collect::<Vec<_>>(),
        )
        .await
    {
        return failure(workflow, "github_labels_failed", &error);
    }
    workflow.clone()
}

pub(super) fn resolve_worktree(
    item: &TaskBoardItem,
    workflow: &TaskBoardWorkflowState,
    session_worktrees: &BTreeMap<String, String>,
    project_dir: Option<&str>,
    config: &GitHubProjectConfig,
) -> Option<String> {
    workflow
        .worktree
        .as_deref()
        .filter(|path| !path.trim().is_empty())
        .map(ToString::to_string)
        .or_else(|| {
            item.session_id
                .as_deref()
                .and_then(|session_id| session_worktrees.get(session_id))
                .cloned()
        })
        .or_else(|| {
            project_dir
                .filter(|path| !path.trim().is_empty())
                .map(ToString::to_string)
        })
        .or_else(|| {
            (!config.checkout_path.as_os_str().is_empty())
                .then(|| config.checkout_path.to_string_lossy().into_owned())
        })
}

pub(super) fn is_repo_scoped(item: &TaskBoardItem, config: &GitHubProjectConfig) -> bool {
    let repository = config.repository_slug();
    item.project_id.as_deref() == Some(repository.as_str())
}

pub(super) fn managed_branch_name(
    config: &GitHubProjectConfig,
    item_id: &str,
    host_id: &str,
) -> String {
    let host_suffix = &host_id[..host_id.len().min(8)];
    format!("{}{}-{}", config.branch_prefix.trim(), item_id, host_suffix)
}

pub(super) fn pull_request_request(
    item: &TaskBoardItem,
    config: &GitHubProjectConfig,
    branch: &str,
) -> GitHubCreatePullRequest {
    GitHubCreatePullRequest {
        title: item.title.clone(),
        body: Some(pull_request_body(item, config)),
        head_branch: branch.to_string(),
        base_branch: config.default_branch.clone(),
        draft: true,
    }
}

pub(super) fn update_pull_request_metadata(
    workflow: &mut TaskBoardWorkflowState,
    pull_request: &GitHubPullRequestHandle,
) {
    workflow.pr_number = Some(pull_request.number);
    workflow.pr_url.clone_from(&pull_request.html_url);
}

pub(super) fn load_session_worktrees(
    items: &[TaskBoardItem],
    db: Option<&DaemonDb>,
) -> Result<BTreeMap<String, String>, CliError> {
    let mut worktrees = BTreeMap::new();
    for session_id in items.iter().filter_map(|item| item.session_id.as_deref()) {
        let detail = session_detail_core(session_id, db)?;
        let path = detail.session.worktree_path.trim();
        if !path.is_empty() {
            worktrees.insert(session_id.to_string(), path.to_string());
        }
    }
    Ok(worktrees)
}

pub(super) async fn load_session_worktrees_async(
    items: &[TaskBoardItem],
    async_db: &AsyncDaemonDb,
) -> Result<BTreeMap<String, String>, CliError> {
    let mut worktrees = BTreeMap::new();
    for session_id in items.iter().filter_map(|item| item.session_id.as_deref()) {
        let detail = session_detail_core_async(session_id, Some(async_db)).await?;
        let path = detail.session.worktree_path.trim();
        if !path.is_empty() {
            worktrees.insert(session_id.to_string(), path.to_string());
        }
    }
    Ok(worktrees)
}

pub(super) fn automation_config(
    settings: &TaskBoardOrchestratorSettings,
) -> Option<(GitHubProjectConfig, String)> {
    let settings_repository = {
        let project = &settings.github_project;
        (!project.owner.trim().is_empty() && !project.repo.trim().is_empty())
            .then(|| project.repository_slug())
    };
    let external_sync_config =
        external_sync_config_for_repository(settings_repository.as_deref(), &[]);
    let token = external_sync_config
        .token_for(ExternalProvider::GitHub)?
        .to_string();
    let mut config = settings.github_project.clone();
    if (config.owner.trim().is_empty() || config.repo.trim().is_empty())
        && let Some(repository) = external_sync_config.github_repository()
        && let Some((owner, repo)) = repository.split_once('/')
    {
        config.owner = owner.to_string();
        config.repo = repo.to_string();
    }
    if config.owner.trim().is_empty() || config.repo.trim().is_empty() {
        return None;
    }
    let enabled = config
        .enabled_automations
        .enables(GitHubAutomation::CreateBranch)
        || config
            .enabled_automations
            .enables(GitHubAutomation::OpenPullRequest)
        || config
            .enabled_automations
            .enables(GitHubAutomation::WatchChecks)
        || config
            .enabled_automations
            .enables(GitHubAutomation::RequestReview)
        || config
            .enabled_automations
            .enables(GitHubAutomation::AutoMerge);
    enabled.then_some((config, token))
}

pub(super) fn action_policy(
    board_root: &Path,
    item: &TaskBoardItem,
    action: PolicyAction,
    branch: Option<&str>,
    pull_request: Option<u64>,
    input: Option<&PolicyInput>,
) -> PolicyDecision {
    let mut policy_input = input.cloned().unwrap_or_else(|| PolicyInput::new(action));
    policy_input.action = action;
    policy_input.subject = PolicySubject {
        task_board_item_id: Some(item.id.clone()),
        session_id: item.session_id.clone(),
        repository: item.project_id.clone(),
        branch: branch.map(ToString::to_string),
        pull_request: pull_request.map(|number| number.to_string()),
        ..PolicySubject::default()
    };
    if let Some(document) = resolve_gate_policy(board_root)
        && document.mode != PolicyPipelineMode::Draft
    {
        let simulation = document.simulate(&policy_input);
        let decision = simulation.decision;
        record_policy_decision(
            RecordedPolicyDecision::new(
                document.revision,
                policy_input,
                decision.clone(),
                simulation.visited_node_ids,
                "task_board_github",
            )
            .with_canvas_id(document.canvas_id.clone()),
        );
        return decision;
    }
    BuiltInPolicyGate::default().evaluate(&policy_input)
}

pub(super) fn waiting(
    workflow: &mut TaskBoardWorkflowState,
    step_id: &str,
) -> TaskBoardWorkflowState {
    workflow.current_step_id = Some(step_id.to_string());
    clear_error(workflow);
    workflow.clone()
}

pub(super) fn clear_error(workflow: &mut TaskBoardWorkflowState) {
    workflow.last_error = None;
}

pub(super) fn failure(
    workflow: &mut TaskBoardWorkflowState,
    step_id: &str,
    error: &CliError,
) -> TaskBoardWorkflowState {
    workflow.current_step_id = Some(step_id.to_string());
    workflow.last_error = Some(error.to_string());
    workflow.clone()
}

pub(super) fn step(workflow: &mut TaskBoardWorkflowState, step_id: &str) {
    workflow.current_step_id = Some(step_id.to_string());
    clear_error(workflow);
}

pub(super) fn policy_blocked(
    workflow: &mut TaskBoardWorkflowState,
    action: PolicyAction,
    decision: &PolicyDecision,
) -> TaskBoardWorkflowState {
    workflow.current_step_id = Some(STEP_POLICY_BLOCKED.to_string());
    workflow.last_error = Some(format!("policy blocked {action:?}: {decision:?}"));
    workflow.clone()
}

pub(super) fn new_policy_trace_id() -> String {
    format!("policy-trace-{}", Uuid::new_v4().simple())
}

pub(super) fn run_blocking<T>(
    future: impl Future<Output = Result<T, CliError>>,
) -> Result<T, CliError> {
    TokioRuntimeBuilder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| CliErrorKind::workflow_io(format!("create task-board runtime: {error}")))?
        .block_on(future)
}

fn pull_request_body(item: &TaskBoardItem, config: &GitHubProjectConfig) -> String {
    let mut lines = vec![format!("Task board item: `{}`", item.id)];
    if let Some(session_id) = &item.session_id {
        lines.push(format!("Session: `{session_id}`"));
    }
    if let Some(work_item_id) = &item.work_item_id {
        lines.push(format!("Work item: `{work_item_id}`"));
    }
    if let Some(summary) = item.planning.summary.as_deref() {
        lines.push(String::new());
        lines.push(summary.to_string());
    }
    if let Some(issue_number) = item.external_refs.iter().find_map(|reference| {
        let repository = config.repository_slug();
        (reference.provider == ExternalRefProvider::GitHub
            && item.project_id.as_deref() == Some(repository.as_str()))
        .then(|| reference.external_id.clone())
    }) {
        lines.push(String::new());
        lines.push(format!("Closes #{issue_number}"));
    }
    lines.join("\n")
}
