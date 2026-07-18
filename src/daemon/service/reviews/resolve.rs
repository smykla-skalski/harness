use std::collections::{BTreeMap, HashSet};

use crate::errors::CliError;
use crate::reviews::{
    ReviewItem, ReviewRepositoryLabel, ReviewsGitHubClient, ReviewsPullRequestReference,
    ReviewsPullRequestResolveRequest, ReviewsPullRequestResolveResponse,
};
use crate::workspace::utc_now;

use super::cache_internal::{patch_cached_items, patch_cached_repository_labels};
use super::policy;
use super::policy_event_inbox;
use super::token::token_bound_pull_request_references;

pub(super) struct ResolvedPullRequests {
    pub(super) items: Vec<ReviewItem>,
    missing_references: Vec<ReviewsPullRequestReference>,
    repository_labels: BTreeMap<String, Vec<ReviewRepositoryLabel>>,
    pub(super) authoritative_viewer_keys: HashSet<String>,
}

/// Resolve exact `owner/repo#number` pull request references without loading
/// all open pull requests from those repositories.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a required token is missing,
/// or GitHub cannot return the requested pull requests.
pub async fn resolve_review_pull_requests(
    request: &ReviewsPullRequestResolveRequest,
) -> Result<ReviewsPullRequestResolveResponse, CliError> {
    let resolved = fetch_pull_requests_by_reference(request).await?;
    if !resolved.repository_labels.is_empty() {
        patch_cached_repository_labels(&resolved.repository_labels);
    }
    patch_cached_items(&resolved.items, &[], &resolved.authoritative_viewer_keys);
    policy_event_inbox::resume_waiting_reviews_policy_runs(&resolved.items).await;
    policy::start_background_reviews_policy_runs(&resolved.items).await;
    Ok(ReviewsPullRequestResolveResponse {
        fetched_at: utc_now(),
        items: resolved.items,
        missing_references: resolved.missing_references,
    })
}

pub(super) async fn fetch_pull_requests_by_reference(
    request: &ReviewsPullRequestResolveRequest,
) -> Result<ResolvedPullRequests, CliError> {
    fetch_pull_requests_by_reference_with_freshness(request, false).await
}

pub(super) async fn fetch_pull_requests_by_reference_authoritative(
    request: &ReviewsPullRequestResolveRequest,
) -> Result<ResolvedPullRequests, CliError> {
    fetch_pull_requests_by_reference_with_freshness(request, true).await
}

async fn fetch_pull_requests_by_reference_with_freshness(
    request: &ReviewsPullRequestResolveRequest,
    authoritative: bool,
) -> Result<ResolvedPullRequests, CliError> {
    request.validate()?;
    let normalized = request.normalized_references();
    let references_by_key = normalized
        .iter()
        .map(|reference| (reference.key(), reference.clone()))
        .collect::<BTreeMap<_, _>>();
    let mut items = Vec::new();
    let mut missing_references = Vec::<ReviewsPullRequestReference>::new();
    let mut repository_labels = BTreeMap::new();
    let mut authoritative_viewer_keys = HashSet::new();
    for segment in token_bound_pull_request_references(&normalized)? {
        let segment_request = ReviewsPullRequestResolveRequest {
            references: segment.references,
            backport_detection_enabled: request.backport_detection_enabled,
            backport_patterns: request.normalized_backport_patterns(),
        };
        let client = ReviewsGitHubClient::new(&segment.token)?;
        let fetch = if authoritative {
            client
                .fetch_by_references_authoritative(&segment_request)
                .await?
        } else {
            client.fetch_by_references(&segment_request).await?
        };
        // GitHub returns both viewer-scoped values for the authenticated token.
        authoritative_viewer_keys.extend(fetch.items.iter().map(super::review_item_key));
        items.extend(fetch.items);
        missing_references.extend(
            fetch
                .missing
                .iter()
                .filter_map(|key| references_by_key.get(key).cloned()),
        );
        super::merge_segment_repository_labels(&mut repository_labels, fetch.repository_labels);
    }
    Ok(ResolvedPullRequests {
        items,
        missing_references,
        repository_labels,
        authoritative_viewer_keys,
    })
}
