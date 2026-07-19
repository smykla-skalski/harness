use std::path::Path;

use tokio::task::spawn_blocking;

use crate::errors::{CliError, CliErrorKind};
use crate::git::GitRepository;
use crate::task_board::github::{
    GitHubAutomationClient, GitHubBranchState, GitHubProjectConfig, GitHubPullRequestHandle,
};
use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardPullRequestHeadIdentity, TaskBoardPullRequestIdentity,
    TaskBoardWorkflowExecutionRecord, normalize_repository_slug,
};

use super::invalid_transition;

pub(super) struct LocalHeadEvidence {
    pub(super) revision: String,
    pub(super) tree: String,
}

pub(super) fn freeze_pull_request(
    repository: &str,
    handle: &GitHubPullRequestHandle,
) -> Result<TaskBoardPullRequestIdentity, CliError> {
    if handle.merged || !handle.open {
        return Err(invalid_transition(
            "PrFix publication requires an open pull request",
        ));
    }
    let head_repository = handle
        .head_repository
        .as_deref()
        .and_then(|value| normalize_repository_slug(Some(value)))
        .ok_or_else(|| invalid_transition("pull request head repository is unavailable"))?;
    let head_branch = non_empty(handle.head_branch.as_deref())
        .ok_or_else(|| invalid_transition("pull request head branch is unavailable"))?;
    let head_revision = non_empty(Some(&handle.head_sha))
        .ok_or_else(|| invalid_transition("pull request head revision is unavailable"))?;
    Ok(TaskBoardPullRequestIdentity {
        repository: repository.into(),
        number: handle.number,
        head: Some(TaskBoardPullRequestHeadIdentity {
            repository: head_repository,
            branch: head_branch,
            revision: head_revision,
        }),
    })
}

pub(super) fn validate_pull_request_target(
    handle: &GitHubPullRequestHandle,
    identity: &TaskBoardPullRequestIdentity,
    expected_head: &TaskBoardPullRequestHeadIdentity,
) -> Result<(), CliError> {
    let actual = freeze_pull_request(&identity.repository, handle)?;
    let actual_head = required_frozen_head(&actual)?;
    if actual.number != identity.number
        || actual.repository != identity.repository
        || actual_head.repository != expected_head.repository
        || actual_head.branch != expected_head.branch
    {
        return Err(invalid_transition(
            "pull request publication target changed from its frozen identity",
        ));
    }
    Ok(())
}

pub(super) fn validate_published_evidence(
    handle: &GitHubPullRequestHandle,
    identity: &TaskBoardPullRequestIdentity,
    expected_head: &TaskBoardPullRequestHeadIdentity,
    branch: &GitHubBranchState,
    local: &LocalHeadEvidence,
) -> Result<(), CliError> {
    validate_pull_request_target(handle, identity, expected_head)?;
    if handle.head_sha != branch.commit_sha {
        return Err(invalid_transition(
            "pull request head does not match its frozen publication branch",
        ));
    }
    if branch.tree_sha != local.tree {
        return Err(invalid_transition(
            "published pull request tree does not match the reviewed implementation",
        ));
    }
    Ok(())
}

pub(super) fn validate_publication_repository(
    execution_repository: Option<&str>,
    configured_repository: &str,
) -> Result<(), CliError> {
    if execution_repository == Some(configured_repository) {
        Ok(())
    } else {
        Err(invalid_transition(
            "write workflow repository does not match GitHub publication configuration",
        ))
    }
}

pub(super) fn required_frozen_head(
    identity: &TaskBoardPullRequestIdentity,
) -> Result<&TaskBoardPullRequestHeadIdentity, CliError> {
    identity
        .head
        .as_ref()
        .ok_or_else(|| invalid_transition("write workflow has no frozen pull request head"))
}

pub(super) async fn required_branch_state(
    client: &dyn GitHubAutomationClient,
    config: &GitHubProjectConfig,
    branch: &str,
) -> Result<GitHubBranchState, CliError> {
    client
        .get_branch_state(config, branch)
        .await?
        .ok_or_else(|| {
            CliErrorKind::workflow_io(format!(
                "GitHub branch '{}/{}' is not visible",
                config.repository_slug(),
                branch
            ))
            .into()
        })
}

