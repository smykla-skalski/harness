use std::collections::{BTreeMap, BTreeSet};
use std::slice;
use std::sync::OnceLock;
use std::time::Duration;

use octocrab::Octocrab;

const GITHUB_HTTP_CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
const GITHUB_HTTP_READ_TIMEOUT: Duration = Duration::from_secs(60);
use rustls::crypto::ring::default_provider;
use serde_json::json;

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::github::{GitHubApiAutomationClient, GitHubAutomationClient};

mod check_status;
mod coverage;
mod errors;
mod ingest;
mod mapping;
mod pagination;
pub(super) mod queries;
mod rate_limit;
mod types;

use chrono::{DateTime, Utc};

use coverage::log_check_details_url_coverage;
use errors::{client_error, operation_error};
use ingest::{ingest_nodes_chunk, ingest_search_node};
use mapping::{
    NodeContinuation, action_result, github_project_config, next_cursor_or_scope_limit,
    parse_timestamp, scopes,
};
use pagination::resolve_continuation;
use queries::{
    ADD_COMMENT_MUTATION, APPROVE_MUTATION, NODES_BY_IDS_QUERY, ORGANIZATION_REPOSITORIES_QUERY,
    PULL_REQUEST_BODY_QUERY, REREQUEST_CHECK_SUITE_MUTATION, SEARCH_QUERY,
    UPDATE_PULL_REQUEST_BODY_MUTATION,
};
use types::{
    NodesResponse, OrganizationRepositoriesResponse, PullRequestBodyResponse, SearchResponse,
    UpdatePullRequestBodyResponse,
};

use super::{
    DependencyUpdateActionKind, DependencyUpdateActionOutcome, DependencyUpdateActionResult,
    DependencyUpdateCheck, DependencyUpdateCheckConclusion, DependencyUpdateCheckRunStatus,
    DependencyUpdateCheckStatus, DependencyUpdateItem, DependencyUpdateMergeableState,
    DependencyUpdatePullRequestState, DependencyUpdateRepositoryLabel, DependencyUpdateReview,
    DependencyUpdateReviewEventState, DependencyUpdateReviewStatus, DependencyUpdateTarget,
    DependencyUpdatesApproveRequest, DependencyUpdatesAutoRequest, DependencyUpdatesCommentRequest,
    DependencyUpdatesLabelRequest, DependencyUpdatesMergeRequest, DependencyUpdatesQueryRequest,
    DependencyUpdatesRerunChecksRequest, timeline,
};

pub(crate) struct DependencyUpdatesFetch {
    pub items: Vec<DependencyUpdateItem>,
    pub repository_labels: BTreeMap<String, Vec<DependencyUpdateRepositoryLabel>>,
}

pub(crate) struct DependencyUpdatesFetchByIds {
    pub items: Vec<DependencyUpdateItem>,
    pub missing: Vec<String>,
    pub repository_labels: BTreeMap<String, Vec<DependencyUpdateRepositoryLabel>>,
}

const GRAPHQL_PAGE_SIZE: u32 = 100;
const SEARCH_PAGE_CAP: u32 = 10;
const REPOSITORY_CATALOG_PAGE_CAP: u32 = 5;
const SCOPE_QUERY_CAP: usize = 50;
const NODES_BATCH_SIZE: usize = 50;

static RUSTLS_PROVIDER: OnceLock<()> = OnceLock::new();

pub(crate) struct DependencyUpdatesGitHubClient {
    client: Octocrab,
    automation: GitHubApiAutomationClient,
}

impl DependencyUpdatesGitHubClient {
    /// Borrow the underlying Octocrab client. Used by the REST patch
    /// fetcher in `dependency_updates::files::patch_rest`, which needs
    /// raw `pulls/<n>/files` access alongside the higher-level helpers
    /// on this struct.
    pub(crate) fn octocrab(&self) -> &Octocrab {
        &self.client
    }

