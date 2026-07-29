//! Wire types for the review-thread resolve/unresolve write action. The
//! mutation itself
//! (`harness-reviews::review_thread_resolve::execute_review_thread_resolve_mutation`)
//! stays in `harness-reviews` since it dispatches a real GitHub GraphQL
//! call; these two DTOs are its whole wire shape.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ReviewsReviewThreadResolveRequest {
    pub thread_id: String,
    pub resolved: bool,
    /// PR cache key — the daemon drains the per-PR timeline cache
    /// after a successful mutation so the next fetch reflects the new
    /// `isResolved` state.
    pub pull_request_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ReviewsReviewThreadResolveResponse {
    pub thread_id: String,
    pub resolved: bool,
}
