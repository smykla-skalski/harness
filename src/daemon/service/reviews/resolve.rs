use std::collections::BTreeMap;

use crate::errors::CliError;
use crate::reviews::{
    ReviewsGitHubClient, ReviewsPullRequestReference, ReviewsPullRequestResolveRequest,
    ReviewsPullRequestResolveResponse,
};
use crate::workspace::utc_now;

use super::cache_internal::{patch_cached_items, patch_cached_repository_labels};
use super::policy;
use super::policy_event_inbox;
use super::token::token_bound_pull_request_references;

/// Resolve exact `owner/repo#number` pull request references without loading
/// all open pull requests from those repositories.
///
/// # Errors
/// Returns `CliError` when the request is invalid, a required token is missing,
/// or GitHub cannot return the requested pull requests.
pub async fn resolve_review_pull_requests(
    request: &ReviewsPullRequestResolveRequest,
) -> Result<ReviewsPullRequestResolveResponse, CliError> {
    request.validate()?;
    let normalized = request.normalized_references();
    let references_by_key = normalized
        .iter()
        .map(|reference| (reference.key(), reference.clone()))
        .collect::<BTreeMap<_, _>>();
    let mut items = Vec::new();
    let mut missing_references = Vec::<ReviewsPullRequestReference>::new();
    for segment in token_bound_pull_request_references(&normalized)? {
        let segment_request = ReviewsPullRequestResolveRequest {
            references: segment.references,
            backport_detection_enabled: request.backport_detection_enabled,
            backport_patterns: request.normalized_backport_patterns(),
        };
        let client = ReviewsGitHubClient::new(&segment.token)?;
        let viewer_login = client.fetch_viewer_login().await;
        let fetch = client
            .fetch_by_references(&segment_request, viewer_login.as_deref())
            .await?;
        items.extend(fetch.items);
        missing_references.extend(
            fetch
                .missing
                .iter()
                .filter_map(|key| references_by_key.get(key).cloned()),
        );
        if !fetch.repository_labels.is_empty() {
            patch_cached_repository_labels(&fetch.repository_labels);
        }
    }
    patch_cached_items(&items, &[]);
    policy_event_inbox::resume_waiting_reviews_policy_runs(&items).await;
    policy::start_background_reviews_policy_runs(&items).await;
    Ok(ReviewsPullRequestResolveResponse {
        fetched_at: utc_now(),
        items,
        missing_references,
    })
}