    pub(crate) fn new(token: &str) -> Result<Self, CliError> {
        let token = token.trim();
        if token.is_empty() {
            return Err(
                CliErrorKind::workflow_io("dependency-updates github token missing").into(),
            );
        }
        ensure_rustls_provider();
        let client = Octocrab::builder()
            .personal_token(token.to_string())
            .set_connect_timeout(Some(GITHUB_HTTP_CONNECT_TIMEOUT))
            .set_read_timeout(Some(GITHUB_HTTP_READ_TIMEOUT))
            .build()
            .map_err(client_error)?;
        let automation = GitHubApiAutomationClient::new(token)?;
        Ok(Self { client, automation })
    }

    pub(crate) async fn fetch_updates(
        &self,
        request: &DependencyUpdatesQueryRequest,
    ) -> Result<DependencyUpdatesFetch, CliError> {
        let mut deduped: BTreeMap<String, DependencyUpdateItem> = BTreeMap::new();
        let mut continuations: BTreeMap<String, NodeContinuation> = BTreeMap::new();
        let mut repository_labels: BTreeMap<String, Vec<DependencyUpdateRepositoryLabel>> =
            BTreeMap::new();
        let mut repository_label_continuation_seen: BTreeSet<String> = BTreeSet::new();
        for scope in scopes(request)? {
            self.fetch_updates_scope(
                request,
                &scope,
                &mut deduped,
                &mut continuations,
                &mut repository_labels,
                &mut repository_label_continuation_seen,
            )
            .await?;
        }
        for (key, continuation) in continuations {
            if let Some(item) = deduped.get_mut(&key) {
                resolve_continuation(&self.client, item, &mut repository_labels, continuation)
                    .await?;
            }
        }
        let items = deduped.into_values().collect::<Vec<_>>();
        log_check_details_url_coverage(&items);
        Ok(DependencyUpdatesFetch {
            items,
            repository_labels,
        })
    }

    async fn fetch_updates_scope(
        &self,
        request: &DependencyUpdatesQueryRequest,
        scope: &mapping::ScopeQuery,
        deduped: &mut BTreeMap<String, DependencyUpdateItem>,
        continuations: &mut BTreeMap<String, NodeContinuation>,
        repository_labels: &mut BTreeMap<String, Vec<DependencyUpdateRepositoryLabel>>,
        repository_label_continuation_seen: &mut BTreeSet<String>,
    ) -> Result<(), CliError> {
        let mut cursor = None;
        let mut page = 1_u32;
        loop {
            let response: SearchResponse = self
                .client
                .graphql(&json!({
                    "query": SEARCH_QUERY,
                    "variables": {
                        "query": scope.query,
                        "after": cursor.as_deref(),
                    },
                }))
                .await
                .map_err(operation_error)?;
            for node in response.search.nodes {
                ingest_search_node(
                    node,
                    request,
                    deduped,
                    continuations,
                    repository_labels,
                    repository_label_continuation_seen,
                )?;
            }
            if !response.search.page_info.has_next_page {
                return Ok(());
            }
            cursor = next_cursor_or_scope_limit(
                &response.search.page_info,
                page,
                SEARCH_PAGE_CAP,
                &format!("dependency-updates query '{}'", scope.query),
            )?;
            page += 1;
        }
    }

    pub(crate) async fn fetch_by_ids(
        &self,
        ids: &[String],
    ) -> Result<DependencyUpdatesFetchByIds, CliError> {
        if ids.is_empty() {
            return Ok(DependencyUpdatesFetchByIds {
                items: Vec::new(),
                missing: Vec::new(),
                repository_labels: BTreeMap::new(),
            });
        }
        let mut items: Vec<DependencyUpdateItem> = Vec::with_capacity(ids.len());
        let mut continuations: Vec<NodeContinuation> = Vec::new();
        let mut missing = Vec::new();
        let mut repository_labels: BTreeMap<String, Vec<DependencyUpdateRepositoryLabel>> =
            BTreeMap::new();
        let mut repository_label_continuation_seen: BTreeSet<String> = BTreeSet::new();
        for chunk in ids.chunks(NODES_BATCH_SIZE) {
            let response: NodesResponse = self
                .client
                .graphql(&json!({
                    "query": NODES_BY_IDS_QUERY,
                    "variables": { "ids": chunk },
                }))
                .await
                .map_err(operation_error)?;
            ingest_nodes_chunk(
                response.nodes,
                chunk,
                &mut items,
                &mut continuations,
                &mut missing,
                &mut repository_labels,
                &mut repository_label_continuation_seen,
            )?;
        }
        for continuation in continuations {
            if let Some(item) = items
                .iter_mut()
                .find(|item| item.pull_request_id == continuation.pull_request_id)
            {
                resolve_continuation(&self.client, item, &mut repository_labels, continuation)
                    .await?;
            }
        }
        log_check_details_url_coverage(&items);
        Ok(DependencyUpdatesFetchByIds {
            items,
            missing,
            repository_labels,
        })
    }

