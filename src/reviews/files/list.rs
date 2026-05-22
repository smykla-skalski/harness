//! GraphQL fetch for the per-PR files list.
//!
//! Loops through `pullRequest.files(first: 100, after: $cursor)` until
//! `pageInfo.hasNextPage == false` or `FILES_PAGE_CAP` pages have been
//! traversed - whichever comes first. Returns the materialized
//! `ReviewsFilesListResponse` plus a `ReviewsRateLimitSnapshot`
//! extracted from the top-level `rateLimit` field.
//!
//! Patches are NOT fetched here - this surface is metadata only. The Monitor
//! requests patches on-demand for the files the user expands.

use chrono::{DateTime, Utc};
use octocrab::Octocrab;
use serde::Deserialize;
use serde_json::json;

use crate::reviews::github::queries::LIST_PR_FILES_QUERY;

use super::{
    ReviewFile, ReviewFileChangeType, ReviewFileViewedState,
    ReviewsFilesListRequest, ReviewsFilesListResponse,
    ReviewsRateLimitSnapshot, FILES_PAGE_CAP, infer_language,
};

#[derive(Debug, Deserialize)]
struct GraphqlData {
    node: Option<PullRequestNode>,
    #[serde(rename = "rateLimit")]
    rate_limit: Option<GraphqlRateLimitNode>,
}

#[derive(Debug, Deserialize)]
struct PullRequestNode {
    number: Option<u64>,
    #[serde(rename = "headRefOid")]
    head_ref_oid: Option<String>,
    #[serde(rename = "headRefName")]
    head_ref_name: Option<String>,
    #[serde(rename = "baseRefOid")]
    base_ref_oid: Option<String>,
    #[serde(rename = "baseRefName")]
    base_ref_name: Option<String>,
    #[serde(rename = "viewerCanUpdate")]
    viewer_can_update: Option<bool>,
    repository: Option<RepositoryNode>,
    files: Option<FilesConnection>,
}

#[derive(Debug, Deserialize)]
struct RepositoryNode {
    #[serde(rename = "nameWithOwner")]
    name_with_owner: Option<String>,
}

#[derive(Debug, Deserialize)]
struct FilesConnection {
    #[serde(rename = "pageInfo")]
    page_info: PageInfo,
    #[serde(default)]
    nodes: Vec<FileNode>,
}

#[derive(Debug, Deserialize)]
struct PageInfo {
    #[serde(rename = "hasNextPage")]
    has_next_page: bool,
    #[serde(rename = "endCursor")]
    end_cursor: Option<String>,
}

#[derive(Debug, Deserialize)]
struct FileNode {
    path: String,
    #[serde(default)]
    additions: u32,
    #[serde(default)]
    deletions: u32,
    #[serde(rename = "changeType")]
    change_type: Option<String>,
    #[serde(rename = "viewerViewedState")]
    viewer_viewed_state: Option<String>,
}

#[derive(Debug, Deserialize)]
struct GraphqlRateLimitNode {
    #[serde(default)]
    limit: u32,
    #[serde(default)]
    cost: u32,
    #[serde(default)]
    remaining: u32,
    #[serde(rename = "resetAt")]
    reset_at: Option<String>,
}

