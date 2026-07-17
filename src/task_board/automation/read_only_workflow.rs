use thiserror::Error;

use crate::task_board::{
    ExternalRef, ExternalRefProvider, TaskBoardItem, TaskBoardPullRequestIdentity, TaskBoardStatus,
    normalize_repository_slug,
};

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum TaskBoardReadOnlyWorkflowContractError {
    #[error("workflow execution repository is invalid")]
    InvalidRepository,
    #[error("PrReview workflow requires exactly one active GitHub pull request")]
    AmbiguousPullRequest,
    #[error("PrReview pull request identity is incomplete")]
    IncompletePullRequest,
    #[error("PrReview pull request number is invalid")]
    InvalidPullRequestNumber,
    #[error("PrReview pull request contradicts its execution repository")]
    PullRequestRepositoryMismatch,
}

/// Resolve the canonical repository used by a read-only workflow.
///
/// Explicit execution targeting wins. Legacy project identity is accepted only when the item is
/// linked to GitHub, so unrelated provider project ids cannot become repository slugs.
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
    Ok(TaskBoardPullRequestIdentity { repository, number })
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
    use crate::task_board::{ExternalRef, ExternalRefProvider, TaskBoardItem};

    use super::*;

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
