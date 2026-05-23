#![allow(dead_code)]

mod helpers;
mod hot;
mod simple_actor;
mod unknown;

use serde_json::Value;

use super::types::ReviewTimelineEntry;

fn typename(node: &Value) -> Option<&str> {
    node.get("__typename").and_then(Value::as_str)
}

/// Dispatches a single timeline node to its mapper based on
/// `__typename`. Hot kinds get dedicated mappers in [`hot`]; the 39
/// lightweight `SimpleActorEvent` typeenames funnel through
/// [`simple_actor::map_simple_actor_event`]. Anything that matches
/// neither (e.g. a future GitHub variant we haven't taught the
/// mapper about) falls through to [`unknown::map_unknown`], which
/// preserves the raw JSON for forward-compat rendering.
pub(super) fn map_node(node: &Value) -> Option<ReviewTimelineEntry> {
    let name = typename(node)?;
    match name {
        "IssueComment" => hot::map_issue_comment(node),
        "PullRequestReview" => hot::map_pull_request_review(node),
        "PullRequestReviewThread" => hot::map_pull_request_review_thread(node),
        "PullRequestCommit" => hot::map_pull_request_commit(node),
        "HeadRefForcePushedEvent" => hot::map_head_ref_force_pushed(node),
        other => simple_actor::map_simple_actor_event(other, node)
            .or_else(|| unknown::map_unknown(other, node)),
    }
}

/// Reads the viewer's ability to comment on the pull-request node.
/// GitHub's GraphQL schema does not yet expose
/// `viewerCanCommentOnPullRequest`, so we proxy via `viewerCanUpdate`
/// when the dedicated field is absent. If GitHub later ships the
/// dedicated field, the query in `queries::PR_TIMELINE_PAGE_QUERY`
/// can be extended to fetch it and this helper will start returning
/// the more precise value automatically.
pub(super) fn viewer_can_comment_from_pull_request(node: &Value) -> bool {
    node.get("viewerCanCommentOnPullRequest")
        .and_then(Value::as_bool)
        .or_else(|| node.get("viewerCanUpdate").and_then(Value::as_bool))
        .unwrap_or(false)
}