/// Fetch the changed-files list for one PR via GraphQL.
///
/// Returns the metadata + a rate-limit snapshot. Pagination is capped at
/// `FILES_PAGE_CAP * 100` (default 2000 files); PRs larger than that get
/// truncated with `hasNextPage` ignored after the cap.
pub(crate) async fn fetch_files(
    client: &Octocrab,
    request: &ReviewsFilesListRequest,
    fetched_at: DateTime<Utc>,
) -> Result<ReviewsFilesListResponse, ListError> {
    let pull_request_id = request.normalized_pull_request_id();
    if pull_request_id.is_empty() {
        return Err(ListError::InvalidRequest(
            "reviews files list: pull_request_id is empty".into(),
        ));
    }

    let mut head_ref_oid = String::new();
    let mut number: Option<u64> = None;
    let mut head_ref_name: Option<String> = None;
    let mut base_ref_oid: Option<String> = None;
    let mut base_ref_name: Option<String> = None;
    let mut repository_full_name: Option<String> = None;
    let mut viewer_can_update = false;
    let mut files: Vec<ReviewFile> = Vec::new();
    let mut cursor: Option<String> = None;
    let mut rate_limit_snapshot: Option<ReviewsRateLimitSnapshot> = None;
    let mut pagination_complete = true;

    for page_index in 0..FILES_PAGE_CAP {
        let data: GraphqlData = client
            .graphql(&json!({
                "query": LIST_PR_FILES_QUERY,
                "variables": {
                    "id": pull_request_id,
                    "after": cursor,
                },
            }))
            .await
            .map_err(|err| ListError::Graphql(err.to_string()))?;

        if let Some(rate) = data.rate_limit {
            rate_limit_snapshot = Some(ReviewsRateLimitSnapshot {
                remaining: rate.remaining,
                limit: rate.limit,
                reset_at: rate.reset_at,
                cost: Some(rate.cost),
            });
        }

        let node = data
            .node
            .ok_or_else(|| ListError::NotFound(pull_request_id.clone()))?;

        if head_ref_oid.is_empty() {
            head_ref_oid = node.head_ref_oid.clone().unwrap_or_default();
        }
        if number.is_none() {
            number = node.number;
        }
        if head_ref_name.is_none() {
            head_ref_name = node.head_ref_name.clone();
        }
        if base_ref_oid.is_none() {
            base_ref_oid = node.base_ref_oid.clone();
        }
        if base_ref_name.is_none() {
            base_ref_name = node.base_ref_name.clone();
        }
        if repository_full_name.is_none() {
            repository_full_name = node
                .repository
                .as_ref()
                .and_then(|r| r.name_with_owner.clone());
        }
        if let Some(can_update) = node.viewer_can_update {
            viewer_can_update = can_update;
        }

        let Some(connection) = node.files else {
            // PR exists but no `files` field (e.g. permission gated). Return
            // what we have so far.
            break;
        };

        for raw in connection.nodes {
            files.push(ReviewFile {
                language_hint: infer_language(&raw.path),
                change_type: raw
                    .change_type
                    .as_deref()
                    .map(ReviewFileChangeType::parse)
                    .unwrap_or_default(),
                viewer_viewed_state: raw
                    .viewer_viewed_state
                    .as_deref()
                    .map(ReviewFileViewedState::parse)
                    .unwrap_or_default(),
                path: raw.path,
                previous_path: None,
                additions: raw.additions,
                deletions: raw.deletions,
                is_binary: false,
                mode_change: None,
            });
        }

        if !connection.page_info.has_next_page {
            break;
        }
        cursor = connection.page_info.end_cursor;
        if cursor.is_none() {
            // GitHub said hasNextPage=true but didn't return a cursor. Treat
            // as partial so the caller can surface a warning.
            pagination_complete = false;
            break;
        }
        // The cap is exclusive: if we've consumed the last allowed page and
        // GitHub still has more, mark the response as partial.
        if page_index + 1 == FILES_PAGE_CAP && connection.page_info.has_next_page {
            pagination_complete = false;
        }
    }

    Ok(ReviewsFilesListResponse {
        pull_request_id,
        number,
        head_ref_oid,
        head_ref_name,
        base_ref_oid,
        base_ref_name,
        repository_full_name,
        viewer_can_mark_viewed: viewer_can_update,
        files,
        fetched_at: fetched_at.to_rfc3339(),
        pagination_complete,
        rate_limit_snapshot,
    })
}

/// Error variants surfaced from the list call. Wrapped into the caller's
/// `CliError` at the service layer (A.10).
#[derive(Debug)]
pub(crate) enum ListError {
    InvalidRequest(String),
    Graphql(String),
    NotFound(String),
}

impl std::fmt::Display for ListError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidRequest(msg) => write!(f, "{msg}"),
            Self::Graphql(msg) => write!(f, "reviews files list graphql: {msg}"),
            Self::NotFound(id) => write!(
                f,
                "reviews files list: pull request '{id}' not found"
            ),
        }
    }
}

impl std::error::Error for ListError {}
