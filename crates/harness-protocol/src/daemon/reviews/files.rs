//! Inline PR file-changes wire types for the Reviews dashboard, relocated
//! from `harness-reviews::files`. The GraphQL/REST fetch, local-clone
//! runtime, patch parsing, caching, and strategy-selection logic all stay in
//! `harness-reviews`; only the request/response DTOs and the enums with
//! self-contained parse/format helpers move.

pub mod blob;
pub mod language;
pub mod local_clone;
pub mod viewed;

pub use blob::{ReviewImageMime, ReviewsFilesBlobRequest, ReviewsFilesBlobResponse};
pub use language::HarnessCodeLanguage;
pub use local_clone::LocalCloneListEntry;
pub use viewed::{
    ReviewFileViewedOutcome, ReviewFilesViewedResult, ReviewFilesViewedTarget,
    ReviewsFilesViewedRequest, ReviewsFilesViewedResponse,
};

use serde::{Deserialize, Serialize};

/// User-facing toggle in Settings. Picked from the `SwiftUI` Picker;
/// serialized through to the daemon on each request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum FilesLargeDiffStrategy {
    /// For PRs above the threshold, use the local bare clone.
    #[default]
    AutoLocalClone,
    /// Always use GitHub REST regardless of size (no local clones).
    #[serde(rename = "force_github_rest", alias = "force_git_hub_rest")]
    ForceGitHubRest,
}

/// Request a list of changed files for a single pull request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ReviewsFilesListRequest {
    pub pull_request_id: String,
    #[serde(default)]
    pub force_refresh: bool,
}

impl ReviewsFilesListRequest {
    #[must_use]
    pub fn normalized_pull_request_id(&self) -> String {
        self.pull_request_id.trim().to_string()
    }
}

/// Response shape for a files-list call.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ReviewsFilesListResponse {
    pub pull_request_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub number: Option<u64>,
    pub head_ref_oid: String,
    /// PR's source branch name (e.g. `renovate/foo`). Used by the local-clone
    /// path so `ensure_clone` fetches the right ref instead of always
    /// opening `refs/heads/main`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head_ref_name: Option<String>,
    /// Merge-base OID for the PR. Required for the local-clone diff path
    /// to compute `base..head` patches.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_ref_oid: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_ref_name: Option<String>,
    /// `owner/name` of the repository the PR lives in. Lets the Monitor
    /// hand the patch request a clone target without re-querying GraphQL.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository_full_name: Option<String>,
    pub viewer_can_mark_viewed: bool,
    pub files: Vec<ReviewFile>,
    pub fetched_at: String,
    /// `true` when the pagination loop drained every page from GitHub.
    /// `false` when the loop bailed out under `FILES_PAGE_CAP` while
    /// GitHub still had `hasNextPage == true` - the response is partial
    /// and the caller should surface a warning. Defaults to `true` for
    /// backwards compatibility with older callers that don't read this
    /// field.
    #[serde(default = "default_pagination_complete")]
    pub pagination_complete: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rate_limit_snapshot: Option<ReviewsRateLimitSnapshot>,
}

fn default_pagination_complete() -> bool {
    true
}

/// Metadata for one file inside a PR. No patch body here - patches arrive
/// via the separate `patch` endpoint (REST or local-clone diff).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ReviewFile {
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previous_path: Option<String>,
    pub change_type: ReviewFileChangeType,
    pub additions: u32,
    pub deletions: u32,
    pub viewer_viewed_state: ReviewFileViewedState,
    #[serde(default)]
    pub is_binary: bool,
    pub language_hint: HarnessCodeLanguage,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode_change: Option<String>,
}

/// GitHub `PullRequestFileChangeType` enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum ReviewFileChangeType {
    Added,
    Copied,
    Deleted,
    #[default]
    Modified,
    Renamed,
    Changed,
    /// Forward-compat slot for unknown GraphQL enum values.
    Other,
}

impl ReviewFileChangeType {
    /// Parse a GraphQL enum value (uppercase) into a known variant.
    #[must_use]
    pub fn parse(value: &str) -> Self {
        match value {
            "ADDED" => Self::Added,
            "COPIED" => Self::Copied,
            "DELETED" => Self::Deleted,
            "MODIFIED" => Self::Modified,
            "RENAMED" => Self::Renamed,
            "CHANGED" => Self::Changed,
            _ => Self::Other,
        }
    }
}

/// GitHub `FileViewedState` enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum ReviewFileViewedState {
    Dismissed,
    Viewed,
    #[default]
    Unviewed,
}

impl ReviewFileViewedState {
    /// Parse a GraphQL enum value (uppercase) into a known variant.
    #[must_use]
    pub fn parse(value: &str) -> Self {
        match value {
            "DISMISSED" => Self::Dismissed,
            "VIEWED" => Self::Viewed,
            _ => Self::Unviewed,
        }
    }
}

/// Lightweight echo of the rate-limit budget at the time of the response.
/// The Monitor uses this to surface a cooling banner without polling a
/// separate endpoint.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ReviewsRateLimitSnapshot {
    pub remaining: u32,
    pub limit: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reset_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost: Option<u32>,
}

