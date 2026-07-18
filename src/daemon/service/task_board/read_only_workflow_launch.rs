use std::path::{Path, PathBuf};

use tokio::task::spawn_blocking;

use crate::daemon::db::AsyncDaemonDb;
use crate::errors::{CliError, CliErrorKind};
use crate::git::GitRepository;
use crate::reviews::ReviewPullRequestState;
use crate::task_board::{
    AgentMode, DispatchAppliedTask, TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION, TaskBoardItem,
    TaskBoardPullRequestIdentity, TaskBoardReadOnlyRunContext, TaskBoardReadOnlyWorkflowLaunch,
    TaskBoardWorkflowKind, resolve_task_board_pull_request_identity, resolve_task_board_reviewers,
    task_board_read_only_execution_repository, validate_task_board_read_only_item_revisions,
    validate_task_board_read_only_run_context,
};

pub(super) async fn prepare_read_only_workflow_launch(
    db: &AsyncDaemonDb,
    item_id: &str,
    session_id: &str,
    worktree: &str,
    source_item_revision: Option<i64>,
) -> Result<Option<TaskBoardReadOnlyWorkflowLaunch>, CliError> {
    let item_snapshot = db.task_board_item_snapshot(item_id).await?;
    let item = item_snapshot.item;
    let source_item_revision = match (
        is_read_only_workflow(item.workflow_kind),
        source_item_revision,
    ) {
        (false, None) => return Ok(None),
        (false, Some(_)) => {
            return Err(invalid_transition(
                "read-only workflow kind changed after dispatch reservation",
            ));
        }
        (true, None) => {
            return Err(invalid_transition(
                "read-only workflow preparation has no frozen item revision",
            ));
        }
        (true, Some(source_item_revision)) => source_item_revision,
    };
    if item_snapshot.item_revision != source_item_revision {
        return Err(invalid_transition(
            "read-only workflow item revision changed after dispatch reservation",
        ));
    }
    if item.agent_mode != AgentMode::Evaluate {
        return Err(invalid_transition(
            "Review and PrReview workflows require Evaluate agent mode",
        ));
    }
    let settings = db.task_board_orchestrator_settings_snapshot().await?;
    let configuration_revision = u64::try_from(settings.row_revision)
        .map_err(|_| invalid_transition("orchestrator settings revision is out of range"))?;
    let execution_repository = normalized_execution_repository(&item)?;
    let resolved_reviewers = resolve_task_board_reviewers(
        &settings.settings.reviewers,
        item.workflow_kind,
        execution_repository.as_deref(),
    )
    .map_err(|error| invalid_transition(error.to_string()))?;
    ensure_supported_runtimes(&resolved_reviewers)?;
    let (pull_request, exact_head_revision) = resolve_exact_head(&item, worktree).await?;
    Ok(Some(TaskBoardReadOnlyWorkflowLaunch {
        workflow_kind: item.workflow_kind,
        execution_repository,
        configuration_revision,
        policy_version: settings.settings.policy_version,
        resolved_reviewers,
        source_item_revision,
        prepared_item_revision: source_item_revision,
        run_context: TaskBoardReadOnlyRunContext {
            schema_version: TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
            session_id: session_id.to_string(),
            title: item.title.clone(),
            body: item.body.clone(),
            tags: item.tags.clone(),
            worktree: worktree.to_string(),
        },
        provider_revision: None,
        pull_request,
        exact_head_revision,
    }))
}

