use serde::Deserialize;
use serde_json::json;
use std::time::Duration;

use crate::errors::{CliError, CliErrorKind};
use crate::github_api::{
    GitHubCachePolicy, GitHubPriority, GitHubProtectedClient, GitHubRequestDescriptor,
};

use super::client::{GitHubCreatePullRequest, GitHubPullRequestHandle};
use super::config::GitHubProjectConfig;

mod fresh;
pub(super) use fresh::pull_request_handle_fresh;

const GRAPHQL_PAGE_LIMIT: u32 = 5;

pub(super) async fn pull_request_handle(
    client: &GitHubProtectedClient,
    config: &GitHubProjectConfig,
    pull_request_number: u64,
) -> Result<Option<GitHubPullRequestHandle>, CliError> {
    let response: PullRequestHandleResponse = client
        .graphql(
            github_graphql_descriptor("task_board.github.pull_request_handle"),
            json!({
            "query": PULL_REQUEST_HANDLE_QUERY,
            "variables": {
                "owner": config.owner.as_str(),
                "repo": config.repo.as_str(),
                "number": pull_request_number,
            },
            }),
        )
        .await
        .map(|response| response.body)?;
    let Some(graphql_handle) = response.pull_request() else {
        return Ok(None);
    };
    let page_info = graphql_handle.review_requests.page_info.clone();
    let mut handle = graphql_handle.into_handle();
    load_remaining_review_requests(client, config, pull_request_number, page_info, &mut handle)
        .await?;
    Ok(Some(handle))
}

pub(super) async fn open_pull_request_for_branch(
    client: &GitHubProtectedClient,
    config: &GitHubProjectConfig,
    request: &GitHubCreatePullRequest,
) -> Result<Option<GitHubPullRequestHandle>, CliError> {
    let search = format!(
        "repo:{}/{} is:pr is:open head:{}:{}",
        config.owner, config.repo, config.owner, request.head_branch
    );
    let response: PullRequestSearchResponse = client
        .graphql(
            github_graphql_descriptor("task_board.github.open_pull_request_for_branch"),
            json!({
            "query": OPEN_PULL_REQUEST_FOR_BRANCH_QUERY,
            "variables": {
                "query": search,
            },
            }),
        )
        .await
        .map(|response| response.body)?;
    let Some(graphql_handle) = response.first_pull_request() else {
        return Ok(None);
    };
    let page_info = graphql_handle.review_requests.page_info.clone();
    let mut handle = graphql_handle.into_handle();
    load_remaining_review_requests(client, config, handle.number, page_info, &mut handle).await?;
    Ok(Some(handle))
}

pub(super) async fn pull_request_labels(
    client: &GitHubProtectedClient,
    config: &GitHubProjectConfig,
    pull_request_number: u64,
) -> Result<Vec<String>, CliError> {
    let response: PullRequestLabelsResponse = client
        .graphql(
            github_graphql_descriptor("task_board.github.pull_request_labels"),
            json!({
            "query": PULL_REQUEST_LABELS_QUERY,
            "variables": {
                "owner": config.owner.as_str(),
                "repo": config.repo.as_str(),
                "number": pull_request_number,
            },
            }),
        )
        .await
        .map(|response| response.body)?;
    let Some(labels_page) = response.labels_page() else {
        return Err(pull_request_not_found(config, pull_request_number));
    };
    let mut labels = labels_page
        .nodes
        .into_iter()
        .map(|label| label.name)
        .collect::<Vec<_>>();
    load_remaining_labels(
        client,
        config,
        pull_request_number,
        labels_page.page_info,
        &mut labels,
    )
    .await?;
    Ok(labels)
}

async fn load_remaining_review_requests(
    client: &GitHubProtectedClient,
    config: &GitHubProjectConfig,
    pull_request_number: u64,
    mut page_info: GitHubGraphqlPageInfo,
    handle: &mut GitHubPullRequestHandle,
) -> Result<(), CliError> {
    let mut pages = 1_u32;
    while page_info.has_next_page {
        let cursor = next_cursor(&page_info, "pull request review requests")?;
        page_limit("pull request review requests", pages)?;
        let response: PullRequestReviewRequestsResponse = client
            .graphql(
                github_graphql_descriptor("task_board.github.review_requests_page"),
                json!({
                "query": PULL_REQUEST_REVIEW_REQUESTS_QUERY,
                "variables": {
                    "owner": config.owner.as_str(),
                    "repo": config.repo.as_str(),
                    "number": pull_request_number,
                    "after": cursor,
                },
                }),
            )
            .await
            .map(|response| response.body)?;
        let Some(page) = response.review_requests_page() else {
            return Err(pull_request_not_found(config, pull_request_number));
        };
        handle.extend_review_requests(page.nodes);
        page_info = page.page_info;
        pages += 1;
    }
    Ok(())
}

