//! Review-thread resolve / unresolve write-action: types + GitHub
//! mutation invocation. The daemon service layer calls
//! `execute_review_thread_resolve_mutation` so the GraphQL strings +
//! Octocrab dispatch stay inside the `dependency_updates` module
//! (where the other write actions live) while the service-layer just
//! handles token resolution and cache drain.

use std::time::Duration;

use octocrab::Octocrab;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::github::queries::{
    RESOLVE_REVIEW_THREAD_MUTATION, UNRESOLVE_REVIEW_THREAD_MUTATION,
};
use crate::errors::{CliError, CliErrorKind};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
const READ_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesReviewThreadResolveRequest {
    pub thread_id: String,
    pub resolved: bool,
    /// PR cache key — the daemon drains the per-PR timeline cache
    /// after a successful mutation so the next fetch reflects the new
    /// `isResolved` state.
    pub pull_request_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesReviewThreadResolveResponse {
    pub thread_id: String,
    pub resolved: bool,
}

/// Execute the resolve / unresolve mutation against GitHub. Returns
/// the confirmed server-side `isResolved` value from the GraphQL
/// response. The service layer is responsible for cache drain.
///
/// # Errors
/// Returns `CliError` when the Octocrab client fails to build, the
/// GraphQL transport fails, or the response is missing the expected
/// `{resolveReviewThread,unresolveReviewThread}.thread.isResolved`
/// field.
pub async fn execute_review_thread_resolve_mutation(
    token: &str,
    thread_id: &str,
    resolved: bool,
) -> Result<bool, CliError> {
    let client = Octocrab::builder()
        .personal_token(token.to_string())
        .set_connect_timeout(Some(CONNECT_TIMEOUT))
        .set_read_timeout(Some(READ_TIMEOUT))
        .build()
        .map_err(|err| -> CliError {
            CliErrorKind::workflow_io(format!("thread-resolve client build: {err}")).into()
        })?;

    let query = if resolved {
        RESOLVE_REVIEW_THREAD_MUTATION
    } else {
        UNRESOLVE_REVIEW_THREAD_MUTATION
    };
    let response: Value = client
        .graphql(&json!({
            "query": query,
            "variables": { "threadId": thread_id },
        }))
        .await
        .map_err(|err| -> CliError {
            CliErrorKind::workflow_io(format!("thread-resolve upstream: {err}")).into()
        })?;

    // Octocrab's `.graphql()` unwraps the outer `{data: ...}` envelope,
    // so we look at the inner mutation payload directly. Both mutations
    // return the thread under the same `thread.isResolved` path; try
    // both keys.
    response
        .pointer("/resolveReviewThread/thread/isResolved")
        .or_else(|| response.pointer("/unresolveReviewThread/thread/isResolved"))
        .and_then(Value::as_bool)
        .ok_or_else(|| -> CliError {
            CliErrorKind::workflow_io("thread-resolve response missing isResolved").into()
        })
}
