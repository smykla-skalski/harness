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

mod language;
pub(crate) mod list;

#[cfg(test)]
mod tests;

pub use language::{HarnessCodeLanguage, infer_language};

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
    pub head_ref_oid: String,
    pub viewer_can_mark_viewed: bool,
    pub files: Vec<DependencyUpdateFile>,
    pub fetched_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rate_limit_snapshot: Option<DependencyUpdatesRateLimitSnapshot>,
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
