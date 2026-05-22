#![allow(dead_code)]

use chrono::Utc;
use serde_json::Value;

use super::super::types::{
    Actor, CommitEntry, DependencyUpdateTimelineEntry, HeadRefForcePushedEntry, IssueCommentEntry,
    ReviewEntry, ReviewThreadEntry,
};
use super::helpers::{
    parse_actor, parse_bool, parse_commit_oid, parse_i32, parse_iso8601,
    parse_review_inline_comments, parse_review_state, parse_review_thread_comments, parse_string,
    parse_string_required, parse_u32,
};

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
