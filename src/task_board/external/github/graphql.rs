use octocrab::Octocrab;
use serde::Deserialize;
use serde_json::json;

use crate::errors::{CliError, CliErrorKind};

use super::{
    GitHubRepository, assigned_issue_query, author_issue_query, github_sync_error_with_context,
    warn_github_message,
};

pub(super) const GITHUB_SEARCH_PAGE_CAP: u32 = 10;

const GITHUB_SEARCH_PAGE_SIZE: usize = 100;
const AUTOMATION_ISSUE_AUTHORS: &[&str] = &["renovate[bot]"];

const VIEWER_QUERY: &str = r"
query TaskBoardViewer {
  viewer {
    login
  }
}
";

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

pub(super) async fn current_user_login(client: &Octocrab) -> Result<String, CliError> {
    let response: GitHubViewerResponse = client
        .graphql(&json!({ "query": VIEWER_QUERY }))
        .await
        .map_err(|error| {
            github_sync_error_with_context("loading authenticated GitHub viewer", error)
        })?;
    let login = response.viewer.login.trim();
    if login.is_empty() {
        return Err(CliErrorKind::workflow_io(
            "loading authenticated GitHub viewer returned an empty login",
        )
        .into());
    }
    Ok(login.to_string())
}

pub(super) async fn issue_updated_at(
    client: &Octocrab,
    repository: &GitHubRepository,
    issue_number: u64,
) -> Result<String, CliError> {
    let response: GitHubIssueUpdatedAtResponse = client
        .graphql(&json!({
            "query": ISSUE_UPDATED_AT_QUERY,
            "variables": {
                "owner": repository.owner.as_str(),
                "repo": repository.repo.as_str(),
                "number": issue_number,
            },
        }))
        .await
        .map_err(|error| {
            github_sync_error_with_context(
                format!("loading issue {issue_number} in {}", repository.slug()),
                error,
            )
        })?;
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
    client: &Octocrab,
    query: &str,
    context: &str,
) -> Result<Vec<GitHubSearchIssuePullRequestItem>, CliError> {
    let mut cursor = None;
    let mut page = 1_u32;
    let mut items = Vec::new();
    loop {
        let response: GitHubSearchIssuePullRequestResponse = client
            .graphql(&json!({
                "query": ISSUE_SEARCH_QUERY,
                "variables": {
                    "query": query,
                    "after": cursor.as_deref(),
                },
            }))
            .await
            .map_err(|error| github_sync_error_with_context(context, error))?;
        items.extend(response.search.nodes.into_iter().flatten());
        if !response.search.page_info.has_next_page {
            break;
        }
        if page >= GITHUB_SEARCH_PAGE_CAP {
            warn_search_results_truncated(context);
            break;
        }
        page += 1;
        cursor = response.search.page_info.end_cursor;
    }
    Ok(items)
}

fn warn_search_results_truncated(context: &str) {
    warn_github_message(&format!(
        "github search results truncated at {} hits while {context}",
        GITHUB_SEARCH_PAGE_CAP * GITHUB_SEARCH_PAGE_SIZE as u32
    ));
}

#[derive(Debug, Deserialize)]
struct GitHubViewerResponse {
    viewer: GitHubViewer,
}

#[derive(Debug, Deserialize)]
struct GitHubViewer {
    login: String,
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
mod tests {
    use super::*;

    #[test]
    fn personal_issue_queries_scope_to_user_and_renovate() {
        let repository = GitHubRepository {
            owner: "owner".into(),
            repo: "repo".into(),
        };

        assert_eq!(
            personal_issue_queries(&repository, "octo-user"),
            vec![
                "repo:owner/repo is:issue assignee:octo-user state:all",
                "repo:owner/repo is:issue author:octo-user state:all",
                "repo:owner/repo is:issue author:renovate[bot] state:all",
            ]
        );
    }

    #[test]
    fn graphql_search_item_deserializes_label_names() {
        let payload = json!({
            "number": 42,
            "title": "Fix bug",
            "body": null,
            "url": "https://example.com/i/42",
            "state": "OPEN",
            "updatedAt": "2026-05-15T00:00:00Z",
            "labels": {
                "nodes": [{ "name": "needs-fix" }, { "name": "automation" }]
            }
        });

        let item: GitHubSearchIssuePullRequestItem =
            serde_json::from_value(payload).expect("deserialize search item");

        assert_eq!(
            item.label_names(),
            vec!["needs-fix".to_string(), "automation".to_string()]
        );
    }

    #[test]
    fn issue_updated_at_response_deserializes_minimal_payload() {
        let payload = json!({
            "repository": {
                "issue": {
                    "updatedAt": "2026-05-20T12:00:00Z"
                }
            }
        });
        let response: GitHubIssueUpdatedAtResponse =
            serde_json::from_value(payload).expect("deserialize issue timestamp");

        assert_eq!(
            response
                .repository
                .and_then(|repository| repository.issue)
                .map(|issue| issue.updated_at),
            Some("2026-05-20T12:00:00Z".to_string())
        );
    }

    #[test]
    fn github_search_page_cap_keeps_total_hits_under_one_thousand() {
        assert_eq!(GITHUB_SEARCH_PAGE_CAP, 10);
    }
}
