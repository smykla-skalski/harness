//! REST-path patch fetcher. Pages until `Link: rel="next"` is exhausted or
//! `FILES_PAGE_CAP` pages have been visited. Supports `If-None-Match`
//! conditional revalidation so callers can short-circuit on cached `ETags`.

use reqwest::Method;
use reqwest::header::{ETAG, HeaderMap, HeaderValue, IF_NONE_MATCH};
use std::error::Error;
use std::fmt;

use super::parsing::{RestPullFile, parse_next_link, select_patches_by_path, split_repo_full_name};
use crate::github_api::{
    GitHubCachePolicy, GitHubPriority, GitHubProtectedClient, GitHubRequestDescriptor,
};
use crate::reviews::files::{FILES_PAGE_CAP, ReviewFilePatch};

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
    client: &GitHubProtectedClient,
    repo_full_name: &str,
    pr_number: u64,
    head_ref_oid: &str,
    requested_paths: &[String],
    if_none_match: Option<&str>,
) -> Result<ConditionalFetchOutcome, RestFetchError> {
    let (owner, repo) = split_repo_full_name(repo_full_name).ok_or_else(|| {
        RestFetchError::InvalidRequest("repo_full_name must be owner/name".into())
    })?;
    let route = format!("/repos/{owner}/{repo}/pulls/{pr_number}/files");

    let mut request_headers = HeaderMap::new();
    if let Some(etag) = if_none_match
        && !etag.is_empty()
    {
        request_headers.insert(
            IF_NONE_MATCH,
            HeaderValue::from_str(etag)
                .map_err(|e| RestFetchError::InvalidRequest(format!("etag header value: {e}")))?,
        );
    }

    let response = client
        .rest_json_with_headers::<Vec<RestPullFile>>(
            Method::GET,
            route,
            None,
            patch_descriptor("reviews.files_patch"),
            request_headers,
        )
        .await
        .map_err(|e| RestFetchError::Http(e.to_string()))?;

    if response.status == reqwest::StatusCode::NOT_MODIFIED {
        return Ok(ConditionalFetchOutcome::NotModified);
    }
    if !response.status.is_success() {
        return Err(RestFetchError::Http(format!(
            "rest patches status {}",
            response.status
        )));
    }

    let etag = response
        .headers
        .get(ETAG)
        .and_then(|v| v.to_str().ok())
        .map(ToString::to_string);
    let next_link = response
        .headers
        .get("link")
        .and_then(|v| v.to_str().ok())
        .and_then(parse_next_link);

    let first_page = response
        .body
        .ok_or_else(|| RestFetchError::Http("rest patches missing body".into()))?;

    let all_entries = fetch_remaining_pages(client, first_page, next_link, requested_paths).await?;

    let mut patches = select_patches_by_path(&all_entries, requested_paths);
    let head = head_ref_oid.to_string();
    for patch in &mut patches {
        patch.head_ref_oid.clone_from(&head);
        patch.etag.clone_from(&etag);
    }
    Ok(ConditionalFetchOutcome::Fetched { etag, patches })
}

async fn fetch_remaining_pages(
    client: &GitHubProtectedClient,
    first_page: Vec<RestPullFile>,
    next_link: Option<String>,
    requested_paths: &[String],
) -> Result<Vec<RestPullFile>, RestFetchError> {
    let mut all_entries = first_page;
    if all_requested_paths_found(&all_entries, requested_paths) {
        return Ok(all_entries);
    }
    let mut next_uri = next_link;
    let mut visited_pages = 1_u32;
    while visited_pages < FILES_PAGE_CAP
        && let Some(uri_str) = next_uri.take()
    {
        let response = client
            .rest_json_with_headers::<Vec<RestPullFile>>(
                Method::GET,
                uri_str,
                None,
                patch_descriptor("reviews.files_patch_page"),
                HeaderMap::new(),
            )
            .await
            .map_err(|e| RestFetchError::Http(e.to_string()))?;
        if !response.status.is_success() {
            return Err(RestFetchError::Http(format!(
                "rest patches paginated status {}",
                response.status
            )));
        }
        next_uri = response
            .headers
            .get("link")
            .and_then(|v| v.to_str().ok())
            .and_then(parse_next_link);
        let page = response
            .body
            .ok_or_else(|| RestFetchError::Http("paginated body missing".into()))?;
        all_entries.extend(page);
        visited_pages += 1;
        if all_requested_paths_found(&all_entries, requested_paths) {
            break;
        }
    }
    Ok(all_entries)
}

fn all_requested_paths_found(entries: &[RestPullFile], requested_paths: &[String]) -> bool {
    !requested_paths.is_empty()
        && requested_paths
            .iter()
            .all(|path| entries.iter().any(|entry| &entry.filename == path))
}

/// Unconditional variant of [`fetch_patches_conditional`]. Returns just the
/// patches; the response `ETag` (if any) is dropped. Kept for back-compat with
/// callers that don't yet persist `ETags`.
///
/// # Errors
/// Returns `RestFetchError` on network / auth failures.
pub async fn fetch_patches(
    client: &GitHubProtectedClient,
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

fn patch_descriptor(operation: &str) -> GitHubRequestDescriptor {
    GitHubRequestDescriptor::rest_core(
        operation,
        GitHubPriority::NormalRead,
        GitHubCachePolicy::no_store(),
    )
}