async fn load_remaining_labels(
    client: &GitHubProtectedClient,
    config: &GitHubProjectConfig,
    pull_request_number: u64,
    mut page_info: GitHubGraphqlPageInfo,
    labels: &mut Vec<String>,
) -> Result<(), CliError> {
    let mut pages = 1_u32;
    while page_info.has_next_page {
        let cursor = next_cursor(&page_info, "pull request labels")?;
        page_limit("pull request labels", pages)?;
        let response: PullRequestLabelsResponse = client
            .graphql(
                github_graphql_descriptor("task_board.github.pull_request_labels_page"),
                json!({
                "query": PULL_REQUEST_LABELS_PAGE_QUERY,
                "variables": {
                    "owner": config.owner.as_str(),
                    "repo": config.repo.as_str(),
                    "number": pull_request_number,
                    "after": cursor,
                },
                }),
            )
            .await
            .map(|response| response.body)?;
        let Some(page) = response.labels_page() else {
            return Err(pull_request_not_found(config, pull_request_number));
        };
        labels.extend(page.nodes.into_iter().map(|label| label.name));
        page_info = page.page_info;
        pages += 1;
    }
    Ok(())
}

fn next_cursor(page_info: &GitHubGraphqlPageInfo, page: &str) -> Result<String, CliError> {
    page_info
        .end_cursor
        .clone()
        .ok_or_else(|| CliErrorKind::workflow_io(format!("{page} missing GraphQL cursor")).into())
}

fn page_limit(page: &str, loaded_pages: u32) -> Result<(), CliError> {
    if loaded_pages < GRAPHQL_PAGE_LIMIT {
        return Ok(());
    }
    Err(CliErrorKind::workflow_io(format!(
        "{page} exceeded {GRAPHQL_PAGE_LIMIT} GitHub GraphQL pages"
    ))
    .into())
}

fn pull_request_not_found(config: &GitHubProjectConfig, pull_request_number: u64) -> CliError {
    CliErrorKind::workflow_io(format!(
        "task-board github pull request not found: {}/{}#{}",
        config.owner, config.repo, pull_request_number
    ))
    .into()
}

fn github_graphql_descriptor(operation: &str) -> GitHubRequestDescriptor {
    GitHubRequestDescriptor::graphql(
        operation,
        GitHubPriority::FreshRead,
        GitHubCachePolicy::read_through(Duration::from_mins(5), Duration::from_hours(1)),
    )
    .with_expected_cost(5)
}

const PULL_REQUEST_HANDLE_QUERY: &str = r"
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      ...PullRequestHandleFields
    }
  }
}

fragment PullRequestHandleFields on PullRequest {
  number
  url
  isDraft
  merged
  headRefOid
  headRefName
  headRepository { nameWithOwner }
  reviewRequests(first: 100) {
    pageInfo { hasNextPage endCursor }
    nodes {
      requestedReviewer {
        __typename
        ... on User { login }
        ... on Team { slug }
      }
    }
  }
}
";

const OPEN_PULL_REQUEST_FOR_BRANCH_QUERY: &str = r"
query($query: String!) {
  search(query: $query, type: ISSUE, first: 1) {
    nodes {
      ... on PullRequest {
        ...PullRequestHandleFields
      }
    }
  }
}

fragment PullRequestHandleFields on PullRequest {
  number
  url
  isDraft
  merged
  headRefOid
  headRefName
  headRepository { nameWithOwner }
  reviewRequests(first: 100) {
    pageInfo { hasNextPage endCursor }
    nodes {
      requestedReviewer {
        __typename
        ... on User { login }
        ... on Team { slug }
      }
    }
  }
}
";

const PULL_REQUEST_REVIEW_REQUESTS_QUERY: &str = r"
query($owner: String!, $repo: String!, $number: Int!, $after: String!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewRequests(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          requestedReviewer {
            __typename
            ... on User { login }
            ... on Team { slug }
          }
        }
      }
    }
  }
}
";

const PULL_REQUEST_LABELS_QUERY: &str = r"
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      labels(first: 100) {
        pageInfo { hasNextPage endCursor }
        nodes { name }
      }
    }
  }
}
";

const PULL_REQUEST_LABELS_PAGE_QUERY: &str = r"
query($owner: String!, $repo: String!, $number: Int!, $after: String!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      labels(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { name }
      }
    }
  }
}
";

#[derive(Debug, Deserialize)]
struct PullRequestHandleResponse {
    repository: Option<GraphqlRepository>,
}

impl PullRequestHandleResponse {
    fn pull_request(self) -> Option<GraphqlPullRequestHandle> {
        self.repository.and_then(|repo| repo.pull_request)
    }
}

#[derive(Debug, Deserialize)]
struct PullRequestSearchResponse {
    search: GraphqlSearch,
}

impl PullRequestSearchResponse {
    fn first_pull_request(self) -> Option<GraphqlPullRequestHandle> {
        self.search.nodes.into_iter().flatten().next()
    }
}