pub(crate) async fn validate_read_only_workflow_launch(
    db: &AsyncDaemonDb,
    applied: &DispatchAppliedTask,
) -> Result<(), CliError> {
    let Some(launch) = applied.read_only_workflow.as_ref() else {
        return Ok(());
    };
    let item_snapshot = db.task_board_item_snapshot(&applied.board_item_id).await?;
    let item = item_snapshot.item;
    let settings = db.task_board_orchestrator_settings_snapshot().await?;
    validate_task_board_read_only_run_context(&launch.run_context)
        .map_err(|error| invalid_transition(error.to_string()))?;
    validate_task_board_read_only_item_revisions(
        launch.source_item_revision,
        launch.prepared_item_revision,
    )
    .map_err(|error| invalid_transition(error.to_string()))?;
    let configuration_revision = u64::try_from(settings.row_revision)
        .map_err(|_| invalid_transition("orchestrator settings revision is out of range"))?;
    let execution_repository = normalized_execution_repository(&item)?;
    let reviewers = resolve_task_board_reviewers(
        &settings.settings.reviewers,
        item.workflow_kind,
        execution_repository.as_deref(),
    )
    .map_err(|error| invalid_transition(error.to_string()))?;
    ensure_supported_runtimes(&reviewers)?;
    if item.workflow_kind != launch.workflow_kind
        || item.agent_mode != AgentMode::Evaluate
        || execution_repository != launch.execution_repository
        || configuration_revision != launch.configuration_revision
        || settings.settings.policy_version != launch.policy_version
        || reviewers != launch.resolved_reviewers
        || item_snapshot.item_revision != launch.prepared_item_revision
        || launch.run_context.session_id != applied.session_id
        || launch.run_context.title != item.title
        || launch.run_context.body != item.body
        || launch.run_context.tags != item.tags
        || item.session_id.as_deref() != Some(launch.run_context.session_id.as_str())
        || item.workflow.worktree.as_deref() != Some(launch.run_context.worktree.as_str())
    {
        return Err(invalid_transition(
            "read-only workflow launch contract changed before worker start",
        ));
    }
    let fresh_head = if let Some(identity) = launch.pull_request.as_ref() {
        resolve_pr_review_head(identity).await?
    } else {
        let worktree = item
            .workflow
            .worktree
            .as_deref()
            .ok_or_else(|| invalid_transition("Review workflow has no local worktree"))?;
        let worktree = PathBuf::from(worktree);
        spawn_blocking(move || local_head(&worktree))
            .await
            .map_err(|error| invalid_transition(format!("join local head resolver: {error}")))??
    };
    if fresh_head != launch.exact_head_revision {
        return Err(invalid_transition(
            "read-only workflow exact head changed before worker start",
        ));
    }
    Ok(())
}

pub(crate) async fn resolve_pr_review_head(
    identity: &TaskBoardPullRequestIdentity,
) -> Result<String, CliError> {
    let review =
        super::super::reviews::resolve_exact_pull_request(&identity.repository, identity.number)
            .await?;
    if review.state != ReviewPullRequestState::Open {
        return Err(invalid_transition(format!(
            "pull request '{}#{}' is not open",
            identity.repository, identity.number
        )));
    }
    required_head(&review.head_sha)
}

async fn resolve_exact_head(
    item: &TaskBoardItem,
    worktree: &str,
) -> Result<(Option<TaskBoardPullRequestIdentity>, String), CliError> {
    if item.workflow_kind == TaskBoardWorkflowKind::PrReview {
        let identity = resolve_task_board_pull_request_identity(item)
            .map_err(|error| invalid_transition(error.to_string()))?;
        let head = resolve_pr_review_head(&identity).await?;
        return Ok((Some(identity), head));
    }
    let worktree = PathBuf::from(worktree);
    let head = spawn_blocking(move || local_head(&worktree))
        .await
        .map_err(|error| invalid_transition(format!("join local head resolver: {error}")))??;
    Ok((None, head))
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

fn ensure_supported_runtimes(
    reviewers: &crate::task_board::TaskBoardResolvedReviewer,
) -> Result<(), CliError> {
    if reviewers
        .profiles
        .iter()
        .all(|profile| profile.runtime == "codex")
    {
        Ok(())
    } else {
        Err(invalid_transition(
            "local read-only workflows currently require Codex reviewer runtimes",
        ))
    }
}

fn normalized_execution_repository(item: &TaskBoardItem) -> Result<Option<String>, CliError> {
    task_board_read_only_execution_repository(item)
        .map_err(|error| invalid_transition(error.to_string()))
}

fn required_head(head: &str) -> Result<String, CliError> {
    let head = head.trim();
    if head.is_empty() {
        Err(invalid_transition("workflow exact head is empty"))
    } else {
        Ok(head.to_string())
    }
}

const fn is_read_only_workflow(kind: TaskBoardWorkflowKind) -> bool {
    matches!(
        kind,
        TaskBoardWorkflowKind::Review | TaskBoardWorkflowKind::PrReview
    )
}

fn invalid_transition(detail: impl Into<String>) -> CliError {
    CliErrorKind::invalid_transition(detail.into()).into()
}
