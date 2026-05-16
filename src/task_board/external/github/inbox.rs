use std::fmt;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::external::{
    ExternalProvider, ExternalSyncClient, ExternalSyncConfig, ExternalTask, ExternalTaskRef,
    normalize_token,
};
use crate::task_board::types::{TaskBoardItem, TaskBoardStatus};

use super::{
    GitHubRepository, assigned_issue_query, ensure_rustls_provider, github_client_error,
    github_external_id, github_inbox_issue_status, github_sync_error, parse_github_repository,
    review_request_query, search_label_matches_filter,
};

const GITHUB_SEARCH_PAGE_CAP: u32 = 10;

#[derive(Clone)]
pub struct GitHubInboxSyncClient {
    client: octocrab::Octocrab,
    repositories: Vec<GitHubRepository>,
    import_labels: Vec<String>,
}

impl GitHubInboxSyncClient {
    /// Build a GitHub inbox client from token and repositories.
    ///
    /// # Errors
    /// Returns an error when the token is empty, repositories are invalid, or
    /// the SDK client cannot be built.
    pub fn new(token: impl Into<String>, repositories: &[String]) -> Result<Self, CliError> {
        Self::new_with_labels(token, repositories, &[])
    }

    /// Build a GitHub inbox client with an optional label filter applied to issue
    /// searches.
    ///
    /// # Errors
    /// Returns an error when the token is empty, repositories are invalid, or
    /// the SDK client cannot be built.
    pub fn new_with_labels(
        token: impl Into<String>,
        repositories: &[String],
        import_labels: &[String],
    ) -> Result<Self, CliError> {
        let token = normalize_token(ExternalProvider::GitHub, token)?;
        ensure_rustls_provider();
        let client = octocrab::Octocrab::builder()
            .personal_token(token)
            .build()
            .map_err(github_client_error)?;
        let repositories = repositories
            .iter()
            .map(String::as_str)
            .map(parse_github_repository)
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Self {
            client,
            repositories,
            import_labels: import_labels.to_vec(),
        })
    }

    /// Build a GitHub inbox client from external sync config.
    ///
    /// # Errors
    /// Returns an error when no GitHub token is configured or repositories are invalid.
    pub fn from_config(config: &ExternalSyncConfig) -> Result<Self, CliError> {
        Self::new_with_labels(
            config.require_token(ExternalProvider::GitHub)?,
            config.github_inbox_repositories(),
            config.github_import_labels(),
        )
    }

    async fn current_user_login(&self) -> Result<String, CliError> {
        let user: GitHubCurrentUser = self
            .client
            .get("/user", None::<&()>)
            .await
            .map_err(github_sync_error)?;
        Ok(user.login)
    }

    async fn search(&self, query: &str) -> Result<Vec<GitHubSearchIssuePullRequestItem>, CliError> {
        let mut page = 1_u32;
        let mut items = Vec::new();
        loop {
            let response: GitHubSearchIssuePullRequestResponse = self
                .client
                .get(
                    "/search/issues",
                    Some(&GitHubSearchIssuePullRequestQuery {
                        q: query.to_owned(),
                        per_page: 100,
                        page,
                    }),
                )
                .await
                .map_err(github_sync_error)?;
            let count = response.items.len();
            items.extend(response.items);
            match next_search_page(count, page) {
                Some(next_page) => page = next_page,
                None => break,
            }
        }
        Ok(items)
    }
}

fn next_search_page(count: usize, page: u32) -> Option<u32> {
    if count < 100 {
        return None;
    }
    if page >= GITHUB_SEARCH_PAGE_CAP {
        warn_search_results_truncated();
        return None;
    }
    Some(page + 1)
}

#[allow(clippy::cognitive_complexity)]
fn warn_search_results_truncated() {
    tracing::warn!(
        target: "harness::task_board::external::github::inbox",
        "github search results truncated at {} hits",
        GITHUB_SEARCH_PAGE_CAP * 100
    );
}

impl fmt::Debug for GitHubInboxSyncClient {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("GitHubInboxSyncClient")
            .field("provider", &ExternalProvider::GitHub)
            .field("repositories", &self.repositories)
            .finish_non_exhaustive()
    }
}

#[async_trait]
impl ExternalSyncClient for GitHubInboxSyncClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::GitHub
    }

    fn allows_push(&self) -> bool {
        false
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        if self.repositories.is_empty() {
            return Ok(Vec::new());
        }
        let login = self.current_user_login().await?;
        let mut tasks = Vec::new();
        for repository in &self.repositories {
            tasks.extend(
                self.assigned_issue_tasks(repository, login.as_str())
                    .await?,
            );
            tasks.extend(
                self.review_request_tasks(repository, login.as_str())
                    .await?,
            );
        }
        Ok(tasks)
    }

    async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        Err(CliErrorKind::workflow_io(
            "task-board github inbox sync is pull-only and cannot create remote items",
        )
        .into())
    }
}

