mod actions;
mod blob_ops;
mod check_status;
mod client;
mod coverage;
mod fetch;
mod ingest;
mod mapping;
mod pagination;
pub(super) mod queries;
mod resolve;
mod types;

// Lift the two constants `mapping.rs` imports via `super::{...}` back into the
// `github` namespace. The other companion modules use `super::client::X` paths
// directly, so they need no re-export here.
pub(super) use client::{GRAPHQL_PAGE_SIZE, SCOPE_QUERY_CAP};

// Public re-export keeps `reviews::ReviewsGitHubClient` available to the
// daemon service layer.
pub(crate) use client::ReviewsGitHubClient;

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

// Lift the parent's shared review types into the `github` namespace so each
// companion module can keep `use super::{ReviewItem, ...}` imports working
// without reaching back into `crate::reviews::...`.
pub(super) use super::{
    PullRequestReview, ReviewActionKind, ReviewActionOutcome, ReviewActionResult, ReviewCheck,
    ReviewCheckConclusion, ReviewCheckRunStatus, ReviewCheckStatus, ReviewItem,
    ReviewMergeableState, ReviewPullRequestState, ReviewRepositoryLabel, ReviewReviewEventState,
    ReviewReviewStatus, ReviewTarget, ReviewsApproveRequest, ReviewsCommentRequest,
    ReviewsFileCommentKind, ReviewsFileCommentRequest, ReviewsFileCommentResponse,
    ReviewsLabelRequest, ReviewsMergeRequest, ReviewsPullRequestResolveRequest,
    ReviewsQueryRequest, ReviewsRefreshRequest, ReviewsRequestReviewRequest,
    ReviewsRerunChecksRequest, timeline,
};

#[cfg(test)]
mod tests;
