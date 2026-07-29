use thiserror::Error;

use crate::{
    ExternalRef, ExternalRefProvider, TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION, TaskBoardItem,
    TaskBoardPullRequestIdentity, TaskBoardReadOnlyRunContext, TaskBoardStatus,
    normalize_repository_slug,
};

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum TaskBoardReadOnlyWorkflowContractError {
    #[error("workflow execution repository is invalid")]
    InvalidRepository,
    #[error("pull request workflow requires exactly one active GitHub pull request")]
    AmbiguousPullRequest,
    #[error("pull request identity is incomplete")]
    IncompletePullRequest,
    #[error("pull request number is invalid")]
    InvalidPullRequestNumber,
    #[error("pull request contradicts its execution repository")]
    PullRequestRepositoryMismatch,
    #[error("read-only workflow run context uses an unsupported schema version")]
    UnsupportedRunContextVersion,
    #[error("read-only workflow run context is incomplete")]
    IncompleteRunContext,
    #[error("read-only workflow item revision fence is invalid")]
    InvalidItemRevisionFence,
    #[error("pull request identity no longer matches the item's active pull request")]
    PullRequestIdentityChanged,
}

/// Validate the monotonic item revision fence carried by a read-only launch.
///
/// # Errors
///
/// Returns an error when either revision is invalid or the prepared revision predates capture.
pub fn validate_task_board_read_only_item_revisions(
    source_item_revision: i64,
    prepared_item_revision: i64,
) -> Result<(), TaskBoardReadOnlyWorkflowContractError> {
    if source_item_revision > 0 && prepared_item_revision >= source_item_revision {
        Ok(())
    } else {
        Err(TaskBoardReadOnlyWorkflowContractError::InvalidItemRevisionFence)
    }
}

/// Validate an immutable local run context before it is used for a read-only workflow.
///
/// # Errors
///
/// Returns an error when the version is unsupported or the stable session, title, or worktree
/// binding is empty.
pub fn validate_task_board_read_only_run_context(
    context: &TaskBoardReadOnlyRunContext,
) -> Result<(), TaskBoardReadOnlyWorkflowContractError> {
    if context.schema_version != TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION {
        return Err(TaskBoardReadOnlyWorkflowContractError::UnsupportedRunContextVersion);
    }
    if context.session_id.trim().is_empty()
        || context.title.trim().is_empty()
        || context.worktree.trim().is_empty()
    {
        return Err(TaskBoardReadOnlyWorkflowContractError::IncompleteRunContext);
    }
    Ok(())
}

/// Resolve the canonical repository used by a read-only workflow.
///
/// Explicit execution targeting wins. Legacy project identity is accepted only when the item is
/// linked to GitHub, so unrelated provider project ids cannot become repository slugs.
///
/// # Errors
///
/// Returns an error when the selected repository cannot be normalized to an owner/repository slug.
pub fn task_board_read_only_execution_repository(
    item: &TaskBoardItem,
) -> Result<Option<String>, TaskBoardReadOnlyWorkflowContractError> {
    let repository = item.execution_repository.as_deref().or_else(|| {
        item.external_refs
            .iter()
            .any(|reference| reference.provider == ExternalRefProvider::GitHub)
            .then_some(item.project_id.as_deref())
            .flatten()
    });
    repository.map_or(Ok(None), |repository| {
        normalize_repository_slug(Some(repository))
            .map(Some)
            .ok_or(TaskBoardReadOnlyWorkflowContractError::InvalidRepository)
    })
}

/// Resolve one active GitHub pull-request identity and bind it to the execution repository.
///
/// The returned identity carries no head: a board item records only the repository and number,
/// never the head branch or revision. The frozen head is captured once from a live GitHub read at
/// launch and threaded through the workflow launch, so any later re-derivation compares against
/// that frozen head rather than expecting the item to reproduce it.
///
/// # Errors
///
/// Returns an error when the item does not have exactly one active GitHub pull request, its
/// identity is incomplete or invalid, or its repository contradicts the execution repository.
pub fn resolve_task_board_pull_request_identity(
    item: &TaskBoardItem,
) -> Result<TaskBoardPullRequestIdentity, TaskBoardReadOnlyWorkflowContractError> {
    let references = item
        .external_refs
        .iter()
        .filter(|reference| is_active_github_pull_request(reference))
        .collect::<Vec<_>>();
    let [reference] = references.as_slice() else {
        return Err(TaskBoardReadOnlyWorkflowContractError::AmbiguousPullRequest);
    };
    parse_pull_request_reference(item, reference)
}

