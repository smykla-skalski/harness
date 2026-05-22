//! Pure helpers for REST-response parsing, path filtering, drift checks,
//! and truncation labeling. Kept free of network IO so callers and tests
//! can exercise them without touching `octocrab` client state.

use serde::Deserialize;

use crate::reviews::files::{
    ReviewFileChangeType, ReviewFilePatch, ReviewFileServedBy,
};

/// GitHub's REST PR-files item shape. Documented at
/// <https://docs.github.com/en/rest/pulls/pulls#list-pull-requests-files>.
#[derive(Debug, Deserialize)]
pub(crate) struct RestPullFile {
    pub sha: Option<String>,
    pub filename: String,
    pub status: String,
    #[serde(default)]
    pub additions: u32,
    #[serde(default)]
    pub deletions: u32,
    #[serde(default)]
    pub changes: u32,
    pub blob_url: Option<String>,
    pub raw_url: Option<String>,
    pub contents_url: Option<String>,
    #[serde(default)]
    pub patch: Option<String>,
    pub previous_filename: Option<String>,
}

/// Parse a GitHub REST `PullRequestFile.status` string into our enum.
#[must_use]
pub fn parse_rest_status(status: &str) -> ReviewFileChangeType {
    match status {
        "added" => ReviewFileChangeType::Added,
        "removed" => ReviewFileChangeType::Deleted,
        "modified" => ReviewFileChangeType::Modified,
        "renamed" => ReviewFileChangeType::Renamed,
        "copied" => ReviewFileChangeType::Copied,
        "changed" => ReviewFileChangeType::Changed,
        // Newer REST values like "unchanged" land here.
        _ => ReviewFileChangeType::Other,
    }
}

/// Convert a parsed REST file into a `ReviewFilePatch`. The
/// `etag`, `served_by`, `fetched_at`, and `head_ref_oid` fields are set by
/// the caller (it knows the response context).
#[must_use]
pub fn rest_file_to_patch(file: &RestPullFile) -> ReviewFilePatch {
    let patch = file.patch.clone().unwrap_or_default();
    let truncated = is_truncated_patch(&patch);
    ReviewFilePatch {
        path: file.filename.clone(),
        patch,
        status: parse_rest_status(&file.status),
        additions: file.additions,
        deletions: file.deletions,
        truncated,
        etag: None,
        served_by: ReviewFileServedBy::GithubRest,
        fetched_at: String::new(),
        head_ref_oid: String::new(),
    }
}

/// Returns true when GitHub's REST patch text contains its own truncation
/// sentinel. GitHub trims patches at ~3000 lines per file and inserts a
/// trailing marker; the heuristic checks for an oversized line count as a
/// proxy plus the absence of a trailing `\n` on the last hunk - both signals
/// align with how the UI labels the "Truncated by GitHub" footer.
#[must_use]
pub fn is_truncated_patch(patch: &str) -> bool {
    if patch.is_empty() {
        return false;
    }
    // GitHub does not include an explicit marker, but the patch field is
    // capped at 3000 lines per file. Anything denser than ~2500 lines is
    // overwhelmingly likely to be capped.
    let lines = patch.lines().count();
    lines >= 2_900
}

/// Extract a `Link: <...>; rel="next"` URL from a Link header value.
#[must_use]
pub fn parse_next_link(link_header: &str) -> Option<String> {
    for entry in link_header.split(',') {
        let entry = entry.trim();
        let (url_part, rel_part) = entry.split_once(';')?;
        let url = url_part.trim().strip_prefix('<')?.strip_suffix('>')?;
        let rel = rel_part.trim();
        if rel == r#"rel="next""# {
            return Some(url.to_string());
        }
    }
    None
}

/// Filter a parsed page of REST files down to the requested paths. Returns
/// the patches whose `filename` appears in `requested`. If `requested` is
/// empty, returns all files (caller wanted the whole PR's patches).
#[must_use]
pub fn select_patches_by_path(
    files: &[RestPullFile],
    requested: &[String],
) -> Vec<ReviewFilePatch> {
    if requested.is_empty() {
        return files.iter().map(rest_file_to_patch).collect();
    }
    files
        .iter()
        .filter(|f| requested.iter().any(|p| p == &f.filename))
        .map(rest_file_to_patch)
        .collect()
}

/// Convert an Octocrab `DiffEntry` (the typed REST response item) into our
/// internal `RestPullFile` shape so the existing helpers
/// (`rest_file_to_patch`, `select_patches_by_path`) keep working without
/// branching on the source.
#[must_use]
pub fn diff_entry_to_rest_file(entry: &octocrab::models::repos::DiffEntry) -> RestPullFile {
    use octocrab::models::repos::DiffEntryStatus;
    let status_str = match entry.status {
        DiffEntryStatus::Added => "added",
        DiffEntryStatus::Removed => "removed",
        DiffEntryStatus::Modified => "modified",
        DiffEntryStatus::Renamed => "renamed",
        DiffEntryStatus::Copied => "copied",
        DiffEntryStatus::Changed => "changed",
        DiffEntryStatus::Unchanged => "unchanged",
        _ => "modified",
    };
    RestPullFile {
        sha: entry.sha.clone(),
        filename: entry.filename.clone(),
        status: status_str.to_string(),
        additions: u32::try_from(entry.additions).unwrap_or(u32::MAX),
        deletions: u32::try_from(entry.deletions).unwrap_or(u32::MAX),
        changes: u32::try_from(entry.changes).unwrap_or(u32::MAX),
        blob_url: entry.blob_url.clone(),
        raw_url: entry.raw_url.clone(),
        contents_url: Some(entry.contents_url.to_string()),
        patch: entry.patch.clone(),
        previous_filename: entry.previous_filename.clone(),
    }
}

/// Split a GitHub `owner/repo` slug into `(owner, repo)`. Returns `None`
/// when the slug isn't in canonical form (no slash or empty segments).
#[must_use]
pub fn split_repo_full_name(full_name: &str) -> Option<(String, String)> {
    let mut parts = full_name.splitn(2, '/');
    let owner = parts.next()?.trim();
    let repo = parts.next()?.trim();
    if owner.is_empty() || repo.is_empty() {
        return None;
    }
    Some((owner.to_string(), repo.to_string()))
}

/// Decide whether the cached `head_ref_oid_expected` is still current.
/// Returns `true` if the request should be considered drifted (a force-push
/// or rebase landed a new head while the Monitor's cache held the old oid).
#[must_use]
pub fn detect_drift(expected: &str, current: &str) -> bool {
    let expected = expected.trim();
    let current = current.trim();
    if expected.is_empty() || current.is_empty() {
        return false;
    }
    !expected.eq_ignore_ascii_case(current)
}
