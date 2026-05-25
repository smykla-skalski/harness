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

use std::error::Error;
use std::fmt;
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::json;

use crate::github_api::{
    GitHubCachePolicy, GitHubPriority, GitHubProtectedClient, GitHubRequestDescriptor,
};
use crate::reviews::github::queries::LIST_PR_FILES_QUERY;

use super::{
    FILES_PAGE_CAP, ReviewFile, ReviewFileChangeType, ReviewFileViewedState,
    ReviewsFilesListRequest, ReviewsFilesListResponse, ReviewsRateLimitSnapshot, infer_language,
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
    client: &GitHubProtectedClient,
    request: &ReviewsFilesListRequest,
    fetched_at: DateTime<Utc>,
) -> Result<ReviewsFilesListResponse, ListError> {
    let pull_request_id = request.normalized_pull_request_id();
    if pull_request_id.is_empty() {
        return Err(ListError::InvalidRequest(
            "reviews files list: pull_request_id is empty".into(),
        ));
    }
    fetch_files_paginated(client, pull_request_id, fetched_at).await
}

/// Return value for one page step: `None` = done, `Some(cursor)` = continue.
enum PageStep {
    Done,
    Partial,
    Continue(String),
}

fn apply_rate_limit(snapshot: &mut Option<ReviewsRateLimitSnapshot>, rate: GraphqlRateLimitNode) {
    *snapshot = Some(ReviewsRateLimitSnapshot {
        remaining: rate.remaining,
        limit: rate.limit,
        reset_at: rate.reset_at,
        cost: Some(rate.cost),
    });
}

fn process_files_page(
    state: &mut FilesPageState,
    files: &mut Vec<ReviewFile>,
    data: GraphqlData,
    pull_request_id: &str,
    page_index: u32,
    rate_limit_snapshot: &mut Option<ReviewsRateLimitSnapshot>,
) -> Result<PageStep, ListError> {
    if let Some(rate) = data.rate_limit {
        apply_rate_limit(rate_limit_snapshot, rate);
    }
    let node = data
        .node
        .ok_or_else(|| ListError::NotFound(pull_request_id.to_string()))?;
    state.merge_node(&node);
    let Some(connection) = node.files else {
        return Ok(PageStep::Done);
    };
    files.extend(connection.nodes.into_iter().map(file_node_to_review_file));
    if !connection.page_info.has_next_page {
        return Ok(PageStep::Done);
    }
    match connection.page_info.end_cursor {
        None => Ok(PageStep::Partial),
        Some(cursor) if page_index + 1 == FILES_PAGE_CAP => {
            let _ = cursor;
            Ok(PageStep::Partial)
        }
        Some(cursor) => Ok(PageStep::Continue(cursor)),
    }
}

async fn fetch_files_paginated(
    client: &GitHubProtectedClient,
    pull_request_id: String,
    fetched_at: DateTime<Utc>,
) -> Result<ReviewsFilesListResponse, ListError> {
    let mut state = FilesPageState::new();
    let mut files: Vec<ReviewFile> = Vec::new();
    let mut cursor: Option<String> = None;
    let mut rate_limit_snapshot: Option<ReviewsRateLimitSnapshot> = None;
    let mut pagination_complete = true;

    for page_index in 0..FILES_PAGE_CAP {
        let data: GraphqlData = client
            .graphql(
                GitHubRequestDescriptor::graphql(
                    "reviews.files_list",
                    GitHubPriority::NormalRead,
                    GitHubCachePolicy::read_through(
                        Duration::from_mins(5),
                        Duration::from_mins(60),
                    ),
                )
                .with_expected_cost(10),
                json!({
                "query": LIST_PR_FILES_QUERY,
                "variables": {
                    "id": pull_request_id,
                    "after": cursor,
                },
                }),
            )
            .await
            .map(|response| response.body)
            .map_err(|err| ListError::Graphql(err.to_string()))?;

        match process_files_page(
            &mut state,
            &mut files,
            data,
            &pull_request_id,
            page_index,
            &mut rate_limit_snapshot,
        )? {
            PageStep::Done => break,
            PageStep::Partial => {
                pagination_complete = false;
                break;
            }
            PageStep::Continue(next) => cursor = Some(next),
        }
    }

    Ok(ReviewsFilesListResponse {
        pull_request_id,
        number: state.number,
        head_ref_oid: state.head_ref_oid,
        head_ref_name: state.head_ref_name,
        base_ref_oid: state.base_ref_oid,
        base_ref_name: state.base_ref_name,
        repository_full_name: state.repository_full_name,
        viewer_can_mark_viewed: state.viewer_can_update,
        files,
        fetched_at: fetched_at.to_rfc3339(),
        pagination_complete,
        rate_limit_snapshot,
    })
}

struct FilesPageState {
    head_ref_oid: String,
    number: Option<u64>,
    head_ref_name: Option<String>,
    base_ref_oid: Option<String>,
    base_ref_name: Option<String>,
    repository_full_name: Option<String>,
    viewer_can_update: bool,
}

impl FilesPageState {
    fn new() -> Self {
        Self {
            head_ref_oid: String::new(),
            number: None,
            head_ref_name: None,
            base_ref_oid: None,
            base_ref_name: None,
            repository_full_name: None,
            viewer_can_update: false,
        }
    }

    fn merge_node(&mut self, node: &PullRequestNode) {
        merge_option_first_wins(&mut self.head_ref_name, node.head_ref_name.as_ref());
        merge_option_first_wins(&mut self.base_ref_oid, node.base_ref_oid.as_ref());
        merge_option_first_wins(&mut self.base_ref_name, node.base_ref_name.as_ref());
        merge_scalar_fields(self, node);
    }
}

fn merge_option_first_wins(target: &mut Option<String>, source: Option<&String>) {
    if target.is_none() {
        *target = source.cloned();
    }
}

fn merge_scalar_fields(state: &mut FilesPageState, node: &PullRequestNode) {
    if state.head_ref_oid.is_empty() {
        state.head_ref_oid = node.head_ref_oid.clone().unwrap_or_default();
    }
    if state.number.is_none() {
        state.number = node.number;
    }
    if state.repository_full_name.is_none() {
        state.repository_full_name = node
            .repository
            .as_ref()
            .and_then(|r| r.name_with_owner.clone());
    }
    if let Some(can_update) = node.viewer_can_update {
        state.viewer_can_update = can_update;
    }
}

fn file_node_to_review_file(raw: FileNode) -> ReviewFile {
    ReviewFile {
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
    }
}

/// Error variants surfaced from the list call. Wrapped into the caller's
/// `CliError` at the service layer (A.10).
#[derive(Debug)]
pub(crate) enum ListError {
    InvalidRequest(String),
    Graphql(String),
    NotFound(String),
}

impl fmt::Display for ListError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidRequest(msg) => write!(f, "{msg}"),
            Self::Graphql(msg) => write!(f, "reviews files list graphql: {msg}"),
            Self::NotFound(id) => write!(f, "reviews files list: pull request '{id}' not found"),
        }
    }
}

impl Error for ListError {}
