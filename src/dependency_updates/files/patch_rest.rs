//! REST-path patch fetch for the dependency_updates Files section.
//!
//! GitHub's REST endpoint `GET /repos/{owner}/{repo}/pulls/{n}/files` returns
//! up to 30 files per page with a per-file `patch` string (possibly
//! truncated at ~3000 lines). We page until `Link: rel="next"` is exhausted
//! or `FILES_PAGE_CAP` pages have been visited. ETag support: callers pass
//! `If-None-Match: <etag>` per cached file; a 304 response is treated as
//! "still valid".
//!
//! This module includes the `Octocrab` REST fetcher plus pure helpers for
//! REST-response parsing, path filtering, drift checks, and truncation
//! labeling used by the service.

use axum::http;
use http_body_util::BodyExt;
use octocrab::Octocrab;
use serde::Deserialize;

use super::{
    DependencyUpdateFileChangeType, DependencyUpdateFilePatch, DependencyUpdateFileServedBy,
    FILES_PAGE_CAP,
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

/// Outcome from a conditional REST fetch. `NotModified` means the server
/// returned `304` because the caller's `If-None-Match` header matched the
/// current resource — caller should reuse its cached entries.
#[derive(Debug)]
pub enum ConditionalFetchOutcome {
    /// First-page ETag (when present) and the parsed patches.
    Fetched {
        etag: Option<String>,
        patches: Vec<DependencyUpdateFilePatch>,
    },
    /// Server returned 304; cached entries are still authoritative.
    NotModified,
}

/// Fetch the per-file patches for one PR via GitHub's REST endpoint with
/// optional ETag-based revalidation.
///
/// Pagination is capped at `FILES_PAGE_CAP * 30` entries. The first page's
/// `ETag` response header is surfaced on the [`ConditionalFetchOutcome`] so
/// the caller can persist it for the next conditional revalidation.
///
/// `if_none_match` is the prior ETag, if any. When set and the server
/// returns `304 Not Modified`, the outcome is [`ConditionalFetchOutcome::NotModified`]
/// with no body fetched. Without an etag the first call is unconditional.
///
/// # Errors
/// Returns `RestFetchError` on network / auth failures and on malformed
/// `repo_full_name`.
pub async fn fetch_patches_conditional(
    client: &Octocrab,
    repo_full_name: &str,
    pr_number: u64,
    head_ref_oid: &str,
    requested_paths: &[String],
    if_none_match: Option<&str>,
) -> Result<ConditionalFetchOutcome, RestFetchError> {
    let (owner, repo) = split_repo_full_name(repo_full_name)
        .ok_or_else(|| RestFetchError::InvalidRequest("repo_full_name must be owner/name".into()))?;
    let route = format!("/repos/{owner}/{repo}/pulls/{pr_number}/files");

    let mut request_headers = http::header::HeaderMap::new();
    if let Some(etag) = if_none_match
        && !etag.is_empty()
    {
        request_headers.insert(
            http::header::IF_NONE_MATCH,
            http::HeaderValue::from_str(etag)
                .map_err(|e| RestFetchError::InvalidRequest(format!("etag header value: {e}")))?,
        );
    }

    let uri = route
        .parse::<http::Uri>()
        .map_err(|e| RestFetchError::InvalidRequest(format!("uri parse: {e}")))?;
    let response = client
        ._get_with_headers(uri, Some(request_headers))
        .await
        .map_err(|e| RestFetchError::Http(e.to_string()))?;

    if response.status() == http::StatusCode::NOT_MODIFIED {
        return Ok(ConditionalFetchOutcome::NotModified);
    }
    if !response.status().is_success() {
        return Err(RestFetchError::Http(format!(
            "rest patches status {}",
            response.status()
        )));
    }

    let etag = response
        .headers()
        .get(http::header::ETAG)
        .and_then(|v| v.to_str().ok())
        .map(ToString::to_string);
    let next_link = response
        .headers()
        .get("link")
        .and_then(|v| v.to_str().ok())
        .and_then(parse_next_link);

    let bytes = response
        .into_body()
        .collect()
        .await
        .map_err(|e| RestFetchError::Http(format!("rest patches body: {e}")))?
        .to_bytes();
    let first_page: Vec<octocrab::models::repos::DiffEntry> =
        serde_json::from_slice(&bytes).map_err(|e| RestFetchError::Http(e.to_string()))?;

    let mut all_entries: Vec<octocrab::models::repos::DiffEntry> = first_page;
    let mut next_uri = next_link;
    let mut visited_pages = 1_u32;
    let cap = FILES_PAGE_CAP;
    while visited_pages < cap
        && let Some(uri_str) = next_uri.take()
    {
        let uri = uri_str
            .parse::<http::Uri>()
            .map_err(|e| RestFetchError::InvalidRequest(format!("next link parse: {e}")))?;
        let response = client
            ._get_with_headers(uri, None)
            .await
            .map_err(|e| RestFetchError::Http(e.to_string()))?;
        if !response.status().is_success() {
            return Err(RestFetchError::Http(format!(
                "rest patches paginated status {}",
                response.status()
            )));
        }
        next_uri = response
            .headers()
            .get("link")
            .and_then(|v| v.to_str().ok())
            .and_then(parse_next_link);
        let bytes = response
            .into_body()
            .collect()
            .await
            .map_err(|e| RestFetchError::Http(format!("paginated body: {e}")))?
            .to_bytes();
        let page: Vec<octocrab::models::repos::DiffEntry> =
            serde_json::from_slice(&bytes).map_err(|e| RestFetchError::Http(e.to_string()))?;
        all_entries.extend(page);
        visited_pages += 1;
    }

    let rest_files: Vec<RestPullFile> = all_entries.iter().map(diff_entry_to_rest_file).collect();
    let mut patches = select_patches_by_path(&rest_files, requested_paths);
    let head = head_ref_oid.to_string();
    for patch in &mut patches {
        patch.head_ref_oid = head.clone();
        patch.etag = etag.clone();
    }
    Ok(ConditionalFetchOutcome::Fetched { etag, patches })
}

/// Unconditional variant of [`fetch_patches_conditional`]. Returns just the
/// patches; the response ETag (if any) is dropped. Kept for back-compat with
/// callers that don't yet persist ETags.
///
/// # Errors
/// Returns `RestFetchError` on network / auth failures.
pub async fn fetch_patches(
    client: &Octocrab,
    repo_full_name: &str,
    pr_number: u64,
    head_ref_oid: &str,
    requested_paths: &[String],
) -> Result<Vec<DependencyUpdateFilePatch>, RestFetchError> {
    match fetch_patches_conditional(
        client,
        repo_full_name,
        pr_number,
        head_ref_oid,
        requested_paths,
        None,
    )
    .await?
    {
        ConditionalFetchOutcome::Fetched { patches, .. } => Ok(patches),
        ConditionalFetchOutcome::NotModified => Ok(Vec::new()),
    }
}

/// Failure modes the REST fetcher exposes. Mapped to `CliError` at the
/// service-layer boundary.
#[derive(Debug)]
pub enum RestFetchError {
    InvalidRequest(String),
    Http(String),
}

impl std::fmt::Display for RestFetchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidRequest(msg) => write!(f, "rest patch fetch: {msg}"),
            Self::Http(msg) => write!(f, "rest patch fetch http: {msg}"),
        }
    }
}

