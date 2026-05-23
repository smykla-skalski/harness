//! Wire types for the reviews service.
//!
//! Houses the request and response DTOs along with the shared
//! [`ReviewTarget`] / [`ReviewActionResult`] structs. Behavior lives in
//! [`crate::reviews::logic`]; enum variants live in [`crate::reviews::enums`].

use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::task_board::github::GitHubMergeMethod;

use super::enums::{
    ReviewActionKind, ReviewActionOutcome, ReviewActionPreviewKind,
    ReviewCheckConclusion, ReviewCheckRunStatus, ReviewCheckStatus,
    ReviewMergeableState, ReviewPullRequestState, ReviewReviewEventState,
    ReviewReviewStatus,
};
use super::logic::{
    default_cache_max_age_seconds, default_pull_request_state,
    default_viewer_can_merge_as_admin, default_viewer_can_update,
};
use super::timeline;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsQueryRequest {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub authors: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub organizations: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub repositories: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub exclude_repositories: Vec<String>,
    #[serde(default)]
    pub force_refresh: bool,
    #[serde(default = "default_cache_max_age_seconds")]
    pub cache_max_age_seconds: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsRepositoryCatalogRequest {
    pub organization: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsRepositoryCatalogResponse {
    pub organization: String,
    #[serde(default)]
    pub repositories: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsQueryResponse {
    pub fetched_at: String,
    pub from_cache: bool,
    pub summary: ReviewsSummary,
    pub items: Vec<ReviewItem>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub repository_labels: BTreeMap<String, Vec<ReviewRepositoryLabel>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewRepositoryLabel {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsSummary {
    pub total: usize,
    pub review_required: usize,
    pub ready_to_merge: usize,
    pub auto_approvable: usize,
    pub waiting_on_checks: usize,
    pub blocked: usize,
}

/// Per-PR state flags bundled into at most 3 booleans.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct ReviewItemFlags {
    #[serde(default)]
    pub is_draft: bool,
    #[serde(default)]
    pub policy_blocked: bool,
    #[serde(default = "default_viewer_can_update")]
    pub viewer_can_update: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewItem {
    pub pull_request_id: String,
    pub repository_id: String,
    pub repository: String,
    pub number: u64,
    pub title: String,
    pub url: String,
    pub author_login: String,
    pub state: ReviewPullRequestState,
    pub mergeable: ReviewMergeableState,
    pub review_status: ReviewReviewStatus,
    pub check_status: ReviewCheckStatus,
    #[serde(flatten)]
    pub flags: ReviewItemFlags,
    #[serde(default = "default_viewer_can_merge_as_admin")]
    pub viewer_can_merge_as_admin: bool,
    pub head_sha: String,
    #[serde(default)]
    pub labels: Vec<String>,
    #[serde(default)]
    pub checks: Vec<ReviewCheck>,
    #[serde(default)]
    pub reviews: Vec<PullRequestReview>,
    pub additions: u64,
    pub deletions: u64,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    #[serde(default)]
    pub required_failed_check_names: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewCheck {
    pub name: String,
    pub status: ReviewCheckRunStatus,
    pub conclusion: ReviewCheckConclusion,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub check_suite_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PullRequestReview {
    pub author: String,
    pub state: ReviewReviewEventState,
}

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

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsRefreshRequest {
    #[serde(default)]
    pub targets: Vec<ReviewTarget>,
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
