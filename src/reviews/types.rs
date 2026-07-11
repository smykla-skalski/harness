//! Wire types for the reviews service.
//!
//! Houses the request and response DTOs along with the shared
//! [`ReviewTarget`] / [`ReviewActionResult`] structs. Behavior lives in
//! [`crate::reviews::logic`]; enum variants live in [`crate::reviews::enums`].

use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::enums::{
    ReviewAuthorAssociation, ReviewCheckConclusion, ReviewCheckRunStatus, ReviewCheckStatus,
    ReviewMergeableState, ReviewPullRequestState, ReviewReviewEventState, ReviewReviewStatus,
};
use super::logic::{
    default_backport_detection_enabled, default_backport_patterns, default_cache_max_age_seconds,
    default_viewer_can_merge_as_admin, default_viewer_can_update,
};

mod actions;
mod policy;

pub use self::actions::{
    ReviewActionPreviewTarget, ReviewActionResult, ReviewTarget, ReviewTargetFlags,
    ReviewsActionCapabilities, ReviewsActionPreviewRequest, ReviewsActionPreviewResponse,
    ReviewsActionResponse, ReviewsApproveRequest, ReviewsApproveRequestSource, ReviewsAutoRequest,
    ReviewsBodyRequest, ReviewsBodyResponse, ReviewsCacheClearResponse,
    ReviewsCapabilitiesResponse, ReviewsCommentRequest, ReviewsLabelRequest, ReviewsMergeRequest,
    ReviewsRefreshRequest, ReviewsRefreshResponse, ReviewsRequestReviewRequest,
    ReviewsRerunChecksRequest,
};
pub use self::policy::{
    ReviewsPolicyHistoryRequest, ReviewsPolicyHistoryResponse, ReviewsPolicyPreviewRequest,
    ReviewsPolicyPreviewResponse, ReviewsPolicyPreviewStep, ReviewsPolicyRunMetrics,
    ReviewsPolicyRunResponse, ReviewsPolicyRunStartRequest, ReviewsPolicyRunStatus,
    ReviewsPolicyRunStep, ReviewsPolicyStatusRequest, ReviewsPolicyStatusResponse,
    ReviewsPolicyStepType, ReviewsPolicySubject, ReviewsPolicyTimelineEntry, ReviewsPolicyTrigger,
    ReviewsPolicyWait,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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
    #[serde(default = "default_backport_detection_enabled")]
    pub backport_detection_enabled: bool,
    #[serde(
        default = "default_backport_patterns",
        skip_serializing_if = "Vec::is_empty"
    )]
    pub backport_patterns: Vec<String>,
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
pub struct ReviewsPullRequestReference {
    pub repository: String,
    pub number: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPullRequestResolveRequest {
    #[serde(default)]
    pub references: Vec<ReviewsPullRequestReference>,
    #[serde(default = "default_backport_detection_enabled")]
    pub backport_detection_enabled: bool,
    #[serde(
        default = "default_backport_patterns",
        skip_serializing_if = "Vec::is_empty"
    )]
    pub backport_patterns: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsPullRequestResolveResponse {
    pub fetched_at: String,
    #[serde(default)]
    pub items: Vec<ReviewItem>,
    #[serde(default)]
    pub missing_references: Vec<ReviewsPullRequestReference>,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_ref_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_branch_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub backport_source: Option<ReviewBackportSource>,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub required_approving_review_count: Option<u32>,
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
pub struct ReviewBackportSource {
    pub number: u64,
    pub repository: String,
    pub url: String,
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
