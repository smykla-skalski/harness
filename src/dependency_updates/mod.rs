use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::task_board::github::GitHubMergeMethod;

mod body_update;
pub(crate) mod files;
mod github;
pub(crate) mod timeline;
mod validation;

pub use body_update::{
    DependencyUpdatesBodyUpdateOutcome, DependencyUpdatesBodyUpdateRequest,
    DependencyUpdatesBodyUpdateResponse,
};
#[allow(unused_imports)] // RegistryEntry + RepoKey are used by daemon-service tests.
pub(crate) use files::local_clone::{LocalCloneRegistry, LocalCloneRoot, RegistryEntry, RepoKey};
pub(crate) use files::viewed::{ViewedMutation, classify_outcome};
pub use files::{
    DependencyUpdateFile, DependencyUpdateFileChangeType, DependencyUpdateFilePatch,
    DependencyUpdateFileServedBy, DependencyUpdateFileViewedOutcome,
    DependencyUpdateFileViewedState, DependencyUpdateFilesViewedResult,
    DependencyUpdateFilesViewedTarget, DependencyUpdateImageMime,
    DependencyUpdatesFilesBlobRequest, DependencyUpdatesFilesBlobResponse,
    DependencyUpdatesFilesListRequest, DependencyUpdatesFilesListResponse,
    DependencyUpdatesFilesPatchRequest, DependencyUpdatesFilesPatchResponse,
    DependencyUpdatesFilesViewedRequest, DependencyUpdatesFilesViewedResponse,
    DependencyUpdatesRateLimitSnapshot, FilesLargeDiffStrategy, HarnessCodeLanguage,
    LocalCloneListEntry, image_mime_for_path, infer_language,
};
pub(crate) use github::DependencyUpdatesGitHubClient;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesQueryRequest {
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
pub struct DependencyUpdatesRepositoryCatalogRequest {
    pub organization: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesRepositoryCatalogResponse {
    pub organization: String,
    #[serde(default)]
    pub repositories: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesQueryResponse {
    pub fetched_at: String,
    pub from_cache: bool,
    pub summary: DependencyUpdatesSummary,
    pub items: Vec<DependencyUpdateItem>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub repository_labels: BTreeMap<String, Vec<DependencyUpdateRepositoryLabel>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdateRepositoryLabel {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesSummary {
    pub total: usize,
    pub review_required: usize,
    pub ready_to_merge: usize,
    pub auto_approvable: usize,
    pub waiting_on_checks: usize,
    pub blocked: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdateItem {
    pub pull_request_id: String,
    pub repository_id: String,
    pub repository: String,
    pub number: u64,
    pub title: String,
    pub url: String,
    pub author_login: String,
    pub state: DependencyUpdatePullRequestState,
    pub mergeable: DependencyUpdateMergeableState,
    pub review_status: DependencyUpdateReviewStatus,
    pub check_status: DependencyUpdateCheckStatus,
    pub policy_blocked: bool,
    pub is_draft: bool,
    pub head_sha: String,
    #[serde(default)]
    pub labels: Vec<String>,
    #[serde(default)]
    pub checks: Vec<DependencyUpdateCheck>,
    #[serde(default)]
    pub reviews: Vec<DependencyUpdateReview>,
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
pub struct DependencyUpdateCheck {
    pub name: String,
    pub status: DependencyUpdateCheckRunStatus,
    pub conclusion: DependencyUpdateCheckConclusion,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub check_suite_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdateReview {
    pub author: String,
    pub state: DependencyUpdateReviewEventState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesApproveRequest {
    pub targets: Vec<DependencyUpdateTarget>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesMergeRequest {
    pub targets: Vec<DependencyUpdateTarget>,
    #[serde(default)]
    pub method: GitHubMergeMethod,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesRerunChecksRequest {
    pub targets: Vec<DependencyUpdateTarget>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesLabelRequest {
    pub targets: Vec<DependencyUpdateTarget>,
    pub label: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesAutoRequest {
    pub targets: Vec<DependencyUpdateTarget>,
    #[serde(default)]
    pub method: GitHubMergeMethod,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesCommentRequest {
    pub targets: Vec<DependencyUpdateTarget>,
    pub body: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesCapabilitiesResponse {
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
pub struct DependencyUpdatesActionPreviewRequest {
    pub action: DependencyUpdateActionPreviewKind,
    pub targets: Vec<DependencyUpdateTarget>,
    #[serde(default)]
    pub method: GitHubMergeMethod,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesActionPreviewResponse {
    pub action: DependencyUpdateActionPreviewKind,
    pub capabilities: DependencyUpdatesCapabilitiesResponse,
    pub total_count: usize,
    pub actionable_count: usize,
    pub skipped_count: usize,
    #[serde(default)]
    pub warnings: Vec<String>,
    #[serde(default)]
    pub targets: Vec<DependencyUpdateActionPreviewTarget>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdateActionPreviewTarget {
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
pub struct DependencyUpdatesActionResponse {
    pub summary: String,
    #[serde(default)]
    pub results: Vec<DependencyUpdateActionResult>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesCacheClearResponse {
    pub cleared_entries: usize,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesRefreshRequest {
    #[serde(default)]
    pub targets: Vec<DependencyUpdateTarget>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesRefreshResponse {
    pub fetched_at: String,
    #[serde(default)]
    pub items: Vec<DependencyUpdateItem>,
    #[serde(default)]
    pub missing_pull_request_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesBodyRequest {
    pub pull_request_id: String,
    #[serde(default)]
    pub force_refresh: bool,
    #[serde(default = "default_cache_max_age_seconds")]
    pub cache_max_age_seconds: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesBodyResponse {
    pub pull_request_id: String,
    pub body: String,
    pub pr_updated_at: DateTime<Utc>,
    pub fetched_at: String,
    pub from_cache: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdateTarget {
    pub pull_request_id: String,
    pub repository_id: String,
    pub repository: String,
    pub number: u64,
    pub url: String,
    #[serde(default = "default_pull_request_state")]
    pub state: DependencyUpdatePullRequestState,
    #[serde(default)]
    pub is_draft: bool,
    pub head_sha: String,
    pub mergeable: DependencyUpdateMergeableState,
    pub review_status: DependencyUpdateReviewStatus,
    pub check_status: DependencyUpdateCheckStatus,
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
pub struct DependencyUpdateActionResult {
    pub repository: String,
    pub number: u64,
    pub action: DependencyUpdateActionKind,
    pub outcome: DependencyUpdateActionOutcome,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeline_entry: Option<timeline::DependencyUpdateTimelineEntry>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DependencyUpdatePullRequestState {
    Open,
    Closed,
    Merged,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DependencyUpdateMergeableState {
    Mergeable,
    Conflicting,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DependencyUpdateReviewStatus {
    None,
    ReviewRequired,
    Approved,
    ChangesRequested,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DependencyUpdateCheckStatus {
    None,
    Success,
    Failure,
    Pending,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DependencyUpdateCheckRunStatus {
    Completed,
    InProgress,
    Queued,
    Requested,
    Waiting,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DependencyUpdateCheckConclusion {
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
pub enum DependencyUpdateReviewEventState {
    Approved,
    ChangesRequested,
    Commented,
    Dismissed,
    Pending,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DependencyUpdateActionKind {
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
pub enum DependencyUpdateActionPreviewKind {
    Approve,
    Merge,
    RerunChecks,
    AddLabel,
    Auto,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DependencyUpdateActionOutcome {
    Applied,
    Skipped,
    Failed,
}

fn default_cache_max_age_seconds() -> u64 {
    600
}

fn default_pull_request_state() -> DependencyUpdatePullRequestState {
    DependencyUpdatePullRequestState::Open
}

impl DependencyUpdatesQueryRequest {
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

impl DependencyUpdatesRepositoryCatalogRequest {
    #[must_use]
    pub fn normalized_organization(&self) -> String {
        self.organization.trim().to_lowercase()
    }
}

impl DependencyUpdatesBodyRequest {
    #[must_use]
    pub fn normalized_pull_request_id(&self) -> String {
        self.pull_request_id.trim().to_string()
    }

    #[must_use]
    pub fn cache_max_age_seconds(&self) -> u64 {
        self.cache_max_age_seconds.max(1)
    }
}

impl DependencyUpdatesQueryResponse {
    #[must_use]
    pub fn new(items: Vec<DependencyUpdateItem>, fetched_at: String) -> Self {
        Self {
            fetched_at,
            from_cache: false,
            summary: DependencyUpdatesSummary::from_items(&items),
            items,
            repository_labels: BTreeMap::new(),
        }
    }

    pub fn set_repository_labels(
        &mut self,
        repository_labels: BTreeMap<String, Vec<DependencyUpdateRepositoryLabel>>,
    ) {
        self.repository_labels = repository_labels;
    }
}

impl DependencyUpdatesCapabilitiesResponse {
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

impl DependencyUpdatesSummary {
    #[must_use]
    pub fn from_items(items: &[DependencyUpdateItem]) -> Self {
        Self {
            total: items.len(),
            review_required: items
                .iter()
                .filter(|item| item.review_status == DependencyUpdateReviewStatus::ReviewRequired)
                .count(),
            ready_to_merge: items.iter().filter(|item| item.is_ready_to_merge()).count(),
            auto_approvable: items
                .iter()
                .filter(|item| item.is_auto_approvable())
                .count(),
            waiting_on_checks: items
                .iter()
                .filter(|item| item.check_status == DependencyUpdateCheckStatus::Pending)
                .count(),
            blocked: items
                .iter()
                .filter(|item| item.requires_attention())
                .count(),
        }
    }
}

impl DependencyUpdateItem {
    #[must_use]
    pub fn target(&self) -> DependencyUpdateTarget {
        DependencyUpdateTarget {
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
            || self.mergeable == DependencyUpdateMergeableState::Conflicting
            || self.review_status == DependencyUpdateReviewStatus::ChangesRequested
            || self.check_status == DependencyUpdateCheckStatus::Failure
    }
}

impl DependencyUpdateTarget {
    #[must_use]
    pub fn can_attempt_manual_approval(&self) -> bool {
        self.viewer_can_update
            && self.state == DependencyUpdatePullRequestState::Open
            && matches!(
                self.review_status,
                DependencyUpdateReviewStatus::ReviewRequired | DependencyUpdateReviewStatus::None
            )
    }

    #[must_use]
    pub fn can_attempt_manual_merge(&self) -> bool {
        self.viewer_can_update
            && self.state == DependencyUpdatePullRequestState::Open
            && !self.is_draft
            && self.mergeable != DependencyUpdateMergeableState::Conflicting
    }

    #[must_use]
    pub fn can_attempt_rerun_checks(&self) -> bool {
        self.viewer_can_update && !self.check_suite_ids.is_empty()
    }

    #[must_use]
    pub fn can_add_label(&self) -> bool {
        self.viewer_can_update && self.state == DependencyUpdatePullRequestState::Open
    }

    #[must_use]
    pub fn is_auto_approvable(&self) -> bool {
        self.viewer_can_update
            && self.state == DependencyUpdatePullRequestState::Open
            && self.check_status == DependencyUpdateCheckStatus::Success
            && matches!(
                self.review_status,
                DependencyUpdateReviewStatus::ReviewRequired | DependencyUpdateReviewStatus::None
            )
            && self.mergeable != DependencyUpdateMergeableState::Conflicting
    }

    #[must_use]
    pub fn is_auto_mergeable(&self) -> bool {
        self.viewer_can_update
            && self.state == DependencyUpdatePullRequestState::Open
            && !self.is_draft
            && matches!(
                self.review_status,
                DependencyUpdateReviewStatus::Approved | DependencyUpdateReviewStatus::None
            )
            && self.check_status == DependencyUpdateCheckStatus::Success
            && self.mergeable != DependencyUpdateMergeableState::Conflicting
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
