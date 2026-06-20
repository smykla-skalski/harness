use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

use serde_json::json;

use crate::errors::{CliError, CliErrorKind};
use crate::github_api::{GitHubCachePolicy, GitHubPriority, GitHubRequestDescriptor};
use crate::reviews::backports::BackportDetector;

use super::client::{
    NODES_BATCH_SIZE, REPOSITORY_CATALOG_PAGE_CAP, ReviewsFetch, ReviewsFetchByIds,
    ReviewsGitHubClient, SEARCH_PAGE_CAP,
};
use super::coverage::log_check_details_url_coverage;
use super::ingest::{SearchIngestState, ingest_nodes_chunk, ingest_search_node};
use super::mapping::{self, NodeContinuation, next_cursor_or_scope_limit, scopes};
use super::pagination::resolve_continuation;
use super::queries::{NODES_BY_IDS_QUERY, ORGANIZATION_REPOSITORIES_QUERY, SEARCH_QUERY};
use super::types::{NodesResponse, OrganizationRepositoriesResponse, SearchResponse};
use super::{ReviewItem, ReviewRepositoryLabel, ReviewsQueryRequest, ReviewsRefreshRequest};

const HOURS: u64 = 60 * 60;

pub(super) fn search_descriptor(request: &ReviewsQueryRequest) -> GitHubRequestDescriptor {
    let cache_policy = GitHubCachePolicy {
        force_refresh: request.force_refresh,
        ..GitHubCachePolicy::read_through(
            Duration::from_secs(request.cache_max_age_seconds()),
            Duration::from_hours(1),
        )
    };
    GitHubRequestDescriptor::graphql(
        "reviews.search",
        if request.force_refresh {
            GitHubPriority::FreshRead
        } else {
            GitHubPriority::Background
        },
        cache_policy,
    )
    .with_expected_cost(30)
}

impl ReviewsGitHubClient {
    pub(crate) async fn fetch_updates(
        &self,
        request: &ReviewsQueryRequest,
        viewer_login: Option<&str>,
    ) -> Result<ReviewsFetch, CliError> {
        let mut deduped: BTreeMap<String, ReviewItem> = BTreeMap::new();
        let mut continuations: BTreeMap<String, NodeContinuation> = BTreeMap::new();
        let mut repository_labels: BTreeMap<String, Vec<ReviewRepositoryLabel>> = BTreeMap::new();
        let mut repository_label_continuation_seen: BTreeSet<String> = BTreeSet::new();
        let backport_detector = BackportDetector::from_query(request)?;
        for scope in scopes(request)? {
            self.fetch_updates_scope(
                request,
                &scope,
                backport_detector.as_ref(),
                viewer_login,
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

    #[expect(
        clippy::too_many_arguments,
        reason = "search fanout accumulates shared dedupe and continuation state across pages"
    )]
    async fn fetch_updates_scope(
        &self,
        request: &ReviewsQueryRequest,
        scope: &mapping::ScopeQuery,
        backport_detector: Option<&BackportDetector>,
        viewer_login: Option<&str>,
        deduped: &mut BTreeMap<String, ReviewItem>,
        continuations: &mut BTreeMap<String, NodeContinuation>,
        repository_labels: &mut BTreeMap<String, Vec<ReviewRepositoryLabel>>,
        repository_label_continuation_seen: &mut BTreeSet<String>,
    ) -> Result<(), CliError> {
        let mut cursor = None;
        let mut page = 1_u32;
        let mut ingest_state = SearchIngestState {
            request,
            backport_detector,
            viewer_login,
            deduped,
            continuations,
            repository_labels,
            repository_label_continuation_seen,
        };
        loop {
            let descriptor = search_descriptor(request);
            let response: SearchResponse = self
                .client
                .graphql(
                    descriptor,
                    json!({
                        "query": SEARCH_QUERY,
                        "variables": {
                            "query": scope.query,
                            "after": cursor.as_deref(),
                        },
                    }),
                )
                .await
                .map(|response| response.body)?;
            for node in response.search.nodes {
                ingest_search_node(node, &mut ingest_state)?;
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
        request: &ReviewsRefreshRequest,
        viewer_login: Option<&str>,
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
        let mut repository_labels: BTreeMap<String, Vec<ReviewRepositoryLabel>> = BTreeMap::new();
        let mut repository_label_continuation_seen: BTreeSet<String> = BTreeSet::new();
        let backport_detector = BackportDetector::from_refresh(request)?;
        for chunk in ids.chunks(NODES_BATCH_SIZE) {
            let response: NodesResponse = self
                .client
                .graphql(
                    GitHubRequestDescriptor::graphql(
                        "reviews.nodes_by_ids",
                        GitHubPriority::FreshRead,
                        GitHubCachePolicy::read_through(
                            Duration::from_mins(5),
                            Duration::from_hours(1),
                        ),
                    ),
                    json!({
                    "query": NODES_BY_IDS_QUERY,
                    "variables": { "ids": chunk },
                    }),
                )
                .await
                .map(|response| response.body)?;
            ingest_nodes_chunk(
                response.nodes,
                chunk,
                backport_detector.as_ref(),
                viewer_login,
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
                .graphql(
                    GitHubRequestDescriptor::graphql(
                        "reviews.organization_repositories",
                        GitHubPriority::NormalRead,
                        GitHubCachePolicy::read_through(
                            Duration::from_secs(6 * HOURS),
                            Duration::from_secs(24 * HOURS),
                        ),
                    ),
                    json!({
                    "query": ORGANIZATION_REPOSITORIES_QUERY,
                    "variables": {
                        "organization": organization,
                        "after": cursor.as_deref(),
                    },
                    }),
                )
                .await
                .map(|response| response.body)?;
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
