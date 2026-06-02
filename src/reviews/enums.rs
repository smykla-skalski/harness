//! Enum definitions for the reviews wire surface.
//!
//! Kept in a dedicated module so the type and behavior modules can import
//! them without pulling in the full module root.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewPullRequestState {
    Open,
    Closed,
    Merged,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewMergeableState {
    Mergeable,
    Conflicting,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewReviewStatus {
    None,
    ReviewRequired,
    Approved,
    ChangesRequested,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewCheckStatus {
    None,
    Success,
    Failure,
    Pending,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewCheckRunStatus {
    Completed,
    InProgress,
    Queued,
    Requested,
    Waiting,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewCheckConclusion {
    None,
    Success,
    Failure,
    Neutral,
    Cancelled,
    TimedOut,
    ActionRequired,
    Skipped,
    Stale,
    StartupFailure,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewReviewEventState {
    Approved,
    ChangesRequested,
    Commented,
    Dismissed,
    Pending,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ReviewAuthorAssociation {
    Owner,
    Member,
    Collaborator,
    Contributor,
    FirstTimer,
    FirstTimeContributor,
    Mannequin,
    #[default]
    None,
    Other,
}

impl ReviewAuthorAssociation {
    #[must_use]
    pub fn parse(value: Option<&str>) -> Self {
        match value {
            Some("OWNER") => Self::Owner,
            Some("MEMBER") => Self::Member,
            Some("COLLABORATOR") => Self::Collaborator,
            Some("CONTRIBUTOR") => Self::Contributor,
            Some("FIRST_TIMER") => Self::FirstTimer,
            Some("FIRST_TIME_CONTRIBUTOR") => Self::FirstTimeContributor,
            Some("MANNEQUIN") => Self::Mannequin,
            None | Some("NONE") => Self::None,
            _ => Self::Other,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewActionKind {
    Approve,
    Merge,
    RerunChecks,
    AddLabel,
    AutoApprove,
    AutoMerge,
    Comment,
    RequestReview,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewActionPreviewKind {
    Approve,
    Merge,
    RerunChecks,
    AddLabel,
    Auto,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewActionOutcome {
    Applied,
    Skipped,
    Failed,
}
