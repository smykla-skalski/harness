use std::collections::{BTreeMap, BTreeSet};
use std::slice;
use std::sync::OnceLock;

use octocrab::Octocrab;
use rustls::crypto::ring::default_provider;
use serde_json::json;

use crate::errors::{CliError, CliErrorKind};
use crate::github_api_errors;
use crate::task_board::github::{GitHubApiAutomationClient, GitHubAutomationClient};

mod ingest;
mod mapping;
mod pagination;
mod queries;
mod types;

use chrono::{DateTime, Utc};

use ingest::{ingest_nodes_chunk, ingest_search_node};
use mapping::{
    action_result, github_project_config, next_cursor_or_scope_limit, parse_timestamp, scopes,
    NodeContinuation,
};
use pagination::resolve_continuation;
use queries::{
    APPROVE_MUTATION, NODES_BY_IDS_QUERY, ORGANIZATION_REPOSITORIES_QUERY,
    PULL_REQUEST_BODY_QUERY, REREQUEST_CHECK_SUITE_MUTATION, SEARCH_QUERY,
};
use types::{
    NodesResponse, OrganizationRepositoriesResponse, PullRequestBodyResponse, SearchResponse,
};

use super::{
    DependencyUpdateActionKind, DependencyUpdateActionOutcome, DependencyUpdateActionResult,
    DependencyUpdateCheck, DependencyUpdateCheckConclusion, DependencyUpdateCheckRunStatus,
    DependencyUpdateCheckStatus, DependencyUpdateItem, DependencyUpdateMergeableState,
    DependencyUpdatePullRequestState, DependencyUpdateRepositoryLabel, DependencyUpdateReview,
    DependencyUpdateReviewEventState, DependencyUpdateReviewStatus, DependencyUpdateTarget,
    DependencyUpdatesApproveRequest, DependencyUpdatesAutoRequest, DependencyUpdatesLabelRequest,
    DependencyUpdatesMergeRequest, DependencyUpdatesQueryRequest,
    DependencyUpdatesRerunChecksRequest,
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
        Ok(DependencyUpdatesFetch {
            items: deduped.into_values().collect(),
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

fn ensure_rustls_provider() {
    RUSTLS_PROVIDER.get_or_init(|| {
        let _ = default_provider().install_default();
    });
}

fn client_error(error: octocrab::Error) -> CliError {
    github_api_errors::client_error("create dependency-updates github client", error)
}

fn operation_error(error: octocrab::Error) -> CliError {
    github_api_errors::operation_error("dependency-updates github request failed", error)
}

#[cfg(test)]
mod tests;
