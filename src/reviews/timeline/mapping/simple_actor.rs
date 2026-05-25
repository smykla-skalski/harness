#![allow(dead_code)]

use serde_json::Value;

use super::super::types::{ReviewTimelineEntry, SimpleActorEventEntry, SimpleActorEventKind};
use super::helpers::{parse_actor, parse_commit_oid, parse_iso8601, parse_string};

fn typename_to_simple_kind(typename: &str) -> Option<SimpleActorEventKind> {
    use SimpleActorEventKind::{
        Assigned, AutoMergeDisabled, AutoMergeEnabled, AutoRebaseEnabled, AutoSquashEnabled,
        BaseRefChanged, BaseRefDeleted, BaseRefForcePushed, Closed, Connected, ConvertToDraft,
        CrossReferenced, Demilestoned, Disconnected, HeadRefDeleted, HeadRefRestored, Labeled,
        Locked, MarkedAsDuplicate, Mentioned, Merged, Milestoned, Pinned, ReadyForReview,
        Referenced, RenamedTitle, Reopened, ReviewDismissed, ReviewRequestRemoved, ReviewRequested,
        RevisionMarker, Subscribed, Transferred, Unassigned, Unlabeled, Unlocked,
        UnmarkedAsDuplicate, Unpinned, Unsubscribed,
    };
    Some(match typename {
        "HeadRefDeletedEvent" => HeadRefDeleted,
        "HeadRefRestoredEvent" => HeadRefRestored,
        "BaseRefChangedEvent" => BaseRefChanged,
        "BaseRefForcePushedEvent" => BaseRefForcePushed,
        "BaseRefDeletedEvent" => BaseRefDeleted,
        "LabeledEvent" => Labeled,
        "UnlabeledEvent" => Unlabeled,
        "AssignedEvent" => Assigned,
        "UnassignedEvent" => Unassigned,
        "MergedEvent" => Merged,
        "ClosedEvent" => Closed,
        "ReopenedEvent" => Reopened,
        "RenamedTitleEvent" => RenamedTitle,
        "ReviewRequestedEvent" => ReviewRequested,
        "ReviewRequestRemovedEvent" => ReviewRequestRemoved,
        "ReviewDismissedEvent" => ReviewDismissed,
        "ReadyForReviewEvent" => ReadyForReview,
        "ConvertToDraftEvent" => ConvertToDraft,
        "AutoMergeEnabledEvent" => AutoMergeEnabled,
        "AutoMergeDisabledEvent" => AutoMergeDisabled,
        "AutoRebaseEnabledEvent" => AutoRebaseEnabled,
        "AutoSquashEnabledEvent" => AutoSquashEnabled,
        "LockedEvent" => Locked,
        "UnlockedEvent" => Unlocked,
        "PinnedEvent" => Pinned,
        "UnpinnedEvent" => Unpinned,
        "MilestonedEvent" => Milestoned,
        "DemilestonedEvent" => Demilestoned,
        "ReferencedEvent" => Referenced,
        "CrossReferencedEvent" => CrossReferenced,
        "MentionedEvent" => Mentioned,
        "SubscribedEvent" => Subscribed,
        "UnsubscribedEvent" => Unsubscribed,
        "MarkedAsDuplicateEvent" => MarkedAsDuplicate,
        "UnmarkedAsDuplicateEvent" => UnmarkedAsDuplicate,
        "TransferredEvent" => Transferred,
        "ConnectedEvent" => Connected,
        "DisconnectedEvent" => Disconnected,
        "PullRequestRevisionMarker" => RevisionMarker,
        _ => return None,
    })
}

fn synthesize_id(typename: &str, node: &Value) -> String {
    let created = node.get("createdAt").and_then(Value::as_str).unwrap_or("");
    let marker_oid = node
        .get("lastSeenCommit")
        .and_then(Value::as_object)
        .and_then(|c| c.get("oid"))
        .and_then(Value::as_str)
        .unwrap_or("");
    format!("synthetic:{typename}:{marker_oid}:{created}")
}

pub(super) fn map_simple_actor_event(typename: &str, node: &Value) -> Option<ReviewTimelineEntry> {
    let event_kind = typename_to_simple_kind(typename)?;
    let id = node
        .get("id")
        .and_then(Value::as_str)
        .map_or_else(|| synthesize_id(typename, node), str::to_string);
    let created_at = parse_iso8601(node.get("createdAt"))?;
    let actor = parse_actor(node.get("actor"));
    let mut entry = SimpleActorEventEntry {
        id,
        created_at,
        actor,
        event_kind,
        label: None,
        label_color: None,
        milestone_title: None,
        old_title: None,
        new_title: None,
        source_url: None,
        source_title: None,
        source_number: None,
        branch_name: None,
        before_oid: None,
        after_oid: None,
        lock_reason: None,
        dismissal_message: None,
        requested_reviewer_login: None,
        requested_reviewer_team_slug: None,
        assignee_login: None,
        source_repository: None,
        destination_repository: None,
    };
    fill_entry_fields(&mut entry, event_kind, node);
    Some(ReviewTimelineEntry::SimpleActorEvent(entry))
}

