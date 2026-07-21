use std::fmt;

use async_trait::async_trait;

use crate::errors::{CliError, CliErrorKind};
use crate::github_api::GitHubProtectedClient;
use crate::task_board::external::targeting::github_repository_for_item;
use crate::task_board::external::{
    ExternalProvider, ExternalSyncClient, ExternalSyncConfig, ExternalTask, ExternalTaskRef,
    normalize_token,
};
use crate::task_board::normalize_repository_slug;
use crate::task_board::types::{TaskBoardItem, TaskBoardStatus};

use super::{
    GitHubRepository, assigned_issue_query, body_lists_child_issues, github_external_id,
    github_inbox_issue_status, graphql, parent_reference_in_body, parse_github_repository,
    review_request_query, search_label_matches_filter, warn_github_message,
};

#[derive(Clone)]
pub struct GitHubInboxSyncClient {
    client: GitHubProtectedClient,
    repositories: Vec<GitHubRepository>,
    import_labels: Vec<String>,
    include_review_requests: bool,
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
        let client = GitHubProtectedClient::new(&token)?;
        let repositories = repositories
            .iter()
            .map(String::as_str)
            .map(parse_github_repository)
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Self {
            client,
            repositories,
            import_labels: import_labels.to_vec(),
            include_review_requests: true,
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

    pub(crate) fn from_config_assigned_only(config: &ExternalSyncConfig) -> Result<Self, CliError> {
        let mut client = Self::from_config(config)?;
        client.include_review_requests = false;
        Ok(client)
    }

    async fn current_user_login(&self) -> Result<String, CliError> {
        self.client.viewer_login().await
    }

    async fn search(
        &self,
        repository: &GitHubRepository,
        kind: GitHubInboxSearchKind,
        login: &str,
    ) -> Result<Vec<graphql::GitHubSearchIssuePullRequestItem>, CliError> {
        let query = kind.query(repository, login);
        graphql::search_issue_pull_requests(&self.client, &query, &kind.context(repository)).await
    }
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

    fn scope_id(&self) -> String {
        self.repositories.first().map_or_else(
            || "inbox".into(),
            |repository| {
                normalize_repository_slug(Some(&repository.slug()))
                    .expect("parsed GitHub repository must have a normalized slug")
            },
        )
    }

    fn scope_for_item(&self, item: &TaskBoardItem) -> String {
        normalize_repository_slug(github_repository_for_item(item))
            .unwrap_or_else(|| self.scope_id())
    }

    fn allows_push(&self) -> bool {
        false
    }

    fn authoritative_review_inbox(&self) -> bool {
        self.include_review_requests
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        if self.repositories.is_empty() {
            return Ok(Vec::new());
        }
        let login = self.current_user_login().await?;
        let mut tasks = Vec::new();
        let mut failures = Vec::new();
        let mut pulled_repository_count = 0_usize;
        for repository in &self.repositories {
            let assigned_tasks = match self.assigned_issue_tasks(repository, login.as_str()).await {
                Ok(assigned_tasks) => assigned_tasks,
                Err(error) => {
                    record_repository_failure(
                        &mut failures,
                        repository,
                        "assigned issue search",
                        &error,
                    );
                    continue;
                }
            };
            pulled_repository_count += 1;
            tasks.extend(assigned_tasks);

            if !self.include_review_requests {
                continue;
            }
            match self.review_request_tasks(repository, login.as_str()).await {
                Ok(review_tasks) => tasks.extend(review_tasks),
                Err(error) => record_repository_failure(
                    &mut failures,
                    repository,
                    "review request search",
                    &error,
                ),
            }
        }
        if pulled_repository_count == 0 && !failures.is_empty() {
            return Err(all_inbox_repositories_failed(failures));
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
            .search(repository, GitHubInboxSearchKind::AssignedIssues, login)
            .await?;
        Ok(items
            .into_iter()
            .filter(|item| search_label_matches_filter(&item.label_names(), &self.import_labels))
            .map(|item| {
                let labels = item.label_names();
                let body = item.body.unwrap_or_default();
                let parent_reference = parent_reference_in_body(repository, &body);
                let tracks_children = body_lists_child_issues(&body);
                ExternalTask {
                    reference: github_task_ref(repository, item.number, item.url),
                    title: item.title,
                    body,
                    status: github_inbox_issue_status(item.state.as_str()),
                    project_id: Some(project_id.clone()),
                    updated_at: Some(item.updated_at),
                    labels,
                    parent_reference,
                    tracks_children,
                }
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
            .search(repository, GitHubInboxSearchKind::ReviewRequests, login)
            .await?;
        Ok(items
            .into_iter()
            .filter(|item| search_label_matches_filter(&item.label_names(), &self.import_labels))
            .map(|item| {
                let labels = item.label_names();
                // A review-requested PR names its tracking issue the same
                // way an issue does ("Part of #N"), so it participates in
                // the same hierarchy rather than always importing as a leaf.
                let body = item.body.unwrap_or_default();
                let parent_reference = parent_reference_in_body(repository, &body);
                let tracks_children = body_lists_child_issues(&body);
                ExternalTask {
                    reference: github_task_ref(repository, item.number, item.url),
                    title: item.title,
                    body,
                    status: TaskBoardStatus::Backlog,
                    project_id: Some(project_id.clone()),
                    updated_at: Some(item.updated_at),
                    labels,
                    parent_reference,
                    tracks_children,
                }
            })
            .collect())
    }
}

fn record_repository_failure(
    failures: &mut Vec<String>,
    repository: &GitHubRepository,
    operation: &str,
    error: &CliError,
) {
    let failure = format!(
        "{} {operation} failed: {}",
        repository.slug(),
        error.message()
    );
    warn_github_message(&format!("skipping GitHub inbox repository {failure}"));
    failures.push(failure);
}

fn all_inbox_repositories_failed(failures: Vec<String>) -> CliError {
    let details = failures
        .into_iter()
        .map(|failure| format!("- {failure}"))
        .collect::<Vec<_>>()
        .join("\n");
    CliErrorKind::workflow_io("task-board github inbox sync failed for all configured repositories")
        .with_details(details)
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum GitHubInboxSearchKind {
    AssignedIssues,
    ReviewRequests,
}

impl GitHubInboxSearchKind {
    fn query(self, repository: &GitHubRepository, login: &str) -> String {
        match self {
            Self::AssignedIssues => assigned_issue_query(repository, login),
            Self::ReviewRequests => review_request_query(repository, login),
        }
    }

    fn context(self, repository: &GitHubRepository) -> String {
        match self {
            Self::AssignedIssues => format!("searching assigned issues in {}", repository.slug()),
            Self::ReviewRequests => format!("searching review requests in {}", repository.slug()),
        }
    }
}

#[cfg(test)]
mod tests;