pub(super) fn implementation_base(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<&str, CliError> {
    execution
        .attempts
        .iter()
        .find_map(|attempt| match attempt.artifact.as_ref() {
            Some(TaskBoardAttemptResultArtifact::Implementation(result))
                if result.revision_cycle == 1 =>
            {
                Some(result.base_head_revision.as_str())
            }
            _ => None,
        })
        .ok_or_else(|| invalid_transition("write publication has no implementation base evidence"))
}

pub(super) async fn local_head_evidence(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<LocalHeadEvidence, CliError> {
    let worktree = worktree_path(execution)?.to_path_buf();
    let evidence = spawn_blocking(move || load_local_head_evidence(&worktree))
        .await
        .map_err(|error| {
            invalid_transition(format!("join publication head resolver: {error}"))
        })??;
    if execution.transition.exact_head_revision.as_deref() != Some(evidence.revision.as_str()) {
        return Err(invalid_transition(
            "local implementation head changed before publication verification",
        ));
    }
    Ok(evidence)
}

fn load_local_head_evidence(worktree: &Path) -> Result<LocalHeadEvidence, CliError> {
    let repository = GitRepository::discover(worktree)
        .map_err(|error| invalid_transition(format!("discover publication repository: {error}")))?;
    let repository = repository
        .open_gix()
        .map_err(|error| invalid_transition(format!("open publication repository: {error}")))?;
    let head = repository
        .head_commit()
        .map_err(|error| invalid_transition(format!("resolve publication HEAD: {error}")))?;
    let tree = head
        .tree_id()
        .map_err(|error| invalid_transition(format!("resolve publication tree: {error}")))?;
    Ok(LocalHeadEvidence {
        revision: head.id.to_hex().to_string(),
        tree: tree.detach().to_hex().to_string(),
    })
}

pub(super) fn worktree_path(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<&Path, CliError> {
    execution
        .snapshot
        .read_only_run_context
        .as_ref()
        .map(|context| Path::new(&context.worktree))
        .ok_or_else(|| invalid_transition("write publication has no frozen worktree"))
}

pub(super) fn publication_number(
    workflow_pr_number: Option<u64>,
    frozen_number: Option<u64>,
) -> Result<u64, CliError> {
    if let (Some(workflow), Some(frozen)) = (workflow_pr_number, frozen_number)
        && workflow != frozen
    {
        return Err(invalid_transition(
            "write workflow publication changed its frozen pull request",
        ));
    }
    workflow_pr_number.or(frozen_number).ok_or_else(|| {
        CliErrorKind::workflow_io("write workflow publication did not produce a pull request")
            .into()
    })
}

pub(super) fn known_publication_number(
    execution: &TaskBoardWorkflowExecutionRecord,
    known_external_url: Option<&str>,
    repository: &str,
) -> Result<u64, CliError> {
    let observed = known_external_url.map(parse_publication_url).transpose()?;
    if observed
        .as_ref()
        .is_some_and(|(observed_repository, _)| observed_repository != repository)
    {
        return Err(invalid_transition(
            "write workflow publication URL changed its frozen repository",
        ));
    }
    reconcile_publication_number(
        observed.map(|(_, number)| number),
        execution
            .transition
            .pull_request
            .as_ref()
            .map(|pr| pr.number),
    )
}

pub(in crate::daemon::service::task_board_github) fn reconcile_publication_number(
    observed_number: Option<u64>,
    frozen_number: Option<u64>,
) -> Result<u64, CliError> {
    match (observed_number, frozen_number) {
        (Some(observed), Some(frozen)) if observed != frozen => Err(invalid_transition(
            "write workflow publication changed its frozen pull request",
        )),
        (Some(observed), _) => Ok(observed),
        (None, Some(frozen)) => Ok(frozen),
        (None, None) => Err(CliErrorKind::workflow_io(
            "write workflow publication identity is unavailable after an ambiguous outcome",
        )
        .into()),
    }
}

pub(in crate::daemon::service::task_board_github) fn parse_publication_url(
    url: &str,
) -> Result<(String, u64), CliError> {
    let path = url
        .strip_prefix("https://github.com/")
        .ok_or_else(|| invalid_transition("publication URL is not canonical GitHub"))?;
    let (repository, number) = path
        .split_once("/pull/")
        .ok_or_else(|| invalid_transition("publication URL has no pull request"))?;
    let repository = normalize_repository_slug(Some(repository))
        .ok_or_else(|| invalid_transition("publication repository is invalid"))?;
    let number = number
        .parse::<u64>()
        .ok()
        .filter(|number| *number > 0)
        .ok_or_else(|| invalid_transition("publication pull request is invalid"))?;
    Ok((repository, number))
}

fn non_empty(value: Option<&str>) -> Option<String> {
    let value = value?.trim();
    (!value.is_empty()).then(|| value.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reconstructed_remote_commit_is_accepted_by_reviewed_tree_and_frozen_target() {
        let identity = frozen_identity();
        let head = required_frozen_head(&identity).expect("frozen head");
        let handle = pull_request_handle("remote-reconstructed-commit");
        let branch = GitHubBranchState {
            commit_sha: "remote-reconstructed-commit".into(),
            tree_sha: "reviewed-tree".into(),
        };
        let local = LocalHeadEvidence {
            revision: "local-reviewed-commit".into(),
            tree: "reviewed-tree".into(),
        };

        validate_published_evidence(&handle, &identity, head, &branch, &local)
            .expect("the remote commit may differ while its reviewed tree is exact");
        assert_ne!(local.revision, branch.commit_sha);
    }

    #[test]
    fn publication_verification_rejects_target_head_and_tree_drift() {
        let identity = frozen_identity();
        let head = required_frozen_head(&identity).expect("frozen head");
        let local = LocalHeadEvidence {
            revision: "local-reviewed-commit".into(),
            tree: "reviewed-tree".into(),
        };
        let branch = GitHubBranchState {
            commit_sha: "remote-reconstructed-commit".into(),
            tree_sha: "reviewed-tree".into(),
        };

        let mut wrong_target = pull_request_handle("remote-reconstructed-commit");
        wrong_target.head_repository = Some("example/upstream".into());
        assert!(
            validate_published_evidence(&wrong_target, &identity, head, &branch, &local).is_err()
        );

        let stale_head = pull_request_handle("stale-remote-commit");
        assert!(
            validate_published_evidence(&stale_head, &identity, head, &branch, &local).is_err()
        );

        let wrong_tree = GitHubBranchState {
            commit_sha: "remote-reconstructed-commit".into(),
            tree_sha: "different-tree".into(),
        };
        let handle = pull_request_handle("remote-reconstructed-commit");
        assert!(
            validate_published_evidence(&handle, &identity, head, &wrong_tree, &local).is_err()
        );
    }

    #[test]
    fn pull_request_target_requires_open_state_but_accepts_open_drafts() {
        let identity = frozen_identity();
        let head = required_frozen_head(&identity).expect("frozen head");

        let mut closed = pull_request_handle("frozen-source-head");
        closed.open = false;
        assert!(validate_pull_request_target(&closed, &identity, head).is_err());

        let mut merged = pull_request_handle("frozen-source-head");
        merged.open = false;
        merged.merged = true;
        assert!(validate_pull_request_target(&merged, &identity, head).is_err());

        let mut draft = pull_request_handle("frozen-source-head");
        draft.draft = true;
        validate_pull_request_target(&draft, &identity, head).expect("open draft target");
    }

    #[test]
    fn write_launch_repository_must_match_configured_publication() {
        validate_publication_repository(Some("example/compass"), "example/compass")
            .expect("matching repository");
        assert!(validate_publication_repository(None, "example/compass").is_err());
        assert!(validate_publication_repository(Some("example/other"), "example/compass").is_err());
    }

    fn frozen_identity() -> TaskBoardPullRequestIdentity {
        TaskBoardPullRequestIdentity {
            repository: "example/upstream".into(),
            number: 42,
            head: Some(TaskBoardPullRequestHeadIdentity {
                repository: "contributor/fork".into(),
                branch: "feature/fix".into(),
                revision: "frozen-source-head".into(),
            }),
        }
    }

    fn pull_request_handle(head_sha: &str) -> GitHubPullRequestHandle {
        GitHubPullRequestHandle {
            number: 42,
            html_url: Some("https://github.com/example/upstream/pull/42".into()),
            draft: false,
            open: true,
            merged: false,
            head_sha: head_sha.into(),
            head_repository: Some("contributor/fork".into()),
            head_branch: Some("feature/fix".into()),
            requested_reviewers: Vec::new(),
            requested_team_reviewers: Vec::new(),
        }
    }
}