    pub(crate) async fn catalog_organization_repositories(
        &self,
        organization: &str,
    ) -> Result<Vec<String>, CliError> {
        let mut repositories = Vec::new();
        let mut cursor = None;
        let mut page = 1_u32;
        loop {
            let response: OrganizationRepositoriesResponse = self
                .client
                .graphql(&json!({
                    "query": ORGANIZATION_REPOSITORIES_QUERY,
                    "variables": {
                        "organization": organization,
                        "after": cursor.as_deref(),
                    },
                }))
                .await
                .map_err(operation_error)?;
            let Some(connection) = response
                .organization
                .map(|organization| organization.repositories)
            else {
                return Err(CliErrorKind::workflow_parse(format!(
                    "dependency-updates organization '{organization}' was not found or is not accessible"
                ))
                .into());
            };
            repositories.extend(
                connection
                    .nodes
                    .into_iter()
                    .map(|repository| repository.name_with_owner.to_lowercase()),
            );
            if !connection.page_info.has_next_page {
                break;
            }
            cursor = next_cursor_or_scope_limit(
                &connection.page_info,
                page,
                REPOSITORY_CATALOG_PAGE_CAP,
                &format!("dependency-updates repository catalog for '{organization}'"),
            )?;
            page += 1;
        }
        repositories.sort();
        repositories.dedup();
        Ok(repositories)
    }

    pub(crate) async fn fetch_pull_request_files(
        &self,
        request: &super::DependencyUpdatesFilesListRequest,
    ) -> Result<super::DependencyUpdatesFilesListResponse, CliError> {
        use chrono::Utc;
        super::files::list::fetch_files(&self.client, request, Utc::now())
            .await
            .map_err(|err| {
                CliErrorKind::workflow_io(format!("dependency-updates files list: {err}")).into()
            })
    }

    /// Run a `markFileAsViewed` or `unmarkFileAsViewed` GraphQL mutation
    /// against one (pullRequestId, path) pair. The mutation response is
    /// inspected only for success/failure; daemon-side drift detection
    /// happens before this method is called.
    pub(crate) async fn toggle_pull_request_file_viewed(
        &self,
        pull_request_id: &str,
        path: &str,
        mark_viewed: bool,
    ) -> Result<(), CliError> {
        let query = if mark_viewed {
            queries::MARK_PR_FILE_AS_VIEWED_MUTATION
        } else {
            queries::UNMARK_PR_FILE_AS_VIEWED_MUTATION
        };
        self.client
            .graphql::<serde_json::Value>(&json!({
                "query": query,
                "variables": {
                    "pullRequestId": pull_request_id,
                    "path": path,
                },
            }))
            .await
            .map(|_| ())
            .map_err(operation_error)
    }

