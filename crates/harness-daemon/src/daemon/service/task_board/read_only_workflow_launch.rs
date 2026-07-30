use std::path::{Path, PathBuf};

use tokio::task::spawn_blocking;

use crate::daemon::db::AsyncDaemonDb;
use crate::git::GitRepository;
use crate::reviews::ReviewPullRequestState;
use crate::sandbox;
use crate::task_board::TaskBoardResolvedReviewer;
use crate::task_board::{
    AgentMode, DispatchAppliedTask, TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION, TaskBoardItem,
    TaskBoardPullRequestIdentity, TaskBoardReadOnlyRunContext, TaskBoardReadOnlyWorkflowLaunch,
    TaskBoardWorkflowKind, resolve_task_board_pull_request_identity, resolve_task_board_reviewers,
    task_board_read_only_execution_repository, validate_task_board_read_only_item_revisions,
    validate_task_board_read_only_run_context,
};
use harness_kernel::errors::{CliError, CliErrorKind};

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
        (false, _) => return Ok(None),
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
    ensure_supported_read_only_runtimes(&resolved_reviewers)?;
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
    ensure_supported_read_only_runtimes(&reviewers)?;
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
        resolve_worktree_head(worktree).await?
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
    if item.workflow_kind.is_read_only_review() {
        let identity = resolve_task_board_pull_request_identity(item)
            .map_err(|error| invalid_transition(error.to_string()))?;
        let head = resolve_pr_review_head(&identity).await?;
        return Ok((Some(identity), head));
    }
    let head = resolve_worktree_head(worktree).await?;
    Ok((None, head))
}

pub(super) async fn resolve_worktree_head(worktree: &str) -> Result<String, CliError> {
    let worktree = PathBuf::from(worktree);
    spawn_blocking(move || local_head(&worktree))
        .await
        .map_err(|error| invalid_transition(format!("join local head resolver: {error}")))?
}

fn local_head(worktree: &Path) -> Result<String, CliError> {
    // Bind the grant, never `let _ =`: it must outlive every read below, or a
    // sandboxed daemon loses access to the origin gitdir mid-call.
    let _origin_grant = sandbox::hold_worktree_origin_grant(worktree);
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

/// Reviewer runtimes a local read-only workflow can dispatch. Codex runs the
/// long-standing durable path; `openrouter` runs the shared non-Codex turn
/// through the `agent_turn_runs` store. The write launch path is stricter -
/// there is no non-Codex write execution yet - so it keeps its own set rather
/// than sharing this one.
pub(super) const SUPPORTED_READ_ONLY_RUNTIMES: [&str; 2] = ["codex", "openrouter"];

/// Refuse a reviewer profile whose runtime is not in `allowed`, before any side
/// effect. `workflow` names the launch path so the operator-facing error is
/// accurate for whichever gate rejected it.
pub(super) fn ensure_runtimes_supported(
    reviewers: &TaskBoardResolvedReviewer,
    allowed: &[&str],
    workflow: &str,
) -> Result<(), CliError> {
    if let Some(profile) = reviewers
        .profiles
        .iter()
        .find(|profile| !allowed.contains(&profile.runtime.as_str()))
    {
        Err(invalid_transition(format!(
            "local {workflow} workflows do not support reviewer runtime '{}'",
            profile.runtime
        )))
    } else {
        Ok(())
    }
}

pub(super) fn ensure_supported_read_only_runtimes(
    reviewers: &TaskBoardResolvedReviewer,
) -> Result<(), CliError> {
    ensure_runtimes_supported(reviewers, &SUPPORTED_READ_ONLY_RUNTIMES, "read-only")
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
    matches!(kind, TaskBoardWorkflowKind::Review) || kind.is_read_only_review()
}

fn invalid_transition(detail: impl Into<String>) -> CliError {
    CliErrorKind::invalid_transition(detail.into()).into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task_board::TaskBoardReviewerProfile;

    fn reviewer(runtime: &str) -> TaskBoardReviewerProfile {
        TaskBoardReviewerProfile {
            id: format!("reviewer-{runtime}"),
            runtime: runtime.into(),
            persona: "code-reviewer".into(),
            agent_mode: crate::task_board::AgentMode::Evaluate,
            model: None,
            effort: None,
        }
    }

    fn resolved(runtimes: &[&str]) -> TaskBoardResolvedReviewer {
        TaskBoardResolvedReviewer {
            reviewer_count: 1,
            required_approvals: 1,
            max_revision_cycles: 3,
            profiles: runtimes.iter().map(|runtime| reviewer(runtime)).collect(),
        }
    }

    #[test]
    fn read_only_gate_accepts_codex_and_openrouter() {
        ensure_supported_read_only_runtimes(&resolved(&["codex"])).expect("codex accepted");
        ensure_supported_read_only_runtimes(&resolved(&["openrouter"]))
            .expect("openrouter accepted");
        ensure_supported_read_only_runtimes(&resolved(&["codex", "openrouter"]))
            .expect("a mixed supported set is accepted");
    }

    #[test]
    fn read_only_gate_refuses_an_unsupported_runtime_by_name() {
        let error = ensure_supported_read_only_runtimes(&resolved(&["gemini"]))
            .expect_err("unsupported runtime");
        assert!(error.to_string().contains("gemini"), "{error}");
        assert!(error.to_string().contains("read-only"), "{error}");
    }

    #[test]
    fn a_stricter_gate_refuses_openrouter_with_its_own_wording() {
        // The write launch path passes a Codex-only set: openrouter is refused
        // there, and the error names that path rather than "read-only".
        ensure_runtimes_supported(&resolved(&["codex"]), &["codex"], "write")
            .expect("codex accepted on the write path");
        let error = ensure_runtimes_supported(&resolved(&["openrouter"]), &["codex"], "write")
            .expect_err("openrouter refused on the write path");
        assert!(error.to_string().contains("openrouter"), "{error}");
        assert!(error.to_string().contains("write"), "{error}");
    }
}
