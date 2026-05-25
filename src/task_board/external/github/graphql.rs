use std::collections::BTreeMap;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::json;

use crate::errors::{CliError, CliErrorKind};
use crate::github_api::{
    GitHubCachePolicy, GitHubPriority, GitHubProtectedClient, GitHubRequestDescriptor,
};

use super::{GitHubRepository, assigned_issue_query, author_issue_query, warn_github_message};

pub(super) const GITHUB_SEARCH_PAGE_CAP: u32 = 10;

const GITHUB_SEARCH_PAGE_SIZE: u32 = 100;
const AUTOMATION_ISSUE_AUTHORS: &[&str] = &["renovate[bot]"];
const HOURS: u64 = 60 * 60;
const DAYS: u64 = 24 * HOURS;
const GITHUB_GRAPHQL_CACHE_TTL: Duration = Duration::from_secs(60);
const GITHUB_GRAPHQL_CACHE_ENTRY_CAP: usize = 128;

pub(super) type GitHubGraphqlCacheKey = u64;

static VIEWER_CACHE: OnceLock<Mutex<BTreeMap<GitHubGraphqlCacheKey, CachedViewerLogin>>> =
    OnceLock::new();
static SEARCH_CACHE: OnceLock<
    Mutex<BTreeMap<(GitHubGraphqlCacheKey, String), CachedSearchResults>>,
> = OnceLock::new();

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

pub(super) fn token_cache_key(token: &str) -> GitHubGraphqlCacheKey {
    let mut hasher = DefaultHasher::new();
    token.hash(&mut hasher);
    hasher.finish()
}

pub(super) async fn current_user_login(
    client: &GitHubProtectedClient,
    cache_key: GitHubGraphqlCacheKey,
) -> Result<String, CliError> {
    if let Some(login) = cached_viewer_login(cache_key) {
        return Ok(login);
    }
    let response: GitHubViewerResponse = client
        .graphql(
            GitHubRequestDescriptor::graphql(
                "task_board.github.viewer",
                GitHubPriority::NormalRead,
                GitHubCachePolicy::read_through(
                    Duration::from_secs(24 * HOURS),
                    Duration::from_secs(7 * DAYS),
                ),
            ),
            json!({ "query": VIEWER_QUERY }),
        )
        .await
        .map(|response| response.body)?;
    let login = response.viewer.login.trim();
    if login.is_empty() {
        return Err(CliErrorKind::workflow_io(
            "loading authenticated GitHub viewer returned an empty login",
        )
        .into());
    }
    store_viewer_login(cache_key, login);
    Ok(login.to_string())
}

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
    cache_key: GitHubGraphqlCacheKey,
    query: &str,
    context: &str,
) -> Result<Vec<GitHubSearchIssuePullRequestItem>, CliError> {
    if let Some(items) = cached_search_results(cache_key, query) {
        return Ok(items);
    }
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
                        Duration::from_mins(60),
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
    store_search_results(cache_key, query, &items);
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

fn cached_viewer_login(cache_key: GitHubGraphqlCacheKey) -> Option<String> {
    let mut cache = VIEWER_CACHE
        .get_or_init(|| Mutex::new(BTreeMap::new()))
        .lock()
        .ok()?;
    prune_viewer_cache(&mut cache);
    cache.get(&cache_key).map(|cached| cached.login.clone())
}

fn store_viewer_login(cache_key: GitHubGraphqlCacheKey, login: &str) {
    if let Ok(mut cache) = VIEWER_CACHE
        .get_or_init(|| Mutex::new(BTreeMap::new()))
        .lock()
    {
        prune_viewer_cache(&mut cache);
        cache.insert(
            cache_key,
            CachedViewerLogin {
                login: login.to_owned(),
                stored_at: Instant::now(),
            },
        );
        trim_viewer_cache(&mut cache);
    }
}

fn cached_search_results(
    cache_key: GitHubGraphqlCacheKey,
    query: &str,
) -> Option<Vec<GitHubSearchIssuePullRequestItem>> {
    let mut cache = SEARCH_CACHE
        .get_or_init(|| Mutex::new(BTreeMap::new()))
        .lock()
        .ok()?;
    prune_search_cache(&mut cache);
    cache
        .get(&(cache_key, query.to_owned()))
        .map(|cached| cached.items.clone())
}

fn store_search_results(
    cache_key: GitHubGraphqlCacheKey,
    query: &str,
    items: &[GitHubSearchIssuePullRequestItem],
) {
    if let Ok(mut cache) = SEARCH_CACHE
        .get_or_init(|| Mutex::new(BTreeMap::new()))
        .lock()
    {
        prune_search_cache(&mut cache);
        cache.insert(
            (cache_key, query.to_owned()),
            CachedSearchResults {
                items: items.to_vec(),
                stored_at: Instant::now(),
            },
        );
        trim_search_cache(&mut cache);
    }
}

fn prune_viewer_cache(cache: &mut BTreeMap<GitHubGraphqlCacheKey, CachedViewerLogin>) {
    cache.retain(|_, cached| cached.is_fresh());
}

fn prune_search_cache(cache: &mut BTreeMap<(GitHubGraphqlCacheKey, String), CachedSearchResults>) {
    cache.retain(|_, cached| cached.is_fresh());
}

fn trim_viewer_cache(cache: &mut BTreeMap<GitHubGraphqlCacheKey, CachedViewerLogin>) {
    while cache.len() > GITHUB_GRAPHQL_CACHE_ENTRY_CAP {
        let Some(key) = cache
            .iter()
            .min_by_key(|(_, cached)| cached.stored_at)
            .map(|(key, _)| *key)
        else {
            break;
        };
        cache.remove(&key);
    }
}

fn trim_search_cache(cache: &mut BTreeMap<(GitHubGraphqlCacheKey, String), CachedSearchResults>) {
    while cache.len() > GITHUB_GRAPHQL_CACHE_ENTRY_CAP {
        let Some(key) = cache
            .iter()
            .min_by_key(|(_, cached)| cached.stored_at)
            .map(|(key, _)| key.clone())
        else {
            break;
        };
        cache.remove(&key);
    }
}

fn warn_search_results_truncated(context: &str) {
    warn_github_message(&format!(
        "github search results truncated at {} hits while {context}",
        GITHUB_SEARCH_PAGE_CAP * GITHUB_SEARCH_PAGE_SIZE
    ));
}

#[derive(Debug, Clone)]
struct CachedViewerLogin {
    login: String,
    stored_at: Instant,
}

impl CachedViewerLogin {
    fn is_fresh(&self) -> bool {
        self.stored_at.elapsed() <= GITHUB_GRAPHQL_CACHE_TTL
    }
}

#[derive(Debug, Clone)]
struct CachedSearchResults {
    items: Vec<GitHubSearchIssuePullRequestItem>,
    stored_at: Instant,
}

impl CachedSearchResults {
    fn is_fresh(&self) -> bool {
        self.stored_at.elapsed() <= GITHUB_GRAPHQL_CACHE_TTL
    }
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
mod tests;
