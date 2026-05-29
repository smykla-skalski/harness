use chrono::{DateTime, Utc};
use tempfile::tempdir;

use super::*;

fn event(event_key: &str, subject_key: &str, occurred_at: &str) -> PolicyWorkflowEvent {
    PolicyWorkflowEvent {
        event_key: event_key.to_owned(),
        subject_key: subject_key.to_owned(),
        occurred_at: occurred_at.to_owned(),
    }
}

fn at(rfc3339: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(rfc3339)
        .expect("parse fixed instant")
        .with_timezone(&Utc)
}

fn inbox() -> (tempfile::TempDir, PolicyEventInbox) {
    let dir = tempdir().expect("tempdir");
    let inbox = PolicyEventInbox::new(dir.path().to_path_buf());
    (dir, inbox)
}

#[test]
fn publish_then_pending_returns_the_event() {
    let (_dir, inbox) = inbox();
    inbox
        .publish_at(
            event("reviews.checks_passed", "owner/repo#1", "2026-05-29T12:00:00Z"),
            at("2026-05-29T12:00:00Z"),
        )
        .expect("publish");
    let pending = inbox.pending().expect("pending");
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].event_key, "reviews.checks_passed");
    assert_eq!(pending[0].subject_key, "owner/repo#1");
}

#[test]
fn publish_dedupes_by_event_key_and_subject_keeping_latest() {
    let (_dir, inbox) = inbox();
    let now = at("2026-05-29T12:05:00Z");
    inbox
        .publish_at(
            event("reviews.checks_passed", "owner/repo#1", "2026-05-29T12:00:00Z"),
            now,
        )
        .expect("publish first");
    inbox
        .publish_at(
            event("reviews.checks_passed", "owner/repo#1", "2026-05-29T12:04:00Z"),
            now,
        )
        .expect("publish second");
    let pending = inbox.pending().expect("pending");
    assert_eq!(pending.len(), 1, "same key+subject collapses to one slot");
    assert_eq!(pending[0].occurred_at, "2026-05-29T12:04:00Z");
}

#[test]
fn publish_keeps_distinct_subjects_separate() {
    let (_dir, inbox) = inbox();
    let now = at("2026-05-29T12:05:00Z");
    inbox
        .publish_at(
            event("reviews.checks_passed", "owner/repo#1", "2026-05-29T12:00:00Z"),
            now,
        )
        .expect("publish a");
    inbox
        .publish_at(
            event("reviews.checks_passed", "owner/repo#2", "2026-05-29T12:00:00Z"),
            now,
        )
        .expect("publish b");
    assert_eq!(inbox.pending().expect("pending").len(), 2);
}

#[test]
fn remove_delivered_drops_only_the_listed_events() {
    let (_dir, inbox) = inbox();
    let now = at("2026-05-29T12:05:00Z");
    let delivered = event("reviews.checks_passed", "owner/repo#1", "2026-05-29T12:00:00Z");
    inbox.publish_at(delivered.clone(), now).expect("publish a");
    inbox
        .publish_at(
            event("reviews.checks_passed", "owner/repo#2", "2026-05-29T12:00:00Z"),
            now,
        )
        .expect("publish b");
    inbox
        .remove_delivered_at(&[delivered], now)
        .expect("remove delivered");
    let pending = inbox.pending().expect("pending");
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].subject_key, "owner/repo#2");
}

#[test]
fn publish_prunes_events_older_than_retention() {
    let (_dir, inbox) = inbox();
    inbox
        .publish_at(
            event("reviews.checks_passed", "stale/repo#9", "2026-05-29T10:00:00Z"),
            at("2026-05-29T10:00:00Z"),
        )
        .expect("publish stale");
    // Two hours later a fresh, unrelated event prunes the expired one.
    inbox
        .publish_at(
            event("reviews.checks_passed", "fresh/repo#1", "2026-05-29T12:00:00Z"),
            at("2026-05-29T12:00:00Z"),
        )
        .expect("publish fresh");
    let pending = inbox.pending().expect("pending");
    assert_eq!(pending.len(), 1, "stale event pruned by retention");
    assert_eq!(pending[0].subject_key, "fresh/repo#1");
}
