//! REST-path patch fetcher. Pages until `Link: rel="next"` is exhausted or
//! `FILES_PAGE_CAP` pages have been visited. Supports `If-None-Match`
//! conditional revalidation so callers can short-circuit on cached `ETags`.

use std::error::Error;
use std::fmt;

use axum::http;
use http::header::{ETAG, IF_NONE_MATCH, HeaderMap};
use http_body_util::BodyExt;
use octocrab::Octocrab;
use octocrab::models::repos::DiffEntry;

use super::parsing::{
    diff_entry_to_rest_file, parse_next_link, select_patches_by_path,
    split_repo_full_name, RestPullFile,
};
use crate::reviews::files::{ReviewFilePatch, FILES_PAGE_CAP};

/// Outcome from a conditional REST fetch. `NotModified` means the server
/// returned `304` because the caller's `If-None-Match` header matched the
/// current resource — caller should reuse its cached entries.
#[derive(Debug)]
pub enum ConditionalFetchOutcome {
    /// First-page `ETag` (when present) and the parsed patches.
    Fetched {
        etag: Option<String>,
        patches: Vec<ReviewFilePatch>,
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
/// `if_none_match` is the prior `ETag`, if any. When set and the server
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

    let mut request_headers = HeaderMap::new();
    if let Some(etag) = if_none_match
        && !etag.is_empty()
    {
        request_headers.insert(
            IF_NONE_MATCH,
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
        .get(ETAG)
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
    let first_page: Vec<DiffEntry> =
        serde_json::from_slice(&bytes).map_err(|e| RestFetchError::Http(e.to_string()))?;

    let all_entries = fetch_remaining_pages(client, first_page, next_link).await?;

    let rest_files: Vec<RestPullFile> = all_entries.iter().map(diff_entry_to_rest_file).collect();
    let mut patches = select_patches_by_path(&rest_files, requested_paths);
    let head = head_ref_oid.to_string();
    for patch in &mut patches {
        patch.head_ref_oid.clone_from(&head);
        patch.etag.clone_from(&etag);
    }
    Ok(ConditionalFetchOutcome::Fetched { etag, patches })
}

async fn fetch_remaining_pages(
    client: &Octocrab,
    first_page: Vec<DiffEntry>,
    next_link: Option<String>,
) -> Result<Vec<DiffEntry>, RestFetchError> {
    let mut all_entries = first_page;
    let mut next_uri = next_link;
    let mut visited_pages = 1_u32;
    while visited_pages < FILES_PAGE_CAP
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
        let page: Vec<DiffEntry> =
            serde_json::from_slice(&bytes).map_err(|e| RestFetchError::Http(e.to_string()))?;
        all_entries.extend(page);
        visited_pages += 1;
    }
    Ok(all_entries)
}

/// Unconditional variant of [`fetch_patches_conditional`]. Returns just the
/// patches; the response `ETag` (if any) is dropped. Kept for back-compat with
/// callers that don't yet persist `ETags`.
///
/// # Errors
/// Returns `RestFetchError` on network / auth failures.
pub async fn fetch_patches(
    client: &Octocrab,
    repo_full_name: &str,
    pr_number: u64,
    head_ref_oid: &str,
    requested_paths: &[String],
) -> Result<Vec<ReviewFilePatch>, RestFetchError> {
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

impl fmt::Display for RestFetchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidRequest(msg) => write!(f, "rest patch fetch: {msg}"),
            Self::Http(msg) => write!(f, "rest patch fetch http: {msg}"),
        }
    }
}

impl Error for RestFetchError {}
