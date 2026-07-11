use std::time::Duration;

use serde::Deserialize;
use serde_json::json;

use crate::errors::{CliError, CliErrorKind};
use crate::github_api::{
    GitHubCachePolicy, GitHubPriority, GitHubProtectedClient, GitHubRequestDescriptor,
    retry_stable_read,
};

use super::{GitHubRepository, assigned_issue_query, author_issue_query, warn_github_message};

pub(super) const GITHUB_SEARCH_PAGE_CAP: u32 = 10;

const GITHUB_SEARCH_PAGE_SIZE: u32 = 100;
const AUTOMATION_ISSUE_AUTHORS: &[&str] = &["renovate[bot]"];
const GITHUB_GRAPHQL_CACHE_TTL: Duration = Duration::from_mins(1);

const ISSUE_SEARCH_QUERY: &str = r"
query TaskBoardGitHubSearch($query: String!, $after: String) {
  search(query: $query, type: ISSUE, first: 100, after: $after) {
    pageInfo {
      hasNextPage
      endCursor
    }
    nodes {
      ... on Issue {
        number
        title
        body
        url
        state
        updatedAt
        labels(first: 20) {
          nodes {
            name
          }
        }
      }
      ... on PullRequest {
        number
        title
        body
        url
        state
        updatedAt
        labels(first: 20) {
          nodes {
            name
          }
        }
      }
    }
  }
}
";

const ISSUE_UPDATED_AT_QUERY: &str = r"
query TaskBoardIssueUpdatedAt($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      updatedAt
    }
  }
}
";

pub(super) async fn issue_updated_at(
    client: &GitHubProtectedClient,
    repository: &GitHubRepository,
    issue_number: u64,
) -> Result<String, CliError> {
    let response: GitHubIssueUpdatedAtResponse = client
        .graphql(
            GitHubRequestDescriptor::graphql(
                "task_board.github.issue_updated_at",
                GitHubPriority::FreshRead,
                GitHubCachePolicy::no_store(),
            ),
            json!({
            "query": ISSUE_UPDATED_AT_QUERY,
            "variables": {
                "owner": repository.owner.as_str(),
                "repo": repository.repo.as_str(),
                "number": issue_number,
            },
            }),
        )
        .await
        .map(|response| response.body)?;
    response
        .repository
        .and_then(|repository| repository.issue)
        .map(|issue| issue.updated_at)
        .ok_or_else(|| {
            CliErrorKind::workflow_io(format!(
                "loading issue {issue_number} in {} returned no issue",
                repository.slug()
            ))
            .into()
        })
}

pub(super) fn personal_issue_queries(repository: &GitHubRepository, login: &str) -> Vec<String> {
    let mut queries = vec![
        assigned_issue_query(repository, login),
        author_issue_query(repository, login),
    ];
    for author in AUTOMATION_ISSUE_AUTHORS {
        if !author.eq_ignore_ascii_case(login) {
            queries.push(author_issue_query(repository, author));
        }
    }
    queries.sort();
    queries.dedup();
    queries
}

pub(super) async fn search_issue_pull_requests(
    client: &GitHubProtectedClient,
    query: &str,
    context: &str,
) -> Result<Vec<GitHubSearchIssuePullRequestItem>, CliError> {
    retry_stable_read("task_board.github.search_issues", |_| {
        search_issue_pull_requests_at_revision(client, query, context)
    })
    .await
    .map(|(items, _)| items)
}

async fn search_issue_pull_requests_at_revision(
    client: &GitHubProtectedClient,
    query: &str,
    context: &str,
) -> Result<Vec<GitHubSearchIssuePullRequestItem>, CliError> {
    let mut cursor = None;
    let mut page = 1_u32;
    let mut items = Vec::new();
    loop {
        let response: GitHubSearchIssuePullRequestResponse = client
            .graphql(
                GitHubRequestDescriptor::graphql(
                    "task_board.github.search_issues",
                    GitHubPriority::Background,
                    GitHubCachePolicy::read_through(
                        GITHUB_GRAPHQL_CACHE_TTL,
                        Duration::from_hours(1),
                    ),
                )
                .with_expected_cost(20),
                json!({
                "query": ISSUE_SEARCH_QUERY,
                "variables": {
                    "query": query,
                    "after": cursor.as_deref(),
                },
                }),
            )
            .await
            .map(|response| response.body)?;
        let page_info = response.search.page_info;
        items.extend(response.search.nodes.into_iter().flatten());
        let Some(next_cursor) = next_search_cursor(page, context, page_info)? else {
            break;
        };
        page += 1;
        cursor = Some(next_cursor);
    }
    Ok(items)
}

fn next_search_cursor(
    page: u32,
    context: &str,
    page_info: GitHubSearchPageInfo,
) -> Result<Option<String>, CliError> {
    if !page_info.has_next_page {
        return Ok(None);
    }
    if page >= GITHUB_SEARCH_PAGE_CAP {
        warn_search_results_truncated(context);
        return Ok(None);
    }
    page_info.end_cursor.map(Some).ok_or_else(|| {
        CliErrorKind::workflow_io(format!(
            "github search pagination returned a next page without a cursor while {context}"
        ))
        .into()
    })
}

fn warn_search_results_truncated(context: &str) {
    warn_github_message(&format!(
        "github search results truncated at {} hits while {context}",
        GITHUB_SEARCH_PAGE_CAP * GITHUB_SEARCH_PAGE_SIZE
    ));
}

#[derive(Debug, Deserialize)]
struct GitHubIssueUpdatedAtResponse {
    repository: Option<GitHubIssueUpdatedAtRepository>,
}

#[derive(Debug, Deserialize)]
struct GitHubIssueUpdatedAtRepository {
    issue: Option<GitHubIssueUpdatedAtNode>,
}

#[derive(Debug, Deserialize)]
struct GitHubIssueUpdatedAtNode {
    #[serde(rename = "updatedAt")]
    updated_at: String,
}

#[derive(Debug, Deserialize)]
struct GitHubSearchIssuePullRequestResponse {
    search: GitHubSearchConnection,
}

#[derive(Debug, Deserialize)]
struct GitHubSearchConnection {
    #[serde(rename = "pageInfo")]
    page_info: GitHubSearchPageInfo,
    nodes: Vec<Option<GitHubSearchIssuePullRequestItem>>,
}

#[derive(Debug, Deserialize)]
struct GitHubSearchPageInfo {
    #[serde(rename = "hasNextPage")]
    has_next_page: bool,
    #[serde(rename = "endCursor")]
    end_cursor: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub(super) struct GitHubSearchIssuePullRequestItem {
    pub(super) number: u64,
    pub(super) title: String,
    #[serde(default)]
    pub(super) body: Option<String>,
    pub(super) url: String,
    pub(super) state: String,
    #[serde(rename = "updatedAt")]
    pub(super) updated_at: String,
    #[serde(default)]
    labels: GitHubSearchLabelConnection,
}

impl GitHubSearchIssuePullRequestItem {
    pub(super) fn label_names(&self) -> Vec<String> {
        self.labels
            .nodes
            .iter()
            .map(|label| label.name.clone())
            .collect()
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
struct GitHubSearchLabelConnection {
    #[serde(default)]
    nodes: Vec<GitHubSearchLabel>,
}

#[derive(Debug, Clone, Deserialize)]
struct GitHubSearchLabel {
    name: String,
}

#[cfg(test)]
mod tests;
