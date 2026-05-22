#![cfg(test)]

use serde_json::Value;

use super::mapping;
use super::types::{
    ReviewTimelineEntry, ReviewState, SimpleActorEventEntry, SimpleActorEventKind,
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

// Real captured production response from smykla-skalski/harness#152 — a
// Renovate PR closed without merge. Exercises the realistic Renovate flow
// (label → approval review → multiple force-pushes → final commit → close
// → branch delete → Renovate ignore notification) so the mapping contract
// is verified against the actual GitHub GraphQL shape, not hand-built
// approximations.
#[test]
fn mixed_page_maps_all_supported_kinds() {
    let env = parse(MIXED_PAGE);
    let nodes = env
        .pointer("/data/node/timelineItems/nodes")
        .and_then(Value::as_array)
        .expect("nodes array");
    let entries: Vec<_> = nodes.iter().filter_map(mapping::map_node).collect();
    assert_eq!(entries.len(), 9, "all nine nodes should map");
    assert!(matches!(
        entries[0],
        ReviewTimelineEntry::SimpleActorEvent(SimpleActorEventEntry {
            event_kind: SimpleActorEventKind::Labeled,
            ..
        })
    ));
    assert!(matches!(
        entries[1],
        ReviewTimelineEntry::Review(_)
    ));
    assert!(matches!(
        entries[2],
        ReviewTimelineEntry::HeadRefForcePushed(_)
    ));
    assert!(matches!(
        entries[3],
        ReviewTimelineEntry::HeadRefForcePushed(_)
    ));
    assert!(matches!(
        entries[4],
        ReviewTimelineEntry::Commit(_)
    ));
    assert!(matches!(
        entries[5],
        ReviewTimelineEntry::HeadRefForcePushed(_)
    ));
    assert!(matches!(
        entries[6],
        ReviewTimelineEntry::SimpleActorEvent(SimpleActorEventEntry {
            event_kind: SimpleActorEventKind::Closed,
            ..
        })
    ));
    assert!(matches!(
        entries[7],
        ReviewTimelineEntry::SimpleActorEvent(SimpleActorEventEntry {
            event_kind: SimpleActorEventKind::HeadRefDeleted,
            ..
        })
    ));
    assert!(matches!(
        entries[8],
        ReviewTimelineEntry::IssueComment(_)
    ));

    let ReviewTimelineEntry::SimpleActorEvent(l) = &entries[0] else {
        panic!("expected LabeledEvent");
    };
    assert_eq!(l.label.as_deref(), Some("dependencies"));
    assert_eq!(l.label_color.as_deref(), Some("ededed"));
    assert_eq!(l.actor.as_ref().map(|a| a.login.as_str()), Some("renovate"),);

    let ReviewTimelineEntry::Review(r) = &entries[1] else {
        panic!("expected Review");
    };
    assert_eq!(r.state, ReviewState::Approved);
    assert!(
        r.body.as_deref().unwrap_or_default().is_empty(),
        "GitHub web ships approvals with empty body"
    );
    assert_eq!(r.inline_comments.len(), 0);
    assert!(!r.comments_truncated);

    let ReviewTimelineEntry::HeadRefForcePushed(f0) = &entries[2] else {
        panic!("expected HeadRefForcePushed");
    };
    assert_eq!(f0.before_abbreviated_oid, "aedcb8c");
    assert_eq!(f0.after_abbreviated_oid, "b3b0183");
    assert!(
        f0.ref_name.is_none(),
        "production responses leave ref null on Renovate force-pushes",
    );

    let ReviewTimelineEntry::Commit(commit) = &entries[4] else {
        panic!("expected Commit");
    };
    assert_eq!(commit.abbreviated_oid, "c4de983");
    assert_eq!(commit.author_login.as_deref(), Some("renovate[bot]"));
    assert_eq!(
        commit.message_headline,
        "fix(deps): update opentelemetry-rust monorepo to 0.32.0",
    );

    let ReviewTimelineEntry::SimpleActorEvent(closed) = &entries[6] else {
        panic!("expected ClosedEvent");
    };
    assert_eq!(
        closed.actor.as_ref().map(|a| a.login.as_str()),
        Some("bartsmykla"),
    );

    let ReviewTimelineEntry::SimpleActorEvent(deleted) = &entries[7] else {
        panic!("expected HeadRefDeletedEvent");
    };
    assert_eq!(
        deleted.branch_name.as_deref(),
        Some("renovate/opentelemetry-rust-monorepo"),
    );

    let ReviewTimelineEntry::IssueComment(c) = &entries[8] else {
        panic!("expected IssueComment");
    };
    assert!(c.body.starts_with("### Renovate Ignore Notification"));
    assert_eq!(c.reactions_total, 0);
    assert!(!c.viewer_did_author);
}

// Real captured production response from kumahq/kuma#16275's
// PullRequestReview `PRR_kwDOCnTGG872zzzB` ("docs(MADR): added policy
// matching", reviewer @slonka, 11 inline comments). Captured via
// `gh api graphql` with `inlineCommentPageSize: 5` so the first page
// returns 5 + `hasNextPage: true` — forces the drain contract to
// kick in against real GitHub wire format.
#[test]
fn paginated_review_first_page_inline_comments() {
    let node = parse(REVIEW_PAGED);
    let entry = mapping::map_node(&node).expect("maps to review");
    let ReviewTimelineEntry::Review(r) = entry else {
        panic!("expected Review");
    };
    // Real reviews come back as COMMENTED most often (general feedback
    // pass), not CHANGES_REQUESTED — that's what the hand-built
    // fixture got wrong. Asserting on the real state catches future
    // mappings that conflate the two.
    assert_eq!(r.state, ReviewState::Commented);
    assert_eq!(
        r.inline_comments.len(),
        5,
        "first page has 5/11 inline comments"
    );
    assert_eq!(
        r.inline_comments[0].body,
        "MADR-062 also deferred `MeshFaultInjection` - do we want to covert it here? \
         Should we explicitly mention that it's out of scope? There is also mentions of MFI below."
    );
    assert!(
        r.inline_comments[0].reply_to_id.is_none(),
        "top-level review comments have null replyTo in real responses"
    );
    // Service-layer drain marks this true once it confirms the
    // continuation succeeded; the parser-layer fixture-only test
    // sees `comments_truncated: false` because mapping never sets it.
    assert!(!r.comments_truncated);
    assert_eq!(r.actor.as_ref().map(|a| a.login.as_str()), Some("slonka"),);
}

#[test]
fn paginated_review_thread_first_page_comments() {
    let node = parse(THREAD_PAGED);
    let entry = mapping::map_node(&node).expect("maps to review thread");
    let ReviewTimelineEntry::ReviewThread(t) = entry else {
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
    let ReviewTimelineEntry::Unknown(u) = entry else {
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
    let ReviewTimelineEntry::SimpleActorEvent(e) = entry else {
        panic!("expected SimpleActorEvent");
    };
    assert_eq!(e.event_kind, SimpleActorEventKind::RevisionMarker);
    assert!(e.id.starts_with("synthetic:PullRequestRevisionMarker:"));
    assert_eq!(
        e.after_oid.as_deref(),
        Some("deadbeef00000000000000000000000000000000"),
    );
}
