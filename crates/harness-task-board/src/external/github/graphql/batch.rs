use std::collections::HashMap;
use std::time::Duration;

use futures_util::future::join_all;
use serde_json::json;

use harness_github_api::{
    GitHubCachePolicy, GitHubPriority, GitHubProtectedClient, GitHubRequestDescriptor,
    retry_stable_read,
};
use harness_kernel::errors::{CliError, CliErrorKind};

use super::{
    GITHUB_GRAPHQL_CACHE_TTL, GitHubSearchConnection, GitHubSearchIssuePullRequestItem,
    search_issue_pull_requests_from_connection,
};

const ISSUE_BATCH_SEARCH_FRAGMENT: &str = r"
fragment TaskBoardInboxSearch on SearchResultItemConnection {
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
      repository { nameWithOwner }
      labels(first: 20) { nodes { name } }
    }
    ... on PullRequest {
      number
      title
      body
      url
      state
      updatedAt
      headRefOid
      repository { nameWithOwner }
      author { login }
      labels(first: 20) { nodes { name } }
    }
  }
}
";

const FULL_SEARCH_PAGE_SIZE: u32 = 100;

pub(in crate::external::github) async fn search_issue_pull_requests_batch(
    client: &GitHubProtectedClient,
    queries: &[String],
    contexts: &[String],
    fresh: bool,
) -> Result<Vec<Result<GitHubBatchSearchResult, String>>, CliError> {
    if queries.len() != contexts.len() {
        return Err(CliErrorKind::workflow_parse(
            "github inbox batch query/context count mismatch",
        )
        .into());
    }
    retry_stable_read("task_board.github.search_issues_batch", |_| {
        search_issue_pull_requests_batch_at_revision(client, queries, contexts, fresh)
    })
    .await
    .map(|(results, _)| results)
}

async fn search_issue_pull_requests_batch_at_revision(
    client: &GitHubProtectedClient,
    queries: &[String],
    contexts: &[String],
    fresh: bool,
) -> Result<Vec<Result<GitHubBatchSearchResult, String>>, CliError> {
    let query = batch_query_document(queries.len());
    let variables = queries
        .iter()
        .enumerate()
        .map(|(index, query)| (format!("q{index}"), json!(query)))
        .collect::<serde_json::Map<_, _>>();
    let expected_cost = u32::try_from(queries.len())
        .unwrap_or(u32::MAX)
        .saturating_add(1);
    let response = client
        .graphql_partial_envelope(
            GitHubRequestDescriptor::graphql(
                "task_board.github.search_issues_batch",
                if fresh {
                    GitHubPriority::FreshRead
                } else {
                    GitHubPriority::Background
                },
                GitHubCachePolicy::read_through(GITHUB_GRAPHQL_CACHE_TTL, Duration::from_hours(1)),
            )
            .with_expected_cost(expected_cost),
            json!({ "query": query, "variables": variables }),
        )
        .await?
        .body;
    let errors = batch_field_errors(&response)?;
    let data = response
        .get("data")
        .and_then(serde_json::Value::as_object)
        .ok_or_else(|| {
            CliError::from(CliErrorKind::workflow_parse(
                "github inbox batch response missing data",
            ))
        })?;
    let mut fields = Vec::with_capacity(queries.len());
    for (index, (query, context)) in queries.iter().zip(contexts).enumerate() {
        let alias = format!("q{index}");
        if let Some(error) = errors.get(&alias) {
            fields.push(BatchSearchField::Failed(error.clone()));
            continue;
        }
        let connection: GitHubSearchConnection =
            serde_json::from_value(data.get(&alias).cloned().unwrap_or(serde_json::Value::Null))
                .map_err(|error| {
                    CliErrorKind::workflow_parse(format!(
                        "decode github inbox batch field {alias}: {error}"
                    ))
                })?;
        if connection.page_info.has_next_page {
            fields.push(BatchSearchField::Paginated {
                query: query.clone(),
                context: context.clone(),
                connection,
            });
        } else {
            fields.push(BatchSearchField::Ready(GitHubBatchSearchResult {
                items: connection.nodes.into_iter().flatten().collect(),
                complete: true,
            }));
        }
    }
    Ok(join_all(
        fields
            .into_iter()
            .map(|field| async move { resolve_field(client, field, fresh).await }),
    )
    .await)
}

async fn resolve_field(
    client: &GitHubProtectedClient,
    field: BatchSearchField,
    fresh: bool,
) -> Result<GitHubBatchSearchResult, String> {
    match field {
        BatchSearchField::Ready(result) => Ok(result),
        BatchSearchField::Failed(error) => Err(error),
        BatchSearchField::Paginated {
            query,
            context,
            connection,
        } => {
            search_issue_pull_requests_from_connection(client, &query, &context, connection, fresh)
                .await
                .map(|items| GitHubBatchSearchResult {
                    items,
                    complete: true,
                })
                .map_err(|error| error.to_string())
        }
    }
}

enum BatchSearchField {
    Ready(GitHubBatchSearchResult),
    Paginated {
        query: String,
        context: String,
        connection: GitHubSearchConnection,
    },
    Failed(String),
}

pub(in crate::external::github) struct GitHubBatchSearchResult {
    pub(in crate::external::github) items: Vec<GitHubSearchIssuePullRequestItem>,
    pub(in crate::external::github) complete: bool,
}

fn batch_query_document(count: usize) -> String {
    let variables = (0..count)
        .map(|index| format!("$q{index}: String!"))
        .collect::<Vec<_>>()
        .join(", ");
    let fields = (0..count)
        .map(|index| {
            format!(
                "q{index}: search(query: $q{index}, type: ISSUE, first: {FULL_SEARCH_PAGE_SIZE}) \
{{ ...TaskBoardInboxSearch }}"
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    format!(
        "query TaskBoardGitHubInboxBatch({variables}) {{\n{fields}\n}}\n\
{ISSUE_BATCH_SEARCH_FRAGMENT}"
    )
}

fn batch_field_errors(response: &serde_json::Value) -> Result<HashMap<String, String>, CliError> {
    let mut by_alias = HashMap::new();
    for error in response
        .get("errors")
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
    {
        let Some(alias) = error
            .get("path")
            .and_then(serde_json::Value::as_array)
            .and_then(|path| path.first())
            .and_then(serde_json::Value::as_str)
        else {
            return Err(CliErrorKind::workflow_io(format!("GitHub GraphQL error: {error}")).into());
        };
        let message = error
            .get("message")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("GitHub GraphQL field failed");
        by_alias.insert(alias.to_owned(), message.to_owned());
    }
    Ok(by_alias)
}
