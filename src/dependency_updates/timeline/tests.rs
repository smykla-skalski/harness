#![cfg(test)]

use serde_json::Value;

use super::mapping;
use super::types::{
    DependencyUpdateTimelineEntry, ReviewState, SimpleActorEventEntry, SimpleActorEventKind,
};

const MIXED_PAGE: &str = include_str!("fixtures/mixed_page.json");
const REVIEW_PAGED: &str = include_str!("fixtures/review_with_paginated_inline_comments.json");
const THREAD_PAGED: &str = include_str!("fixtures/review_thread_with_paginated_comments.json");
const UNKNOWN: &str = include_str!("fixtures/unknown_typename.json");
const LOW_QUOTA: &str = include_str!("fixtures/rate_limit_near_zero.json");

fn parse(json: &str) -> Value {
    serde_json::from_str(json).expect("valid fixture JSON")
}

fn pull_request_node(envelope: &Value) -> &Value {
    envelope
        .pointer("/data/node")
        .expect("envelope has /data/node")
}

#[test]
fn mixed_page_maps_all_supported_kinds() {
    let env = parse(MIXED_PAGE);
    let nodes = env
        .pointer("/data/node/timelineItems/nodes")
        .and_then(Value::as_array)
        .expect("nodes array");
    let entries: Vec<_> = nodes.iter().filter_map(mapping::map_node).collect();
    assert_eq!(entries.len(), 5, "all five nodes should map");
    assert!(matches!(entries[0], DependencyUpdateTimelineEntry::IssueComment(_)));
    assert!(matches!(
        entries[1],
        DependencyUpdateTimelineEntry::SimpleActorEvent(SimpleActorEventEntry {
            event_kind: SimpleActorEventKind::Labeled,
            ..
        })
    ));
    assert!(matches!(entries[2], DependencyUpdateTimelineEntry::Commit(_)));
    assert!(matches!(entries[3], DependencyUpdateTimelineEntry::Review(_)));
    assert!(matches!(
        entries[4],
        DependencyUpdateTimelineEntry::HeadRefForcePushed(_)
    ));

    let DependencyUpdateTimelineEntry::IssueComment(c) = &entries[0] else {
        panic!("expected IssueComment");
    };
    assert_eq!(c.body, "LGTM");
    assert!(c.viewer_did_author);
    assert_eq!(c.reactions_total, 2);

    let DependencyUpdateTimelineEntry::SimpleActorEvent(l) = &entries[1] else {
        panic!("expected SimpleActorEvent");
    };
    assert_eq!(l.label.as_deref(), Some("dependencies"));
    assert_eq!(l.label_color.as_deref(), Some("0366d6"));

    let DependencyUpdateTimelineEntry::Commit(commit) = &entries[2] else {
        panic!("expected Commit");
    };
    assert_eq!(commit.abbreviated_oid, "abcd123");
    assert_eq!(commit.author_login.as_deref(), Some("renovate"));

    let DependencyUpdateTimelineEntry::Review(r) = &entries[3] else {
        panic!("expected Review");
    };
    assert_eq!(r.state, ReviewState::Approved);
    assert_eq!(r.inline_comments.len(), 0);
    assert!(!r.comments_truncated);

    let DependencyUpdateTimelineEntry::HeadRefForcePushed(f) = &entries[4] else {
        panic!("expected HeadRefForcePushed");
    };
    assert_eq!(f.before_abbreviated_oid, "1111111");
    assert_eq!(f.after_abbreviated_oid, "2222222");
    assert_eq!(f.ref_name.as_deref(), Some("renovate/foo-v2"));
}

#[test]
fn paginated_review_first_page_inline_comments() {
    let node = parse(REVIEW_PAGED);
    let entry = mapping::map_node(&node).expect("maps to review");
    let DependencyUpdateTimelineEntry::Review(r) = entry else {
        panic!("expected Review");
    };
    assert_eq!(r.state, ReviewState::ChangesRequested);
    assert_eq!(r.inline_comments.len(), 2);
    assert_eq!(r.inline_comments[0].body, "Inline comment 1");
    assert!(r.inline_comments[0].reply_to_id.is_none());
    assert_eq!(
        r.inline_comments[1].reply_to_id.as_deref(),
        Some("PRRC_001"),
    );
    assert!(!r.comments_truncated);
}

#[test]
fn paginated_review_thread_first_page_comments() {
    let node = parse(THREAD_PAGED);
    let entry = mapping::map_node(&node).expect("maps to review thread");
    let DependencyUpdateTimelineEntry::ReviewThread(t) = entry else {
        panic!("expected ReviewThread");
    };
    assert_eq!(t.path, "src/baz.rs");
    assert_eq!(t.comments.len(), 1);
    assert_eq!(t.comments[0].body, "Thread comment 1");
    assert_eq!(
        t.actor.as_ref().map(|a| a.login.as_str()),
        Some("alice"),
        "actor falls back to first comment's author"
    );
}

#[test]
fn unknown_typename_falls_through_to_unknown_entry() {
    let node = parse(UNKNOWN);
    let entry = mapping::map_node(&node).expect("maps to unknown");
    let DependencyUpdateTimelineEntry::Unknown(u) = entry else {
        panic!("expected Unknown");
    };
    assert_eq!(u.typename, "FutureGitHubEvent");
    assert_eq!(u.id, "FGE_001");
    assert_eq!(
        u.raw_payload.get("futureField").and_then(Value::as_str),
        Some("future value"),
    );
}

#[test]
fn viewer_can_comment_proxies_viewer_can_update() {
    let env = parse(LOW_QUOTA);
    let node = pull_request_node(&env);
    assert!(!mapping::viewer_can_comment_from_pull_request(node));
    let mut overridden = node.clone();
    overridden["viewerCanCommentOnPullRequest"] = Value::Bool(true);
    assert!(mapping::viewer_can_comment_from_pull_request(&overridden));
}

#[test]
fn rate_limit_near_zero_envelope_parses() {
    let env = parse(LOW_QUOTA);
    let remaining = env
        .pointer("/data/rateLimit/remaining")
        .and_then(Value::as_u64);
    assert_eq!(remaining, Some(5));
}

#[test]
fn revision_marker_synthesizes_id() {
    let json = serde_json::json!({
        "__typename": "PullRequestRevisionMarker",
        "createdAt": "2026-05-21T11:00:00Z",
        "lastSeenCommit": {
            "oid": "deadbeef00000000000000000000000000000000",
            "abbreviatedOid": "deadbee"
        }
    });
    let entry = mapping::map_node(&json).expect("maps to simple actor");
    let DependencyUpdateTimelineEntry::SimpleActorEvent(e) = entry else {
        panic!("expected SimpleActorEvent");
    };
    assert_eq!(e.event_kind, SimpleActorEventKind::RevisionMarker);
    assert!(e.id.starts_with("synthetic:PullRequestRevisionMarker:"));
    assert_eq!(
        e.after_oid.as_deref(),
        Some("deadbeef00000000000000000000000000000000"),
    );
}
