use std::collections::BTreeMap;
use std::sync::OnceLock;

use octocrab::Octocrab;
use rustls::crypto::ring::default_provider;
use serde_json::json;

use crate::errors::{CliError, CliErrorKind};
use crate::github_api_errors;
use crate::task_board::github::{GitHubApiAutomationClient, GitHubAutomationClient};

mod mapping;
mod queries;
mod types;

use mapping::{
    action_result, convert_node, github_project_config, next_cursor_or_scope_limit, scopes,
};
use queries::{
    APPROVE_MUTATION, ORGANIZATION_REPOSITORIES_QUERY, REREQUEST_CHECK_SUITE_MUTATION, SEARCH_QUERY,
};
use types::{OrganizationRepositoriesResponse, SearchResponse};

use super::{
    DependencyUpdateActionKind, DependencyUpdateActionOutcome, DependencyUpdateActionResult,
    DependencyUpdateCheck, DependencyUpdateCheckConclusion, DependencyUpdateCheckRunStatus,
    DependencyUpdateCheckStatus, DependencyUpdateItem, DependencyUpdateMergeableState,
    DependencyUpdatePullRequestState, DependencyUpdateReview, DependencyUpdateReviewEventState,
    DependencyUpdateReviewStatus, DependencyUpdateTarget, DependencyUpdatesApproveRequest,
    DependencyUpdatesAutoRequest, DependencyUpdatesLabelRequest, DependencyUpdatesMergeRequest,
    DependencyUpdatesQueryRequest, DependencyUpdatesRerunChecksRequest,
};

const GRAPHQL_PAGE_SIZE: u32 = 100;
const SEARCH_PAGE_CAP: u32 = 10;
const REPOSITORY_CATALOG_PAGE_CAP: u32 = 5;
const SCOPE_QUERY_CAP: usize = 50;

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
    ) -> Result<Vec<DependencyUpdateItem>, CliError> {
        let mut deduped = BTreeMap::new();
        for scope in scopes(request)? {
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
                    let item = convert_node(node)?;
                    if request
                        .normalized_exclude_repositories()
                        .contains(&item.repository)
                    {
                        continue;
                    }
                    deduped.insert(format!("{}#{}", item.repository, item.number), item);
                }
                if !response.search.page_info.has_next_page {
                    break;
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
        Ok(deduped.into_values().collect())
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
                    .sync_pull_request_labels(&config, target.number, &[], &[request.label.clone()])
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
