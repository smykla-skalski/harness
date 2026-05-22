//! Inline PR file-changes data layer for the Dependencies dashboard.
//!
//! The daemon fetches per-file metadata (path, additions, deletions, change
//! type, viewed state) from GitHub via GraphQL, then later fetches patches
//! either over REST (small PRs) or a local bare clone (substantial PRs).
//! Image previews + mark-viewed state round out the surface.
//!
//! Public types live here in `mod.rs`. Submodules will be wired in by
//! subsequent commits (A.3 through A.10):
//!
//! - `list` - GraphQL paginated metadata fetch (this commit, A.2)
//! - `patch_rest` - REST patch fetch with ETag (A.3)
//! - `viewed` - GraphQL mark-viewed mutations + hash guard (A.4)
//! - `blob` - GraphQL image blob fetch (A.5)
//! - `cache` - per-PR on-disk patch cache + GC (A.6)
//! - `local_clone` - bare partial clone registry (A.7)
//! - `patch_local` - `git diff` parser (A.8)
//! - `service` - strategy selector + handlers (A.9-A.10)

#![allow(dead_code)] // wired into service handlers in subsequent commits

use serde::{Deserialize, Serialize};

pub(crate) mod blob;
pub(crate) mod cache;
mod language;
pub(crate) mod list;
pub(crate) mod local_clone;
pub(crate) mod local_clone_diff;
pub(crate) mod local_clone_progress_event;
pub(crate) mod local_clone_runtime;
pub(crate) mod patch_local;
pub(crate) mod patch_rest;
pub(crate) mod service;
pub(crate) mod viewed;

#[cfg(test)]
mod tests;

pub use blob::{
    DependencyUpdateImageMime, DependencyUpdatesFilesBlobRequest,
    DependencyUpdatesFilesBlobResponse, image_mime_for_path,
};
pub use language::{HarnessCodeLanguage, infer_language};
pub use local_clone::LocalCloneListEntry;
pub use service::FilesLargeDiffStrategy;
pub use viewed::{
    DependencyUpdateFileViewedOutcome, DependencyUpdateFilesViewedResult,
    DependencyUpdateFilesViewedTarget, DependencyUpdatesFilesViewedRequest,
    DependencyUpdatesFilesViewedResponse,
};

/// Soft cap on paginated `pullRequest.files` queries. GitHub returns up to 100
/// nodes per page; this cap times 100 is the per-PR file limit we'll surface.
pub(crate) const FILES_PAGE_CAP: u32 = 20;

/// Maximum files we'll list per PR regardless of pagination cap.
pub(crate) const FILES_MAX: u32 = FILES_PAGE_CAP * 100;

/// Request a list of changed files for a single pull request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesFilesListRequest {
    pub pull_request_id: String,
    #[serde(default)]
    pub force_refresh: bool,
}

impl DependencyUpdatesFilesListRequest {
    #[must_use]
    pub fn normalized_pull_request_id(&self) -> String {
        self.pull_request_id.trim().to_string()
    }
}

/// Response shape for a files-list call.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesFilesListResponse {
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
    pub files: Vec<DependencyUpdateFile>,
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
    pub rate_limit_snapshot: Option<DependencyUpdatesRateLimitSnapshot>,
}

fn default_pagination_complete() -> bool {
    true
}

/// Metadata for one file inside a PR. No patch body here - patches arrive
/// via the separate `patch` endpoint (REST or local-clone diff).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdateFile {
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previous_path: Option<String>,
    pub change_type: DependencyUpdateFileChangeType,
    pub additions: u32,
    pub deletions: u32,
    pub viewer_viewed_state: DependencyUpdateFileViewedState,
    #[serde(default)]
    pub is_binary: bool,
    pub language_hint: HarnessCodeLanguage,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode_change: Option<String>,
}

/// GitHub `PullRequestFileChangeType` enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum DependencyUpdateFileChangeType {
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

impl DependencyUpdateFileChangeType {
    /// Parse a GraphQL enum value (uppercase) into a known variant.
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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum DependencyUpdateFileViewedState {
    Dismissed,
    Viewed,
    #[default]
    Unviewed,
}

impl DependencyUpdateFileViewedState {
    /// Parse a GraphQL enum value (uppercase) into a known variant.
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
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesRateLimitSnapshot {
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
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesFilesPatchRequest {
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
    pub large_diff_strategy: Option<service::FilesLargeDiffStrategy>,
}

impl DependencyUpdatesFilesPatchRequest {
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
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesFilesPatchResponse {
    pub pull_request_id: String,
    pub patches: Vec<DependencyUpdateFilePatch>,
    pub drifted: bool,
    pub current_head_ref_oid: String,
    pub fetched_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rate_limit_snapshot: Option<DependencyUpdatesRateLimitSnapshot>,
}

/// Annotates which path produced a patch body so the UI can label provenance.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum DependencyUpdateFileServedBy {
    #[default]
    GithubRest,
    LocalClone,
    /// Local-clone path was attempted but fell back to REST due to a clone
    /// failure. Surfaces a different UI affordance ("via local clone
    /// (fallback)").
    GithubRestFallback,
}

/// One file's patch body + metadata produced by either REST or local clone.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdateFilePatch {
    pub path: String,
    pub patch: String,
    pub status: DependencyUpdateFileChangeType,
    pub additions: u32,
    pub deletions: u32,
    #[serde(default)]
    pub truncated: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub etag: Option<String>,
    #[serde(default)]
    pub served_by: DependencyUpdateFileServedBy,
    #[serde(default)]
    pub fetched_at: String,
    #[serde(default)]
    pub head_ref_oid: String,
}
