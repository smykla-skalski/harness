#![allow(dead_code)]

use chrono::{DateTime, Utc};
use serde_json::Value;

use super::types::{
    Actor, CommitEntry, DependencyUpdateTimelineEntry, HeadRefForcePushedEntry, IssueCommentEntry,
    ReviewEntry, ReviewInlineCommentEntry, ReviewState, ReviewThreadCommentEntry,
    ReviewThreadEntry, SimpleActorEventEntry, SimpleActorEventKind,
};

pub(super) fn parse_iso8601(value: Option<&Value>) -> Option<DateTime<Utc>> {
    value
        .and_then(Value::as_str)
        .and_then(|raw| DateTime::parse_from_rfc3339(raw).ok())
        .map(|dt| dt.with_timezone(&Utc))
}

pub(super) fn parse_actor(value: Option<&Value>) -> Option<Actor> {
    let obj = value?.as_object()?;
    let login = obj.get("login").and_then(Value::as_str)?.to_string();
    let avatar_url = obj
        .get("avatarUrl")
        .and_then(Value::as_str)
        .map(str::to_string);
    Some(Actor { login, avatar_url })
}

pub(super) fn parse_string(value: Option<&Value>) -> Option<String> {
    value.and_then(Value::as_str).map(str::to_string)
}

pub(super) fn parse_string_required(node: &Value, field: &str) -> Option<String> {
    parse_string(node.get(field))
}

pub(super) fn parse_bool(value: Option<&Value>) -> bool {
    value.and_then(Value::as_bool).unwrap_or(false)
}

pub(super) fn parse_i32(value: Option<&Value>) -> Option<i32> {
    value
        .and_then(Value::as_i64)
        .and_then(|n| i32::try_from(n).ok())
}

pub(super) fn parse_u32(value: Option<&Value>) -> u32 {
    value
        .and_then(Value::as_u64)
        .and_then(|n| u32::try_from(n).ok())
        .unwrap_or(0)
}

pub(super) fn typename<'a>(node: &'a Value) -> Option<&'a str> {
    node.get("__typename").and_then(Value::as_str)
}

/// Result of parsing a `comments` connection's first page on a
/// `PullRequestReview` node: the entries themselves, the next cursor,
/// and the `hasNextPage` flag the service handler uses to decide
/// whether to issue a continuation fetch.
pub(super) struct InlineCommentsPage {
    pub entries: Vec<ReviewInlineCommentEntry>,
    pub end_cursor: Option<String>,
    pub has_next_page: bool,
}