    /// Fetch the text payload of one blob via GraphQL. Returns
    /// `(content_base64, byte_size, is_truncated, is_too_large)`. Binary
    /// blobs return empty content (`text == null` on the GraphQL side);
    /// callers should fall through to a REST raw-bytes fetch when the
    /// byte_size is non-zero but the content is empty.
    pub(crate) async fn fetch_repository_blob_text(
        &self,
        repository_id: &str,
        oid: &str,
    ) -> Result<crate::daemon::service::BlobTextProjection, CliError> {
        use base64::Engine as _;
        #[derive(Debug, serde::Deserialize)]
        struct RepositoryBlobResponse {
            node: Option<RepositoryBlobNode>,
        }
        #[derive(Debug, serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct RepositoryBlobNode {
            name_with_owner: Option<String>,
            object: Option<RepositoryBlobObject>,
        }
        #[derive(Debug, serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct RepositoryBlobObject {
            byte_size: Option<u64>,
            text: Option<String>,
            is_truncated: Option<bool>,
        }
        let response: RepositoryBlobResponse = self
            .client
            .graphql(&json!({
                "query": queries::REPOSITORY_BLOB_QUERY,
                "variables": {
                    "id": repository_id,
                    "expression": oid,
                },
            }))
            .await
            .map_err(operation_error)?;
        let node = response.node.ok_or_else(|| {
            CliErrorKind::workflow_parse(format!(
                "dependency-updates blob '{oid}' was not found in repository '{repository_id}'"
            ))
        })?;
        let repository_full_name = node.name_with_owner;
        let blob = node.object.ok_or_else(|| {
            CliErrorKind::workflow_parse(format!(
                "dependency-updates blob '{oid}' was not found in repository '{repository_id}'"
            ))
        })?;
        let byte_size = blob.byte_size.unwrap_or_default();
        let is_too_large = crate::dependency_updates::files::blob::blob_exceeds_cap(byte_size);
        let content_base64 = blob
            .text
            .as_deref()
            .filter(|_| !is_too_large)
            .map(|text| base64::engine::general_purpose::STANDARD.encode(text.as_bytes()))
            .unwrap_or_default();
        let is_truncated = blob.is_truncated.unwrap_or_default();
        Ok(crate::daemon::service::BlobTextProjection {
            repository_full_name,
            content_base64,
            byte_size,
            is_truncated,
            is_too_large,
        })
    }

    /// Fetch one git blob through GitHub REST and return its base64 payload.
    /// Used as the binary-image fallback after GraphQL has resolved the
    /// repository `nameWithOwner`.
    pub(crate) async fn fetch_repository_blob_base64(
        &self,
        repo_full_name: &str,
        oid: &str,
    ) -> Result<crate::daemon::service::BlobTextProjection, CliError> {
        #[derive(Debug, serde::Deserialize)]
        struct GitBlobResponse {
            content: String,
            encoding: String,
            size: u64,
        }

        let (owner, repo) =
            crate::dependency_updates::files::patch_rest::split_repo_full_name(repo_full_name)
                .ok_or_else(|| {
                    CliErrorKind::workflow_parse(format!(
                        "dependency-updates blob: repository '{repo_full_name}' is not owner/name"
                    ))
                })?;
        let route = format!("/repos/{owner}/{repo}/git/blobs/{oid}");
        let blob: GitBlobResponse = self
            .client
            .get(route, None::<&()>)
            .await
            .map_err(operation_error)?;
        if !blob.encoding.eq_ignore_ascii_case("base64") {
            return Err(CliErrorKind::workflow_parse(format!(
                "dependency-updates blob '{oid}' returned unsupported encoding '{}'",
                blob.encoding
            ))
            .into());
        }
        let is_too_large = crate::dependency_updates::files::blob::blob_exceeds_cap(blob.size);
        let content_base64 = if is_too_large {
            String::new()
        } else {
            normalize_git_blob_base64(&blob.content)
        };
        Ok(crate::daemon::service::BlobTextProjection {
            repository_full_name: Some(repo_full_name.to_string()),
            content_base64,
            byte_size: blob.size,
            is_truncated: false,
            is_too_large,
        })
    }

    pub(crate) async fn fetch_pull_request_body(
        &self,
        pull_request_id: &str,
    ) -> Result<(String, DateTime<Utc>), CliError> {
        let response: PullRequestBodyResponse = self
            .client
            .graphql(&json!({
                "query": PULL_REQUEST_BODY_QUERY,
                "variables": { "id": pull_request_id },
            }))
            .await
            .map_err(operation_error)?;
        let node = response.node.ok_or_else(|| {
            CliErrorKind::workflow_parse(format!(
                "dependency-updates pull request '{pull_request_id}' was not found or is not accessible"
            ))
        })?;
        let updated_at = parse_timestamp(node.updated_at.as_str())?;
        Ok((node.body.unwrap_or_default(), updated_at))
    }

    pub(crate) async fn update_pull_request_body(
        &self,
        pull_request_id: &str,
        body: &str,
    ) -> Result<(String, DateTime<Utc>), CliError> {
        let response: UpdatePullRequestBodyResponse = self
            .client
            .graphql(&json!({
                "query": UPDATE_PULL_REQUEST_BODY_MUTATION,
                "variables": { "id": pull_request_id, "body": body },
            }))
            .await
            .map_err(operation_error)?;
        let node = response
            .update_pull_request
            .and_then(|payload| payload.pull_request)
            .ok_or_else(|| {
                CliErrorKind::workflow_parse(format!(
                    "dependency-updates pull request '{pull_request_id}' rejected the body update"
                ))
            })?;
        let updated_at = parse_timestamp(node.updated_at.as_str())?;
        Ok((node.body.unwrap_or_default(), updated_at))
    }

    pub(crate) async fn approve(
        &self,
        request: &DependencyUpdatesApproveRequest,
    ) -> Result<Vec<DependencyUpdateActionResult>, CliError> {
        let mut results = Vec::with_capacity(request.targets.len());
        for target in &request.targets {
            let result = self
                .client
                .graphql::<serde_json::Value>(&json!({
                    "query": APPROVE_MUTATION,
                    "variables": {
                        "id": target.pull_request_id,
                    },
                }))
                .await;
            results.push(action_result(
                target,
                DependencyUpdateActionKind::Approve,
                result.map(|_| ()).map_err(operation_error),
            ));
        }
        Ok(results)
    }

    pub(crate) async fn comment(
        &self,
        request: &DependencyUpdatesCommentRequest,
    ) -> Result<Vec<DependencyUpdateActionResult>, CliError> {
        let mut results = Vec::with_capacity(request.targets.len());
        for target in &request.targets {
            let result = self
                .client
                .graphql::<serde_json::Value>(&json!({
                    "query": ADD_COMMENT_MUTATION,
                    "variables": {
                        "id": target.pull_request_id,
                        "body": request.body,
                    },
                }))
                .await
                .map_err(operation_error);
            results.push(comment_action_result(target, result));
        }
        Ok(results)
    }

    pub(crate) async fn merge(
        &self,
        request: &DependencyUpdatesMergeRequest,
    ) -> Result<Vec<DependencyUpdateActionResult>, CliError> {
        let mut results = Vec::with_capacity(request.targets.len());
        for target in &request.targets {
            let result = if let Some(config) = github_project_config(&target.repository) {
                self.automation
                    .merge_pull_request(
                        &config,
                        target.number,
                        request.method,
                        Some(target.head_sha.as_str()),
                    )
                    .await
            } else {
                Err(CliErrorKind::workflow_parse(format!(
                    "invalid dependency-updates repository '{}'",
                    target.repository
                ))
                .into())
            };
            results.push(action_result(
                target,
                DependencyUpdateActionKind::Merge,
                result,
            ));
        }
        Ok(results)
    }

    pub(crate) async fn rerun_checks(
        &self,
        request: &DependencyUpdatesRerunChecksRequest,
    ) -> Result<Vec<DependencyUpdateActionResult>, CliError> {
        let mut results = Vec::with_capacity(request.targets.len());
        for target in &request.targets {
            if target.check_suite_ids.is_empty() {
                results.push(DependencyUpdateActionResult {
                    repository: target.repository.clone(),
                    number: target.number,
                    action: DependencyUpdateActionKind::RerunChecks,
                    outcome: DependencyUpdateActionOutcome::Skipped,
                    message: Some("no rerunnable check suites were available".to_string()),
                    timeline_entry: None,
                });
                continue;
            }
            let mut outcome = Ok(());
            for check_suite_id in &target.check_suite_ids {
                if let Err(error) = self
                    .client
                    .graphql::<serde_json::Value>(&json!({
                        "query": REREQUEST_CHECK_SUITE_MUTATION,
                        "variables": {
                            "checkSuiteId": check_suite_id,
                            "repositoryId": target.repository_id,
                        },
                    }))
                    .await
                    .map_err(operation_error)
                {
                    outcome = Err(error);
                    break;
                }
            }
            results.push(action_result(
                target,
                DependencyUpdateActionKind::RerunChecks,
                outcome,
            ));
        }
        Ok(results)
    }

    pub(crate) async fn add_label(
        &self,
        request: &DependencyUpdatesLabelRequest,
    ) -> Result<Vec<DependencyUpdateActionResult>, CliError> {
        let mut results = Vec::with_capacity(request.targets.len());
        for target in &request.targets {
            let result = if let Some(config) = github_project_config(&target.repository) {
                self.automation
                    .sync_pull_request_labels(
                        &config,
                        target.number,
                        &[],
                        slice::from_ref(&request.label),
                    )
                    .await
            } else {
                Err(CliErrorKind::workflow_parse(format!(
                    "invalid dependency-updates repository '{}'",
                    target.repository
                ))
                .into())
            };
            results.push(action_result(
                target,
                DependencyUpdateActionKind::AddLabel,
                result,
            ));
        }
        Ok(results)
    }

    pub(crate) async fn auto_mode(
        &self,
        request: &DependencyUpdatesAutoRequest,
    ) -> Result<Vec<DependencyUpdateActionResult>, CliError> {
        let mut results = Vec::new();
        for target in request
            .targets
            .iter()
            .filter(|target| target.is_auto_approvable())
        {
            let result = self
                .client
                .graphql::<serde_json::Value>(&json!({
                    "query": APPROVE_MUTATION,
                    "variables": {
                        "id": target.pull_request_id,
                    },
                }))
                .await
                .map(|_| ())
                .map_err(operation_error);
            results.push(action_result(
                target,
                DependencyUpdateActionKind::AutoApprove,
                result,
            ));
        }
        for target in request
            .targets
            .iter()
            .filter(|target| target.is_auto_mergeable() || target.is_auto_approvable())
        {
            let result = if let Some(config) = github_project_config(&target.repository) {
                self.automation
                    .merge_pull_request(
                        &config,
                        target.number,
                        request.method,
                        Some(target.head_sha.as_str()),
                    )
                    .await
            } else {
                Err(CliErrorKind::workflow_parse(format!(
                    "invalid dependency-updates repository '{}'",
                    target.repository
                ))
                .into())
            };
            results.push(action_result(
                target,
                DependencyUpdateActionKind::AutoMerge,
                result,
            ));
        }
        Ok(results)
    }
}

