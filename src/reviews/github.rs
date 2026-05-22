mod actions;
mod blob_ops;
mod check_status;
mod client;
mod coverage;
mod errors;
mod fetch;
mod ingest;
mod mapping;
mod pagination;
pub(super) mod queries;
mod rate_limit;
mod types;

// Lift the two constants `mapping.rs` imports via `super::{...}` back into the
// `github` namespace. The other companion modules use `super::client::X` paths
// directly, so they need no re-export here.
pub(super) use client::{GRAPHQL_PAGE_SIZE, SCOPE_QUERY_CAP};

// Public re-export keeps `reviews::ReviewsGitHubClient` and the test-only
// `reviews::github::ensure_rustls_provider` paths working without changes.
pub(crate) use client::ReviewsGitHubClient;
#[cfg(test)]
pub(crate) use client::ensure_rustls_provider;

// Re-exports for the `super::*` glob in `tests.rs` (kept identical to the
// pre-split private imports). Gated on `cfg(test)` to avoid leaking the
// symbols into the production surface.
#[cfg(test)]
use client::{
    GITHUB_HTTP_CONNECT_TIMEOUT, GITHUB_HTTP_READ_TIMEOUT, SEARCH_PAGE_CAP,
    normalize_git_blob_base64,
};
#[cfg(test)]
use mapping::{next_cursor_or_scope_limit, parse_timestamp, scopes};
#[cfg(test)]
use octocrab::Octocrab;

// Lift the parent's shared review types into the `github` namespace so each
// companion module can keep `use super::{ReviewItem, ...}` imports working
// without reaching back into `crate::reviews::...`.
pub(super) use super::{
    ReviewActionKind, ReviewActionOutcome, ReviewActionResult,
    ReviewCheck, ReviewCheckConclusion, ReviewCheckRunStatus,
    ReviewCheckStatus, ReviewItem, ReviewMergeableState,
    ReviewPullRequestState, ReviewRepositoryLabel, PullRequestReview,
    ReviewReviewEventState, ReviewReviewStatus, ReviewTarget,
    ReviewsApproveRequest, ReviewsAutoRequest, ReviewsCommentRequest,
    ReviewsLabelRequest, ReviewsMergeRequest, ReviewsQueryRequest,
    ReviewsRerunChecksRequest, timeline,
};

#[cfg(test)]
mod tests;
