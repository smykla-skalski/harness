use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::task_board::github::GitHubMergeMethod;

mod body_update;
pub(crate) mod files;
mod github;
pub(crate) mod review_thread_resolve;
pub(crate) mod timeline;
mod validation;

pub use body_update::{
    ReviewsBodyUpdateOutcome, ReviewsBodyUpdateRequest,
    ReviewsBodyUpdateResponse,
};
#[allow(unused_imports)] // RegistryEntry + RepoKey are used by daemon-service tests.
pub(crate) use files::local_clone::{LocalCloneRegistry, LocalCloneRoot, RegistryEntry, RepoKey};
pub(crate) use files::viewed::{ViewedMutation, classify_outcome};
pub use files::{
    ReviewFile, ReviewFileChangeType, ReviewFilePatch,
    ReviewFileServedBy, ReviewFileViewedOutcome,
    ReviewFileViewedState, ReviewFilesViewedResult,
    ReviewFilesViewedTarget, ReviewImageMime,
    ReviewsFilesBlobRequest, ReviewsFilesBlobResponse,
    ReviewsFilesListRequest, ReviewsFilesListResponse,
    ReviewsFilesPatchRequest, ReviewsFilesPatchResponse,
    ReviewsFilesViewedRequest, ReviewsFilesViewedResponse,
    ReviewsRateLimitSnapshot, FilesLargeDiffStrategy, HarnessCodeLanguage,
    LocalCloneListEntry, image_mime_for_path, infer_language,
};
pub(crate) use github::ReviewsGitHubClient;

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
    pub policy_blocked: bool,
    pub is_draft: bool,
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
    #[serde(default = "default_viewer_can_update")]
    pub viewer_can_update: bool,
    #[serde(default = "default_viewer_can_merge_as_admin")]
    pub viewer_can_merge_as_admin: bool,
}

fn default_viewer_can_update() -> bool {
    true
}