fn parse_pull_request_reference(
    item: &TaskBoardItem,
    reference: &ExternalRef,
) -> Result<TaskBoardPullRequestIdentity, TaskBoardReadOnlyWorkflowContractError> {
    let (repository, number) = reference
        .external_id
        .rsplit_once('#')
        .map_or_else(
            || {
                item.execution_repository
                    .as_deref()
                    .or(item.project_id.as_deref())
                    .zip(Some(reference.external_id.as_str()))
            },
            |(repository, number)| Some((repository, number)),
        )
        .ok_or(TaskBoardReadOnlyWorkflowContractError::IncompletePullRequest)?;
    let repository = normalize_repository_slug(Some(repository))
        .ok_or(TaskBoardReadOnlyWorkflowContractError::InvalidRepository)?;
    let number = number
        .trim()
        .parse::<u64>()
        .ok()
        .filter(|number| *number > 0)
        .ok_or(TaskBoardReadOnlyWorkflowContractError::InvalidPullRequestNumber)?;
    if task_board_read_only_execution_repository(item)?.as_deref() != Some(repository.as_str()) {
        return Err(TaskBoardReadOnlyWorkflowContractError::PullRequestRepositoryMismatch);
    }
    Ok(TaskBoardPullRequestIdentity {
        repository,
        number,
        head: None,
    })
}

/// Confirm that a frozen pull-request identity still describes the item's active pull request.
///
/// Durable start and worker start re-run this against the live item. The item exposes only the
/// repository and number, so the check matches on those and treats the launch's frozen head as
/// authoritative; an unchanged pull request whose head the item cannot reproduce is never mistaken
/// for a changed identity. When `require_head` is set, a dependency-update launch that lost its
/// frozen head is rejected instead of silently starting without one.
///
/// # Errors
///
/// Returns an error when the item no longer resolves to the frozen repository and number, when the
/// item's pull request can no longer be resolved, or when a required frozen head is absent.
pub fn confirm_frozen_pull_request_identity(
    item: &TaskBoardItem,
    frozen: &TaskBoardPullRequestIdentity,
    require_head: bool,
) -> Result<(), TaskBoardReadOnlyWorkflowContractError> {
    let derived = resolve_task_board_pull_request_identity(item)?;
    if derived.repository != frozen.repository || derived.number != frozen.number {
        return Err(TaskBoardReadOnlyWorkflowContractError::PullRequestIdentityChanged);
    }
    if require_head && frozen.head.is_none() {
        return Err(TaskBoardReadOnlyWorkflowContractError::IncompletePullRequest);
    }
    Ok(())
}

fn is_active_github_pull_request(reference: &ExternalRef) -> bool {
    reference.provider == ExternalRefProvider::GitHub
        && reference
            .url
            .as_deref()
            .is_some_and(|url| url.contains("/pull/"))
        && reference.sync_state.as_ref().and_then(|state| state.status)
            != Some(TaskBoardStatus::Done)
}

#[cfg(test)]
mod tests {
    use crate::{ExternalRef, ExternalRefProvider, TaskBoardItem};

    use super::*;

    #[test]
    fn item_revision_fence_accepts_equal_or_advanced_preparation() {
        for (source, prepared) in [(1, 1), (1, 2), (7, 9)] {
            validate_task_board_read_only_item_revisions(source, prepared)
                .expect("valid item revision fence");
        }
    }