pub(super) fn parse_review_inline_comments(
    comments_field: Option<&Value>,
) -> InlineCommentsPage {
    let Some(connection) = comments_field.and_then(Value::as_object) else {
        return InlineCommentsPage {
            entries: Vec::new(),
            end_cursor: None,
            has_next_page: false,
        };
    };
    let page_info = connection.get("pageInfo").and_then(Value::as_object);
    let end_cursor = page_info
        .and_then(|p| p.get("endCursor"))
        .and_then(Value::as_str)
        .map(str::to_string);
    let has_next_page = page_info
        .and_then(|p| p.get("hasNextPage"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let entries = connection
        .get("nodes")
        .and_then(Value::as_array)
        .map(|nodes| {
            nodes
                .iter()
                .filter_map(parse_review_inline_comment)
                .collect()
        })
        .unwrap_or_default();
    InlineCommentsPage {
        entries,
        end_cursor,
        has_next_page,
    }
}

pub(super) fn parse_review_inline_comment(node: &Value) -> Option<ReviewInlineCommentEntry> {
    let id = parse_string_required(node, "id")?;
    let path = parse_string_required(node, "path")?;
    let body = parse_string_required(node, "body")?;
    let created_at = parse_iso8601(node.get("createdAt"))?;
    let position = parse_i32(node.get("position"));
    let url = parse_string(node.get("url"));
    let actor = parse_actor(node.get("author"));
    let reply_to_id = node
        .get("replyTo")
        .and_then(Value::as_object)
        .and_then(|r| r.get("id"))
        .and_then(Value::as_str)
        .map(str::to_string);
    Some(ReviewInlineCommentEntry {
        id,
        path,
        position,
        body,
        created_at,
        actor,
        reply_to_id,
        url,
    })
}

pub(super) struct ThreadCommentsPage {
    pub entries: Vec<ReviewThreadCommentEntry>,
    pub end_cursor: Option<String>,
    pub has_next_page: bool,
}

pub(super) fn parse_review_thread_comments(
    comments_field: Option<&Value>,
) -> ThreadCommentsPage {
    let Some(connection) = comments_field.and_then(Value::as_object) else {
        return ThreadCommentsPage {
            entries: Vec::new(),
            end_cursor: None,
            has_next_page: false,
        };
    };
    let page_info = connection.get("pageInfo").and_then(Value::as_object);
    let end_cursor = page_info
        .and_then(|p| p.get("endCursor"))
        .and_then(Value::as_str)
        .map(str::to_string);
    let has_next_page = page_info
        .and_then(|p| p.get("hasNextPage"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let entries = connection
        .get("nodes")
        .and_then(Value::as_array)
        .map(|nodes| {
            nodes
                .iter()
                .filter_map(parse_review_thread_comment)
                .collect()
        })
        .unwrap_or_default();
    ThreadCommentsPage {
        entries,
        end_cursor,
        has_next_page,
    }
}

pub(super) fn parse_review_thread_comment(node: &Value) -> Option<ReviewThreadCommentEntry> {
    let id = parse_string_required(node, "id")?;
    let body = parse_string_required(node, "body")?;
    let created_at = parse_iso8601(node.get("createdAt"))?;
    let url = parse_string(node.get("url"));
    let actor = parse_actor(node.get("author"));
    Some(ReviewThreadCommentEntry {
        id,
        body,
        created_at,
        actor,
        url,
    })
}

pub(super) fn map_issue_comment(node: &Value) -> Option<DependencyUpdateTimelineEntry> {
    let id = parse_string_required(node, "id")?;
    let body = parse_string_required(node, "body")?;
    let created_at = parse_iso8601(node.get("createdAt"))?;
    let updated_at = parse_iso8601(node.get("updatedAt"));
    let body_text = parse_string(node.get("bodyText"));
    let is_minimized = parse_bool(node.get("isMinimized"));
    let minimized_reason = parse_string(node.get("minimizedReason"));
    let reactions_total = parse_u32(
        node.get("reactions")
            .and_then(Value::as_object)
            .and_then(|r| r.get("totalCount")),
    );
    let viewer_did_author = parse_bool(node.get("viewerDidAuthor"));
    let viewer_can_edit = parse_bool(node.get("viewerCanUpdate"));
    let url = parse_string(node.get("url"));
    let actor = parse_actor(node.get("author"));
    Some(DependencyUpdateTimelineEntry::IssueComment(IssueCommentEntry {
        id,
        created_at,
        updated_at,
        actor,
        body,
        body_text,
        is_minimized,
        minimized_reason,
        reactions_total,
        viewer_did_author,
        viewer_can_edit,
        url,
    }))
}

pub(super) fn map_pull_request_review(node: &Value) -> Option<DependencyUpdateTimelineEntry> {
    let id = parse_string_required(node, "id")?;
    let created_at = parse_iso8601(node.get("createdAt"))?;
    let state = parse_review_state(node.get("state"))?;
    let body = parse_string(node.get("body")).filter(|b| !b.is_empty());
    let url = parse_string(node.get("url"));
    let actor = parse_actor(node.get("author"));
    let inline = parse_review_inline_comments(node.get("comments"));
    Some(DependencyUpdateTimelineEntry::Review(ReviewEntry {
        id,
        created_at,
        actor,
        state,
        body,
        url,
        inline_comments: inline.entries,
        comments_truncated: false,
    }))
}

pub(super) fn parse_review_state(value: Option<&Value>) -> Option<ReviewState> {
    let raw = value.and_then(Value::as_str)?;
    match raw {
        "PENDING" => Some(ReviewState::Pending),
        "COMMENTED" => Some(ReviewState::Commented),
        "APPROVED" => Some(ReviewState::Approved),
        "CHANGES_REQUESTED" => Some(ReviewState::ChangesRequested),
        "DISMISSED" => Some(ReviewState::Dismissed),
        _ => None,
    }
}

pub(super) fn map_pull_request_review_thread(
    node: &Value,
) -> Option<DependencyUpdateTimelineEntry> {
    let id = parse_string_required(node, "id")?;
    let path = parse_string_required(node, "path")?;
    let is_resolved = parse_bool(node.get("isResolved"));
    let is_collapsed = parse_bool(node.get("isCollapsed"));
    let line = parse_i32(node.get("line"));
    let original_line = parse_i32(node.get("originalLine"));
    let diff_side = parse_string(node.get("diffSide"));
    let comments = parse_review_thread_comments(node.get("comments"));
    let first_comment = comments.entries.first();
    let created_at = first_comment.map(|c| c.created_at)?;
    let actor = first_comment.and_then(|c| c.actor.clone());
    Some(DependencyUpdateTimelineEntry::ReviewThread(ReviewThreadEntry {
        id,
        created_at,
        actor,
        is_resolved,
        is_collapsed,
        path,
        line,
        original_line,
        diff_side,
        comments: comments.entries,
        comments_truncated: false,
    }))
}

pub(super) fn map_pull_request_commit(node: &Value) -> Option<DependencyUpdateTimelineEntry> {
    let id = parse_string_required(node, "id")?;
    let url = parse_string(node.get("url"));
    let commit = node.get("commit").and_then(Value::as_object)?;
    let oid = commit.get("oid").and_then(Value::as_str)?.to_string();
    let abbreviated_oid = commit
        .get("abbreviatedOid")
        .and_then(Value::as_str)?
        .to_string();
    let message_headline = commit
        .get("messageHeadline")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let committed_date = parse_iso8601(commit.get("committedDate"));
    let created_at = committed_date.unwrap_or_else(Utc::now);
    let git_actor = commit.get("author").and_then(Value::as_object);
    let author_name = git_actor
        .and_then(|a| a.get("name"))
        .and_then(Value::as_str)
        .map(str::to_string);
    let user_obj = git_actor.and_then(|a| a.get("user").and_then(Value::as_object));
    let author_login = user_obj
        .and_then(|u| u.get("login"))
        .and_then(Value::as_str)
        .map(str::to_string);
    let actor = user_obj.and_then(|u| {
        let login = u.get("login").and_then(Value::as_str)?.to_string();
        let avatar_url = u
            .get("avatarUrl")
            .and_then(Value::as_str)
            .map(str::to_string);
        Some(Actor { login, avatar_url })
    });
    Some(DependencyUpdateTimelineEntry::Commit(CommitEntry {
        id,
        created_at,
        actor,
        oid,
        abbreviated_oid,
        message_headline,
        committed_date,
        author_name,
        author_login,
        url,
    }))
}

pub(super) fn map_head_ref_force_pushed(
    node: &Value,
) -> Option<DependencyUpdateTimelineEntry> {
    let id = parse_string_required(node, "id")?;
    let created_at = parse_iso8601(node.get("createdAt"))?;
    let actor = parse_actor(node.get("actor"));
    let (before_oid, before_abbrev) = parse_commit_oid(node.get("beforeCommit"));
    let (after_oid, after_abbrev) = parse_commit_oid(node.get("afterCommit"));
    let ref_name = node
        .get("ref")
        .and_then(Value::as_object)
        .and_then(|r| r.get("name"))
        .and_then(Value::as_str)
        .map(str::to_string);
    Some(DependencyUpdateTimelineEntry::HeadRefForcePushed(
        HeadRefForcePushedEntry {
            id,
            created_at,
            actor,
            before_oid,
            before_abbreviated_oid: before_abbrev,
            after_oid,
            after_abbreviated_oid: after_abbrev,
            ref_name,
        },
    ))
}

pub(super) fn parse_commit_oid(value: Option<&Value>) -> (String, String) {
    let Some(obj) = value.and_then(Value::as_object) else {
        return (String::new(), String::new());
    };
    let oid = obj
        .get("oid")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let abbreviated = obj
        .get("abbreviatedOid")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    (oid, abbreviated)
}

/// Dispatches a single timeline node to its mapper based on
/// `__typename`. Hot kinds get dedicated mappers; the 39 lightweight
/// `SimpleActorEvent` typeenames funnel through `map_simple_actor_event`.
/// The forward-compat fallback for unknown typeenames lands in A.6.
pub(super) fn map_node(node: &Value) -> Option<DependencyUpdateTimelineEntry> {
    let name = typename(node)?;
    match name {
        "IssueComment" => map_issue_comment(node),
        "PullRequestReview" => map_pull_request_review(node),
        "PullRequestReviewThread" => map_pull_request_review_thread(node),
        "PullRequestCommit" => map_pull_request_commit(node),
        "HeadRefForcePushedEvent" => map_head_ref_force_pushed(node),
        other => map_simple_actor_event(other, node),
    }
}

fn typename_to_simple_kind(typename: &str) -> Option<SimpleActorEventKind> {
    use SimpleActorEventKind::*;
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
    let created = node
        .get("createdAt")
        .and_then(Value::as_str)
        .unwrap_or("");
    let marker_oid = node
        .get("lastSeenCommit")
        .and_then(Value::as_object)
        .and_then(|c| c.get("oid"))
        .and_then(Value::as_str)
        .unwrap_or("");
    format!("synthetic:{typename}:{marker_oid}:{created}")
}

pub(super) fn map_simple_actor_event(
    typename: &str,
    node: &Value,
) -> Option<DependencyUpdateTimelineEntry> {
    let event_kind = typename_to_simple_kind(typename)?;
    let id = node
        .get("id")
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| synthesize_id(typename, node));
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

    match event_kind {
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
        SimpleActorEventKind::ReviewRequested
        | SimpleActorEventKind::ReviewRequestRemoved => {
            if let Some(req) = node.get("requestedReviewer").and_then(Value::as_object) {
                let reviewer_type = req.get("__typename").and_then(Value::as_str).unwrap_or("");
                if reviewer_type == "Team" {
                    entry.requested_reviewer_team_slug = parse_string(req.get("slug"));
                } else {
                    entry.requested_reviewer_login = parse_string(req.get("login"));
                }
            }
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
        SimpleActorEventKind::BaseRefChanged => {
            entry.old_title = parse_string(node.get("previousRefName"));
            entry.new_title = parse_string(node.get("currentRefName"));
        }
        SimpleActorEventKind::BaseRefForcePushed => {
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
    Some(DependencyUpdateTimelineEntry::SimpleActorEvent(entry))
}
