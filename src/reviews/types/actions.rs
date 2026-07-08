use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::task_board::github::GitHubMergeMethod;

use super::super::enums::{
    ReviewActionKind, ReviewActionOutcome, ReviewActionPreviewKind, ReviewCheckStatus,
    ReviewMergeableState, ReviewPullRequestState, ReviewReviewStatus,
};
use super::super::logic::{
    default_backport_detection_enabled, default_backport_patterns, default_cache_max_age_seconds,
    default_pull_request_state, default_viewer_can_merge_as_admin, default_viewer_can_update,
};
use super::super::timeline;
use super::ReviewItem;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsApproveRequest {
    pub targets: Vec<ReviewTarget>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsMergeRequest {
    pub targets: Vec<ReviewTarget>,
    #[serde(default)]
    pub method: GitHubMergeMethod,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsRerunChecksRequest {
    pub targets: Vec<ReviewTarget>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsLabelRequest {
    pub targets: Vec<ReviewTarget>,
    pub label: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsAutoRequest {
    pub targets: Vec<ReviewTarget>,
    #[serde(default)]
    pub method: GitHubMergeMethod,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsCommentRequest {
    pub targets: Vec<ReviewTarget>,
    pub body: String,
}

/// Re-request a fresh review from a specific GitHub login on each target
/// pull request. Mirrors GitHub's "Re-request review" affordance: when a
/// reviewer has already submitted a review (approved, dismissed, or
/// requested changes), this drops them back into the requested-reviewers
/// list so they get notified to look again.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsRequestReviewRequest {
    pub targets: Vec<ReviewTarget>,
    pub reviewer_login: String,
}

/// Action-related feature flags for [`ReviewsCapabilitiesResponse`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct ReviewsActionCapabilities {
    #[serde(default)]
    pub supports_action_preview: bool,
    #[serde(default)]
    pub supports_check_run_links: bool,
    #[serde(default)]
    pub supports_repository_sync_health: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsCapabilitiesResponse {
    pub schema_version: u32,
    #[serde(flatten)]
    pub features: ReviewsActionCapabilities,
    #[serde(default)]
    pub supports_persistent_action_diagnostics: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsActionPreviewRequest {
    pub action: ReviewActionPreviewKind,
    pub targets: Vec<ReviewTarget>,
    #[serde(default)]
    pub method: GitHubMergeMethod,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsActionPreviewResponse {
    pub action: ReviewActionPreviewKind,
    pub capabilities: ReviewsCapabilitiesResponse,
    pub total_count: usize,
    pub actionable_count: usize,
    pub skipped_count: usize,
    #[serde(default)]
    pub warnings: Vec<String>,
    #[serde(default)]
    pub targets: Vec<ReviewActionPreviewTarget>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewActionPreviewTarget {
    pub pull_request_id: String,
    pub repository: String,
    pub number: u64,
    pub eligible: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default)]
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsActionResponse {
    pub summary: String,
    #[serde(default)]
    pub results: Vec<ReviewActionResult>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsCacheClearResponse {
    pub cleared_entries: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsRefreshRequest {
    #[serde(default)]
    pub targets: Vec<ReviewTarget>,
    #[serde(default = "default_backport_detection_enabled")]
    pub backport_detection_enabled: bool,
    #[serde(
        default = "default_backport_patterns",
        skip_serializing_if = "Vec::is_empty"
    )]
    pub backport_patterns: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsRefreshResponse {
    pub fetched_at: String,
    #[serde(default)]
    pub items: Vec<ReviewItem>,
    #[serde(default)]
    pub missing_pull_request_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsBodyRequest {
    pub pull_request_id: String,
    #[serde(default)]
    pub force_refresh: bool,
    #[serde(default = "default_cache_max_age_seconds")]
    pub cache_max_age_seconds: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsBodyResponse {
    pub pull_request_id: String,
    pub body: String,
    pub pr_updated_at: DateTime<Utc>,
    pub fetched_at: String,
    pub from_cache: bool,
}

/// State flags embedded in [`ReviewTarget`] (at most 3 booleans).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct ReviewTargetFlags {
    #[serde(default)]
    pub is_draft: bool,
    #[serde(default)]
    pub policy_blocked: bool,
    #[serde(default = "default_viewer_can_update")]
    pub viewer_can_update: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewTarget {
    pub pull_request_id: String,
    pub repository_id: String,
    pub repository: String,
    pub number: u64,
    pub url: String,
    #[serde(default = "default_pull_request_state")]
    pub state: ReviewPullRequestState,
    pub head_sha: String,
    pub mergeable: ReviewMergeableState,
    pub review_status: ReviewReviewStatus,
    pub check_status: ReviewCheckStatus,
    #[serde(flatten)]
    pub flags: ReviewTargetFlags,
    #[serde(default = "default_viewer_can_merge_as_admin")]
    pub viewer_can_merge_as_admin: bool,
    #[serde(default)]
    pub required_failed_check_names: Vec<String>,
    #[serde(default)]
    pub check_suite_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub has_conflict_markers: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub viewer_has_active_approval: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto_merge_enabled: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approval_requirement_satisfied_after_viewer_approval: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewActionResult {
    pub repository: String,
    pub number: u64,
    pub action: ReviewActionKind,
    pub outcome: ReviewActionOutcome,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeline_entry: Option<timeline::ReviewTimelineEntry>,
}