    #[test]
    fn item_revision_fence_rejects_nonpositive_or_regressing_revisions() {
        for (source, prepared) in [(0, 0), (-1, 1), (2, 1)] {
            let error = validate_task_board_read_only_item_revisions(source, prepared)
                .expect_err("invalid item revision fence");
            assert_eq!(
                error,
                TaskBoardReadOnlyWorkflowContractError::InvalidItemRevisionFence
            );
        }
    }

    #[test]
    fn pull_request_identity_ignores_issues_and_normalizes_legacy_repository() {
        let mut item = item();
        item.execution_repository = None;
        item.project_id = Some(" Acme/Widgets ".into());
        item.external_refs.insert(0, github_ref("17", "/issues/17"));

        let identity = resolve_task_board_pull_request_identity(&item).expect("pull request");

        assert_eq!(identity.repository, "acme/widgets");
        assert_eq!(identity.number, 17);
    }

    #[test]
    fn pull_request_identity_rejects_two_active_pull_requests() {
        let mut item = item();
        item.external_refs
            .push(github_ref("acme/widgets#18", "/pull/18"));

        let error = resolve_task_board_pull_request_identity(&item)
            .expect_err("ambiguous pull request must fail");

        assert_eq!(
            error,
            TaskBoardReadOnlyWorkflowContractError::AmbiguousPullRequest
        );
    }

    #[test]
    fn pull_request_identity_rejects_repository_drift() {
        let mut item = item();
        item.external_refs = vec![github_ref("acme/other#17", "/pull/17")];

        let error = resolve_task_board_pull_request_identity(&item)
            .expect_err("repository drift must fail");

        assert_eq!(
            error,
            TaskBoardReadOnlyWorkflowContractError::PullRequestRepositoryMismatch
        );
    }

    fn frozen(repository: &str, number: u64, with_head: bool) -> TaskBoardPullRequestIdentity {
        TaskBoardPullRequestIdentity {
            repository: repository.into(),
            number,
            head: with_head.then(|| crate::TaskBoardPullRequestHeadIdentity {
                repository: repository.into(),
                branch: "renovate/dependency-update".into(),
                revision: "cafef00d".into(),
            }),
        }
    }

    #[test]
    fn frozen_identity_matches_the_items_repository_and_number() {
        let item = item();

        confirm_frozen_pull_request_identity(&item, &frozen("acme/widgets", 17, true), true)
            .expect("unchanged pull request confirms");
        confirm_frozen_pull_request_identity(&item, &frozen("acme/widgets", 17, false), false)
            .expect("read-only style headless identity confirms when the head is not required");
    }

    #[test]
    fn frozen_identity_rejects_a_missing_required_head() {
        let item = item();

        let error =
            confirm_frozen_pull_request_identity(&item, &frozen("acme/widgets", 17, false), true)
                .expect_err("a dependency launch without a frozen head must be rejected");

        assert_eq!(
            error,
            TaskBoardReadOnlyWorkflowContractError::IncompletePullRequest
        );
    }

    #[test]
    fn frozen_identity_rejects_a_changed_repository_or_number() {
        let item = item();

        for changed in [
            frozen("acme/widgets", 18, true),
            frozen("acme/other", 17, true),
        ] {
            let error = confirm_frozen_pull_request_identity(&item, &changed, true)
                .expect_err("a changed pull request identity must be rejected");
            assert_eq!(
                error,
                TaskBoardReadOnlyWorkflowContractError::PullRequestIdentityChanged
            );
        }
    }

    fn item() -> TaskBoardItem {
        let mut item = TaskBoardItem::new(
            "review-1".into(),
            "Review PR".into(),
            String::new(),
            "2026-07-17T00:00:00Z".into(),
        );
        item.execution_repository = Some("acme/widgets".into());
        item.external_refs = vec![github_ref("Acme/Widgets#17", "/pull/17")];
        item
    }

    fn github_ref(external_id: &str, path: &str) -> ExternalRef {
        ExternalRef {
            provider: ExternalRefProvider::GitHub,
            external_id: external_id.into(),
            url: Some(format!("https://github.com/acme/widgets{path}")),
            sync_state: None,
        }
    }
}
