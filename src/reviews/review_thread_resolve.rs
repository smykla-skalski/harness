//! Review-thread resolve / unresolve write-action: types + GitHub
//! mutation invocation. The daemon service layer calls
//! `execute_review_thread_resolve_mutation` so the GraphQL strings +
//! protected GitHub dispatch stay inside the `reviews` module
//! (where the other write actions live) while the service-layer just
//! handles token resolution and cache drain.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::github::queries::{RESOLVE_REVIEW_THREAD_MUTATION, UNRESOLVE_REVIEW_THREAD_MUTATION};
use crate::errors::{CliError, CliErrorKind};
use crate::github_api::{
    GitHubCachePolicy, GitHubPriority, GitHubProtectedClient, GitHubRequestDescriptor,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsReviewThreadResolveRequest {
    pub thread_id: String,
    pub resolved: bool,
    /// PR cache key — the daemon drains the per-PR timeline cache
    /// after a successful mutation so the next fetch reflects the new
    /// `isResolved` state.
    pub pull_request_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsReviewThreadResolveResponse {
    pub thread_id: String,
    pub resolved: bool,
}

/// Execute the resolve / unresolve mutation against GitHub. Returns
/// the confirmed server-side `isResolved` value from the GraphQL
/// response. The service layer is responsible for cache drain.
///
/// # Errors
/// Returns `CliError` when the protected client fails to build, the
/// GraphQL transport fails, or the response is missing the expected
/// `{resolveReviewThread,unresolveReviewThread}.thread.isResolved`
/// field.
pub async fn execute_review_thread_resolve_mutation(
    token: &str,
    thread_id: &str,
    resolved: bool,
) -> Result<bool, CliError> {
    let client = GitHubProtectedClient::new(token).map_err(|err| -> CliError {
        CliErrorKind::workflow_io(format!("thread-resolve client build: {err}")).into()
    })?;

    let query = if resolved {
        RESOLVE_REVIEW_THREAD_MUTATION
    } else {
        UNRESOLVE_REVIEW_THREAD_MUTATION
    };
    let response: Value = client
        .graphql(
            GitHubRequestDescriptor::graphql(
                "reviews.review_thread_resolve",
                GitHubPriority::Mutation,
                GitHubCachePolicy::no_store(),
            ),
            json!({
            "query": query,
            "variables": { "threadId": thread_id },
            }),
        )
        .await
        .map(|response| response.body)?;

    // Protected GraphQL unwraps the outer `{data: ...}` envelope, so we look at
    // the inner mutation payload directly. Both mutations return the thread
    // under the same `thread.isResolved` path; try both keys.
    response
        .pointer("/resolveReviewThread/thread/isResolved")
        .or_else(|| response.pointer("/unresolveReviewThread/thread/isResolved"))
        .and_then(Value::as_bool)
        .ok_or_else(|| -> CliError {
            CliErrorKind::workflow_io("thread-resolve response missing isResolved").into()
        })
}