impl GitHubInboxSyncClient {
    async fn assigned_issue_tasks(
        &self,
        repository: &GitHubRepository,
        login: &str,
    ) -> Result<Vec<ExternalTask>, CliError> {
        let project_id = repository.slug();
        let items = self
            .search(assigned_issue_query(repository, login).as_str())
            .await?;
        Ok(items
            .into_iter()
            .filter(|item| search_label_matches_filter(&item.label_names(), &self.import_labels))
            .map(|item| ExternalTask {
                reference: github_task_ref(repository, item.number, item.html_url),
                title: item.title,
                body: item.body.unwrap_or_default(),
                status: github_inbox_issue_status(item.state.as_str()),
                project_id: Some(project_id.clone()),
                updated_at: Some(item.updated_at),
            })
            .collect())
    }

    async fn review_request_tasks(
        &self,
        repository: &GitHubRepository,
        login: &str,
    ) -> Result<Vec<ExternalTask>, CliError> {
        let project_id = repository.slug();
        let items = self
            .search(review_request_query(repository, login).as_str())
            .await?;
        Ok(items
            .into_iter()
            .filter(|item| search_label_matches_filter(&item.label_names(), &self.import_labels))
            .map(|item| ExternalTask {
                reference: github_task_ref(repository, item.number, item.html_url),
                title: item.title,
                body: item.body.unwrap_or_default(),
                status: TaskBoardStatus::NeedsYou,
                project_id: Some(project_id.clone()),
                updated_at: Some(item.updated_at),
            })
            .collect())
    }
}

fn github_task_ref(
    repository: &GitHubRepository,
    number: u64,
    html_url: String,
) -> ExternalTaskRef {
    ExternalTaskRef::new(
        ExternalProvider::GitHub,
        github_external_id(repository, number),
    )
    .with_url(html_url)
}

#[derive(Debug, Clone, Deserialize)]
struct GitHubCurrentUser {
    login: String,
}

#[derive(Debug, Clone, Deserialize)]
struct GitHubSearchIssuePullRequestResponse {
    items: Vec<GitHubSearchIssuePullRequestItem>,
}

#[derive(Debug, Clone, Deserialize)]
struct GitHubSearchIssuePullRequestItem {
    number: u64,
    title: String,
    #[serde(default)]
    body: Option<String>,
    html_url: String,
    state: String,
    updated_at: String,
    #[serde(default)]
    labels: Vec<GitHubSearchLabel>,
}

impl GitHubSearchIssuePullRequestItem {
    fn label_names(&self) -> Vec<String> {
        self.labels.iter().map(|label| label.name.clone()).collect()
    }
}

#[derive(Debug, Clone, Deserialize)]
struct GitHubSearchLabel {
    name: String,
}

#[derive(Debug, Clone, Serialize)]
struct GitHubSearchIssuePullRequestQuery {
    q: String,
    per_page: u8,
    page: u32,
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn github_inbox_search_queries_scope_assigned_issues_and_review_requests() {
        let repository = parse_github_repository("owner/repo").expect("repository");

        assert_eq!(
            assigned_issue_query(&repository, "octo-user"),
            "repo:owner/repo is:issue assignee:octo-user state:all"
        );
        assert_eq!(
            review_request_query(&repository, "octo-user"),
            "repo:owner/repo is:pr review-requested:octo-user state:open"
        );
    }

    #[test]
    fn github_inbox_search_payload_serializes_query_page_and_page_size() {
        let payload = GitHubSearchIssuePullRequestQuery {
            q: "repo:owner/repo is:pr review-requested:octo-user state:open".into(),
            per_page: 100,
            page: 2,
        };

        assert_eq!(
            serde_json::to_value(payload).expect("serialize payload"),
            json!({
                "q": "repo:owner/repo is:pr review-requested:octo-user state:open",
                "per_page": 100,
                "page": 2
            })
        );
    }

    #[test]
    fn github_inbox_search_item_deserializes_label_names() {
        let payload = json!({
            "number": 42,
            "title": "Fix bug",
            "body": null,
            "html_url": "https://example.com/i/42",
            "state": "open",
            "updated_at": "2026-05-15T00:00:00Z",
            "labels": [{ "name": "needs-fix" }, { "name": "automation" }]
        });

        let item: GitHubSearchIssuePullRequestItem =
            serde_json::from_value(payload).expect("deserialize search item");

        assert_eq!(
            item.label_names(),
            vec!["needs-fix".to_string(), "automation".to_string()]
        );
    }

    #[test]
    fn search_label_filter_admits_only_matching_labels() {
        assert!(search_label_matches_filter(
            &["bug".into(), "automation".into()],
            &["automation".into()]
        ));
        assert!(!search_label_matches_filter(
            &["docs".into()],
            &["automation".into()]
        ));
        assert!(search_label_matches_filter(
            &["bug".into()],
            &[" Bug ".into()]
        ));
        assert!(search_label_matches_filter(&["bug".into()], &[]));
    }

    #[test]
    fn github_search_page_cap_keeps_total_hits_under_one_thousand() {
        assert_eq!(GITHUB_SEARCH_PAGE_CAP, 10);
        // 10 pages * 100 per page = 1000 total hits before truncation.
    }
}
