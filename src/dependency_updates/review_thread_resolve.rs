//! Types for the review-thread resolve / unresolve write-action surface.
//!
//! The HTTP + WS routes flow a single `DependencyUpdatesReviewThreadResolveRequest`
//! that carries `{ thread_id, resolved }`; the daemon picks the GitHub
//! `resolveReviewThread` or `unresolveReviewThread` mutation per the
//! `resolved` flag and echoes the confirmed `isResolved` from the
//! GraphQL response into
//! `DependencyUpdatesReviewThreadResolveResponse`. Mirrors the existing
//! comment-post + cache-drain pattern in
//! `src/daemon/service/dependency_updates.rs::comment_on_dependency_updates`.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesReviewThreadResolveRequest {
    pub thread_id: String,
    pub resolved: bool,
    /// Per-PR cache key — the daemon drains
    /// `DEPENDENCY_UPDATES_TIMELINE_CACHE` for this PR after a successful
    /// mutation so the next timeline fetch reflects the new
    /// `isResolved` state without an extra GitHub round-trip.
    pub pull_request_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesReviewThreadResolveResponse {
    pub thread_id: String,
    pub resolved: bool,
}
