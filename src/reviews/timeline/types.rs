#![allow(dead_code)]

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value as JsonValue;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Actor {
    pub login: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ReviewTimelineEntry {
    IssueComment(IssueCommentEntry),
    Review(ReviewEntry),
    ReviewThread(ReviewThreadEntry),
    Commit(CommitEntry),
    HeadRefForcePushed(HeadRefForcePushedEntry),
    SimpleActorEvent(SimpleActorEventEntry),
    Unknown(UnknownEntry),
}

impl ReviewTimelineEntry {
    #[must_use]
    pub fn id(&self) -> &str {
        match self {
            Self::IssueComment(entry) => &entry.id,
            Self::Review(entry) => &entry.id,
            Self::ReviewThread(entry) => &entry.id,
            Self::Commit(entry) => &entry.id,
            Self::HeadRefForcePushed(entry) => &entry.id,
            Self::SimpleActorEvent(entry) => &entry.id,
            Self::Unknown(entry) => &entry.id,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IssueCommentEntry {
    pub id: String,
    pub created_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<Actor>,
    pub body: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body_text: Option<String>,
    #[serde(default)]
    pub is_minimized: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub minimized_reason: Option<String>,
    #[serde(default)]
    pub reactions_total: u32,
    #[serde(default)]
    pub viewer_did_author: bool,
    #[serde(default)]
    pub viewer_can_edit: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewEntry {
    pub id: String,
    pub created_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<Actor>,
    pub state: ReviewState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default)]
    pub inline_comments: Vec<ReviewInlineCommentEntry>,
    #[serde(default)]
    pub comments_truncated: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewState {
    Pending,
    Commented,
    Approved,
    ChangesRequested,
    Dismissed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewInlineCommentEntry {
    pub id: String,
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub position: Option<i32>,
    pub body: String,
    pub created_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<Actor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply_to_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewThreadEntry {
    pub id: String,
    pub created_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<Actor>,
    #[serde(default)]
    pub is_resolved: bool,
    #[serde(default)]
    pub is_collapsed: bool,
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub original_line: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub diff_side: Option<String>,
    #[serde(default)]
    pub comments: Vec<ReviewThreadCommentEntry>,
    #[serde(default)]
    pub comments_truncated: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewThreadCommentEntry {
    pub id: String,
    pub body: String,
    pub created_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<Actor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommitEntry {
    pub id: String,
    pub created_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<Actor>,
    pub oid: String,
    pub abbreviated_oid: String,
    pub message_headline: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub committed_date: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author_login: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HeadRefForcePushedEntry {
    pub id: String,
    pub created_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<Actor>,
    pub before_oid: String,
    pub before_abbreviated_oid: String,
    pub after_oid: String,
    pub after_abbreviated_oid: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ref_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SimpleActorEventEntry {
    pub id: String,
    pub created_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<Actor>,
    pub event_kind: SimpleActorEventKind,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label_color: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub milestone_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub old_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub new_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_number: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before_oid: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after_oid: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lock_reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dismissal_message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requested_reviewer_login: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requested_reviewer_team_slug: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assignee_login: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_repository: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub destination_repository: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SimpleActorEventKind {
    HeadRefDeleted,
    HeadRefRestored,
    BaseRefChanged,
    BaseRefForcePushed,
    BaseRefDeleted,
    Labeled,
    Unlabeled,
    Assigned,
    Unassigned,
    Merged,
    Closed,
    Reopened,
    RenamedTitle,
    ReviewRequested,
    ReviewRequestRemoved,
    ReviewDismissed,
    ReadyForReview,
    ConvertToDraft,
    AutoMergeEnabled,
    AutoMergeDisabled,
    AutoRebaseEnabled,
    AutoSquashEnabled,
    Locked,
    Unlocked,
    Pinned,
    Unpinned,
    Milestoned,
    Demilestoned,
    Referenced,
    CrossReferenced,
    Mentioned,
    Subscribed,
    Unsubscribed,
    MarkedAsDuplicate,
    UnmarkedAsDuplicate,
    Transferred,
    Connected,
    Disconnected,
    RevisionMarker,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UnknownEntry {
    pub id: String,
    pub created_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<Actor>,
    pub typename: String,
    #[serde(default, skip_serializing_if = "JsonValue::is_null")]
    pub raw_payload: JsonValue,
}