fn default_viewer_can_merge_as_admin() -> bool {
    false
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsCapabilitiesResponse {
    pub schema_version: u32,
    #[serde(default)]
    pub supports_action_preview: bool,
    #[serde(default)]
    pub supports_check_run_links: bool,
    #[serde(default)]
    pub supports_repository_sync_health: bool,
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewTarget {
    pub pull_request_id: String,
    pub repository_id: String,
    pub repository: String,
    pub number: u64,
    pub url: String,
    #[serde(default = "default_pull_request_state")]
    pub state: ReviewPullRequestState,
    #[serde(default)]
    pub is_draft: bool,
    pub head_sha: String,
    pub mergeable: ReviewMergeableState,
    pub review_status: ReviewReviewStatus,
    pub check_status: ReviewCheckStatus,
    pub policy_blocked: bool,
    #[serde(default)]
    pub required_failed_check_names: Vec<String>,
    #[serde(default = "default_viewer_can_merge_as_admin")]
    pub viewer_can_merge_as_admin: bool,
    #[serde(default)]
    pub check_suite_ids: Vec<String>,
    #[serde(default = "default_viewer_can_update")]
    pub viewer_can_update: bool,
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

fn default_cache_max_age_seconds() -> u64 {
    600
}

fn default_pull_request_state() -> ReviewPullRequestState {
    ReviewPullRequestState::Open
}

impl ReviewsQueryRequest {
    #[must_use]
    pub fn normalized_authors(&self) -> Vec<String> {
        normalized_entries(&self.authors)
    }

    #[must_use]
    pub fn normalized_organizations(&self) -> Vec<String> {
        normalized_entries(&self.organizations)
    }

    #[must_use]
    pub fn normalized_repositories(&self) -> Vec<String> {
        normalized_entries(&self.repositories)
    }

    #[must_use]
    pub fn normalized_exclude_repositories(&self) -> Vec<String> {
        normalized_entries(&self.exclude_repositories)
    }

    #[must_use]
    pub fn cache_key(&self) -> String {
        format!(
            "authors={}|orgs={}|repos={}|exclude={}",
            self.normalized_authors().join(","),
            self.normalized_organizations().join(","),
            self.normalized_repositories().join(","),
            self.normalized_exclude_repositories().join(","),
        )
    }

    #[must_use]
    pub fn cache_max_age_seconds(&self) -> u64 {
        self.cache_max_age_seconds.max(1)
    }

    #[must_use]
    pub fn organization_only_request(&self) -> Self {
        Self {
            authors: self.normalized_authors(),
            organizations: self.normalized_organizations(),
            repositories: Vec::new(),
            exclude_repositories: self.normalized_exclude_repositories(),
            force_refresh: self.force_refresh,
            cache_max_age_seconds: self.cache_max_age_seconds(),
        }
    }

    #[must_use]
    pub fn repository_only_request(&self, repository: &str) -> Self {
        Self {
            authors: self.normalized_authors(),
            organizations: Vec::new(),
            repositories: vec![repository.to_string()],
            exclude_repositories: self.normalized_exclude_repositories(),
            force_refresh: self.force_refresh,
            cache_max_age_seconds: self.cache_max_age_seconds(),
        }
    }
}

impl ReviewsRepositoryCatalogRequest {
    #[must_use]
    pub fn normalized_organization(&self) -> String {
        self.organization.trim().to_lowercase()
    }
}

impl ReviewsBodyRequest {
    #[must_use]
    pub fn normalized_pull_request_id(&self) -> String {
        self.pull_request_id.trim().to_string()
    }

    #[must_use]
    pub fn cache_max_age_seconds(&self) -> u64 {
        self.cache_max_age_seconds.max(1)
    }
}

impl ReviewsQueryResponse {
    #[must_use]
    pub fn new(items: Vec<ReviewItem>, fetched_at: String) -> Self {
        Self {
            fetched_at,
            from_cache: false,
            summary: ReviewsSummary::from_items(&items),
            items,
            repository_labels: BTreeMap::new(),
        }
    }

    pub fn set_repository_labels(
        &mut self,
        repository_labels: BTreeMap<String, Vec<ReviewRepositoryLabel>>,
    ) {
        self.repository_labels = repository_labels;
    }
}

impl ReviewsCapabilitiesResponse {
    #[must_use]
    pub fn current() -> Self {
        Self {
            schema_version: 1,
            supports_action_preview: true,
            supports_check_run_links: true,
            supports_repository_sync_health: true,
            supports_persistent_action_diagnostics: true,
        }
    }
}

impl ReviewsSummary {
    #[must_use]
    pub fn from_items(items: &[ReviewItem]) -> Self {
        Self {
            total: items.len(),
            review_required: items
                .iter()
                .filter(|item| item.review_status == ReviewReviewStatus::ReviewRequired)
                .count(),
            ready_to_merge: items.iter().filter(|item| item.is_ready_to_merge()).count(),
            auto_approvable: items
                .iter()
                .filter(|item| item.is_auto_approvable())
                .count(),
            waiting_on_checks: items
                .iter()
                .filter(|item| item.check_status == ReviewCheckStatus::Pending)
                .count(),
            blocked: items
                .iter()
                .filter(|item| item.requires_attention())
                .count(),
        }
    }
}

impl ReviewItem {
    #[must_use]
    pub fn target(&self) -> ReviewTarget {
        ReviewTarget {
            pull_request_id: self.pull_request_id.clone(),
            repository_id: self.repository_id.clone(),
            repository: self.repository.clone(),
            number: self.number,
            url: self.url.clone(),
            state: self.state,
            is_draft: self.is_draft,
            head_sha: self.head_sha.clone(),
            mergeable: self.mergeable,
            review_status: self.review_status,
            check_status: self.check_status,
            policy_blocked: self.policy_blocked,
            required_failed_check_names: self.required_failed_check_names.clone(),
            viewer_can_merge_as_admin: self.viewer_can_merge_as_admin,
            check_suite_ids: self
                .checks
                .iter()
                .filter_map(|check| check.check_suite_id.clone())
                .collect(),
            viewer_can_update: self.viewer_can_update,
        }
    }

    #[must_use]
    pub fn is_auto_approvable(&self) -> bool {
        self.target().is_auto_approvable()
    }

    #[must_use]
    pub fn is_ready_to_merge(&self) -> bool {
        self.target().is_auto_mergeable()
    }

    #[must_use]
    pub fn requires_attention(&self) -> bool {
        self.policy_blocked
            || self.mergeable == ReviewMergeableState::Conflicting
            || self.review_status == ReviewReviewStatus::ChangesRequested
            || self.check_status == ReviewCheckStatus::Failure
    }
}

impl ReviewTarget {
    #[must_use]
    pub fn can_attempt_manual_approval(&self) -> bool {
        self.viewer_can_update
            && self.state == ReviewPullRequestState::Open
            && matches!(
                self.review_status,
                ReviewReviewStatus::ReviewRequired | ReviewReviewStatus::None
            )
    }

    #[must_use]
    pub fn can_attempt_manual_merge(&self) -> bool {
        self.viewer_can_update
            && self.state == ReviewPullRequestState::Open
            && !self.is_draft
            && self.mergeable != ReviewMergeableState::Conflicting
    }

    #[must_use]
    pub fn can_attempt_rerun_checks(&self) -> bool {
        self.viewer_can_update && !self.check_suite_ids.is_empty()
    }

    #[must_use]
    pub fn can_add_label(&self) -> bool {
        self.viewer_can_update && self.state == ReviewPullRequestState::Open
    }

    #[must_use]
    pub fn is_auto_approvable(&self) -> bool {
        self.viewer_can_update
            && self.state == ReviewPullRequestState::Open
            && self.check_status == ReviewCheckStatus::Success
            && matches!(
                self.review_status,
                ReviewReviewStatus::ReviewRequired | ReviewReviewStatus::None
            )
            && self.mergeable != ReviewMergeableState::Conflicting
    }

    #[must_use]
    pub fn is_auto_mergeable(&self) -> bool {
        self.viewer_can_update
            && self.state == ReviewPullRequestState::Open
            && !self.is_draft
            && matches!(
                self.review_status,
                ReviewReviewStatus::Approved | ReviewReviewStatus::None
            )
            && self.check_status == ReviewCheckStatus::Success
            && self.mergeable != ReviewMergeableState::Conflicting
            && !self.policy_blocked
    }
}

fn normalized_entries(entries: &[String]) -> Vec<String> {
    let mut normalized = entries
        .iter()
        .map(|entry| entry.trim())
        .filter(|entry| !entry.is_empty())
        .map(ToString::to_string)
        .collect::<Vec<_>>();
    normalized.sort();
    normalized.dedup();
    normalized
}

#[cfg(test)]
mod tests;
