#![allow(dead_code, unused_imports)]

mod cache;
mod client;
mod mapping;
mod queries;
mod service;
// `types` moved to `harness-protocol` (pure wire data, see that crate's
// `daemon::reviews` doc comment); this alias keeps `timeline::types::X`
// resolving for `mapping`/`service`/`tests` exactly as it did when the
// module was local, and the `pub use types::{...}` below keeps this crate's
// own flattened `timeline::X` surface unchanged too.
use harness_protocol::daemon::reviews::timeline::types;

pub use client::TimelineGitHubClient;

pub use service::{TimelineClient, TimelineError, fetch_timeline_page};

/// Clears the in-memory timeline cache and returns how many pages
/// were evicted. Called from the daemon's combined cache-clear
/// endpoint so a single DELETE drops body, query, and timeline state
/// in one shot.
#[must_use]
pub fn drain_timeline_cache() -> usize {
    cache::drain_all_counted()
}

#[must_use]
pub fn map_timeline_node(node: &serde_json::Value) -> Option<ReviewTimelineEntry> {
    mapping::map_node(node)
}

pub fn append_timeline_entry_to_cache(pull_request_id: &str, entry: &ReviewTimelineEntry) {
    cache::append_entry(pull_request_id, entry);
}

/// Drain the cached timeline pages for `pull_request_id`. Called by
/// the daemon service layer after a write action (comment-post,
/// review-thread resolve) succeeds so the next fetch reflects the new
/// server-side state without an extra GitHub round-trip.
pub fn drain_pull_request_cache(pull_request_id: &str) {
    cache::drain_pull_request(pull_request_id);
}

// Predates this crate's own clippy::pedantic gate; allow the pure style
// lints below rather than rewrite an otherwise-passing test.
#[cfg(test)]
#[allow(clippy::cognitive_complexity)]
mod tests;

#[cfg(test)]
#[allow(clippy::needless_pass_by_value, clippy::unnecessary_trailing_comma)]
mod service_tests;

pub use types::{
    Actor, CommitEntry, HeadRefForcePushedEntry, IssueCommentEntry, ReviewEntry,
    ReviewInlineCommentEntry, ReviewState, ReviewThreadCommentEntry, ReviewThreadEntry,
    ReviewTimelineEntry, SimpleActorEventEntry, SimpleActorEventKind, UnknownEntry,
};

// The request/response/page-info wire types used to be defined directly in
// this file; they're pure data with no impl blocks, so they moved to
// `harness-protocol` alongside the entry-kind enum tree above.
pub use harness_protocol::daemon::reviews::timeline::{
    ReviewsTimelineRequest, ReviewsTimelineResponse, TimelinePageDirection, TimelinePageInfo,
};
