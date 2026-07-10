//! Token routing helpers for the reviews service.
//!
//! Splits an incoming query or action request into per-token segments so each
//! GitHub call is made with the correct repository-scoped or global token.

use std::collections::BTreeMap;

use crate::daemon::service::task_board_runtime::external_sync_config_for_repository;
use crate::errors::{CliError, CliErrorKind};
use crate::reviews::{ReviewTarget, ReviewsPullRequestReference, ReviewsQueryRequest};
use crate::task_board::ExternalProvider;

#[derive(Clone)]
pub(super) struct TokenBoundRequest {
    pub(super) token: String,
    pub(super) request: ReviewsQueryRequest,
}

#[derive(Clone)]
pub(super) struct TokenBoundTargets {
    pub(super) token: String,
    pub(super) targets: Vec<ReviewTarget>,
}

#[derive(Clone)]
pub(super) struct TokenBoundPullRequestReferences {
    pub(super) token: String,
    pub(super) references: Vec<ReviewsPullRequestReference>,
}

pub(super) fn token_bound_requests(
    request: &ReviewsQueryRequest,
) -> Result<Vec<TokenBoundRequest>, CliError> {
    let global_token = github_token(None);
    let mut segments = Vec::new();

    let org_request = request.organization_only_request();
    if !org_request.normalized_organizations().is_empty() {
        let token = global_token
            .clone()
            .ok_or_else(|| missing_token_error(None))?;
        segments.push(TokenBoundRequest {
            token,
            request: org_request,
        });
    }

    let excluded = request.normalized_exclude_repositories();
    for repository in request.normalized_repositories() {
        if excluded.contains(&repository) {
            continue;
        }
        let token = github_token(Some(repository.as_str()))
            .or_else(|| global_token.clone())
            .ok_or_else(|| missing_token_error(Some(repository.as_str())))?;
        segments.push(TokenBoundRequest {
            token,
            request: request.repository_only_request(&repository),
        });
    }

    if segments.is_empty() {
        return Err(CliErrorKind::workflow_parse(
            "reviews query resolved to zero token-backed scopes",
        )
        .into());
    }
    Ok(segments)
}

pub(super) fn token_bound_targets(
    targets: &[ReviewTarget],
) -> Result<Vec<TokenBoundTargets>, CliError> {
    let global_token = github_token(None);
    let mut grouped = BTreeMap::<String, Vec<ReviewTarget>>::new();
    for target in targets {
        let token = github_token(Some(target.repository.as_str()))
            .or_else(|| global_token.clone())
            .ok_or_else(|| missing_token_error(Some(target.repository.as_str())))?;
        grouped.entry(token).or_default().push(target.clone());
    }
    Ok(grouped
        .into_iter()
        .map(|(token, targets)| TokenBoundTargets { token, targets })
        .collect())
}

pub(super) fn token_bound_pull_request_references(
    references: &[ReviewsPullRequestReference],
) -> Result<Vec<TokenBoundPullRequestReferences>, CliError> {
    let global_token = github_token(None);
    let mut grouped = BTreeMap::<String, Vec<ReviewsPullRequestReference>>::new();
    for reference in references {
        let repository = reference.normalized_repository();
        let token = github_token(Some(repository.as_str()))
            .or_else(|| global_token.clone())
            .ok_or_else(|| missing_token_error(Some(repository.as_str())))?;
        grouped.entry(token).or_default().push(reference.clone());
    }
    Ok(grouped
        .into_iter()
        .map(|(token, references)| TokenBoundPullRequestReferences { token, references })
        .collect())
}

pub(super) fn github_token(repository: Option<&str>) -> Option<String> {
    external_sync_config_for_repository(repository, &[])
        .token_for(ExternalProvider::GitHub)
        .map(ToString::to_string)
}

pub(super) fn missing_token_error(repository: Option<&str>) -> CliError {
    match repository {
        Some(repository) => CliErrorKind::workflow_io(format!(
            "reviews requires a GitHub token for '{repository}'. Configure one in Settings > Secrets."
        ))
        .into(),
        None => CliErrorKind::workflow_io(
            "reviews requires a GitHub token. Configure one in Settings > Secrets.",
        )
        .into(),
    }
}