fn fill_entry_fields(entry: &mut SimpleActorEventEntry, kind: SimpleActorEventKind, node: &Value) {
    match kind {
        SimpleActorEventKind::Labeled | SimpleActorEventKind::Unlabeled => {
            if let Some(label) = node.get("label").and_then(Value::as_object) {
                entry.label = parse_string(label.get("name"));
                entry.label_color = parse_string(label.get("color"));
            }
        }
        SimpleActorEventKind::Assigned | SimpleActorEventKind::Unassigned => {
            entry.assignee_login = node
                .get("assignee")
                .and_then(Value::as_object)
                .and_then(|a| a.get("login"))
                .and_then(Value::as_str)
                .map(str::to_string);
        }
        SimpleActorEventKind::Milestoned | SimpleActorEventKind::Demilestoned => {
            entry.milestone_title = parse_string(node.get("milestoneTitle"));
        }
        SimpleActorEventKind::RenamedTitle => {
            entry.old_title = parse_string(node.get("previousTitle"));
            entry.new_title = parse_string(node.get("currentTitle"));
        }
        SimpleActorEventKind::ReviewRequested | SimpleActorEventKind::ReviewRequestRemoved => {
            fill_review_requested(entry, node);
        }
        SimpleActorEventKind::ReviewDismissed => {
            entry.dismissal_message = parse_string(node.get("dismissalMessage"));
        }
        SimpleActorEventKind::Locked => {
            entry.lock_reason = parse_string(node.get("lockReason"));
        }
        SimpleActorEventKind::Referenced
        | SimpleActorEventKind::Connected
        | SimpleActorEventKind::Disconnected => {
            if let Some(subject) = node.get("subject").and_then(Value::as_object) {
                entry.source_url = parse_string(subject.get("url"));
                entry.source_title = parse_string(subject.get("title"));
                entry.source_number = subject.get("number").and_then(Value::as_i64);
            }
        }
        SimpleActorEventKind::CrossReferenced => {
            fill_cross_referenced(entry, node);
        }
        SimpleActorEventKind::BaseRefChanged => {
            entry.old_title = parse_string(node.get("previousRefName"));
            entry.new_title = parse_string(node.get("currentRefName"));
        }
        SimpleActorEventKind::BaseRefForcePushed => {
            fill_base_ref_force_pushed(entry, node);
        }
        SimpleActorEventKind::BaseRefDeleted => {
            entry.branch_name = parse_string(node.get("baseRefName"));
        }
        SimpleActorEventKind::HeadRefDeleted => {
            entry.branch_name = parse_string(node.get("headRefName"));
        }
        SimpleActorEventKind::Merged => {
            let (oid, _) = parse_commit_oid(node.get("commit"));
            entry.after_oid = Some(oid).filter(|s| !s.is_empty());
            entry.branch_name = parse_string(node.get("mergeRefName"));
        }
        SimpleActorEventKind::Transferred => {
            entry.source_repository = node
                .get("fromRepository")
                .and_then(Value::as_object)
                .and_then(|r| r.get("nameWithOwner"))
                .and_then(Value::as_str)
                .map(str::to_string);
        }
        SimpleActorEventKind::RevisionMarker => {
            let (oid, _) = parse_commit_oid(node.get("lastSeenCommit"));
            entry.after_oid = Some(oid).filter(|s| !s.is_empty());
        }
        _ => {}
    }
}

fn fill_review_requested(entry: &mut SimpleActorEventEntry, node: &Value) {
    if let Some(req) = node.get("requestedReviewer").and_then(Value::as_object) {
        let reviewer_type = req.get("__typename").and_then(Value::as_str).unwrap_or("");
        if reviewer_type == "Team" {
            entry.requested_reviewer_team_slug = parse_string(req.get("slug"));
        } else {
            entry.requested_reviewer_login = parse_string(req.get("login"));
        }
    }
}

fn fill_cross_referenced(entry: &mut SimpleActorEventEntry, node: &Value) {
    if let Some(src) = node.get("source").and_then(Value::as_object) {
        entry.source_url = parse_string(src.get("url"));
        entry.source_title = parse_string(src.get("title"));
        entry.source_number = src.get("number").and_then(Value::as_i64);
        entry.source_repository = src
            .get("repository")
            .and_then(Value::as_object)
            .and_then(|r| r.get("nameWithOwner"))
            .and_then(Value::as_str)
            .map(str::to_string);
    }
}

fn fill_base_ref_force_pushed(entry: &mut SimpleActorEventEntry, node: &Value) {
    let (before, _) = parse_commit_oid(node.get("beforeCommit"));
    let (after, _) = parse_commit_oid(node.get("afterCommit"));
    entry.before_oid = Some(before).filter(|s| !s.is_empty());
    entry.after_oid = Some(after).filter(|s| !s.is_empty());
    entry.branch_name = node
        .get("ref")
        .and_then(Value::as_object)
        .and_then(|r| r.get("name"))
        .and_then(Value::as_str)
        .map(str::to_string);
}
