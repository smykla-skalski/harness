#![allow(dead_code)]

mod helpers;
mod hot;
mod simple_actor;

use serde_json::Value;

use super::types::DependencyUpdateTimelineEntry;

fn typename<'a>(node: &'a Value) -> Option<&'a str> {
    node.get("__typename").and_then(Value::as_str)
}

/// Dispatches a single timeline node to its mapper based on
/// `__typename`. Hot kinds get dedicated mappers in [`hot`]; the 39
/// lightweight `SimpleActorEvent` typeenames funnel through
/// [`simple_actor::map_simple_actor_event`]. The forward-compat
/// fallback for unknown typeenames lands in A.6.
pub(super) fn map_node(node: &Value) -> Option<DependencyUpdateTimelineEntry> {
    let name = typename(node)?;
    match name {
        "IssueComment" => hot::map_issue_comment(node),
        "PullRequestReview" => hot::map_pull_request_review(node),
        "PullRequestReviewThread" => hot::map_pull_request_review_thread(node),
        "PullRequestCommit" => hot::map_pull_request_commit(node),
        "HeadRefForcePushedEvent" => hot::map_head_ref_force_pushed(node),
        other => simple_actor::map_simple_actor_event(other, node),
    }
}