#[derive(Debug, Deserialize)]
struct PullRequestReviewRequestsResponse {
    repository: Option<GraphqlReviewRequestsRepository>,
}

impl PullRequestReviewRequestsResponse {
    fn review_requests_page(self) -> Option<GitHubGraphqlConnection<GraphqlReviewRequest>> {
        self.repository
            .and_then(|repo| repo.pull_request)
            .map(|pull_request| pull_request.review_requests)
    }
}

#[derive(Debug, Deserialize)]
struct PullRequestLabelsResponse {
    repository: Option<GraphqlLabelsRepository>,
}

impl PullRequestLabelsResponse {
    fn labels_page(self) -> Option<GitHubGraphqlConnection<GraphqlLabel>> {
        self.repository
            .and_then(|repo| repo.pull_request)
            .and_then(|pull_request| pull_request.labels)
    }
}

#[derive(Debug, Deserialize)]
struct GraphqlRepository {
    #[serde(rename = "pullRequest")]
    pull_request: Option<GraphqlPullRequestHandle>,
}

#[derive(Debug, Deserialize)]
struct GraphqlSearch {
    nodes: Vec<Option<GraphqlPullRequestHandle>>,
}

#[derive(Debug, Deserialize)]
struct GraphqlReviewRequestsRepository {
    #[serde(rename = "pullRequest")]
    pull_request: Option<GraphqlReviewRequestsPullRequest>,
}

#[derive(Debug, Deserialize)]
struct GraphqlReviewRequestsPullRequest {
    #[serde(rename = "reviewRequests")]
    review_requests: GitHubGraphqlConnection<GraphqlReviewRequest>,
}

#[derive(Debug, Deserialize)]
struct GraphqlLabelsRepository {
    #[serde(rename = "pullRequest")]
    pull_request: Option<GraphqlLabelsPullRequest>,
}

#[derive(Debug, Deserialize)]
struct GraphqlLabelsPullRequest {
    labels: Option<GitHubGraphqlConnection<GraphqlLabel>>,
}

#[derive(Debug, Deserialize)]
struct GraphqlPullRequestHandle {
    number: u64,
    url: String,
    #[serde(rename = "isDraft")]
    is_draft: bool,
    merged: bool,
    #[serde(rename = "headRefOid")]
    head_ref_oid: String,
    #[serde(rename = "headRefName")]
    head_ref_name: Option<String>,
    #[serde(rename = "headRepository")]
    head_repository: Option<GraphqlHeadRepository>,
    #[serde(rename = "reviewRequests")]
    review_requests: GitHubGraphqlConnection<GraphqlReviewRequest>,
}

impl GraphqlPullRequestHandle {
    fn into_handle(self) -> GitHubPullRequestHandle {
        let mut handle = GitHubPullRequestHandle {
            number: self.number,
            html_url: Some(self.url),
            draft: self.is_draft,
            merged: self.merged,
            head_sha: self.head_ref_oid,
            head_repository: self.head_repository.map(|repo| repo.name_with_owner),
            head_branch: self.head_ref_name,
            requested_reviewers: Vec::new(),
            requested_team_reviewers: Vec::new(),
        };
        handle.extend_review_requests(self.review_requests.nodes);
        handle
    }
}

#[derive(Debug, Deserialize)]
struct GraphqlHeadRepository {
    #[serde(rename = "nameWithOwner")]
    name_with_owner: String,
}

#[derive(Debug, Deserialize)]
struct GitHubGraphqlConnection<T> {
    #[serde(rename = "pageInfo")]
    page_info: GitHubGraphqlPageInfo,
    nodes: Vec<T>,
}

#[derive(Debug, Clone, Deserialize)]
struct GitHubGraphqlPageInfo {
    #[serde(rename = "hasNextPage")]
    has_next_page: bool,
    #[serde(rename = "endCursor")]
    end_cursor: Option<String>,
}

#[derive(Debug, Deserialize)]
struct GraphqlReviewRequest {
    #[serde(rename = "requestedReviewer")]
    requested_reviewer: Option<GraphqlRequestedReviewer>,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "__typename")]
enum GraphqlRequestedReviewer {
    User {
        login: String,
    },
    Team {
        slug: String,
    },
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Deserialize)]
struct GraphqlLabel {
    name: String,
}

trait GitHubPullRequestHandleExt {
    fn extend_review_requests(&mut self, nodes: Vec<GraphqlReviewRequest>);
}

impl GitHubPullRequestHandleExt for GitHubPullRequestHandle {
    fn extend_review_requests(&mut self, nodes: Vec<GraphqlReviewRequest>) {
        for node in nodes {
            match node.requested_reviewer {
                Some(GraphqlRequestedReviewer::User { login }) => {
                    self.requested_reviewers.push(login);
                }
                Some(GraphqlRequestedReviewer::Team { slug }) => {
                    self.requested_team_reviewers.push(slug);
                }
                Some(GraphqlRequestedReviewer::Unknown) | None => {}
            }
        }
    }
}
