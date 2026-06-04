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
    ReviewActionKind, ReviewActionOutcome, ReviewActionPreviewKind, ReviewAuthorAssociation,
    ReviewCheckConclusion, ReviewCheckRunStatus, ReviewCheckStatus, ReviewMergeableState,
    ReviewPullRequestState, ReviewReviewEventState, ReviewReviewStatus,
};
use super::logic::{
    default_cache_max_age_seconds, default_pull_request_state, default_reviews_policy_workflow_id,
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
    /// GitHub login of the authenticated viewer for "(you)" reviewer and
    /// "Commenting as @viewer" UI copy. `None` means lookup failed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub viewer_login: Option<String>,
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
#[expect(
    clippy::struct_excessive_bools,
    reason = "wire flags map directly to distinct UI toggles and daemon state"
)]
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct ReviewItemFlags {
    #[serde(default)]
    pub is_draft: bool,
    #[serde(default)]
    pub policy_blocked: bool,
    #[serde(default = "default_viewer_can_update")]
    pub viewer_can_update: bool,
    #[serde(default)]
    pub viewer_is_requested_reviewer: bool,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author_avatar_url: Option<String>,
    #[serde(default)]
    pub author_association: ReviewAuthorAssociation,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author_avatar_url: Option<String>,
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
pub struct ReviewsPolicySubject {
    pub repository: String,
    pub pull_request_number: u64,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewsPolicyTrigger {
    Background,
    Event,
    #[default]
    Manual,
    ManualNudge,
    Timer,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewsPolicyRunStatus {
    Completed,
    Failed,
    Running,
    Waiting,
    Cancelled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewsPolicyStepType {
    Action,
    Wait,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyWait {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub event_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_seconds: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyPreviewStep {
    pub step_type: ReviewsPolicyStepType,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub waiting_on: Option<ReviewsPolicyWait>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyPreviewRequest {
    #[serde(default = "default_reviews_policy_workflow_id")]
    pub workflow_id: String,
    pub target: ReviewTarget,
    #[serde(default)]
    pub method: GitHubMergeMethod,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyPreviewResponse {
    pub workflow_id: String,
    pub subject: ReviewsPolicySubject,
    pub eligible: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub warnings: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub steps: Vec<ReviewsPolicyPreviewStep>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyRunStartRequest {
    #[serde(default = "default_reviews_policy_workflow_id")]
    pub workflow_id: String,
    pub target: ReviewTarget,
    #[serde(default)]
    pub method: GitHubMergeMethod,
    #[serde(default)]
    pub trigger: ReviewsPolicyTrigger,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyRunStep {
    pub step_type: ReviewsPolicyStepType,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub waiting_on: Option<ReviewsPolicyWait>,
    pub recorded_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyRunResponse {
    pub workflow_id: String,
    pub run_id: String,
    pub subject: ReviewsPolicySubject,
    pub trigger: ReviewsPolicyTrigger,
    pub status: ReviewsPolicyRunStatus,
    pub started_at: String,
    pub updated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub waiting_on: Option<ReviewsPolicyWait>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_message: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub steps: Vec<ReviewsPolicyRunStep>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyStatusRequest {
    #[serde(default = "default_reviews_policy_workflow_id")]
    pub workflow_id: String,
    pub subject: ReviewsPolicySubject,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyStatusResponse {
    pub workflow_id: String,
    pub subject: ReviewsPolicySubject,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_run: Option<ReviewsPolicyRunResponse>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub recent_runs: Vec<ReviewsPolicyRunResponse>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyHistoryRequest {
    #[serde(default = "default_reviews_policy_workflow_id")]
    pub workflow_id: String,
    pub subject: ReviewsPolicySubject,
}

/// Aggregate status and trigger counts for the runs in a history response.
/// Mirrors the runtime metrics summary so the Monitor app can render totals
/// without re-deriving them from the run list.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyRunMetrics {
    pub total: usize,
    pub running: usize,
    pub waiting: usize,
    pub completed: usize,
    pub failed: usize,
    pub cancelled: usize,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub by_trigger: BTreeMap<String, usize>,
}

/// A single structured entry in a policy run timeline export, flattened from
/// the recorded step list across the response's runs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyTimelineEntry {
    pub recorded_at: String,
    pub run_id: String,
    pub event: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPolicyHistoryResponse {
    pub workflow_id: String,
    pub subject: ReviewsPolicySubject,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub runs: Vec<ReviewsPolicyRunResponse>,
    #[serde(default)]
    pub metrics: ReviewsPolicyRunMetrics,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub timeline: Vec<ReviewsPolicyTimelineEntry>,
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
