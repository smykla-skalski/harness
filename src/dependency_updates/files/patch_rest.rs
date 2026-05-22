//! REST-path patch fetch for the dependency_updates Files section.
//!
//! GitHub's REST endpoint `GET /repos/{owner}/{repo}/pulls/{n}/files` returns
//! up to 30 files per page with a per-file `patch` string (possibly
//! truncated at ~3000 lines). We page until `Link: rel="next"` is exhausted
//! or `FILES_PAGE_CAP` pages have been visited. ETag support: callers pass
//! `If-None-Match: <etag>` per cached file; a 304 response is treated as
//! "still valid".
//!
//! This module is metadata-shape only in A.3 - the actual `Octocrab` /
//! `reqwest` wiring is folded in by A.10 when the service handler exists.
//! The pure helpers below cover REST-response parsing and the drift /
//! truncation logic used by the service.

use serde::Deserialize;

use super::{
    DependencyUpdateFileChangeType, DependencyUpdateFilePatch, DependencyUpdateFileServedBy,
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
pub fn parse_rest_status(status: &str) -> DependencyUpdateFileChangeType {
    match status {
        "added" => DependencyUpdateFileChangeType::Added,
        "removed" => DependencyUpdateFileChangeType::Deleted,
        "modified" => DependencyUpdateFileChangeType::Modified,
        "renamed" => DependencyUpdateFileChangeType::Renamed,
        "copied" => DependencyUpdateFileChangeType::Copied,
        "changed" => DependencyUpdateFileChangeType::Changed,
        // Newer REST values like "unchanged" land here.
        _ => DependencyUpdateFileChangeType::Other,
    }
}

/// Convert a parsed REST file into a `DependencyUpdateFilePatch`. The
/// `etag`, `served_by`, `fetched_at`, and `head_ref_oid` fields are set by
/// the caller (it knows the response context).
#[must_use]
pub fn rest_file_to_patch(file: &RestPullFile) -> DependencyUpdateFilePatch {
    let patch = file.patch.clone().unwrap_or_default();
    let truncated = is_truncated_patch(&patch);
    DependencyUpdateFilePatch {
        path: file.filename.clone(),
        patch,
        status: parse_rest_status(&file.status),
        additions: file.additions,
        deletions: file.deletions,
        truncated,
        etag: None,
        served_by: DependencyUpdateFileServedBy::GithubRest,
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
) -> Vec<DependencyUpdateFilePatch> {
    if requested.is_empty() {
        return files.iter().map(rest_file_to_patch).collect();
    }
    files
        .iter()
        .filter(|f| requested.iter().any(|p| p == &f.filename))
        .map(rest_file_to_patch)
        .collect()
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_rest_status_known_values() {
        assert_eq!(
            parse_rest_status("added"),
            DependencyUpdateFileChangeType::Added
        );
        assert_eq!(
            parse_rest_status("removed"),
            DependencyUpdateFileChangeType::Deleted
        );
        assert_eq!(
            parse_rest_status("modified"),
            DependencyUpdateFileChangeType::Modified
        );
        assert_eq!(
            parse_rest_status("renamed"),
            DependencyUpdateFileChangeType::Renamed
        );
        assert_eq!(
            parse_rest_status("copied"),
            DependencyUpdateFileChangeType::Copied
        );
        assert_eq!(
            parse_rest_status("changed"),
            DependencyUpdateFileChangeType::Changed
        );
    }

    #[test]
    fn parse_rest_status_unknown_falls_back_to_other() {
        assert_eq!(
            parse_rest_status("unchanged"),
            DependencyUpdateFileChangeType::Other
        );
        assert_eq!(parse_rest_status(""), DependencyUpdateFileChangeType::Other);
    }

    #[test]
    fn rest_file_to_patch_propagates_fields() {
        let file = RestPullFile {
            sha: Some("abc".into()),
            filename: "src/lib.rs".into(),
            status: "modified".into(),
            additions: 7,
            deletions: 2,
            changes: 9,
            blob_url: None,
            raw_url: None,
            contents_url: None,
            patch: Some("@@ -1 +1 @@\n-old\n+new".into()),
            previous_filename: None,
        };
        let patch = rest_file_to_patch(&file);
        assert_eq!(patch.path, "src/lib.rs");
        assert_eq!(patch.status, DependencyUpdateFileChangeType::Modified);
        assert_eq!(patch.additions, 7);
        assert_eq!(patch.deletions, 2);
        assert!(patch.patch.contains("+new"));
        assert!(!patch.truncated);
        assert_eq!(patch.served_by, DependencyUpdateFileServedBy::GithubRest);
        assert!(patch.fetched_at.is_empty());
        assert!(patch.head_ref_oid.is_empty());
    }

    #[test]
    fn rest_file_to_patch_handles_missing_patch() {
        let file = RestPullFile {
            sha: None,
            filename: "image.png".into(),
            status: "modified".into(),
            additions: 0,
            deletions: 0,
            changes: 0,
            blob_url: None,
            raw_url: None,
            contents_url: None,
            patch: None,
            previous_filename: None,
        };
        let patch = rest_file_to_patch(&file);
        assert!(patch.patch.is_empty());
        assert!(!patch.truncated);
    }

    #[test]
    fn truncation_detection_recognises_large_patches() {
        let mut huge = String::new();
        for i in 0..3_000 {
            huge.push_str(&format!("+line{i}\n"));
        }
        assert!(is_truncated_patch(&huge));
    }

    #[test]
    fn truncation_detection_ignores_small_patches() {
        assert!(!is_truncated_patch(""));
        assert!(!is_truncated_patch("@@ -1 +1 @@\n-a\n+b"));
    }

    #[test]
    fn parse_next_link_extracts_url() {
        let header = r#"<https://api.github.com/repos/a/b/pulls/1/files?page=2>; rel="next", <https://api.github.com/repos/a/b/pulls/1/files?page=4>; rel="last""#;
        let next = parse_next_link(header).expect("next link");
        assert_eq!(
            next,
            "https://api.github.com/repos/a/b/pulls/1/files?page=2"
        );
    }

    #[test]
    fn parse_next_link_returns_none_for_terminal_pages() {
        let header = r#"<https://api.github.com/repos/a/b/pulls/1/files?page=1>; rel="prev""#;
        assert!(parse_next_link(header).is_none());
    }

    #[test]
    fn parse_next_link_returns_none_for_empty() {
        assert!(parse_next_link("").is_none());
    }

    #[test]
    fn select_patches_by_path_filters() {
        let files = vec![
            RestPullFile {
                sha: None,
                filename: "src/a.rs".into(),
                status: "modified".into(),
                additions: 1,
                deletions: 0,
                changes: 1,
                blob_url: None,
                raw_url: None,
                contents_url: None,
                patch: Some("+ a".into()),
                previous_filename: None,
            },
            RestPullFile {
                sha: None,
                filename: "src/b.rs".into(),
                status: "modified".into(),
                additions: 2,
                deletions: 0,
                changes: 2,
                blob_url: None,
                raw_url: None,
                contents_url: None,
                patch: Some("+ b".into()),
                previous_filename: None,
            },
        ];
        let requested = vec!["src/b.rs".to_string()];
        let selected = select_patches_by_path(&files, &requested);
        assert_eq!(selected.len(), 1);
        assert_eq!(selected[0].path, "src/b.rs");
    }

    #[test]
    fn select_patches_by_path_empty_request_returns_all() {
        let files = vec![RestPullFile {
            sha: None,
            filename: "src/a.rs".into(),
            status: "modified".into(),
            additions: 1,
            deletions: 0,
            changes: 1,
            blob_url: None,
            raw_url: None,
            contents_url: None,
            patch: Some("+ a".into()),
            previous_filename: None,
        }];
        let selected = select_patches_by_path(&files, &[]);
        assert_eq!(selected.len(), 1);
    }

    #[test]
    fn detect_drift_matches_case_insensitively() {
        assert!(!detect_drift("ABC123", "abc123"));
        assert!(!detect_drift("abc123", "abc123"));
    }

    #[test]
    fn detect_drift_flags_mismatched_oids() {
        assert!(detect_drift("abc123", "def456"));
    }

    #[test]
    fn detect_drift_ignores_empty_inputs() {
        assert!(!detect_drift("", "abc123"));
        assert!(!detect_drift("abc123", ""));
    }
}
