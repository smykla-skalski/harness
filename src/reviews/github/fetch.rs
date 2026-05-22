use std::collections::{BTreeMap, BTreeSet};

use serde_json::json;

use crate::errors::{CliError, CliErrorKind};

use super::client::{
    NODES_BATCH_SIZE, REPOSITORY_CATALOG_PAGE_CAP, ReviewsFetch, ReviewsFetchByIds,
    ReviewsGitHubClient, SEARCH_PAGE_CAP,
};
use super::coverage::log_check_details_url_coverage;
use super::errors::operation_error;
use super::ingest::{ingest_nodes_chunk, ingest_search_node};
use super::mapping::{self, NodeContinuation, next_cursor_or_scope_limit, scopes};
use super::pagination::resolve_continuation;
use super::queries::{
    NODES_BY_IDS_QUERY, ORGANIZATION_REPOSITORIES_QUERY, SEARCH_QUERY,
};
use super::types::{NodesResponse, OrganizationRepositoriesResponse, SearchResponse};
use super::{ReviewItem, ReviewRepositoryLabel, ReviewsQueryRequest};

impl ReviewsGitHubClient {
    pub(crate) async fn fetch_updates(
        &self,
        request: &ReviewsQueryRequest,
    ) -> Result<ReviewsFetch, CliError> {
        let mut deduped: BTreeMap<String, ReviewItem> = BTreeMap::new();
        let mut continuations: BTreeMap<String, NodeContinuation> = BTreeMap::new();
        let mut repository_labels: BTreeMap<String, Vec<ReviewRepositoryLabel>> =
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
        Ok(ReviewsFetch {
            items,
            repository_labels,
        })
    }

    async fn fetch_updates_scope(
        &self,
        request: &ReviewsQueryRequest,
        scope: &mapping::ScopeQuery,
        deduped: &mut BTreeMap<String, ReviewItem>,
        continuations: &mut BTreeMap<String, NodeContinuation>,
        repository_labels: &mut BTreeMap<String, Vec<ReviewRepositoryLabel>>,
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
                &format!("reviews query '{}'", scope.query),
            )?;
            page += 1;
        }
    }

    pub(crate) async fn fetch_by_ids(
        &self,
        ids: &[String],
    ) -> Result<ReviewsFetchByIds, CliError> {
        if ids.is_empty() {
            return Ok(ReviewsFetchByIds {
                items: Vec::new(),
                missing: Vec::new(),
                repository_labels: BTreeMap::new(),
            });
        }
        let mut items: Vec<ReviewItem> = Vec::with_capacity(ids.len());
        let mut continuations: Vec<NodeContinuation> = Vec::new();
        let mut missing = Vec::new();
        let mut repository_labels: BTreeMap<String, Vec<ReviewRepositoryLabel>> =
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
        Ok(ReviewsFetchByIds {
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
                    "reviews organization '{organization}' was not found or is not accessible"
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
                &format!("reviews repository catalog for '{organization}'"),
            )?;
            page += 1;
        }
        repositories.sort();
        repositories.dedup();
        Ok(repositories)
    }
}