fn normalize_git_blob_base64(content: &str) -> String {
    content.chars().filter(|c| !c.is_whitespace()).collect()
}

fn comment_action_result(
    target: &DependencyUpdateTarget,
    result: Result<serde_json::Value, CliError>,
) -> DependencyUpdateActionResult {
    match result {
        Ok(value) => {
            let entry = value
                .pointer("/addComment/commentEdge/node")
                .and_then(timeline::map_timeline_node);
            if let Some(entry) = entry.clone() {
                timeline::append_timeline_entry_to_cache(&target.pull_request_id, entry);
            }
            DependencyUpdateActionResult {
                repository: target.repository.clone(),
                number: target.number,
                action: DependencyUpdateActionKind::Comment,
                outcome: DependencyUpdateActionOutcome::Applied,
                message: None,
                timeline_entry: entry,
            }
        }
        Err(error) => DependencyUpdateActionResult {
            repository: target.repository.clone(),
            number: target.number,
            action: DependencyUpdateActionKind::Comment,
            outcome: DependencyUpdateActionOutcome::Failed,
            message: Some(error.to_string()),
            timeline_entry: None,
        },
    }
}

pub(crate) fn ensure_rustls_provider() {
    RUSTLS_PROVIDER.get_or_init(|| {
        let _ = default_provider().install_default();
    });
}

#[cfg(test)]
mod tests;
