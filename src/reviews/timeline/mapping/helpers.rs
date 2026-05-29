#![allow(dead_code)]

use chrono::{DateTime, Utc};
use serde_json::Value;

use super::super::types::{Actor, ReviewInlineCommentEntry, ReviewState, ReviewThreadCommentEntry};

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

/// Result of parsing a `comments` connection's first page on a
/// `PullRequestReview` node: the entries themselves, the next cursor,
/// and the `hasNextPage` flag the service handler uses to decide
/// whether to issue a continuation fetch.
pub(super) struct InlineCommentsPage {
    pub entries: Vec<ReviewInlineCommentEntry>,
    pub end_cursor: Option<String>,
    pub has_next_page: bool,
}

pub(super) fn parse_review_inline_comments(comments_field: Option<&Value>) -> InlineCommentsPage {
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
    let line = parse_i32(node.get("line"));
    let original_line = parse_i32(node.get("originalLine"));
    let diff_hunk = parse_string(node.get("diffHunk"));
    let url = parse_string(node.get("url"));
    let actor = parse_actor(node.get("author"));
    let reply_to_id = node
        .get("replyTo")
        .and_then(Value::as_object)
        .and_then(|r| r.get("id"))
        .and_then(Value::as_str)
        .map(str::to_string);
    let outdated = node
        .get("outdated")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    Some(ReviewInlineCommentEntry {
        id,
        path,
        position,
        line,
        original_line,
        diff_hunk,
        body,
        created_at,
        actor,
        reply_to_id,
        outdated,
        url,
    })
}

pub(super) struct ThreadCommentsPage {
    pub entries: Vec<ReviewThreadCommentEntry>,
    pub end_cursor: Option<String>,
    pub has_next_page: bool,
}

pub(super) fn parse_review_thread_comments(comments_field: Option<&Value>) -> ThreadCommentsPage {
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