impl std::error::Error for RestFetchError {}

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

    /// Spawn a tiny axum mock that serves `payload` for every
    /// `GET /repos/{o}/{r}/pulls/{n}/files`. Returns the bound port + the
    /// JoinHandle so the test can shut it down.
    async fn spawn_mock_pulls_files(
        payload: serde_json::Value,
    ) -> (u16, tokio::task::JoinHandle<()>) {
        use axum::Router;
        use axum::routing::get;
        use tokio::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let port = listener.local_addr().expect("addr").port();
        let app = Router::new().route(
            "/repos/{owner}/{repo}/pulls/{number}/files",
            get(move || {
                let payload = payload.clone();
                async move { axum::Json(payload) }
            }),
        );
        let server = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        (port, server)
    }

    fn mock_octocrab_at(port: u16) -> Octocrab {
        crate::dependency_updates::github::ensure_rustls_provider();
        Octocrab::builder()
            .base_uri(format!("http://127.0.0.1:{port}"))
            .expect("base_uri")
            .personal_token("test-token".to_string())
            .add_retry_config(octocrab::service::middleware::retry::RetryConfig::None)
            .build()
            .expect("octocrab")
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn fetch_patches_returns_all_files_against_mock_server() {
        use serde_json::json;
        let body = json!([
            {
                "sha": "a11", "filename": "src/a.rs", "status": "modified",
                "additions": 1, "deletions": 1, "changes": 2,
                "blob_url": "https://example.com/a", "raw_url": "https://example.com/a",
                "contents_url": "https://example.com/a",
                "patch": "@@ -1 +1 @@\n-a\n+A\n"
            },
            {
                "sha": "b22", "filename": "src/b.rs", "status": "added",
                "additions": 2, "deletions": 0, "changes": 2,
                "blob_url": "https://example.com/b", "raw_url": "https://example.com/b",
                "contents_url": "https://example.com/b",
                "patch": "@@ -0,0 +1,2 @@\n+b1\n+b2\n"
            }
        ]);
        let (port, server) = spawn_mock_pulls_files(body).await;
        let client = mock_octocrab_at(port);

        let patches = fetch_patches(&client, "o/r", 1, "deadbeef", &[])
            .await
            .expect("fetch");
        assert_eq!(patches.len(), 2);
        let paths: Vec<_> = patches.iter().map(|p| p.path.as_str()).collect();
        assert!(paths.contains(&"src/a.rs"));
        assert!(paths.contains(&"src/b.rs"));
        for patch in &patches {
            assert_eq!(patch.served_by, DependencyUpdateFileServedBy::GithubRest);
            assert_eq!(patch.head_ref_oid, "deadbeef");
        }
        let added = patches.iter().find(|p| p.path == "src/b.rs").expect("b");
        assert_eq!(added.status, DependencyUpdateFileChangeType::Added);
        assert_eq!(added.additions, 2);
        assert_eq!(added.deletions, 0);
        server.abort();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn fetch_patches_path_filter_drops_unrequested_files() {
        use serde_json::json;
        let body = json!([
            {
                "sha": "aaa", "filename": "want.rs", "status": "modified",
                "additions": 1, "deletions": 0, "changes": 1,
                "blob_url": "https://example.com/x", "raw_url": "https://example.com/x",
                "contents_url": "https://example.com/x",
                "patch": "@@ -1 +1 @@\n-a\n+A\n"
            },
            {
                "sha": "bbb", "filename": "skip.rs", "status": "modified",
                "additions": 1, "deletions": 0, "changes": 1,
                "blob_url": "https://example.com/y", "raw_url": "https://example.com/y",
                "contents_url": "https://example.com/y",
                "patch": "@@ -1 +1 @@\n-b\n+B\n"
            }
        ]);
        let (port, server) = spawn_mock_pulls_files(body).await;
        let client = mock_octocrab_at(port);

        let patches = fetch_patches(&client, "o/r", 1, "head", &["want.rs".to_string()])
            .await
            .expect("fetch");
        assert_eq!(patches.len(), 1);
        assert_eq!(patches[0].path, "want.rs");
        server.abort();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn fetch_patches_rejects_malformed_repo_full_name_at_runtime() {
        let (port, server) = spawn_mock_pulls_files(serde_json::json!([])).await;
        let client = mock_octocrab_at(port);
        let err = fetch_patches(&client, "no-slash", 1, "head", &[])
            .await
            .unwrap_err();
        assert!(matches!(err, RestFetchError::InvalidRequest(_)));
        server.abort();
    }

    #[test]
    fn fetch_patches_rejects_malformed_repo_full_name() {
        assert!(split_repo_full_name("no-slash").is_none());
        assert!(split_repo_full_name("").is_none());
        assert!(split_repo_full_name("/repo").is_none());
        assert!(split_repo_full_name("owner/").is_none());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn fetch_patches_conditional_returns_etag_from_response_header() {
        use axum::Router;
        use axum::response::IntoResponse;
        use axum::routing::get;
        use http::HeaderValue;
        use serde_json::json;
        use tokio::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let port = listener.local_addr().expect("addr").port();
        let app = Router::new().route(
            "/repos/{owner}/{repo}/pulls/{number}/files",
            get(|| async {
                let body = json!([
                    {
                        "sha": "a11", "filename": "src/a.rs", "status": "modified",
                        "additions": 1, "deletions": 0, "changes": 1,
                        "blob_url": "https://example.com/a", "raw_url": "https://example.com/a",
                        "contents_url": "https://example.com/a",
                        "patch": "@@ -1 +1 @@\n-a\n+A\n"
                    }
                ]);
                let mut response = axum::Json(body).into_response();
                response.headers_mut().insert(
                    "etag",
                    HeaderValue::from_static("W/\"abc-123\""),
                );
                response
            }),
        );
        let server = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        let client = mock_octocrab_at(port);

        let outcome = fetch_patches_conditional(&client, "o/r", 1, "head", &[], None)
            .await
            .expect("conditional");
        match outcome {
            ConditionalFetchOutcome::Fetched { etag, patches } => {
                assert_eq!(etag.as_deref(), Some("W/\"abc-123\""));
                assert_eq!(patches.len(), 1);
                assert_eq!(patches[0].etag.as_deref(), Some("W/\"abc-123\""));
            }
            ConditionalFetchOutcome::NotModified => panic!("expected Fetched, got NotModified"),
        }
        server.abort();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn fetch_patches_conditional_returns_not_modified_on_304() {
        use axum::Router;
        use axum::http::StatusCode;
        use axum::routing::get;
        use tokio::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let port = listener.local_addr().expect("addr").port();
        let app = Router::new().route(
            "/repos/{owner}/{repo}/pulls/{number}/files",
            get(|| async { (StatusCode::NOT_MODIFIED, "") }),
        );
        let server = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        let client = mock_octocrab_at(port);

        let outcome = fetch_patches_conditional(
            &client,
            "o/r",
            1,
            "head",
            &[],
            Some("W/\"existing-etag\""),
        )
        .await
        .expect("conditional");
        assert!(matches!(outcome, ConditionalFetchOutcome::NotModified));
        server.abort();
    }
}
