//! Tests for the review-policy graph's `AsyncDaemonDb`/`DaemonDb` surface.
//! Stays here rather than moving into `harness-policy-graph-store` with the
//! query logic: several cases (dispatch reservation racing an approval-grant
//! consume, the drain task's decision feed) exercise the daemon's own
//! task-board integration alongside policy-graph persistence, so they need
//! the whole crate to build.

#[path = "reviews_store_tests/approval_grants.rs"]
mod approval_grants;
#[path = "reviews_store_tests/decisions.rs"]
mod decisions;
#[path = "reviews_store_tests/workspace.rs"]
mod workspace;