/// Batched patch request for one PR. The caller supplies the head ref oid it
/// believes it's still on; the daemon compares against the current head and
/// returns `drifted: true` with the fresh oid if a force-push intervened.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ReviewsFilesPatchRequest {
    pub pull_request_id: String,
    pub head_ref_oid_expected: String,
    pub paths: Vec<String>,
    /// GitHub PR number (the integer in `pulls/{n}/files`). Required for
    /// the REST path; when absent, the daemon can only route to the
    /// local-clone path (which uses GitHub's synthetic
    /// `refs/pull/<number>/head` ref for forks + same-repo PR branches).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub number: Option<u64>,
    /// Owner/name of the repository the PR lives in. When present, the
    /// daemon can route the patch fetch through the local-clone runtime
    /// (zero-rate-limit) or the REST path.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository_full_name: Option<String>,
    /// Merge-base OID against which to compute the diff. Required for the
    /// local-clone path; when absent the handler falls back to REST.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_ref_oid_expected: Option<String>,
    /// PR's source branch name (e.g. `renovate/foo`). When present, the
    /// local-clone runtime fetches that ref directly instead of the
    /// daemon's default-branch fallback.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head_ref_name: Option<String>,
    /// PR base branch name. When present, the local clone fetches it directly
    /// before computing the expected base/head OID diff.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_ref_name: Option<String>,
    /// User's `filesLargeDiffStrategy` choice from Settings. Daemon honors
    /// `ForceGitHubRest` by skipping the local-clone runtime entirely.
    /// Defaults to `AutoLocalClone` for callers that don't supply it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub large_diff_strategy: Option<FilesLargeDiffStrategy>,
}

impl ReviewsFilesPatchRequest {
    #[must_use]
    pub fn normalized_pull_request_id(&self) -> String {
        self.pull_request_id.trim().to_string()
    }

    #[must_use]
    pub fn normalized_paths(&self) -> Vec<String> {
        self.paths
            .iter()
            .filter_map(|raw| {
                let trimmed = raw.trim();
                if trimmed.is_empty() {
                    None
                } else {
                    Some(trimmed.to_string())
                }
            })
            .collect()
    }
}

/// Response carrying the per-path patches plus drift detection.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ReviewsFilesPatchResponse {
    pub pull_request_id: String,
    pub patches: Vec<ReviewFilePatch>,
    pub drifted: bool,
    pub current_head_ref_oid: String,
    pub fetched_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rate_limit_snapshot: Option<ReviewsRateLimitSnapshot>,
}

/// Default number of unified-diff lines returned for a preview.
const DEFAULT_PREVIEW_LINE_LIMIT: u32 = 1_000;

#[must_use]
pub const fn preview_line_limit() -> u32 {
    DEFAULT_PREVIEW_LINE_LIMIT
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ReviewsFilesPreviewRequest {
    pub pull_request_id: String,
    pub head_ref_oid_expected: String,
    pub paths: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub number: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository_full_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_ref_oid_expected: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head_ref_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_ref_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub large_diff_strategy: Option<FilesLargeDiffStrategy>,
    #[serde(default = "preview_line_limit")]
    pub line_limit: u32,
}

impl ReviewsFilesPreviewRequest {
    #[must_use]
    pub fn normalized_pull_request_id(&self) -> String {
        self.pull_request_id.trim().to_string()
    }

    #[must_use]
    pub fn normalized_paths(&self) -> Vec<String> {
        self.paths
            .iter()
            .filter_map(|raw| {
                let trimmed = raw.trim();
                if trimmed.is_empty() {
                    None
                } else {
                    Some(trimmed.to_string())
                }
            })
            .collect()
    }

    #[must_use]
    pub fn normalized_line_limit(&self) -> u32 {
        self.line_limit.clamp(1, preview_line_limit())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ReviewFilePreview {
    pub path: String,
    pub patch: String,
    pub status: ReviewFileChangeType,
    pub additions: u32,
    pub deletions: u32,
    #[serde(default)]
    pub truncated: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub etag: Option<String>,
    #[serde(default)]
    pub served_by: ReviewFileServedBy,
    #[serde(default)]
    pub fetched_at: String,
    #[serde(default)]
    pub head_ref_oid: String,
    pub line_count: u32,
    pub line_limit: u32,
    pub has_more: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ReviewsFilesPreviewResponse {
    pub pull_request_id: String,
    pub previews: Vec<ReviewFilePreview>,
    pub drifted: bool,
    pub current_head_ref_oid: String,
    pub fetched_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rate_limit_snapshot: Option<ReviewsRateLimitSnapshot>,
}

/// Annotates which path produced a patch body so the UI can label provenance.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum ReviewFileServedBy {
    #[default]
    GithubRest,
    LocalClone,
    /// Local-clone path was attempted but fell back to REST due to a clone
    /// failure. Surfaces a different UI affordance ("via local clone
    /// (fallback)").
    GithubRestFallback,
}

/// One file's patch body + metadata produced by either REST or local clone.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ReviewFilePatch {
    pub path: String,
    pub patch: String,
    pub status: ReviewFileChangeType,
    pub additions: u32,
    pub deletions: u32,
    #[serde(default)]
    pub truncated: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub etag: Option<String>,
    #[serde(default)]
    pub served_by: ReviewFileServedBy,
    #[serde(default)]
    pub fetched_at: String,
    #[serde(default)]
    pub head_ref_oid: String,
}
